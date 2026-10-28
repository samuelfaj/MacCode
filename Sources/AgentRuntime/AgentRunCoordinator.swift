import Foundation
import CoreModel
import CryptoKit
import Darwin
import Persistence
import os

// QA-MAC_AGENT-010: structured run-lifecycle logging so field issues and test
// flakes (start/finish/duration, checkpoint outcomes) are diagnosable. Routes
// through the unified logging system, keyed by thread/run ids.
private let agentRunLog = Logger(subsystem: "io.remotecode.agent", category: "run")

/// Process-local bearer for the exact currently active Agent run. The raw
/// capability is never persisted; the durable orchestration receipt stores only
/// its SHA-256 digest and remains the authority for thread/run/expiry checks.
public struct AgentActiveDelegationCapability: Sendable, Equatable {
    public let threadId: AgentThreadID
    public let runId: AgentRunID
    public let capability: String
    public let expiresAt: Date

    public init(
        threadId: AgentThreadID,
        runId: AgentRunID,
        capability: String,
        expiresAt: Date
    ) {
        self.threadId = threadId
        self.runId = runId
        self.capability = capability
        self.expiresAt = expiresAt
    }
}

private final class PendingProviderStart: @unchecked Sendable {
    let runId: AgentRunID
    let acceptancePermit: AgentRunAcceptancePermit
    private let lock = NSLock()
    private var isComplete = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var settledHandle: AgentRunHandle?
    private var startFailed = false
    private var acceptanceInvalidated = false

    init(runId: AgentRunID, acceptancePermit: AgentRunAcceptancePermit) {
        self.runId = runId
        self.acceptancePermit = acceptancePermit
    }

    func wait(until deadline: Date) async -> Bool {
        if lock.withLock({ isComplete }) { return true }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard !isComplete else { return true }
                waiters[waiterID] = continuation
                return false
            }
            if resumeNow {
                continuation.resume(returning: true)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0, deadline.timeIntervalSinceNow)
            ) { [weak self] in
                self?.resolveWaiter(waiterID, completed: false)
            }
        }
    }

    @discardableResult
    func invalidateAcceptance() -> AgentRunAcceptanceAttempt? {
        let attempt = acceptancePermit.invalidate()
        lock.withLock { acceptanceInvalidated = true }
        return attempt
    }

    func isAcceptanceInvalidated() -> Bool {
        lock.withLock { acceptanceInvalidated }
    }

    func record(handle: AgentRunHandle) {
        lock.withLock { settledHandle = handle }
    }

    func result() -> (handle: AgentRunHandle?, failed: Bool) {
        lock.withLock { (settledHandle, startFailed) }
    }

    func complete() {
        let pending = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            guard !isComplete else { return [] }
            if settledHandle == nil {
                startFailed = true
            }
            isComplete = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume(returning: true) }
    }

    private func resolveWaiter(_ id: UUID, completed: Bool) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.resume(returning: completed)
    }
}

/// Providers use two accounting contracts: Claude can emit independent
/// per-request charges, while final/model usage and Codex/Grok snapshots are
/// cumulative. Keep both tracks so a final receipt reflects the larger
/// reconciled run total without double-counting cumulative updates.
private struct ReconciledTokenUsageAccumulator {
    private(set) var incremental = AssistantTokenUsage(semantics: .incremental)
    private(set) var cumulative = AssistantTokenUsage(semantics: .cumulative)
    private(set) var hasUsage = false

    mutating func record(_ usage: AssistantTokenUsage) {
        hasUsage = true
        switch usage.resolvedSemantics {
        case .incremental:
            incremental = Self.adding(incremental, usage)
        case .cumulative:
            cumulative = AssistantTokenUsage.merging(cumulative, with: usage)
        }
    }

    var effective: AssistantTokenUsage? {
        guard hasUsage else { return nil }
        return AssistantTokenUsage.merging(incremental, with: cumulative)
    }

    private static func adding(
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
        func maxOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
            guard lhs != nil || rhs != nil else { return nil }
            return max(lhs ?? 0, rhs ?? 0)
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
}

private struct PendingOrchestrationReceiptFinalization {
    let runId: AgentRunID
    let threadId: AgentThreadID
    let status: AgentRunStatus
    let usage: AssistantTokenUsage?
    let qualityOutcome: String
}

/// Immutable host-authoritative view of the runs currently registered in the
/// coordinator. The list is sorted by run ID so consumers never inherit
/// dictionary iteration order when choosing a primary run.
public struct ActiveRunProjection: Equatable, Sendable {
    public struct Run: Equatable, Sendable {
        public let threadId: AgentThreadID
        public let runId: AgentRunID

        public init(threadId: AgentThreadID, runId: AgentRunID) {
            self.threadId = threadId
            self.runId = runId
        }
    }

    public let runs: [Run]

    public init(runs: [Run]) {
        self.runs = runs.sorted {
            $0.runId.value.uuidString < $1.runId.value.uuidString
        }
    }

    public var activeRunCount: Int { runs.count }
    public var primaryRunId: AgentRunID? { runs.first?.runId }
}

/// Merge provider launch env with host-injected keys from the pre-route request.
/// Auto-orchestration previously used `launch?.environment ?? request.environment`,
/// which **dropped** host-injected keys when a launch config existed.
public enum AgentHostEnvironmentMerge {
    public static func preserveHostInjects(
        launch: [String: String]?,
        request: [String: String]
    ) -> [String: String] {
        // Start from launch (or request if no launch), strip host-owned keys so a
        // stale value in launch cannot override the authoritative request.
        var env = stripHostInjects(from: launch ?? request)
        for (key, value) in request where isHostInjectedKey(key) {
            env[key] = value
        }
        if launch == nil {
            // Pure request path: still strip-then-reapply so only request host keys remain.
            return env
        }
        return env
    }

    public static func stripHostInjects(from environment: [String: String]) -> [String: String] {
        var env = environment
        for key in environment.keys where isHostInjectedKey(key) {
            env.removeValue(forKey: key)
        }
        return env
    }

    /// Drops the keys the removed Token Saver / Graphify / Distill compression
    /// lanes read (nothing sets them any more, but a value inherited from an
    /// older build's environment must never reach a provider) and the default
    /// managed bin from PATH. Callers that want nested provider proxies put the
    /// managed bin back first.
    public static func scrubLegacyOptimizationKeys(_ environment: [String: String]) -> [String: String] {
        var cleaned = environment
        for key in environment.keys where isLegacyOptimizationKey(key) {
            cleaned.removeValue(forKey: key)
        }
        if let path = cleaned["PATH"] {
            let managedBin = AgentSkillInstaller.defaultManagedCLIBinDirectory().path
            var kept: [String] = []
            for part in path.split(separator: ":") where part != managedBin {
                kept.append(String(part))
            }
            cleaned["PATH"] = kept.joined(separator: ":")
        }
        return cleaned
    }

    static func isLegacyOptimizationKey(_ key: String) -> Bool {
        key.hasPrefix("RC_GRAPHIFY_")
            || key.hasPrefix("RC_TOKEN_SAVER_")
            || key.hasPrefix("RC_DISTILL_")
            || key == "REMOTE_CODE_DISTILL_STATE_PATH"
    }

    public static func isHostInjectedKey(_ key: String) -> Bool {
        isLegacyOptimizationKey(key)
            // Managed Bot and Agent App MCPs receive these exact host-authoritative
            // identity, run, socket, and capability values for the active request.
            || key == BotSelfConfigCatalog.callerEnvironmentKey
            || key == "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"
            || key == BotPeerDelegation.threadEnvironmentKey
            || key == BotPeerDelegation.runEnvironmentKey
            || key == BotPeerDelegation.socketEnvironmentKey
            || key == BotPeerDelegation.capabilityEnvironmentKey
            || key == BotPeerDelegation.turnContextEnvironmentKey
    }
}

public enum ActiveRunProjectionCause: Equatable, Sendable {
    case started
    case finished(AgentRunStatus)
    case launchReconciliation
}

public protocol AgentRunObserver: AnyObject {
    func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID)
    func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?)
    func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID)
}

public struct AgentThreadForkResult: Sendable, Equatable {
    public let thread: AgentThread
    public let prunedThreadIDs: [AgentThreadID]

    public init(thread: AgentThread, prunedThreadIDs: [AgentThreadID]) {
        self.thread = thread
        self.prunedThreadIDs = prunedThreadIDs
    }
}

/// Result of a post-commit thread-retirement attempt. Only `.retired` may
/// clear host-owned runtime state; `.confirmedPresent` means a restored row
/// still owns that state, and `.retryRequired` leaves everything intact.
public enum AgentDeletedThreadRetirementOutcome: Equatable, Sendable {
    case retired
    case confirmedPresent
    case retryRequired
}

public final class AgentRunCoordinator: @unchecked Sendable {
    private func captureCanonicalContextSnapshot(
        threadId: AgentThreadID,
        excludingCurrentUserText: String,
        excludingCurrentUserMessageId: AgentMessageID? = nil
    ) throws -> ConversationContextSnapshot? {
        // PERF: a thread over the seed bound has no snapshot. Read only the
        // newest rows that can prove it instead of hydrating the whole thread.
        // A window that is not full is the whole thread, in the same order.
        let limit = ConversationContextSnapshot.boundedReadLimit
        var messages = try messageRepo.listRecent(threadId: threadId, limit: limit)
        if messages.count >= limit {
            if ConversationContextSnapshot.exceedsItemBound(newestMessages: messages) {
                return nil
            }
            // System rows fill the window: only the whole thread can decide.
            messages = try messageRepo.list(threadId: threadId)
        }
        return ConversationContextSnapshot.capture(
            messages: messages,
            excludingCurrentUserText: excludingCurrentUserText,
            excludingCurrentUserMessageId: excludingCurrentUserMessageId
        )
    }

    /// Distill must not `session/load` a session whose history the new Main
    /// model cannot accept (another model family's unsigned reasoning, or a
    /// history the provider already rejected). Fills the request with what the
    /// persisted session actually ran and, when the adapter will open a new
    /// session, the newest conversation tail for its handoff. Returns the
    /// runtime payload for the pending upsert.
    private func prepareDistillSessionContinuity(
        _ request: inout AgentRunRequest,
        resumeCursor: String,
        runtimePayloadJSON: String?,
        currentUserMessageID: AgentMessageID,
        repo: ProviderSessionRuntimeRepository
    ) -> String? {
        let threadLogId = request.threadId.value.uuidString
        var payload = ProviderSessionRuntimePayload.decode(runtimePayloadJSON)
        var nextPayloadJSON = runtimePayloadJSON
        if payload.distillSessionId != resumeCursor {
            // No accepted prompt recorded for this cursor yet (rows written
            // before acceptance was recorded). The `model` column is the only
            // evidence, and only until this send's pending upsert replaces it
            // with the requested model, so carry it into the payload once.
            do {
                if let model = try repo.sessionModel(of: request.threadId, resumeCursor: resumeCursor) {
                    payload.distillSessionId = resumeCursor
                    payload.distillSessionModel = model
                    nextPayloadJSON = payload.encoded()
                }
            } catch {
                agentRunLog.error(
                    "distill.session_model.probe_failed thread=\(threadLogId, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                emitPersistenceIssue(
                    "provider_session.distill_session_model.read",
                    error: error,
                    runId: request.runId,
                    threadId: request.threadId
                )
            }
        }
        if payload.distillSessionId == resumeCursor {
            request.priorProviderSessionModel = payload.distillSessionModel
        }
        request.priorProviderSessionRetired = payload.distillRetiredSessionIds?.contains(resumeCursor) == true
        guard request.priorProviderSessionRetired
                || DistillACPAdapter.isCrossModelFamilySwitch(
                    from: request.priorProviderSessionModel,
                    to: request.model
                ) else {
            return nextPayloadJSON
        }
        do {
            // +2: the current prompt is already persisted, and one more row
            // tells the handoff that older messages exist.
            request.priorConversationTail = try messageRepo.listRecent(
                threadId: request.threadId,
                limit: DistillACPAdapter.handoffMaxMessages + 2
            ).filter { $0.id != currentUserMessageID && $0.role != .system }
        } catch {
            // The adapter falls back to `contextSnapshot` for the handoff.
            agentRunLog.error(
                "distill.handoff_tail.read_failed thread=\(threadLogId, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            emitPersistenceIssue(
                "agent_messages.distill_handoff_tail.read",
                error: error,
                runId: request.runId,
                threadId: request.threadId
            )
        }
        return nextPayloadJSON
    }

    static func normalizedProviderReasoningEffort(
        provider: AgentProvider,
        model: String,
        requested: AgentReasoningEffort?
    ) -> AgentReasoningEffort? {
        switch provider {
        case .claude:
            return ClaudeRunner.normalizedReasoningEffort(requested, model: model)
        case .grok:
            return requested.flatMap { GrokRunner.normalizedReasoningEffort($0, model: model) }
        case .distill:
            return requested
        case .codex:
            return requested
        }
    }

    private struct ProviderTurnScope: Equatable {
        let provider: String?
        let delegationCapabilitySHA256: String?
        let botID: String?
        let botSecretValues: [String: String]

        init(environment: [String: String]) {
            provider = environment["REMOTE_CODE_AGENT_PROVIDER"]
            delegationCapabilitySHA256 = environment[
                AgentDelegationCapabilityTransport.environmentKey
            ].flatMap {
                AgentDelegationCapabilityTransport.isWellFormed($0)
                    ? AgentDelegationCapability.sha256Hex($0)
                    : nil
            }
            botID = environment[BotSecretEnvironment.botIDEnvironmentKey]
            botSecretValues = environment[BotSecretEnvironment.secretNamesEnvironmentKey]
                .map { marker in
                    marker
                        .split(separator: ",", omittingEmptySubsequences: true)
                        .map(String.init)
                        .filter(BotKeychainSecretStore.isValidName)
                        .reduce(into: [String: String]()) { values, name in
                            if let value = environment[name] {
                                values[name] = value
                            }
                        }
                } ?? [:]
        }

        var carriesHostScope: Bool {
            delegationCapabilitySHA256 != nil || botID != nil
                || !botSecretValues.isEmpty
        }
    }

    private let runRepo: AgentRunRepository
    private let messageRepo: AgentMessageRepository
    private let threadRepo: AgentThreadRepository
    private let providerSessionRepo: ProviderSessionRuntimeRepository?
    private let checkpointRepo: AgentTurnCheckpointRepository?
    private let orchestrationRuntime: AgentOrchestrationRuntime?
    private let providerSnapshotSupplier: (@Sendable () async throws -> [AgentProviderSnapshot])?
    private let botSecretStore: any BotSecretStore
    public var botContextPinForThread: (@Sendable (AgentThreadID) throws -> BotConversationContextPin?)?
    private var providers: [AgentProvider: AgentProviderAdapter]
    private var active: [AgentRunID: AgentRunHandle] = [:]
    private var activeThreads: [AgentThreadID: AgentRunID] = [:]
    /// Raw delegation bearers exist only while this coordinator owns the exact
    /// active run. Durable receipts retain only the digest.
    private var activeDelegationCapabilities: [AgentRunID: (threadId: AgentThreadID, capability: String)] = [:]
    /// Every run-scoped in-memory residue must retain this association while it
    /// exists. Durable rows can cascade away before a late cumulative usage
    /// snapshot or receipt retry is cleared, so those maps cannot reconstruct a
    /// deleted thread safely on their own.
    private var runThreadOwnership: [AgentRunID: AgentThreadID] = [:]
    /// Transient retirement barrier. It is never a tombstone: it exists only
    /// while one coordinator attempt is checking/stopping a deleted thread.
    private var deletedThreadRetirementsInFlight: Set<AgentThreadID> = []
    /// A late callback with no fast ownership first checks its durable graph.
    /// A transient read error may admit that exact callback once, then a bounded
    /// validation retry either confirms its graph or purges the new residue.
    private struct RunCallbackAdmissionLease: Equatable {
        let threadId: AgentThreadID
        let generation: UInt64

        func matches(threadId: AgentThreadID, generation: UInt64) -> Bool {
            self.threadId == threadId && self.generation == generation
        }
    }
    private struct LateRunAdmissionClaim: Equatable {
        let lease: RunCallbackAdmissionLease
        var validationPending: Bool

        func matches(threadId: AgentThreadID, generation: UInt64) -> Bool {
            lease.matches(threadId: threadId, generation: generation)
        }
    }
    private var lateRunAdmissionClaims: [AgentRunID: LateRunAdmissionClaim] = [:]
    private var runCallbackAdmissionLeases: [AgentRunID: RunCallbackAdmissionLease] = [:]
    private var callbackMutationsInFlight: [AgentRunID: Int] = [:]
    private var lateRunAdmissionGeneration: UInt64 = 0
    private static let pendingLateRunValidationLimit = 64
    private static let lateRunValidationRetryBaseDelayNanoseconds: UInt64 = 50_000_000
    private static let lateRunValidationRetryMaximumDelayNanoseconds: UInt64 = 2_000_000_000
    private var lateRunValidationSweepTask: Task<Void, Never>?
    private var lateRunValidationOutageLogged = false
    private var lateRunValidationCapacityLogged = false
    /// Direct/test surfaces may not have AppContext to retain `.retryRequired`.
    /// Keep one coordinator-owned retry driver for that fallback path.
    private var pendingDeletedThreadRetirementRetries: Set<AgentThreadID> = []
    private var deletedThreadRetirementRetryTask: Task<Void, Never>?
    private static let deletedThreadRetirementRetryBaseDelayNanoseconds: UInt64 = 50_000_000
    private static let deletedThreadRetirementRetryMaximumDelayNanoseconds: UInt64 = 2_000_000_000
    private typealias RunMetadata = (provider: AgentProvider, providerInstanceId: String?, model: String, cwd: String, serviceTier: AgentServiceTier, runtimeMode: AgentPermissionMode, interactionMode: AgentInteractionMode, adapterKey: String, binaryIdentity: String?, reasoningEffort: AgentReasoningEffort?, distillMainEffort: AgentEffortSelection?, distillReasoningEffort: AgentEffortSelection?, distillMode: DistillExecutionMode)
    private var activeRunMetadata: [AgentRunID: RunMetadata] = [:]
    /// Process environments are immutable after launch. Resident provider adapters
    /// therefore retain the exact scope of the process that owns their idle session.
    /// A changed attempt/admission scope forces a process refresh before the next turn.
    private var providerTurnScopes: [AgentThreadID: ProviderTurnScope] = [:]
    private var activeTurnIds: [AgentRunID: String] = [:]
    private var latestTokenUsage: [AgentRunID: AssistantTokenUsage] = [:]
    private var reconciledTokenUsage: [AgentRunID: ReconciledTokenUsageAccumulator] = [:]
    /// Closes the narrow window between consuming the current usage snapshot and
    /// persisting the finalized receipt. Events inside the window remain buffered
    /// for a post-finalization enrichment pass.
    private var receiptUsageFinalizationInFlight: Set<AgentRunID> = []
    private var receiptUsageEnrichmentRetryScheduled: Set<AgentRunID> = []
#if DEBUG
    /// Test-only failure/false seam for a late cumulative usage correction.
    /// Production always calls the durable orchestration runtime directly.
    var receiptUsageEnrichmentOverrideForTesting: ((AgentRunID, AssistantTokenUsage) throws -> Bool)?
    /// Test-only durable-read seams for retirement and post-cleanup callbacks.
    /// `true` means the durable graph is present; production queries SQLite.
    var deletedThreadRetirementPresenceOverrideForTesting: ((AgentThreadID) throws -> Bool)?
    var lateRunAdmissionPresenceOverrideForTesting: ((AgentRunID, AgentThreadID) throws -> Bool)?
    var lateRunAdmissionDidReadPresentForTesting: ((AgentRunID, AgentThreadID) -> Void)?
    var runCallbackDidAdmitBeforeMutationForTesting: ((AgentRunID, AgentThreadID) -> Void)?
    var lateRunValidationRetryDelayNanosecondsForTesting: UInt64?
    var deletedThreadRetirementRetryDelayNanosecondsForTesting: UInt64?
    var lateRunValidationSweepStartsForTesting = 0
    /// Seam-only barrier at the current checkpoint capture boundary. The
    /// T-005 correction moves this invocation after terminal callbacks.
    var checkpointEnrichmentBarrierForTesting: ((AgentRunID) async -> Void)?
#endif
    private var pendingReceiptFinalizations: [AgentRunID: PendingOrchestrationReceiptFinalization] = [:]
    private var receiptFinalizationRetryScheduled: Set<AgentRunID> = []
    /// Last provider `.error` (or stderr-derived) detail for the live run. Used when
    /// committing failed/interrupted terminals so `agent_runs.error_message` is not
    /// left nil after an abnormal end.
    private var latestRunErrorMessages: [AgentRunID: String] = [:]
    private var orchestrationDeadlineWorkItems: [AgentRunID: DispatchWorkItem] = [:]
    private var externalReceiptLeaseWorkItems: [AgentRunID: DispatchWorkItem] = [:]
    private var activeAssistantMessageIds: [AgentRunID: AgentMessageID] = [:]
    /// The primary AI selected `reply_only` after interpreting the user turn.
    /// Its peer reply is already durable and attributed, so suppress only this
    /// exact run's later assistant item/final instead of relying on model copy.
    private var replyOnlyPrimaryRuns: Set<AgentRunID> = []
    private var replyOnlyAssistantItemIDs: [AgentRunID: Set<String>] = [:]
    private var finishingRuns: Set<AgentRunID> = []
    /// Provider terminal payloads wait here until the final stream batch crosses
    /// the SQLite durability barrier. A transient writer lock must never let the
    /// terminal row or mirror notification overtake its preceding events.
    private var pendingTerminalEvents: [AgentRunID: PendingTerminalEvent] = [:]
    private var terminalRetryScheduled: Set<AgentRunID> = []
    /// Exact critical-section ownership from the first terminal graph write
    /// through minimal checkpoint identity persistence. Durable stale-release
    /// must not synthesize a callback while this attempt is still authoritative.
    private var terminalCheckpointAttempts: Set<AgentRunID> = []
    /// Single-flight lease for a *detached durability retry*'s terminal commit.
    /// `scheduleTerminalDurabilityRetry` frees its marker when the task is taken, not
    /// when the task returns, and `.finished` re-entry is allowed while final-response
    /// translation is off — so two retries can adopt the same retained event and publish
    /// the terminal twice (test_stopCannotOvertakeTerminalWaitingForDurabilityBarrier:
    /// `.completed` published twice). Only retries take and observe this lease:
    /// `reconcilePendingTerminalBeforeStart` is documented as intentionally synchronous
    /// and outranking the detached retry, so it must never be refused by it.
    private var terminalCommitsInFlight: Set<AgentRunID> = []
    /// A provider start can fail while SQLite is temporarily unavailable. Keep
    /// the complete failure transition until its run/thread/session/error graph
    /// commits; a new run on the same thread must not overtake it.
    private var pendingStartFailures: [AgentRunID: PendingStartFailure] = [:]
    private var startFailureRetryScheduled: Set<AgentRunID> = []
    /// Provider sendTurn calls that have durable pending rows but have not yet
    /// returned a cancellable handle or failed. Destructive waits must not treat
    /// `activeThreads[thread] == nil` as terminal while one of these exists.
    private var pendingProviderStarts: [AgentThreadID: PendingProviderStart] = [:]
    private var pendingThreadStops: Set<AgentThreadID> = []
    /// S5: generation-owned preparation lifecycle for the accept→spawn window.
    /// Stop/Escape applies `.stopRequested` so a late `claimSpawn` cannot write.
    private var preparationStates: [AgentThreadID: ProviderPreparationState] = [:]
    /// Surface claimed prep but `startRun` has not yet registered pendingProviderStarts.
    /// Keyed by runId so a late startRun for run A cannot clear run B's reservation
    /// on the same thread (multi-surface / resend overlap).
    private var reservedProviderStarts: [AgentRunID: AgentThreadID] = [:]
    /// Run-scoped cancels: one thread-level Stop can mark every reserved run so
    /// a late sibling registration cannot spawn after the first consumes
    /// `pendingThreadStops`. Value is the thread so deletion can evict tokens.
    private var cancelledProviderStartRuns: [AgentRunID: AgentThreadID] = [:]
    /// Runs whose destructive caller is waiting for provider/process teardown.
    /// The matching terminal callback is recorded even when markStopRequested
    /// already made the durable run row terminal.
    private var awaitingTerminationRuns: Set<AgentRunID> = []
    private var providerTerminatedRuns: Set<AgentRunID> = []
    private var pendingGracefulStopFallbacks: Set<AgentRunID> = []
    /// Delegated child run → the primary run that spawned it + its own thread
    /// (bot peer consults). Drives the Active Threads badge exclusion, the
    /// user-facing run projection filter, and the Stop cascade.
    struct DelegatedRunLink {
        let parentRunId: AgentRunID
        let threadId: AgentThreadID
    }
    private var delegatedRuns: [AgentRunID: DelegatedRunLink] = [:]
    /// Cascade re-entrancy guard so a (defensive) parent cycle cannot loop stops.
    private var cascadeStopsInFlight: Set<AgentRunID> = []
    /// Run start and native fork must not snapshot one parent concurrently.
    private var exclusiveThreadMutations: Set<AgentThreadID> = []
    /// Relaunch reconciliation for fork intents is asynchronous because the
    /// provider contract is asynchronous. `reconcileOnLaunch` schedules it
    /// after the synchronous run-state repair and tests may await the barrier.
    private var launchForkReconciliationTask: Task<Void, Never>?
    private var seq: [AgentRunID: Int] = [:]
    // PERF-MAC_AGENT-005: reuse one encoder instead of allocating per stream
    // event, and prune on a cadence rather than every event. Encoding is
    // serialized by `streamEventEncoderLock`; callers may encode outside the
    // mirror lock while provider callbacks arrive concurrently.
    private let streamEventEncoderLock = NSLock()
    private let streamEventEncoder = JSONEncoder()
    private var streamEventsSincePrune: [AgentThreadID: Int] = [:]
    private static let streamEventPruneInterval = 25

    private func encodeStreamEvent(_ event: AssistantEvent) throws -> Data {
        streamEventEncoderLock.lock()
        defer { streamEventEncoderLock.unlock() }
        return try streamEventEncoder.encode(event)
    }
    // PERF-MAC_AGENT-007: per-thread buffer of pending stream-event writes plus
    // the timestamp of the last flush, so 2-3 writes/event collapse into batched
    // flushes (see shouldFlushStreamBatch). All touched under `lock`.
    private var pendingStreamWrites: [AgentThreadID: StreamWriteBatch] = [:]
    /// Run ownership for each buffered thread batch. Recovery may snapshot while
    /// `sendTurn` is still returning, before `activeThreads` is registered.
    private var pendingStreamRunIds: [AgentThreadID: AgentRunID] = [:]
    /// A prune requested by a buffered batch remains pending until that same
    /// batch commits. A failed SQLite transaction must not lose the prune intent.
    private var pendingStreamPrunes: Set<AgentThreadID> = []
    private var lastStreamFlushMs: [AgentThreadID: Int64] = [:]
    /// Once a drained batch loses an AssistantEvent, no later snapshot can
    /// honestly certify a watermark for that thread. Retain the first failure
    /// and fail recovery loudly instead of silently advancing iOS past the gap.
    private var mirrorPersistenceFailures: [AgentThreadID: Error] = [:]
    // UX-MAC_AGENT-BG-AWAIT / incomplete-turn: per-thread consecutive auto-continuation
    // count and a monotonic token used to cancel a scheduled continuation when the
    // thread is stopped or a fresh run starts. Both touched under `lock`. Covers
    // background-await stalls and multi-phase workflow handoffs (see
    // IncompleteTurnContinuation) so full-access runs are not left green-"completed"
    // while unfinished.
    private var autoContinuationCounts: [AgentThreadID: Int] = [:]
    private var autoContinuationTokens: [AgentThreadID: Int] = [:]
    /// Consecutive automatic resumes after transient provider network failures.
    private var networkRetryCounts: [AgentThreadID: Int] = [:]
    // PERF-MAC_AGENT-006: last assistant text persisted per thread, to dedup the
    // turnCompleted/finished pair without reloading the whole thread history.
    private var lastPersistedAssistantContent: [AgentThreadID: String] = [:]
    // UX-MAC-CHECKPOINT-REVERT-UNDO: transient snapshot of the most recent
    // checkpoint revert, captured pre-destruction. Non-nil only inside the undo
    // window; cleared on a successful undo. Lock-guarded like other coord state.
    private var lastCheckpointRevertUndo: CheckpointRevertUndo?
    /// Seconds a checkpoint revert stays reversible after it runs.
    public static let checkpointRevertUndoWindow: TimeInterval = 10
    private let lock = NSLock()
    /// Serializes stream-buffer mutation, SQLite flush, and resume-cursor writes
    /// against mirror snapshot capture. Must not be held across observer /
    /// onAssistantEvent fan-out or stopRun — host callbacks can block on main
    /// while the HTTP mirror path waits on this lock. Recursive so nested
    /// flush helpers can re-enter during a snapshot barrier.
    ///
    /// One lock per thread: every holder (stream append/flush, resume-cursor
    /// read, purge, snapshot barrier) is scoped to a single thread id, so a long
    /// flush or snapshot on thread A no longer stalls a paired-device
    /// `agent.thread.read` of thread B.
    private let mirrorEventLocks = MirrorEventLockTable()

    private func mirrorEventLock(for threadId: AgentThreadID) -> NSRecursiveLock {
        mirrorEventLocks.lock(for: threadId)
    }

    #if DEBUG
    func mirrorEventLockForTesting(threadId: AgentThreadID) -> NSRecursiveLock {
        mirrorEventLock(for: threadId)
    }
    #endif
    private static let externalReceiptLeaseRenewalInterval: TimeInterval = 6 * 60 * 60
    private static let externalReceiptLeaseRetryInterval: TimeInterval = 60
    private var observerRefs: [WeakAgentRunObserver] = []
    public var observer: AgentRunObserver? {
        get {
            lock.lock(); defer { lock.unlock() }
            return observerRefs.compactMap(\.value).first
        }
        set {
            if let newValue { addObserver(newValue) }
        }
    }

    /// GAP-7: bridge agent run lifecycle + timeline to the network event
    /// bus so the iOS mirror receives streaming agent output in real
    /// time. Kept as primitive closures (no SocketServer dependency in
    /// this module); AppShell maps them onto EventBus.
    public var onRunStarted: ((AgentThreadID, AgentRunID) -> Void)?
    public var onAssistantEvent: ((AssistantEvent, AgentThreadID, AgentRunID) -> Void)?
    public var onRunFinished: ((AgentThreadID, AgentRunID, AgentRunStatus) -> Void)?
    /// D12: claims the bot VM an auto-continuation runs on; false (a rebuild
    /// or stop holds it) skips the continuation. The release frees a claim
    /// whose continuation did not start.
    public var autoContinuationClaimsBotVM: (@Sendable (AgentThreadID, AgentRunID) async -> Bool)?
    public var autoContinuationReleasesBotVM: (@Sendable (AgentRunID) async -> Void)?
    /// Provider-native terminal acknowledgement used to wake queued work
    /// causally instead of polling resident adapter sessions.
    public var onProviderIdle: ((AgentThreadID) -> Void)?
    /// Fires only after `activeThreads` commits. Consumers can therefore project
    /// aggregate state without racing the provider's async start/finish path.
    public var onActiveRunProjectionChanged: ((ActiveRunProjection, ActiveRunProjectionCause) -> Void)?
    public var onMessageAppended: ((AgentMessage) -> Void)?
    public var onPersistenceIssue: ((String, AgentThreadID, AgentRunID) -> Void)?
    /// Launch-only fork recovery can commit retention victims before AppShell's
    /// router exists. Fired after the child graph transaction commits so the
    /// host can queue and later mirror those authoritative deletions.
    public var onRecoveredForkPrunedThreadIDs: (@Sendable ([AgentThreadID]) async -> Void)?

    /// Host-injected provider admission gate. AppShell owns memory/process policy;
    /// AgentRuntime only enforces its fail-closed decision before any provider
    /// spawn or pending run/message persistence. The default preserves existing
    /// tests and hosts that do not install a policy.
    public var providerAdmissionCheck: @Sendable (AgentProvider, AgentThreadID) async throws -> Void = { _, _ in }

    /// UX-MAC_AGENT-BG-AWAIT: delay before a full-access run that stalled awaiting a
    /// background job is auto-nudged to resume. Gives the background job time to make
    /// progress before the agent polls it. Injectable so tests drive it to ~0.
    public var backgroundAwaitContinuationDelay: TimeInterval = 45
    /// Backoff before each automatic resume of a turn that failed on a transient
    /// network error (e.g. Distill "error decoding response body"). The count
    /// bounds the retries; injectable so tests drive it to ~0.
    public var networkRetryDelays: [TimeInterval] = [10, 30, 60]
    /// AG-002: normal provider shutdown gets two seconds before hard escalation;
    /// deletion never waits beyond five seconds without failing loud.
    var gracefulStopTimeout: TimeInterval = 2
    var hardStopTimeout: TimeInterval = 5

    /// Host environment for RECOVERED sessions. The coordinator rebuilds the run request for a
    /// resumed session itself (`recoverAdapterSessionIfNeeded`), bypassing the app shell's
    /// `providerEnvironment`. Returns the host env vars (Subagents telemetry) to merge for the
    /// given provider; nil/empty => none.
    public var recoveryEnvironmentProvider: (@Sendable (_ provider: AgentProvider, _ threadId: AgentThreadID) async -> [String: String])?
    /// Exact-thread provider environment overlay for every fresh turn. The app
    /// shell uses this to keep thread-scoped host keys out of provider probes
    /// and unrelated threads.
    public var runEnvironmentProvider: (@Sendable (_ provider: AgentProvider, _ threadId: AgentThreadID, _ base: [String: String]) async -> [String: String])?
    /// Fires after the exact run/thread graph is durable and before provider
    /// start. Payload consumers must remain content-free or store only scoped,
    /// retention-governed data.
    public var onRunPrepared: (@Sendable (_ request: AgentRunRequest, _ originalPrompt: String) async -> Void)?
    /// After a successful spawn claim and before `sendTurn`. Tests park here so
    /// Stop can win the pending start's acceptance without racing durable prep.
    var afterSpawnClaimForTesting: (@Sendable (_ request: AgentRunRequest) async -> Void)?
    /// After the post-claim Stop re-check and immediately before `sendTurn`.
    var afterSpawnConfirmForTesting: (@Sendable (_ request: AgentRunRequest) async -> Void)?

    /// Optional durable terminal-transition ledger (write-before-UI). Forensic only.
    public var terminalTransitionLedger: TerminalTransitionLedger?

    public init(
        runRepo: AgentRunRepository,
        messageRepo: AgentMessageRepository,
        threadRepo: AgentThreadRepository,
        providerSessionRepo: ProviderSessionRuntimeRepository? = nil,
        checkpointRepo: AgentTurnCheckpointRepository? = nil,
        orchestrationRuntime: AgentOrchestrationRuntime? = nil,
        providerSnapshotSupplier: (@Sendable () async throws -> [AgentProviderSnapshot])? = nil,
        providers: [AgentProvider: AgentProviderRunner],
        terminalTransitionLedger: TerminalTransitionLedger? = nil,
        botSecretStore: any BotSecretStore = BotKeychainSecretStore()
    ) {
        self.runRepo = runRepo
        self.messageRepo = messageRepo
        self.threadRepo = threadRepo
        self.providerSessionRepo = providerSessionRepo
        self.checkpointRepo = checkpointRepo
        self.orchestrationRuntime = orchestrationRuntime
        self.providerSnapshotSupplier = providerSnapshotSupplier
        self.botSecretStore = botSecretStore
        self.providers = providers.mapValues { OneShotProviderAdapter(runner: $0) }
        self.terminalTransitionLedger = terminalTransitionLedger
    }

    public convenience init(
        runRepo: AgentRunRepository,
        messageRepo: AgentMessageRepository,
        threadRepo: AgentThreadRepository,
        providerSessionRepo: ProviderSessionRuntimeRepository? = nil,
        checkpointRepo: AgentTurnCheckpointRepository? = nil,
        orchestrationRuntime: AgentOrchestrationRuntime? = nil,
        providerSnapshotSupplier: (@Sendable () async throws -> [AgentProviderSnapshot])? = nil,
        providerAdapters: [AgentProvider: AgentProviderAdapter],
        botSecretStore: any BotSecretStore = BotKeychainSecretStore()
    ) {
        self.init(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            checkpointRepo: checkpointRepo,
            orchestrationRuntime: orchestrationRuntime,
            providerSnapshotSupplier: providerSnapshotSupplier,
            providers: [:],
            botSecretStore: botSecretStore
        )
        self.providers = providerAdapters
    }

    public func replaceProvider(_ provider: AgentProvider, runner: AgentProviderRunner) {
        lock.lock(); defer { lock.unlock() }
        providers[provider] = OneShotProviderAdapter(runner: runner)
    }

    public func replaceProviderAdapter(_ provider: AgentProvider, adapter: AgentProviderAdapter) {
        lock.lock(); defer { lock.unlock() }
        providers[provider] = adapter
    }

    public func addObserver(_ observer: AgentRunObserver) {
        lock.lock()
        observerRefs.removeAll { $0.value == nil }
        if !observerRefs.contains(where: { $0.value === observer }) {
            observerRefs.append(WeakAgentRunObserver(observer))
        }
        lock.unlock()
    }

    /// Drop a closed Agent App surface immediately so multi-tab sessions do not
    /// keep fan-out stream/status work onto a disposed view-model until ARC
    /// reaps the weak slot on the next observersSnapshot().
    public func removeObserver(_ observer: AgentRunObserver) {
        lock.lock()
        observerRefs.removeAll { $0.value == nil || $0.value === observer }
        lock.unlock()
    }

#if DEBUG
    func terminalCheckpointAttemptIsActiveForTesting(_ runId: AgentRunID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return terminalCheckpointAttempts.contains(runId)
    }
#endif

    /// Marks orphaned in-process runs/threads interrupted after relaunch.
    /// - Parameter preservingThreadIDs: threads owned by another process
    ///   (e.g. scheduled-task LaunchAgent) that must stay durable-running.
    public func reconcileOnLaunch(preservingThreadIDs: Set<AgentThreadID> = []) throws {
        // Snapshot active runs before reconcile so we can stamp ledger rows.
        let preLaunchActive = (try? runRepo.listActive()) ?? []
        _ = try runRepo.reconcileRunningOnLaunch(preservingThreadIDs: preservingThreadIDs)
        for run in preLaunchActive {
            if preservingThreadIDs.contains(run.threadId) { continue }
            _ = recordTerminalTransition(
                runId: run.id,
                threadId: run.threadId,
                requestedStatus: .interrupted,
                initiator: .relaunchReconcile
            )
        }
        try orchestrationRuntime?.reconcileReceipts(
            statusForRun: { [runRepo] runId in
                try runRepo.status(of: runId)
            },
            usageForRun: { [runRepo] runId in
                guard let threadId = try runRepo.threadId(of: runId) else { return nil }
                // S3: never rehydrate full history on relaunch — bound the scan
                // (newest window + byte budget) so oversized recovery cannot OOM.
                let bound = 64
                let byteBudget: Int64 = 4 * 1024 * 1024
                return try runRepo.listLatestStreamEvents(
                    threadId: threadId,
                    limit: bound,
                    maxPayloadBytes: byteBudget
                )
                    .reversed()
                    .compactMap { event in
                        if case .tokenUsage(let usage) = event { return usage }
                        return nil
                    }
                    .first
            },
            qualityOutcomeForRun: { [messageRepo, runRepo] runId, status in
                guard status == .completed else {
                    return AgentOrchestrationRuntime.qualityOutcome(status: status, finalMessage: nil)
                }
                guard let threadId = try runRepo.threadId(of: runId) else {
                    return AgentOrchestrationRuntime.qualityOutcome(status: status, finalMessage: nil)
                }
                let hasOutput = try messageRepo.hasNonEmptyAssistantMessage(threadId: threadId)
                return hasOutput
                    ? "verified:output-present"
                    : "rejected:missing-output"
            }
        )
        let now = Date()
        // Status + unread + updated_at only. A leftover `list()` of every
        // 26-column + routing row hitchs launch, then `upsert` rewrites routing.
        try threadRepo.reconcileRunningOnLaunch(
            preservingThreadIDs: preservingThreadIDs,
            at: now,
            hasUnread: Self.hasUnread(for: .interrupted)
        )
        if let providerSessionRepo {
            let future = Date.distantFuture
            for session in try providerSessionRepo.list(status: .running, updatedBefore: future) {
                if preservingThreadIDs.contains(session.threadId) { continue }
                // A stale running session on an already-terminal thread is not a
                // relaunch interrupt. Align the session to the thread so pet/open
                // does not show "interrupted by an app restart" for finished work.
                // Status only — a full 26-column + routing `get` hitchs launch.
                let sessionStatus: AgentRunStatus
                if let status = try? threadRepo.status(of: session.threadId),
                   Self.isTerminalThreadStatus(status),
                   status != .interrupted {
                    sessionStatus = status
                } else {
                    sessionStatus = .interrupted
                }
                try providerSessionRepo.markStopped(threadId: session.threadId, status: sessionStatus, at: now)
            }
        }
        onActiveRunProjectionChanged?(ActiveRunProjection(runs: []), .launchReconciliation)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.sweepEphemeralThreadsOnLaunch()
            await self.reconcileForkIntentsOnLaunch()
        }
        lock.lock()
        launchForkReconciliationTask = task
        lock.unlock()
    }

    public func waitForForkReconciliation() async {
        let task = launchForkReconciliationTaskSnapshot()
        await task?.value
    }

    private func launchForkReconciliationTaskSnapshot() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return launchForkReconciliationTask
    }

    public func runStatus(_ runId: AgentRunID) throws -> AgentRunStatus? {
        try runRepo.status(of: runId)
    }

    /// Returns the persisted start time of the active run for `threadId`, or
    /// nil when no active run is recorded.
    /// WHY: the Mac is the host and owns the authoritative run clock; callers
    /// must use this instead of `Date()` so elapsed-time display is correct
    /// even when the view reloads mid-run (e.g. selectThread after app relaunch).
    /// CONTRACT PIN (iOS): iOS must use `agent.run.started` from the host
    /// mirror event (or the `started_at` field in the run record broadcast)
    /// to match this value across the connection.
    public func runStartedAt(threadId: AgentThreadID) throws -> Date? {
        lock.lock()
        let runId = activeThreads[threadId]
        lock.unlock()
        if let runId {
            return try runRepo.timing(of: runId)?.startedAt
        }
        // Path B: LaunchAgent owns the process; durable agent_runs still has the clock.
        return try runRepo.latestActive(for: threadId)?.startedAt
    }

    public func runStartedAt(runId: AgentRunID) throws -> Date? {
        try runRepo.timing(of: runId)?.startedAt
    }

    #if DEBUG
    public let durableActiveRunThreadProbeForTesting = ActivityReceiptsThreadProbe()
    #endif

    /// Durable active run row for a thread, including LaunchAgent-owned sessions
    /// this process does not track in `activeThreads`.
    public func durableActiveRun(threadId: AgentThreadID) throws -> AgentRun? {
        #if DEBUG
        durableActiveRunThreadProbeForTesting.recordCurrentThread()
        #endif
        lock.lock()
        let runId = activeThreads[threadId]
        lock.unlock()
        if let runId, let run = try runRepo.get(id: runId),
           run.status == .pending || run.status == .running {
            return run
        }
        return try runRepo.latestActive(for: threadId)
    }

    /// Existence-only durable active run. Avoids compiling the 10-column
    /// `agent_runs` row (including `error_message`) on Stop-wait / Stop
    /// chrome / desk live-thread discovery that only need pending/running.
    public func hasDurableActiveRun(threadId: AgentThreadID) throws -> Bool {
        #if DEBUG
        durableActiveRunThreadProbeForTesting.recordCurrentThread()
        #endif
        lock.lock()
        let runId = activeThreads[threadId]
        lock.unlock()
        if let runId,
           let status = try runRepo.status(of: runId),
           status == .pending || status == .running {
            return true
        }
        return try runRepo.hasActive(for: threadId)
    }

    /// id + started_at only. Avoids compiling the 10-column `agent_runs` row
    /// (including `error_message`) on LaunchAgent live poll, Working-for
    /// clocks, iOS active-run snapshots, and Stop targeting.
    public func durableActiveRunChrome(threadId: AgentThreadID) throws -> AgentRunRepository.ActiveRunChrome? {
        #if DEBUG
        durableActiveRunThreadProbeForTesting.recordCurrentThread()
        #endif
        lock.lock()
        let runId = activeThreads[threadId]
        lock.unlock()
        if let runId, let chrome = try runRepo.activeRunChrome(of: runId) {
            return chrome
        }
        return try runRepo.latestActiveChrome(for: threadId)
    }

    /// The currently-active run id for a thread (nil when idle). Lets a surface
    /// resync its per-surface `currentRunId` when it switches to an
    /// already-running thread, so Stop targets the right run.
    public func activeRunId(threadId: AgentThreadID) -> AgentRunID? {
        lock.lock(); defer { lock.unlock() }
        return activeThreads[threadId]
    }

    /// Returns the raw bearer only when the in-memory owner, durable receipt,
    /// exact thread/run binding, and lease expiry all still agree.
    public func activeDelegationCapability(
        threadId: AgentThreadID,
        runId: AgentRunID
    ) throws -> AgentActiveDelegationCapability? {
        guard let orchestrationRuntime else { return nil }
        lock.lock()
        let stored = activeThreads[threadId] == runId
            ? activeDelegationCapabilities[runId]
            : nil
        lock.unlock()
        guard let stored, stored.threadId == threadId,
              let receipt = try orchestrationRuntime.activeReceipt(
                runId: runId,
                threadId: threadId,
                delegationCapability: stored.capability
              ),
              let expiresAt = receipt.deadlineAt,
              expiresAt > Date() else {
            return nil
        }
        lock.lock()
        let stillOwned = activeThreads[threadId] == runId
            && activeDelegationCapabilities[runId]?.threadId == threadId
            && activeDelegationCapabilities[runId]?.capability == stored.capability
        lock.unlock()
        guard stillOwned else { return nil }
        return AgentActiveDelegationCapability(
            threadId: threadId,
            runId: runId,
            capability: stored.capability,
            expiresAt: expiresAt
        )
    }

    #if DEBUG
    /// Test-only: the in-memory bind `startRun` writes before the provider
    /// process is up. Lets a rail-prune race inject a live mapping without
    /// waiting on FakeProviderRunner finish.
    public func bindActiveThreadForTesting(threadId: AgentThreadID, runId: AgentRunID) {
        lock.lock()
        activeThreads[threadId] = runId
        lock.unlock()
    }

    /// Test-only: a run's finish still in flight on `threadId` (the terminal
    /// barrier the idle reaper must wait out), or cleared again.
    public func setFinishingRunForTesting(threadId: AgentThreadID, runId: AgentRunID, finishing: Bool) {
        lock.lock()
        if finishing {
            pendingStreamRunIds[threadId] = runId
            finishingRuns.insert(runId)
        } else {
            pendingStreamRunIds.removeValue(forKey: threadId)
            finishingRuns.remove(runId)
        }
        lock.unlock()
    }
    #endif

    /// Records the semantic mode selected by the primary AI's Bot tool call.
    /// This is run-scoped presentation deduplication, not prompt parsing.
    public func suppressPrimaryAssistantReply(runId: AgentRunID) {
        _ = lock.withLock {
            replyOnlyPrimaryRuns.insert(runId)
        }
    }

    /// Only Distill runs inside a bot's Linux guest. A guest thread whose
    /// provider changed (picker, Auto routing) fails before anything is
    /// persisted or spawned: on the Mac it would run outside the guest it
    /// belongs to, with the guest's session cursor.
    static func checkGuestPlacement(provider: AgentProvider, placement: AgentThreadGuestPlacement?) throws {
        guard placement?.runsInGuest == true, provider != .distill else { return }
        throw DistillGuestLaunchError.unavailable(
            "this bot conversation runs inside the bot's Linux VM, which only runs Distill. "
                + "Switch the conversation back to Distill; it will not run on the Mac."
        )
    }

    /// Every run of a guest thread the user moved to the Mac
    /// (`macHandoffPending`) opens a new Mac session until the provider
    /// accepts one: the guest's session cannot load on the Mac. It clears the
    /// thread's cursor and the provider session's resume cursor (idempotent),
    /// and opens the provider prompt with the recent transcript; the
    /// transcript keeps the user's own words. The marker stays until
    /// `completeMacHandoff`, so a start that fails or is stopped before the
    /// provider took the turn hands off again on the next send instead of
    /// opening a Mac session with no context. Legacy `.vm` threads (no
    /// marker) keep their Mac sessions untouched. Returns the handed-off
    /// request, or nil when no handoff is pending.
    func pendingMacHandoff(
        _ request: AgentRunRequest, placement: AgentThreadGuestPlacement?
    ) throws -> AgentRunRequest? {
        guard placement?.macHandoffPending == true else { return nil }
        let recent = try messageRepo.listRecent(threadId: request.threadId, limit: 50)
        let title = try threadRepo.get(id: request.threadId)?.title ?? ""
        try providerSessionRepo?.clearResumeCursor(threadId: request.threadId)
        try threadRepo.updateProviderThreadId(id: request.threadId, providerThreadId: nil)
        agentRunLog.info(
            "bot.guest.mac_handoff thread=\(request.threadId.value.uuidString, privacy: .public)"
        )
        let summary = recent.contains { $0.role == .user || $0.role == .assistant }
            ? AgentThreadHandoff.summary(title: title, threadId: request.threadId, messages: recent)
            : nil
        var handed = AgentRunRequest(
            runId: request.runId,
            threadId: request.threadId,
            provider: request.provider,
            providerInstanceId: request.providerInstanceId,
            model: request.model,
            cwd: request.cwd,
            prompt: summary.map { "\($0)\n\n\(request.prompt)" } ?? request.prompt,
            userMessageContent: summary == nil ? request.userMessageContent : (request.userMessageContent ?? request.prompt),
            attachments: request.attachments,
            providerThreadId: nil,
            permissionMode: request.permissionMode,
            reasoningEffort: request.reasoningEffort,
            reasoningModel: request.reasoningModel,
            distillMainEffortSelection: request.distillMainEffortSelection,
            distillReasoningEffortSelection: request.distillReasoningEffortSelection,
            distillExecutionMode: request.distillExecutionMode,
            serviceTier: request.serviceTier,
            interactionMode: request.interactionMode,
            providerBinary: request.providerBinary,
            environment: request.environment,
            extraArgs: request.extraArgs,
            runAsUser: request.runAsUser,
            acceptancePermit: request.acceptancePermit,
            contextSnapshot: request.contextSnapshot,
            preparedContextSeed: request.preparedContextSeed
        )
        return handed
    }

    /// The provider took the handed-off turn (a Mac session now carries the
    /// summary): the thread stops handing off. A failure to clear only means
    /// the next send hands off once more; it is reported, never thrown.
    private func completeMacHandoff(runId: AgentRunID, threadId: AgentThreadID) {
        do {
            try threadRepo.setGuestRuntime(id: threadId, nil)
        } catch {
            emitPersistenceIssue("agent_threads.guest_runtime.mac_handoff", error: error, runId: runId, threadId: threadId)
        }
    }

    @discardableResult
    public func startRun(
        _ request: AgentRunRequest,
        routingSnapshot: AgentOrchestrationRoutingSnapshot? = nil,
        isAutoContinuation: Bool = false,
        recordUserMessage: Bool = true
    ) async throws -> AgentRunID {
        var normalizedRequest = request
        if let thread = try threadRepo.get(id: request.threadId).map({ try threadRepo.reconcileBotExecutionTarget($0) }),
           thread.actor.botID != nil,
           thread.executionTarget == .vm,
           request.permissionMode != .fullAccess {
            normalizedRequest = AgentRunRequest(
                runId: request.runId,
                threadId: request.threadId,
                provider: request.provider,
                providerInstanceId: request.providerInstanceId,
                model: request.model,
                cwd: request.cwd,
                prompt: request.prompt,
                userMessageContent: request.userMessageContent,
                attachments: request.attachments,
                providerThreadId: request.providerThreadId,
                permissionMode: .fullAccess,
                reasoningEffort: request.reasoningEffort,
                reasoningModel: request.reasoningModel,
                distillMainEffortSelection: request.distillMainEffortSelection,
                distillReasoningEffortSelection: request.distillReasoningEffortSelection,
                distillExecutionMode: request.distillExecutionMode,
                serviceTier: request.serviceTier,
                interactionMode: request.interactionMode,
                providerBinary: request.providerBinary,
                environment: request.environment,
                extraArgs: request.extraArgs,
                runAsUser: request.runAsUser,
                acceptancePermit: request.acceptancePermit,
                contextSnapshot: request.contextSnapshot,
                preparedContextSeed: request.preparedContextSeed
            )
            normalizedRequest.attachToProviderPromptId = request.attachToProviderPromptId
        }
        let forkRecoveryPending = try threadRepo.hasRecoverableForkIntent(sourceThreadId: request.threadId)
        guard !forkRecoveryPending else {
            throw AgentProviderAdapterError.unsupported(
                "provider run start cannot overtake durable fork recovery for this thread"
            )
        }
        try beginExclusiveThreadMutation(request.threadId, operation: "provider run start")
        defer { endExclusiveThreadMutation(request.threadId) }
        // A Stop/terminal callback may have already claimed the old run's
        // terminal slot while SQLite was busy. Its stream tail can commit
        // before the terminal graph retry gets a scheduling turn, leaving the
        // one-shot adapter's summary temporarily `.running`. Drive that
        // retained terminal through the same durability path before checking
        // the provider session; otherwise a valid next turn is rejected even
        // though the prior run's stream is durable. If the barrier is still
        // unavailable, fail closed and let the caller retry rather than ever
        // allowing two in-flight turns on one thread.
        reconcilePendingTerminalBeforeStart(threadId: request.threadId)
        let terminalStillPending = !pendingTerminalRunIds(for: request.threadId).isEmpty
        if terminalStillPending {
            throw NSError(
                domain: "RemoteCode.AgentRunCoordinator",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey:
                    "A prior provider terminal is still waiting for durable persistence."
                ]
            )
        }
        // A Stop that committed durably may leave a one-shot adapter summary still
        // marked running (coordinator-synthesized `.finished` never re-enters the
        // adapter callback). Reconcile only when durable terminal state proves the
        // prior turn is over — never while this thread still owns an active run or
        // a pending terminal durability barrier.
        reconcileGhostLiveProviderSessionIfDurableTerminal(threadId: request.threadId)

        let runId = request.runId
        let pendingProviderStart = PendingProviderStart(
            runId: runId,
            acceptancePermit: request.acceptancePermit ?? AgentRunAcceptancePermit()
        )
        lock.lock()
        let registeredPendingStart: Bool
        if pendingProviderStarts[request.threadId] == nil {
            pendingProviderStarts[request.threadId] = pendingProviderStart
            // Drop only this run's reservation — never a sibling resend's.
            if reservedProviderStarts[runId] == request.threadId {
                reservedProviderStarts.removeValue(forKey: runId)
            }
            // Re-arm thread stop when this exact run was cancelled while reserved
            // (sibling may already have consumed a prior pendingThreadStops entry).
            if cancelledProviderStartRuns.removeValue(forKey: runId) != nil {
                pendingThreadStops.insert(request.threadId)
            }
            rememberRunThreadOwnershipLocked(runId: runId, threadId: request.threadId)
            registeredPendingStart = true
            // S5: accept generation-owned preparation as soon as the start is admitted.
            _ = applyPreparationLocked(
                threadId: request.threadId,
                event: .accept(
                    draftMessageId: request.runId.value.uuidString,
                    atMs: Int64(Date().timeIntervalSince1970 * 1000)
                )
            )
            CapacityGaugeRecorder.shared.noteAcceptStarted(
                threadKey: request.threadId.value.uuidString
            )
            // Prepare boundary = SM preparing (accept).
            CapacityGaugeRecorder.shared.notePrepareStarted(
                threadKey: request.threadId.value.uuidString
            )
            // Stop that raced ahead of accept still wins: cancel prep immediately.
            if pendingThreadStops.contains(request.threadId) {
                _ = applyPreparationLocked(threadId: request.threadId, event: .stopRequested)
            }
        } else {
            registeredPendingStart = false
        }
        lock.unlock()
        guard registeredPendingStart else {
            throw AgentProviderAdapterError.unsupported(
                "Provider start cannot replace another pending start for this thread"
            )
        }
        defer {
            lock.lock()
            if pendingProviderStarts[request.threadId] === pendingProviderStart {
                pendingProviderStarts.removeValue(forKey: request.threadId)
                // Registered-start cancellation is thread-scoped. If this start
                // exits before claimPreparationSpawnOrCancel consumes the stop
                // (e.g. providerAdmissionCheck throws after Stop), drop the
                // marker so a fresh resend is not poisoned.
                pendingThreadStops.remove(request.threadId)
            }
            // S5: any exit from startRun that never claimed spawn must terminalize
            // the accepted generation so isPreparingProviderStart cannot stick.
            if let prep = preparationStates[request.threadId],
               prep.phase == .preparing || prep.phase == .providerStarting {
                _ = applyPreparationLocked(
                    threadId: request.threadId,
                    event: .preparationFailed(
                        generation: prep.generation,
                        reason: .failed
                    )
                )
            }
            discardRunThreadOwnershipIfReleasedLocked(runId)
            lock.unlock()
            pendingProviderStart.complete()
            CapacityGaugeRecorder.shared.noteTerminalized(
                threadKey: request.threadId.value.uuidString
            )
        }
        guard !hasProviderSession(threadId: request.threadId) else {
            throw AgentProviderAdapterError.unsupported("Provider session already has an in-flight turn")
        }
        lock.lock()
        let pendingStartFailureRunIds = pendingStartFailures.compactMap { runId, pending in
            pending.request.threadId == request.threadId ? runId : nil
        }
        lock.unlock()
        for pendingStartFailureRunId in pendingStartFailureRunIds {
            retryStartFailureCommit(runId: pendingStartFailureRunId)
        }
        lock.lock()
        let startFailureStillPending = pendingStartFailures.values.contains {
            $0.request.threadId == request.threadId
        }
        lock.unlock()
        if startFailureStillPending {
            throw NSError(
                domain: "RemoteCode.AgentRunCoordinator",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey:
                    "A prior provider start failure is still waiting for durable persistence."]
            )
        }
        // AG-001: a prior run may have reached a terminal provider state while its
        // mirror batch was blocked by SQLite. Do not admit a new provider run on
        // this thread until that retained batch commits; otherwise the single
        // per-thread buffer would have two owners and the new run's first event
        // could be dropped while retrying the old owner.
        lock.lock()
        let priorBufferedRunId = pendingStreamRunIds[request.threadId]
        lock.unlock()
        if let priorBufferedRunId, priorBufferedRunId != request.runId,
           let error = flushPendingStreamWrites(runId: priorBufferedRunId, threadId: request.threadId) {
            throw error
        }
        let admittedDeadlineAt = routingSnapshot?.admissionSnapshot?.deadlineAt
        let inheritedDelegationCapability = request.environment[
            AgentDelegationCapabilityTransport.environmentKey
        ].flatMap { candidate -> String? in
            guard let orchestrationRuntime,
                  AgentDelegationCapabilityTransport.isWellFormed(candidate),
                  (try? orchestrationRuntime.activeReceipt(
                    runId: request.runId,
                    threadId: request.threadId,
                    delegationCapability: candidate
                  )) != nil else {
                return nil
            }
            return candidate
        }
        let runsAsSocketOwner = (request.runAsUser?.uid ?? getuid()) == getuid()
        let delegationCapability = orchestrationRuntime == nil || !runsAsSocketOwner
            ? nil
            : (inheritedDelegationCapability ?? AgentDelegationCapability.issue())
        let delegationCapabilitySHA256 = delegationCapability.map(
            AgentDelegationCapability.sha256Hex
        )
        let admittedRequest = try await requestAdmittingAutoRoute(
            normalizedRequest,
            routingSnapshot: routingSnapshot,
            delegationCapabilitySHA256: delegationCapabilitySHA256
        )
        // One read serves the Mac handoff and the guest placement check below.
        let guestPlacement = try threadRepo.guestPlacement(of: admittedRequest.request.threadId)
        var macHandoff = try pendingMacHandoff(admittedRequest.request, placement: guestPlacement)
        // Rebuilt requests drop the runtime-only wake label; carry it through.
        let attachPromptId = normalizedRequest.attachToProviderPromptId
        macHandoff?.attachToProviderPromptId = attachPromptId
        var routedRequest = admittedRequest.request
        routedRequest.attachToProviderPromptId = attachPromptId
        if attachPromptId != nil, routedRequest.provider != normalizedRequest.provider {
            throw AgentProviderAdapterError.unsupported(
                "Provider-initiated turn cannot be re-routed to another provider"
            )
        }
        let request = macHandoff ?? routedRequest
        // A user-initiated run ends any background-await auto-continuation streak;
        // the auto-nudge path passes `isAutoContinuation: true` to preserve the bound.
        // F37: it must also invalidate any ALREADY-SCHEDULED continuation (same
        // token bump as markStopRequested) — resetting only the count left the
        // stale nudge armed, so a user prompt that completed within the delay
        // window was followed by an unrequested autonomous "continue" turn built
        // from the old run's metadata.
        if !isAutoContinuation {
            resetAutoContinuationStreak(request.threadId)
            invalidateScheduledAutoContinuation(request.threadId)
        }
        // A Mac handoff starts a new session: nothing of the guest's is resumed.
        let recoveryContext = request.providerThreadId == nil && macHandoff == nil
            ? try recoverableResumeContext(for: request) : nil
        let resumeCursor = request.providerThreadId ?? recoveryContext?.resumeCursor
        // The displayed user message keeps the human text (with its attachment
        // summary); the provider gets the request prompt (already wrapped by
        // Auto admission, or a host-built bot / handoff prompt).
        let preservedUserContent = request.userMessageContent ?? request.prompt
        let outboundPrompt = request.prompt
        var effectiveEnvironment = request.environment
        // Every provider, Distill included, needs the thread's host scope (app
        // socket, caller Bot, thread) or its RemoteCode MCP tools cannot reach the app.
        let scopedEnvironment = await runEnvironmentProvider?(
            request.provider,
            request.threadId,
            request.environment
        ) ?? [:]
        effectiveEnvironment.merge(scopedEnvironment) { _, scoped in scoped }
        let attemptId = request.runId.value.uuidString
        // Parent linkage is lifecycle metadata: nested receipts attach to the
        // actual controller run.
        effectiveEnvironment["RC_REMOTE_CODE_ROOT_RUN_ID"] = attemptId
        effectiveEnvironment["RC_REMOTE_CODE_ATTEMPT_ID"] = attemptId
        if let delegationCapability {
            effectiveEnvironment[
                AgentDelegationCapabilityTransport.environmentKey
            ] = delegationCapability
        } else {
            effectiveEnvironment.removeValue(
                forKey: AgentDelegationCapabilityTransport.environmentKey
            )
        }
        // Secret loading is part of run admission, not desktop-environment
        // shaping. Reload it for every turn so resident provider processes see
        // the exact current Bot values before scope comparison or provider start.
        if try botContextPinForThread?(request.threadId) != nil {
            effectiveEnvironment = BotSecretEnvironment.scrubbingInherited(from: effectiveEnvironment)
        } else {
            effectiveEnvironment = try BotSecretEnvironment.applying(
                to: effectiveEnvironment,
                store: botSecretStore
            )
        }
        let effectiveReasoningEffort = Self.normalizedProviderReasoningEffort(
            provider: request.provider,
            model: request.model,
            requested: request.reasoningEffort
        )
        var effectiveRequest = AgentRunRequest(
            runId: request.runId,
            threadId: request.threadId,
            provider: request.provider,
            providerInstanceId: request.providerInstanceId,
            model: request.model,
            cwd: request.cwd,
            prompt: outboundPrompt,
            userMessageContent: preservedUserContent,
            attachments: request.attachments,
            providerThreadId: resumeCursor,
            permissionMode: recoveryContext?.runtimeMode ?? request.permissionMode,
            reasoningEffort: effectiveReasoningEffort,
            reasoningModel: request.reasoningModel,
            distillMainEffortSelection: request.distillMainEffortSelection,
            distillReasoningEffortSelection: request.distillReasoningEffortSelection,
            distillExecutionMode: request.distillExecutionMode,
            serviceTier: recoveryContext?.serviceTier ?? request.serviceTier,
            interactionMode: recoveryContext?.interactionMode ?? request.interactionMode,
            providerBinary: request.providerBinary,
            environment: effectiveEnvironment,
            extraArgs: request.extraArgs,
            runAsUser: request.runAsUser,
            acceptancePermit: pendingProviderStart.acceptancePermit
        )
        effectiveRequest.attachToProviderPromptId = attachPromptId
        guard let runner = providers[effectiveRequest.provider] else {
            throw AgentRunError.missingBinary(effectiveRequest.provider.rawValue)
        }
        try Self.checkGuestPlacement(provider: effectiveRequest.provider, placement: guestPlacement)
        try await providerAdmissionCheck(effectiveRequest.provider, effectiveRequest.threadId)
        let adapterKey = providerAdapterKey(runner)
        let binaryIdentity = providerBinaryIdentity(effectiveRequest.provider, adapter: runner)
        try refreshProviderProcessIfScopeChanged(runner, request: effectiveRequest)
        let currentUserMessageID = AgentMessageID(effectiveRequest.runId.value)
        let priorSnapshot = try captureCanonicalContextSnapshot(
            threadId: effectiveRequest.threadId,
            excludingCurrentUserText: preservedUserContent,
            excludingCurrentUserMessageId: currentUserMessageID
        )
        // persist user message
        if recordUserMessage {
            let userMsg = AgentMessage(
                id: AgentMessageID(effectiveRequest.runId.value),
                threadId: effectiveRequest.threadId,
                role: .user,
                content: effectiveRequest.userMessageContent ?? effectiveRequest.prompt,
                attachments: effectiveRequest.attachments
            )
            if try messageRepo.exists(id: userMsg.id) == false {
                try messageRepo.append(userMsg)
                onMessageAppended?(userMsg)
            }
        }
        if let priorSnapshot {
            let verified = try captureCanonicalContextSnapshot(
                threadId: effectiveRequest.threadId,
                excludingCurrentUserText: preservedUserContent,
                excludingCurrentUserMessageId: currentUserMessageID
            )
            if verified?.digest == priorSnapshot.digest {
                effectiveRequest.contextSnapshot = priorSnapshot
            }
        }
        // persist run
        let run = AgentRun(id: effectiveRequest.runId, threadId: effectiveRequest.threadId, provider: effectiveRequest.provider, providerInstanceId: effectiveRequest.providerInstanceId, model: effectiveRequest.model, status: .pending)
        try runRepo.upsert(run)
        // Status + unread + updated_at only. A leftover 26-column + routing
        // `get` then `upsert` hitchs every send and rewrites routing JSON.
        try threadRepo.updateStatus(
            id: effectiveRequest.threadId,
            status: .pending,
            hasUnread: false
        )
        if let repo = providerSessionRepo {
            // Payload JSON only. A leftover 16-column session `get`
            // (including cwd/model/status/error) hitchs every send just
            // to copy `runtime_payload_json` into the pending upsert.
            let existingPayload = try repo.runtimePayloadJSON(of: effectiveRequest.threadId)
            var runtimePayloadJSON: String?
            if let existingPayload {
                runtimePayloadJSON = existingPayload
            } else {
                runtimePayloadJSON = ProviderSessionRuntimePayload.decode(nil).encoded()
            }
            if effectiveRequest.provider == .distill,
               let resumeCursor = effectiveRequest.providerThreadId, !resumeCursor.isEmpty {
                runtimePayloadJSON = prepareDistillSessionContinuity(
                    &effectiveRequest,
                    resumeCursor: resumeCursor,
                    runtimePayloadJSON: runtimePayloadJSON,
                    currentUserMessageID: currentUserMessageID,
                    repo: repo
                )
            }
            try repo.upsert(ProviderSessionRuntime(
                threadId: effectiveRequest.threadId,
                provider: effectiveRequest.provider,
                providerInstanceId: effectiveRequest.providerInstanceId,
                adapterKey: adapterKey,
                binaryIdentity: binaryIdentity,
                status: .pending,
                resumeCursor: effectiveRequest.providerThreadId,
                cwd: effectiveRequest.cwd,
                model: effectiveRequest.model,
                serviceTier: effectiveRequest.serviceTier,
                runtimeMode: effectiveRequest.permissionMode,
                lastRunId: effectiveRequest.runId,
                lastEventKind: "run.pending",
                runtimePayloadJSON: runtimePayloadJSON
            ))
        }
        do {
            if let orchestrationRuntime,
               let delegationCapabilitySHA256 {
                _ = try orchestrationRuntime.recordExternalRoot(
                    runId: effectiveRequest.runId,
                    threadId: effectiveRequest.threadId,
                    provider: effectiveRequest.provider,
                    providerInstanceId: effectiveRequest.providerInstanceId ?? effectiveRequest.provider.rawValue,
                    model: effectiveRequest.model,
                    reasoningEffort: effectiveRequest.reasoningEffort,
                    permissionMode: effectiveRequest.permissionMode,
                    delegationCapabilitySHA256: delegationCapabilitySHA256
                )
                scheduleExternalReceiptLeaseRenewal(
                    runId: effectiveRequest.runId,
                    threadId: effectiveRequest.threadId
                )
            }
        } catch {
            // Lifecycle telemetry must not turn a successfully persisted
            // provider run into a hidden retry. Surface the durability issue
            // and let the provider run fail open.
            emitPersistenceIssue(
                "orchestration.root_receipt",
                error: error,
                runId: effectiveRequest.runId,
                threadId: effectiveRequest.threadId
            )
        }
        await onRunPrepared?(effectiveRequest, preservedUserContent)
        // S5: preparationFinished + one-shot claimSpawn under lock. Stop/Escape
        // that arrived during durable prep revokes the generation so sendTurn
        // never starts the provider.
        guard claimPreparationSpawnOrCancel(
            threadId: effectiveRequest.threadId,
            runId: runId
        ) else {
            markStopRequested(threadId: effectiveRequest.threadId, runId: runId)
            throw AgentRunAcceptanceError.cancelled
        }
        await afterSpawnClaimForTesting?(effectiveRequest)
        guard confirmSpawnClaimStillLive(threadId: effectiveRequest.threadId) else {
            markStopRequested(threadId: effectiveRequest.threadId, runId: runId)
            throw AgentRunAcceptanceError.cancelled
        }
        agentRunLog.info("run.started thread=\(effectiveRequest.threadId.value.uuidString, privacy: .public) run=\(effectiveRequest.runId.value.uuidString, privacy: .public) provider=\(effectiveRequest.provider.rawValue, privacy: .public) model=\(effectiveRequest.model, privacy: .public)")

        let coordinator = self
        let handle: AgentRunHandle
        do {
            await afterSpawnConfirmForTesting?(effectiveRequest)
            guard confirmSpawnClaimStillLive(threadId: effectiveRequest.threadId) else {
                markStopRequested(threadId: effectiveRequest.threadId, runId: runId)
                throw AgentRunAcceptanceError.cancelled
            }
            handle = try await runner.sendTurn(effectiveRequest) { ev in
                coordinator.handle(event: ev, runId: runId, threadId: effectiveRequest.threadId)
            }
            // Spawn boundary = first proven provider handle (not pre-sendTurn).
            CapacityGaugeRecorder.shared.noteSpawned(
                threadKey: effectiveRequest.threadId.value.uuidString
            )
            pendingProviderStart.record(handle: handle)
            lock.lock()
            // An adopted wake turn keeps the live process's original scope.
            if effectiveRequest.attachToProviderPromptId == nil {
                providerTurnScopes[effectiveRequest.threadId] = ProviderTurnScope(environment: effectiveRequest.environment)
            }
            lock.unlock()
        } catch {
            lock.lock()
            let gen = preparationStates[effectiveRequest.threadId]?.generation ?? 0
            // claimSpawn already advanced to running; terminalize that generation.
            _ = applyPreparationLocked(
                threadId: effectiveRequest.threadId,
                event: .providerFinished(generation: gen, reason: .providerFailure)
            )
            // Stop revoked this start before the provider accepted the prompt
            // (e.g. while Distill was still opening its session). The start's
            // failure is the Stop itself: a user cancellation, not a run failure.
            let stoppedBeforeAcceptance = pendingProviderStart.isAcceptanceInvalidated()
            if stoppedBeforeAcceptance {
                pendingThreadStops.remove(effectiveRequest.threadId)
            }
            lock.unlock()
            if stoppedBeforeAcceptance {
                markStopRequested(threadId: effectiveRequest.threadId, runId: runId)
                throw AgentRunAcceptanceError.cancelled
            }
            markStartFailure(
                error,
                request: effectiveRequest,
                runId: runId,
                adapterKey: adapterKey,
                binaryIdentity: binaryIdentity,
                preserveRecoverableSession: recoveryContext?.resumeCursor?.isEmpty == false
            )
            throw error
        }
        // `sendTurn` returning is the first provider-independent proof that a
        // handle exists. Keep the pre-handle graph pending, then atomically move
        // every durable projection to running. A provider may already have
        // emitted a terminal event synchronously; never overwrite that state.
        // Status chrome only. A leftover 10-column run get + 26-column thread
        // get+upsert (rewriting routing) hitchs every send after sendTurn.
        do {
            _ = try runRepo.promotePendingStartToRunning(
                runId: runId,
                threadId: effectiveRequest.threadId
            )
        } catch {
            handle.cancel()
            markStartFailure(
                error,
                request: effectiveRequest,
                runId: runId,
                adapterKey: adapterKey,
                binaryIdentity: binaryIdentity,
                preserveRecoverableSession: recoveryContext?.resumeCursor?.isEmpty == false
            )
            throw error
        }
        let terminalStatus = (try? runRepo.status(of: runId)).flatMap { status -> AgentRunStatus? in
            status == .running || status == .pending ? nil : status
        }
        // A turn that already failed did not take the handoff; the next send retries it.
        if macHandoff != nil, terminalStatus != .failed, terminalStatus != .interrupted {
            completeMacHandoff(runId: runId, threadId: effectiveRequest.threadId)
        }
        if terminalStatus == .cancelled {
            handle.cancel()
            return runId
        }
        lock.lock()
        let shouldCancel: Bool
        let activeProjection: ActiveRunProjection?
        if terminalStatus == nil {
            active[runId] = handle
            activeThreads[effectiveRequest.threadId] = runId
            if let delegationCapability {
                activeDelegationCapabilities[runId] = (
                    threadId: effectiveRequest.threadId,
                    capability: delegationCapability
                )
            }
            activeRunMetadata[runId] = (effectiveRequest.provider, effectiveRequest.providerInstanceId, effectiveRequest.model, effectiveRequest.cwd, effectiveRequest.serviceTier, effectiveRequest.permissionMode, effectiveRequest.interactionMode, adapterKey, binaryIdentity, effectiveRequest.reasoningEffort, effectiveRequest.distillMainEffortSelection, effectiveRequest.distillReasoningEffortSelection, effectiveRequest.distillExecutionMode)
            // A runner may emit synchronously before sendTurn returns. Preserve
            // the sequence already assigned to those buffered events instead of
            // resetting it and reusing seq 1 for a different event. Also seed
            // from durable rows so a recovered process cannot collide with
            // already-committed (run_id, seq) identities.
            if seq[runId] == nil {
                let durableHigh = (try? runRepo.maxStreamEventSeq(runId: runId)) ?? 0
                var high = durableHigh
                if pendingStreamRunIds[effectiveRequest.threadId] == runId,
                   let batch = pendingStreamWrites[effectiveRequest.threadId] {
                    high = max(high, batch.highestSeq)
                }
                seq[runId] = high
            }
            shouldCancel = pendingThreadStops.remove(effectiveRequest.threadId) != nil
            activeProjection = activeRunProjectionLocked()
        } else {
            pendingThreadStops.remove(effectiveRequest.threadId)
            shouldCancel = false
            activeProjection = nil
        }
        lock.unlock()
        if let activeProjection {
            onRunStarted?(effectiveRequest.threadId, effectiveRequest.runId)
            onActiveRunProjectionChanged?(activeProjection, .started)
        }
        if terminalStatus == nil {
            scheduleOrchestrationDeadline(admittedDeadlineAt, runId: runId)
        }
        if shouldCancel { handle.cancel() }
        return runId
    }

    /// Re-drive a terminal retained by a previous Stop/provider callback before
    /// admitting another turn on the same thread. This is intentionally
    /// synchronous: the start gate must observe the durability result, not race
    /// the detached retry task that normally services the same barrier.
    private func reconcilePendingTerminalBeforeStart(threadId: AgentThreadID) {
        for runId in pendingTerminalRunIds(for: threadId) {
            guard let pending = pendingTerminalEvent(runId: runId) else { continue }
            handle(
                event: .finished(
                    pending.status,
                    finalMessage: pending.finalMessage,
                    providerThreadId: pending.providerThreadId
                ),
                runId: runId,
                threadId: threadId,
                deduplicatesInFlightFinish: false,
                providerTerminalAcknowledged: pending.providerTerminalAcknowledged
            )
        }
    }

    private func pendingTerminalRunIds(for threadId: AgentThreadID) -> [AgentRunID] {
        lock.lock()
        let runIds = Array(pendingTerminalEvents.keys)
        lock.unlock()
        return runIds.filter { runId in
            (try? runRepo.threadId(of: runId) == threadId) ?? false
        }
    }

    private func pendingTerminalEvent(runId: AgentRunID) -> PendingTerminalEvent? {
        lock.lock()
        defer { lock.unlock() }
        return pendingTerminalEvents[runId]
    }

    private func scheduleOrchestrationDeadline(_ deadlineAt: Date?, runId: AgentRunID) {
        guard let deadlineAt else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isActive = self.active[runId] != nil
            self.lock.unlock()
            if isActive { self.stopRun(runId) }
        }
        lock.lock()
        orchestrationDeadlineWorkItems[runId]?.cancel()
        orchestrationDeadlineWorkItems[runId] = workItem
        lock.unlock()
        let delay = max(0, deadlineAt.timeIntervalSinceNow)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// External receipts use a bounded lease so a crashed provider cannot leave
    /// a permanently active parent. Renew that lease while this coordinator
    /// still owns the provider run; terminal cleanup cancels the heartbeat.
    private func scheduleExternalReceiptLeaseRenewal(
        runId: AgentRunID,
        threadId: AgentThreadID,
        delay: TimeInterval = AgentRunCoordinator.externalReceiptLeaseRenewalInterval
    ) {
        guard orchestrationRuntime != nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let isActive = self.lock.withLock {
                self.active[runId] != nil || self.activeRunMetadata[runId] != nil
            }
            guard isActive, let runtime = self.orchestrationRuntime else {
                self.lock.withLock {
                    self.externalReceiptLeaseWorkItems.removeValue(forKey: runId)
                    self.discardRunThreadOwnershipIfReleasedLocked(runId)
                }
                return
            }
            do {
                _ = try runtime.renewExternalReceiptLease(
                    runId: runId,
                    ownerProcessID: ProcessInfo.processInfo.processIdentifier
                )
                self.scheduleExternalReceiptLeaseRenewal(
                    runId: runId,
                    threadId: threadId
                )
            } catch {
                self.emitPersistenceIssue(
                    "orchestration.receipt.renew_lease",
                    error: error,
                    runId: runId,
                    threadId: threadId
                )
                self.scheduleExternalReceiptLeaseRenewal(
                    runId: runId,
                    threadId: threadId,
                    delay: Self.externalReceiptLeaseRetryInterval
                )
            }
        }
        lock.withLock {
            rememberRunThreadOwnershipLocked(runId: runId, threadId: threadId)
            externalReceiptLeaseWorkItems.removeValue(forKey: runId)?.cancel()
            externalReceiptLeaseWorkItems[runId] = workItem
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(1, delay),
            execute: workItem
        )
    }

    private func requestAdmittingAutoRoute(
        _ request: AgentRunRequest,
        routingSnapshot suppliedSnapshot: AgentOrchestrationRoutingSnapshot?,
        delegationCapabilitySHA256: String?
    ) async throws -> (request: AgentRunRequest, autoRoute: AgentOrchestrationRoute?) {
        let routingSnapshot: AgentOrchestrationRoutingSnapshot
        if let suppliedSnapshot {
            if suppliedSnapshot.providerSnapshots.isEmpty,
               let providerSnapshotSupplier {
                routingSnapshot = AgentOrchestrationRoutingSnapshot(
                    configuration: suppliedSnapshot.configuration,
                    providerSnapshots: try await providerSnapshotSupplier(),
                    launchConfigurations: suppliedSnapshot.launchConfigurations,
                    admissionSnapshot: suppliedSnapshot.admissionSnapshot
                )
            } else {
                routingSnapshot = suppliedSnapshot
            }
        } else {
            // Routing row only. A leftover 26-column `get` (plus routing JSON)
            // hitchs scheduled / snapshot-less starts just to test Auto mode.
            guard let routing = try threadRepo.routingConfiguration(of: request.threadId),
                  routing.mode == .auto else {
                return (request, nil)
            }
            guard let providerSnapshotSupplier else {
                throw AgentOrchestrationAdmissionError.noEligibleProvider
            }
            routingSnapshot = AgentOrchestrationRoutingSnapshot(
                configuration: routing,
                providerSnapshots: try await providerSnapshotSupplier()
            )
        }
        guard routingSnapshot.configuration.mode == .auto else {
            return (request, nil)
        }
        guard let orchestrationRuntime else {
            // No orchestration runtime: still never switch provider — DEEP on Source.
            return (try Self.autoDeepFallbackRequest(
                request,
                configuration: routingSnapshot.configuration,
                providerSnapshots: routingSnapshot.providerSnapshots,
                launchConfigurations: routingSnapshot.launchConfigurations
            ), nil)
        }
        do {
            let admission = try orchestrationRuntime.admit(
                runId: request.runId,
                threadId: request.threadId,
                configuration: routingSnapshot.configuration,
                providerSnapshots: routingSnapshot.providerSnapshots,
                interactionMode: request.interactionMode,
                permissionMode: request.permissionMode,
                attachments: request.attachments,
                receiptId: routingSnapshot.admissionSnapshot?.admissionReceiptId,
                deadlineAt: routingSnapshot.admissionSnapshot?.deadlineAt,
                budgetTokens: routingSnapshot.admissionSnapshot?.budgetTokens,
                budgetCostMicros: routingSnapshot.admissionSnapshot?.budgetCostMicros,
                reservationId: routingSnapshot.admissionSnapshot?.reservationId,
                reservedTokens: routingSnapshot.admissionSnapshot?.reservedTokens,
                reservedCostMicros: routingSnapshot.admissionSnapshot?.reservedCostMicros,
                delegationCapabilitySHA256: delegationCapabilitySHA256
            )
            let launch = routingSnapshot.launchConfigurations[admission.route.providerInstanceId]
            // Display the user's words unchanged; wrap only the provider-bound prompt
            // so Auto always enters $remote-code-orchestrate with the host receipt
            // the app already admitted (provider/model) — skill must not re-guess.
            let displayPrompt = request.userMessageContent ?? request.prompt
            let orchestratedPrompt = admission.route.provider == .distill
                ? request.prompt
                : AgentOrchestrationRuntime.autoOrchestrateProviderPrompt(
                    userPrompt: request.prompt,
                    admittedRoute: admission.route
                )
            return (AgentRunRequest(
                runId: request.runId,
                threadId: request.threadId,
                provider: admission.route.provider,
                providerInstanceId: admission.route.providerInstanceId,
                model: admission.route.selection.effectiveModel,
                cwd: request.cwd,
                prompt: orchestratedPrompt,
                userMessageContent: displayPrompt,
                attachments: request.attachments,
                providerThreadId: request.providerThreadId,
                permissionMode: request.permissionMode,
                reasoningEffort: admission.route.selection.reasoningEffort,
                reasoningModel: request.reasoningModel,
                distillMainEffortSelection: admission.route.provider == .distill
                    ? admission.route.selection.distillMainEffortSelection : nil,
                distillReasoningEffortSelection: admission.route.provider == .distill
                    ? admission.route.selection.distillReasoningEffortSelection : nil,
                distillExecutionMode: admission.route.provider == .distill
                    ? admission.route.selection.distillExecutionMode : .normal,
                serviceTier: admission.route.selection.serviceTier,
                interactionMode: request.interactionMode,
                providerBinary: launch?.binary ?? request.providerBinary,
                environment: AgentHostEnvironmentMerge.preserveHostInjects(
                    launch: launch?.environment,
                    request: request.environment
                ),
                extraArgs: request.extraArgs,
                runAsUser: request.runAsUser
            ), admission.route)
        } catch let error as AgentOrchestrationAdmissionError {
            // Same-host only. Orchestration gates may drop the skill wrap and
            // use DEEP; never switch Claude → Codex (or any other cross-host).
            switch error {
            case .packageUnavailable, .rolloutDisabled, .killSwitchEnabled, .invalidPolicy:
                return (try Self.autoDeepFallbackRequest(
                    request,
                    configuration: routingSnapshot.configuration,
                    providerSnapshots: routingSnapshot.providerSnapshots,
                    launchConfigurations: routingSnapshot.launchConfigurations,
                    runtime: orchestrationRuntime
                ), nil)
            case .preferredSourceUnavailable, .noEligibleProvider, .invalidRoutingMode,
                 .deadlineExpired, .invalidBudget, .costBudgetUnavailable, .quotaExceeded,
                 .receiptPersistenceFailed, .invalidChildAdmission:
                throw error
            }
        }
    }

    /// Auto without orchestration: bind Source picker host to DEEP (opus/sol/grok-4.6 high).
    private static func autoDeepFallbackRequest(
        _ request: AgentRunRequest,
        configuration: AgentRoutingConfiguration,
        providerSnapshots: [AgentProviderSnapshot],
        launchConfigurations: [String: AgentOrchestrationLaunchConfiguration],
        runtime: AgentOrchestrationRuntime? = nil
    ) throws -> AgentRunRequest {
        let route: AgentOrchestrationRoute
        if let runtime {
            route = try runtime.routeDeepFallback(
                configuration: configuration,
                providerSnapshots: providerSnapshots
            )
        } else {
            let preferred = configuration.manualSelection.provider
            guard let snapshot = AgentOrchestrationRuntime.autoAdmitSnapshot(
                provider: preferred,
                preferredInstanceId: configuration.manualProviderInstanceId,
                providerSnapshots: providerSnapshots,
                requireLiveCatalog: false
            ) else {
                throw AgentOrchestrationAdmissionError.preferredSourceUnavailable(
                    preferred,
                    detail: AgentOrchestrationRuntime.preferredSourceUnavailabilityDetail(
                        provider: preferred,
                        preferredInstanceId: configuration.manualProviderInstanceId,
                        providerSnapshots: providerSnapshots
                    )
                )
            }
            let selection = AgentOrchestrationRuntime.deepControllerSelection(
                provider: preferred,
                availableModels: snapshot.models
            )
            route = AgentOrchestrationRoute(
                provider: preferred,
                providerInstanceId: snapshot.id,
                capabilitySnapshotId: "deep-fallback",
                selection: selection
            )
        }
        let launch = launchConfigurations[route.providerInstanceId]
        let displayPrompt = request.userMessageContent ?? request.prompt
        // No $remote-code-orchestrate — single-agent DEEP on the selected Source.
        return AgentRunRequest(
            runId: request.runId,
            threadId: request.threadId,
            provider: route.provider,
            providerInstanceId: route.providerInstanceId,
            model: route.selection.effectiveModel,
            cwd: request.cwd,
            prompt: request.prompt,
            userMessageContent: displayPrompt,
            attachments: request.attachments,
            providerThreadId: request.providerThreadId,
            permissionMode: request.permissionMode,
            reasoningEffort: route.selection.reasoningEffort,
            reasoningModel: request.reasoningModel,
            serviceTier: route.selection.serviceTier,
            interactionMode: request.interactionMode,
            providerBinary: launch?.binary ?? request.providerBinary,
            environment: AgentHostEnvironmentMerge.preserveHostInjects(
                launch: launch?.environment,
                request: request.environment
            ),
            extraArgs: request.extraArgs,
            runAsUser: request.runAsUser
        )
    }

    public func stopRun(_ runId: AgentRunID) {
        lock.lock()
        let threadId = activeThreads.first(where: { $0.value == runId })?.key
            ?? pendingProviderStarts.first(where: { $0.value.runId == runId })?.key
        if let owner = reservedProviderStarts.removeValue(forKey: runId) {
            cancelledProviderStartRuns[runId] = owner
        }
        let handle = active[runId]
        lock.unlock()
        if let threadId {
            stopRun(threadId: threadId)
        } else {
            handle?.cancel()
            // Even without a live thread mapping, delegated children of this
            // run must not survive it (bot peers spawned by a stopped host).
            stopDelegatedChildRuns(of: runId)
        }
    }

    /// Returns the durable status the F19 guard read when Stop had nothing to
    /// interrupt; nil on every path that touched state. The guard returns before
    /// writing anything, so a repaint that runs right after this call can take
    /// the value instead of paying a second single-column probe.
    @discardableResult
    public func stopRun(threadId: AgentThreadID) -> AgentRunStatus? {
        // RPC/iOS Stop must cancel surface-preflight reservations even when no
        // durable/pending/active run exists yet (surface preparation window).
        cancelPreparation(threadId: threadId)
        lock.lock()
        let runId = activeThreads[threadId]
        let handle = runId.flatMap { active[$0] }
        let pendingStart = pendingProviderStarts[threadId]
        lock.unlock()
        // Stop cascades to delegated bot-peer runs on every exit path: a host
        // stopped mid `bot_ask_peer` must not leave its workers running with
        // spinners pinned in Active Threads / Bots.
        defer {
            if let runId { stopDelegatedChildRuns(of: runId) }
        }
        _ = pendingStart?.invalidateAcceptance()
        if let runId, let handle {
            // Claim userStop before interrupt/cancel callbacks can persist a
            // provider-acknowledged cancellation over the user's Stop.
            markStopRequested(threadId: threadId, runId: runId)
            var deliveredNativeInterrupt = false
            if let adapter = try? adapterForThread(threadId) {
                lock.lock()
                pendingGracefulStopFallbacks.insert(runId)
                lock.unlock()
                do {
                    try adapter.interruptTurn(threadId: threadId)
                    deliveredNativeInterrupt = true
                } catch {
                    lock.lock()
                    pendingGracefulStopFallbacks.remove(runId)
                    providerTerminatedRuns.remove(runId)
                    lock.unlock()
                    deliveredNativeInterrupt = false
                }
            }
            if deliveredNativeInterrupt {
                // Provider-native interrupt must reach the live session before
                // handle cancellation can close its transport. Bound the grace
                // period, then force the exact still-active run if no terminal
                // callback arrived.
                let grace = max(0, gracefulStopTimeout)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [weak self, handle] in
                    guard let self else { return }
                    self.lock.lock()
                    self.pendingGracefulStopFallbacks.remove(runId)
                    let providerAcknowledged = self.providerTerminatedRuns.remove(runId) != nil
                    self.lock.unlock()
                    if !providerAcknowledged { handle.cancel() }
                }
            } else {
                handle.cancel()
            }
            return nil
        }
        // F19: nothing to stop unless the thread is actually running/pending. A
        // second Stop click, or a stop for a long-finished thread, previously fell
        // into the session/recover branches below and either re-broadcast a
        // spurious `.cancelled` (phantom "Thread cancelled" notification, queued
        // messages drained unprompted) or respawned a provider process for a dead
        // thread just to interrupt it. Guard BEFORE touching adapter sessions.
        // Status-only: do not compile the 26-column + routing get.
        let durableStatus = try? threadRepo.status(of: threadId)
        let hasDurableRunningState = durableStatus == .running || durableStatus == .pending
        guard hasDurableRunningState || pendingStart != nil else {
            lock.lock()
            pendingThreadStops.remove(threadId)
            lock.unlock()
            return durableStatus
        }
        if pendingStart != nil && !hasDurableRunningState {
            lock.lock()
            _ = applyPreparationLocked(threadId: threadId, event: .stopRequested)
            pendingThreadStops.insert(threadId)
            lock.unlock()
            return nil
        }
        if let adapter = try? adapterForThread(threadId), adapter.hasSession(threadId: threadId) {
            do {
                try adapter.stopSession(threadId: threadId)
                markStopRequested(threadId: threadId, runId: nil)
                return nil
            } catch {
                // One-shot runners can expose a session before the local run handle exists.
                // Keep the pending stop so handle registration cancels the run.
            }
        }
        if let adapter = try? adapterForThread(threadId), !adapter.hasSession(threadId: threadId) {
            // recoverAdapterSessionIfNeeded is now async (its provider-session
            // recovery no longer blocks the caller on a semaphore). stopRun must
            // stay synchronous for its many non-async callers, so drive the
            // best-effort recover-then-interrupt off the calling thread. The
            // synchronous pendingThreadStops fall-through below remains the stop
            // guarantee; the interrupt here is best-effort exactly as before.
            //
            // Only attempted when there is NO live session: a session that exists
            // without a registered handle is the one-shot-before-handle race, and
            // its interrupt would throw sessionNotFound. That case must fall
            // through to the synchronous pendingThreadStops insertion below so
            // handle registration cancels the run -- it must NOT early-return.
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.recoverAdapterSessionIfNeeded(threadId: threadId, adapter: adapter)
                    if adapter.hasSession(threadId: threadId) {
                        try adapter.interruptTurn(threadId: threadId)
                        // F19: the session was recovered only to deliver the
                        // interrupt — do not leave the respawned provider
                        // process resident after a stop. markStopRequested is
                        // NOT repeated here: the synchronous fall-through below
                        // already broadcast the cancel for this stop.
                        try? adapter.stopSession(threadId: threadId)
                    }
                } catch {
                    // Pending cancellation (recorded synchronously below) covers this;
                    // startRun will fail loudly if recovered state is insufficient.
                }
            }
        }
        lock.lock()
        _ = applyPreparationLocked(threadId: threadId, event: .stopRequested)
        pendingThreadStops.insert(threadId)
        lock.unlock()
        markStopRequested(threadId: threadId, runId: nil)
        return nil
    }

    /// Stop a thread and do not return until the provider has acknowledged a
    /// terminal state and every process captured from its tree is dead. A normal
    /// cancel gets a two-second grace window; hard escalation is bounded by the
    /// five-second deadline. Destructive callers must abort deletion on error.
    public func stopAndAwaitTermination(threadId: AgentThreadID) async throws {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(hardStopTimeout)
        var awaitingRunIds = Set<AgentRunID>()
        var settledPendingStart: PendingProviderStart?
        defer {
            lock.lock()
            for runId in awaitingRunIds {
                awaitingTerminationRuns.remove(runId)
                providerTerminatedRuns.remove(runId)
            }
            lock.unlock()
        }

        // A provider write may already be claimed while sendTurn has not yet
        // returned its handle. Record the pending run before stopping so a
        // synchronous terminal callback counts as provider acknowledgement,
        // then wait causally for handle registration/start failure.
        while true {
            lock.lock()
            let pendingStart = pendingProviderStarts[threadId]
            if let pendingStart {
                awaitingTerminationRuns.insert(pendingStart.runId)
                awaitingRunIds.insert(pendingStart.runId)
            }
            lock.unlock()
            guard let pendingStart else { break }
            stopRun(threadId: threadId)
            guard await pendingStart.wait(until: deadline) else {
                throw terminationTimeoutError(
                    threadId: threadId,
                    survivingPIDs: [],
                    providerSessionAlive: hasProviderSession(threadId: threadId)
                )
            }
            settledPendingStart = pendingStart
        }

        lock.lock()
        let activeRunId = activeThreads[threadId]
        let activeHandle = activeRunId.flatMap { active[$0] }
        let pendingResult = settledPendingStart?.result()
        lock.unlock()
        let durableRun = try durableActiveRunChrome(threadId: threadId)
        let runId = activeRunId
            ?? (pendingResult?.failed == true ? nil : settledPendingStart?.runId)
            ?? durableRun?.id
        let handle = activeHandle ?? pendingResult?.handle
        // A pending start that settled without a handle (admission or sendTurn
        // threw) launched no provider turn to acknowledge; only durable rows,
        // preparation and an adapter session can still be live, and the
        // durable branch below waits for exactly those.
        let pendingStartLaunched = settledPendingStart != nil && pendingResult?.failed != true
        let awaitsInMemoryProvider = activeRunId != nil || activeHandle != nil || pendingStartLaunched
        if let runId {
            lock.lock()
            awaitingTerminationRuns.insert(runId)
            awaitingRunIds.insert(runId)
            lock.unlock()
        }

        let adapter = try? adapterForThread(threadId)
        var processTracker: ProcessTerminator.TreeTracker? = {
            guard let process = handle?.process, process.processIdentifier > 0 else { return nil }
            return ProcessTerminator.TreeTracker(root: process.processIdentifier)
        }()
        var escalated = false

        stopRun(threadId: threadId)
        while true {
            lock.lock()
            let providerTerminated = runId.map(providerTerminatedRuns.contains) ?? false
            let pendingStill = pendingProviderStarts[threadId] != nil
            lock.unlock()
            processTracker?.refresh()
            let survivingPIDs = processTracker?.survivingPIDs() ?? []
            let processTreeDead = survivingPIDs.isEmpty
            let durableStillActive = try hasDurableActiveRun(threadId: threadId)
            let preparing = isPreparingProviderStart(threadId: threadId)
            let providerSessionAlive = adapter.map {
                providerSessionIsLive($0, threadId: threadId)
            } ?? false

            // Terminal adapters can intentionally retain resumable sessions.
            // Deletion is different: once terminal is confirmed, release that
            // session before certifying that no provider child work remains.
            if (providerTerminated || processTreeDead),
               adapter?.hasSession(threadId: threadId) == true {
                try? adapter?.stopSession(threadId: threadId)
            }
            if awaitsInMemoryProvider {
                let terminationConfirmed = providerTerminated
                    || (processTracker != nil && processTreeDead)
                if terminationConfirmed && processTreeDead && !providerSessionAlive {
                    return
                }
            } else if !durableStillActive && !preparing && !pendingStill
                        && !providerSessionAlive && processTreeDead {
                return
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            if !escalated && elapsed >= gracefulStopTimeout {
                escalated = true
                processTracker?.signalSurvivors(SIGTERM)
                handle?.cancel()
                try? adapter?.stopSession(threadId: threadId)
            }
            if escalated && elapsed >= gracefulStopTimeout + 0.25 {
                // Refresh immediately before KILL. This includes children born
                // during TERM handling and members reparented out of the tree.
                processTracker?.refresh()
                processTracker?.signalSurvivors(SIGKILL)
            }
            if Date() >= deadline {
                throw terminationTimeoutError(
                    threadId: threadId,
                    survivingPIDs: survivingPIDs,
                    providerSessionAlive: providerSessionAlive
                )
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func terminationTimeoutError(
        threadId: AgentThreadID,
        survivingPIDs: [pid_t],
        providerSessionAlive: Bool
    ) -> NSError {
        let pidList = survivingPIDs.map(String.init).joined(separator: ",")
        let survivingPIDDescription = pidList.isEmpty ? "none" : pidList
        return NSError(
            domain: "RemoteCode.AgentRunCoordinator",
            code: 504,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Provider for thread \(threadId.value.uuidString) did not terminate within " +
                    "\(hardStopTimeout)s (surviving pids: \(survivingPIDDescription), " +
                    "session alive: \(providerSessionAlive))."
            ]
        )
    }

    /// Starts every provider stop before awaiting any one thread. Each member
    /// shares the same wall-clock stop window, and callers mutate durable rows
    /// only after the whole batch confirms termination.
    public func stopAndAwaitTermination(threadIds: [AgentThreadID]) async throws {
        var seen: Set<AgentThreadID> = []
        let ordered = threadIds.filter { seen.insert($0).inserted }
        let failures = await withTaskGroup(
            of: (AgentThreadID, String?).self,
            returning: [(AgentThreadID, String)].self
        ) { group in
            for threadId in ordered {
                group.addTask { [self] in
                    do {
                        try await stopAndAwaitTermination(threadId: threadId)
                        return (threadId, nil)
                    } catch {
                        return (threadId, error.localizedDescription)
                    }
                }
            }
            var failures: [(AgentThreadID, String)] = []
            for await (threadId, failure) in group {
                if let failure { failures.append((threadId, failure)) }
            }
            return failures.sorted { $0.0.value.uuidString < $1.0.value.uuidString }
        }
        guard !failures.isEmpty else { return }
        let details = failures
            .map { "\($0.0.value.uuidString): \($0.1)" }
            .joined(separator: "; ")
        throw NSError(
            domain: "RemoteCode.AgentRunCoordinator.TerminationBatch",
            code: 504,
            userInfo: [NSLocalizedDescriptionKey: "Provider termination failed for \(failures.count) thread(s): \(details)"]
        )
    }

    /// Provider-authoritative busy state. This remains true when a surface or
    /// coordinator projection is stale but the adapter still owns a live turn.
    public func hasProviderSession(threadId: AgentThreadID) -> Bool {
        // SwiftUI bodies call this on MainActor. Without any live adapter turn
        // the answer is false, so skip the SQLite provider lookup that waits
        // behind long Activity reads on the shared read connection.
        lock.lock()
        let adapters = Array(providers.values)
        lock.unlock()
        guard adapters.contains(where: { providerSessionIsLive($0, threadId: threadId) }) else { return false }
        guard let adapter = try? adapterForThread(threadId) else { return false }
        return providerSessionIsLive(adapter, threadId: threadId)
    }

    /// True after durable pending state is committed and before the provider
    /// returns a cancellable handle (or fails). Router admission must treat this
    /// window as active even when the adapter has not registered a session yet.
    public func hasPendingProviderStart(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingProviderStarts[threadId] != nil
    }

    /// S5: true while accept→spawn preparation is live (preparing/providerStarting).
    public func isPreparingProviderStart(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let phase = preparationStates[threadId]?.phase else { return false }
        return phase == .preparing || phase == .providerStarting
    }

    /// Snapshot of preparation phase for tests / UI accessibility.
    public func preparationPhase(threadId: AgentThreadID) -> ProviderPreparationPhase? {
        lock.lock(); defer { lock.unlock() }
        return preparationStates[threadId]?.phase
    }

    /// S5: Stop/Escape cancels generation-owned preparation and arms pending stop
    /// so a late claimSpawn/sendTurn cannot start the provider.
    /// Arms `pendingThreadStops` only when a pending start or surface reservation
    /// exists — a preparation-only cancel before claim must not poison resend.
    /// Invalidates the pending start's acceptance permit under the coordinator
    /// lock so a concurrent `withAcceptance` cannot claim after Stop is recorded.
    public func cancelPreparation(threadId: AgentThreadID) {
        lock.lock()
        let pendingStart = pendingProviderStarts[threadId]
        // Invalidate before unlock so a concurrent withAcceptance cannot
        // claim a still-pending permit after Stop is recorded.
        _ = pendingStart?.invalidateAcceptance()
        _ = applyPreparationLocked(threadId: threadId, event: .stopRequested)
        // Per-run cancel tokens so one Stop cancels every reserved run. Do not
        // arm thread-level pendingThreadStops for reservation-only gaps — a
        // fresh resend reserved after Stop must not consume a stale thread stop.
        // PERF: single pass — collect this thread's runs, then move them (was
        // filter + re-filter: two full scans plus two intermediate dictionaries).
        var stoppedRunIds: [AgentRunID] = []
        for (runId, owner) in reservedProviderStarts where owner == threadId {
            stoppedRunIds.append(runId)
        }
        for runId in stoppedRunIds {
            reservedProviderStarts.removeValue(forKey: runId)
            cancelledProviderStartRuns[runId] = threadId
        }
        if pendingStart != nil {
            pendingThreadStops.insert(threadId)
        }
        lock.unlock()
    }

    /// Surface finished its preparation claim and is about to call startRun. Stop in the
    /// gap must arm pendingThreadStops so registration cannot spawn.
    /// Reservation is run-scoped so late registration of a cancelled run cannot
    /// clear a concurrent resend reservation on the same thread.
    public func reserveProviderStart(threadId: AgentThreadID, runId: AgentRunID) {
        lock.lock()
        reservedProviderStarts[runId] = threadId
        // A fresh reserve is a new attempt — clear any stale cancel token for this run.
        cancelledProviderStartRuns.removeValue(forKey: runId)
        lock.unlock()
    }

    public func releaseProviderStartReservation(threadId: AgentThreadID, runId: AgentRunID) {
        lock.lock()
        if reservedProviderStarts[runId] == threadId {
            reservedProviderStarts.removeValue(forKey: runId)
        }
        cancelledProviderStartRuns.removeValue(forKey: runId)
        lock.unlock()
    }

    /// Local Stop abandoned this run without startRun — drop cancel tokens so
    /// process-lifetime state does not grow from cancelled preflights.
    public func discardProviderStartReservation(threadId: AgentThreadID, runId: AgentRunID) {
        lock.lock()
        if reservedProviderStarts[runId] == threadId {
            reservedProviderStarts.removeValue(forKey: runId)
        }
        if cancelledProviderStartRuns[runId] == threadId {
            cancelledProviderStartRuns.removeValue(forKey: runId)
        }
        lock.unlock()
    }

    /// Test/telemetry: residual cancellation/reservation bookkeeping for a thread.
    public func residualProviderStartBookkeepingCount(threadId: AgentThreadID) -> Int {
        lock.lock(); defer { lock.unlock() }
        // PERF: one pass per map (was two filter intermediates); count only.
        var count = 0
        for owner in reservedProviderStarts.values where owner == threadId { count += 1 }
        for owner in cancelledProviderStartRuns.values where owner == threadId { count += 1 }
        return count
    }

    @discardableResult
    private func applyPreparationLocked(
        threadId: AgentThreadID,
        event: ProviderPreparationEvent
    ) -> ProviderPreparationTransition {
        let current = preparationStates[threadId] ?? ProviderPreparationState()
        let transition = ProviderPreparationStateMachine.apply(state: current, event: event)
        preparationStates[threadId] = transition.state
        return transition
    }

    /// Completes durable prep and one-shot claims the spawn permit under the
    /// coordinator lock. Returns false when Stop revoked the generation.
    private func claimPreparationSpawnOrCancel(
        threadId: AgentThreadID,
        runId: AgentRunID
    ) -> Bool {
        lock.lock()
        if pendingThreadStops.remove(threadId) != nil {
            _ = applyPreparationLocked(threadId: threadId, event: .stopRequested)
            lock.unlock()
            return false
        }
        let current = preparationStates[threadId] ?? ProviderPreparationState()
        let finished = ProviderPreparationStateMachine.apply(
            state: current,
            event: .preparationFinished(generation: current.generation)
        )
        preparationStates[threadId] = finished.state
        // Re-check Stop after preparationFinished so a concurrent cancel that
        // arrived mid-apply cannot be overtaken by a retained permit.
        if pendingThreadStops.remove(threadId) != nil {
            _ = applyPreparationLocked(threadId: threadId, event: .stopRequested)
            lock.unlock()
            return false
        }
        let claimed = ProviderPreparationStateMachine.claimSpawn(
            state: preparationStates[threadId] ?? finished.state,
            permitGeneration: finished.spawnPermitGeneration
        )
        preparationStates[threadId] = claimed.state
        let ok = claimed.state.phase == .running && claimed.ignoredReason == nil
        if !ok {
            _ = applyPreparationLocked(threadId: threadId, event: .stopRequested)
            pendingThreadStops.remove(threadId)
        }
        lock.unlock()
        return ok
    }

    /// Re-checks Stop after the spawn-claim lock is released. A Desk stop can
    /// arrive in that gap; `sendTurn` must not start the provider.
    private func confirmSpawnClaimStillLive(threadId: AgentThreadID) -> Bool {
        lock.lock()
        let stopArmed = pendingThreadStops.remove(threadId) != nil
        let acceptanceRevoked = pendingProviderStarts[threadId]?.isAcceptanceInvalidated() == true
        if stopArmed || acceptanceRevoked {
            _ = applyPreparationLocked(threadId: threadId, event: .stopRequested)
            lock.unlock()
            return false
        }
        lock.unlock()
        return true
    }

    private func providerSessionIsLive(
        _ adapter: AgentProviderAdapter,
        threadId: AgentThreadID
    ) -> Bool {
        guard adapter.hasSession(threadId: threadId) else { return false }
        guard let summary = adapter.listSessions().first(where: { $0.threadId == threadId }) else {
            // A session the adapter cannot summarize proves nothing about an
            // in-flight turn. Treating it as live routed composer sends into
            // the queue on an IDLE thread ("will run after the current turn"
            // with no turn), and with no queue repo wired the prompt was
            // silently dropped. Runs stay serialized by the coordinator's
            // exclusive thread mutation either way.
            return false
        }
        return summary.status == .running || summary.status == .pending
    }

    /// After a durable terminal commit (or a proven-safe start gate), repair
    /// adapter summaries that still claim an in-flight turn. One-shot adapters
    /// only learn terminal status via their event callback; coordinator-
    /// synthesized Stop cancellation never re-enters that path.
    private func reconcileProviderSessionAfterDurableTerminal(
        threadId: AgentThreadID,
        status: AgentRunStatus,
        providerThreadId: String?
    ) {
        guard Self.isTerminalThreadStatus(status) else { return }
        guard let adapter = try? adapterForThread(threadId) else { return }
        guard providerSessionIsLive(adapter, threadId: threadId) else { return }
        if let oneShot = adapter as? OneShotProviderAdapter {
            oneShot.noteCoordinatorTerminal(
                threadId: threadId,
                status: status,
                providerThreadId: providerThreadId
            )
            return
        }
        // Multi-turn adapters clear in-flight on their own interrupt/finish
        // path. If they still report live after durable terminal, leave them:
        // stopSession would destroy resume state without identity proof here.
    }

    /// Start-gate variant: only reconcile a ghost live adapter turn when
    /// durable rows and in-memory ownership both prove the prior turn is over.
    private func reconcileGhostLiveProviderSessionIfDurableTerminal(threadId: AgentThreadID) {
        guard hasProviderSession(threadId: threadId) else { return }
        lock.lock()
        let hasActiveRun = activeThreads[threadId] != nil
        let streamOwner = pendingStreamRunIds[threadId]
        let terminalBarrierPending = streamOwner.map {
            pendingTerminalEvents[$0] != nil
                || finishingRuns.contains($0)
        } ?? false
        lock.unlock()
        guard !hasActiveRun, !terminalBarrierPending else { return }
        // Status + cursor only. A leftover 26-column + routing `get` hitchs
        // every follow-up send that still has a live adapter session.
        guard let status = try? threadRepo.status(of: threadId),
              Self.isTerminalThreadStatus(status) else { return }
        if (try? runRepo.latestActive(for: threadId)) != nil {
            return
        }
        guard let cursor = try? threadRepo.providerThreadId(of: threadId) else { return }
        reconcileProviderSessionAfterDurableTerminal(
            threadId: threadId,
            status: status,
            providerThreadId: cursor.isEmpty ? nil : cursor
        )
    }

    /// F19: release a thread's resident provider adapter session WITHOUT emitting
    /// any run-lifecycle events. For the idle-session reaper: the reaped thread
    /// finished long ago, so routing the release through stopRun/markStopRequested
    /// broadcast a spurious `.cancelled` ("Thread cancelled" notification, status
    /// pill flip, queued-message drain) for a thread nobody stopped. No-op when the
    /// thread still has an active run or no live session. `markCompleted: false`
    /// keeps the durable session status (a failed, cancelled or interrupted row).
    ///
    /// The capped pass targets threads that finished seconds ago, so the release
    /// also waits out a finish still in flight (pending or finishing
    /// terminal, the ghost-reconcile barrier) and any in-memory ownership, then
    /// holds the thread's start gate across `stopSession`: a start cannot begin
    /// on the session being stopped. A start that loses that race fails like any
    /// other start that overlaps a provider mutation, and is never killed mid-turn.
    public func releaseProviderSession(threadId: AgentThreadID, markCompleted: Bool = true) {
        lock.lock()
        let streamOwner = pendingStreamRunIds[threadId]
        let terminalBarrierPending = streamOwner.map {
            pendingTerminalEvents[$0] != nil
                || finishingRuns.contains($0)
        } ?? false
        // A surface that reserved a start is about to send on this session.
        let startReserved = reservedProviderStarts.values.contains(threadId)
        guard !terminalBarrierPending, !startReserved, !hasUnsafeInMemoryOwnershipLocked(threadId) else {
            lock.unlock()
            return
        }
        exclusiveThreadMutations.insert(threadId)
        lock.unlock()
        defer { endExclusiveThreadMutation(threadId) }
        guard let adapter = try? adapterForThread(threadId),
              adapter.hasSession(threadId: threadId) else { return }
        try? adapter.stopSession(threadId: threadId)
        lock.lock()
        providerTurnScopes.removeValue(forKey: threadId)
        lock.unlock()
        // Preserve resume eligibility: default `.cancelled` removes Continue (plan-final W2).
        // Completed is the honest session status when the turn already finished.
        if markCompleted {
            try? providerSessionRepo?.markStopped(threadId: threadId, status: .completed)
        }
    }

    /// Every resident adapter session across providers, for the idle reaper.
    public func liveProviderSessions() -> [AgentProviderSessionSummary] {
        lock.lock()
        let adapters = Array(providers.values)
        lock.unlock()
        return adapters.flatMap { $0.listSessions() }
    }

    /// Marking a session stopped in the DB does not free its provider process:
    /// release every thread the reaper picked, keeping the statuses it says to keep.
    public func releaseReapedProviderSessions(_ result: ProviderSessionReaperResult) {
        for threadId in result.stoppedThreadIds + result.cappedThreadIds {
            releaseProviderSession(
                threadId: threadId,
                markCompleted: !result.statusPreservedThreadIds.contains(threadId)
            )
        }
    }

    /// Retires process-local ownership only after a thread DELETE has committed.
    ///
    /// A cap delete cascades durable run/session rows, but resident adapters and
    /// in-memory retry buffers are process state. Never route this through
    /// `stopRun`: a completed idle session must not manufacture a cancelled run
    /// lifecycle. Conversely, an active, pending, or unsummarized provider
    /// session is deliberately left untouched -- it may belong to work this
    /// coordinator cannot safely identify from a deleted row.
    @discardableResult
    public func retireDeletedThreads(
        _ ids: [AgentThreadID],
        scheduleRetries: Bool = true
    ) -> [AgentThreadID: AgentDeletedThreadRetirementOutcome] {
        var seen: Set<AgentThreadID> = []
        let ordered = ids
            .filter { seen.insert($0).inserted }
            .sorted { $0.value.uuidString < $1.value.uuidString }
        var outcomes: [AgentThreadID: AgentDeletedThreadRetirementOutcome] = [:]
        for threadId in ordered {
            outcomes[threadId] = retireDeletedThread(threadId)
        }
        if scheduleRetries {
            updateDeletedThreadRetirementRetries(outcomes)
        }
        return outcomes
    }

    private func updateDeletedThreadRetirementRetries(
        _ outcomes: [AgentThreadID: AgentDeletedThreadRetirementOutcome]
    ) {
        var newlyPending: [AgentThreadID] = []
        var resolved: [(AgentThreadID, AgentDeletedThreadRetirementOutcome)] = []
        let hasPending = lock.withLock { () -> Bool in
            for threadId in outcomes.keys.sorted(by: {
                $0.value.uuidString < $1.value.uuidString
            }) {
                guard let outcome = outcomes[threadId] else { continue }
                switch outcome {
                case .retryRequired:
                    if pendingDeletedThreadRetirementRetries.insert(threadId).inserted {
                        newlyPending.append(threadId)
                    }
                case .retired, .confirmedPresent:
                    if pendingDeletedThreadRetirementRetries.remove(threadId) != nil {
                        resolved.append((threadId, outcome))
                    }
                }
            }
            return !pendingDeletedThreadRetirementRetries.isEmpty
        }
        for threadId in newlyPending {
            agentRunLog.info(
                "thread.retirement.retry_pending thread=\(threadId.value.uuidString, privacy: .public)"
            )
        }
        for (threadId, outcome) in resolved {
            agentRunLog.info(
                "thread.retirement.retry_resolved thread=\(threadId.value.uuidString, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)"
            )
        }
        if hasPending {
            scheduleDeletedThreadRetirementRetryDriver()
        }
    }

    private func scheduleDeletedThreadRetirementRetryDriver() {
        lock.lock()
        guard deletedThreadRetirementRetryTask == nil,
              !pendingDeletedThreadRetirementRetries.isEmpty else {
            lock.unlock()
            return
        }
        let task = Task.detached { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let delay = self?.deletedThreadRetirementRetryDelay(attempt: attempt) else {
                    return
                }
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled else { return }
                let ids = self.lock.withLock {
                    Array(self.pendingDeletedThreadRetirementRetries)
                        .sorted { $0.value.uuidString < $1.value.uuidString }
                        .prefix(64)
                }
                var outcomes: [AgentThreadID: AgentDeletedThreadRetirementOutcome] = [:]
                for threadId in ids {
                    outcomes[threadId] = self.retireDeletedThread(threadId)
                }
                self.updateDeletedThreadRetirementRetries(outcomes)
                let shouldContinue = self.lock.withLock { () -> Bool in
                    if self.pendingDeletedThreadRetirementRetries.isEmpty {
                        self.deletedThreadRetirementRetryTask = nil
                        return false
                    }
                    return true
                }
                guard shouldContinue else { return }
                attempt = min(attempt + 1, 5)
            }
        }
        deletedThreadRetirementRetryTask = task
        lock.unlock()
    }

    private func deletedThreadRetirementRetryDelay(attempt: Int) -> UInt64 {
        #if DEBUG
        let baseDelay = lock.withLock {
            deletedThreadRetirementRetryDelayNanosecondsForTesting
                ?? Self.deletedThreadRetirementRetryBaseDelayNanoseconds
        }
        #else
        let baseDelay = Self.deletedThreadRetirementRetryBaseDelayNanoseconds
        #endif
        return min(
            baseDelay * UInt64(1 << min(attempt, 5)),
            Self.deletedThreadRetirementRetryMaximumDelayNanoseconds
        )
    }

    private func retireDeletedThread(
        _ threadId: AgentThreadID
    ) -> AgentDeletedThreadRetirementOutcome {
        let registered = lock.withLock {
            deletedThreadRetirementsInFlight.insert(threadId).inserted
        }
        guard registered else { return .retryRequired }
        defer {
            lock.withLock {
                _ = deletedThreadRetirementsInFlight.remove(threadId)
            }
        }

        do {
            guard try !isDeletedThreadPresentForRetirement(threadId) else {
                return .confirmedPresent
            }
            guard try !hasDurableActiveRun(threadId),
                  !hasUnsafeInMemoryOwnership(threadId),
                  let terminalResidentAdapters = terminalResidentAdapters(forDeletedThread: threadId) else {
                return .retryRequired
            }

            // Re-read immediately before touching an adapter. This closes the
            // ordinary restore/read race and makes a read failure fail closed.
            if try isDeletedThreadPresentForRetirement(threadId) {
                return .confirmedPresent
            }
            guard try !hasDurableActiveRun(threadId),
                  !hasUnsafeInMemoryOwnership(threadId) else {
                return .retryRequired
            }

            for adapter in terminalResidentAdapters {
                try adapter.stopSession(threadId: threadId)
            }
        } catch {
            // A database or adapter failure never permits host/runtime purge.
            return .retryRequired
        }

        // Stream writers take mirrorEventLock before lock. Match that order so a
        // last buffered event cannot resurrect a deleted thread while we clear it.
        mirrorEventLock(for: threadId).lock()
        lock.lock()
        let mayPurge = !hasUnsafeInMemoryOwnershipLocked(threadId)
        if mayPurge {
            purgeDeletedThreadRuntimeLocked(threadId)
        }
        lock.unlock()
        mirrorEventLock(for: threadId).unlock()
        return mayPurge ? .retired : .retryRequired
    }

    private func isDeletedThreadPresentForRetirement(_ threadId: AgentThreadID) throws -> Bool {
        #if DEBUG
        if let presence = deletedThreadRetirementPresenceOverrideForTesting {
            return try presence(threadId)
        }
        #endif
        return try threadRepo.status(of: threadId) != nil
    }

    private func hasDurableActiveRun(_ threadId: AgentThreadID) throws -> Bool {
        try runRepo.latestActive(for: threadId) != nil
    }

    private func hasUnsafeInMemoryOwnership(_ threadId: AgentThreadID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasUnsafeInMemoryOwnershipLocked(threadId)
    }

    private func hasUnsafeInMemoryOwnershipLocked(_ threadId: AgentThreadID) -> Bool {
        activeThreads[threadId] != nil
            || pendingProviderStarts[threadId] != nil
            || pendingThreadStops.contains(threadId)
            || exclusiveThreadMutations.contains(threadId)
            || runThreadOwnership.contains {
                $0.value == threadId
                    && (active[$0.key] != nil || callbackMutationsInFlight[$0.key] != nil)
            }
    }

    /// Must be called with `lock` held. The index is deliberately independent
    /// from durable `agent_runs`: cap deletes cascade those rows before late
    /// provider usage or receipt retries have necessarily drained.
    private func rememberRunThreadOwnershipLocked(
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {
        runThreadOwnership[runId] = threadId
    }

    /// Every map here is keyed by a run id or contains one as a value. Keep the
    /// ownership index only while at least one such residue remains. A future
    /// late usage event carries its thread id and will re-establish ownership.
    private func hasRunScopedResidueLocked(_ runId: AgentRunID) -> Bool {
        active[runId] != nil
            || activeThreads.values.contains(runId)
            || activeRunMetadata[runId] != nil
            || activeTurnIds[runId] != nil
            || latestTokenUsage[runId] != nil
            || reconciledTokenUsage[runId] != nil
            || receiptUsageFinalizationInFlight.contains(runId)
            || receiptUsageEnrichmentRetryScheduled.contains(runId)
            || pendingReceiptFinalizations[runId] != nil
            || receiptFinalizationRetryScheduled.contains(runId)
            || latestRunErrorMessages[runId] != nil
            || orchestrationDeadlineWorkItems[runId] != nil
            || externalReceiptLeaseWorkItems[runId] != nil
            || activeAssistantMessageIds[runId] != nil
            || finishingRuns.contains(runId)
            || pendingTerminalEvents[runId] != nil
            || terminalRetryScheduled.contains(runId)
            || pendingStartFailures[runId] != nil
            || startFailureRetryScheduled.contains(runId)
            || pendingProviderStarts.values.contains { $0.runId == runId }
            || awaitingTerminationRuns.contains(runId)
            || providerTerminatedRuns.contains(runId)
            || pendingGracefulStopFallbacks.contains(runId)
            || callbackMutationsInFlight[runId] != nil
            || lateRunAdmissionClaims[runId]?.validationPending == true
            || seq[runId] != nil
            || pendingStreamRunIds.values.contains(runId)
    }

    /// Must be called with `lock` held after removing run-scoped state.
    private func discardRunThreadOwnershipIfReleasedLocked(_ runId: AgentRunID) {
        guard !hasRunScopedResidueLocked(runId) else { return }
        runCallbackAdmissionLeases.removeValue(forKey: runId)
        runThreadOwnership.removeValue(forKey: runId)
    }

    /// Returns nil when any adapter state could be active or belongs to a
    /// different provider. An empty result is safe and simply means no resident
    /// session needs releasing.
    private func terminalResidentAdapters(
        forDeletedThread threadId: AgentThreadID
    ) -> [AgentProviderAdapter]? {
        lock.lock()
        let adapters = Array(providers.values)
        lock.unlock()

        var terminalAdapters: [AgentProviderAdapter] = []
        for adapter in adapters {
            let summaries = adapter.listSessions().filter { $0.threadId == threadId }
            let hasSession = adapter.hasSession(threadId: threadId)
            if hasSession && summaries.isEmpty {
                // An adapter that cannot summarize a session may still own an
                // in-flight provider process. Treat it as foreign/unsafe.
                return nil
            }
            guard summaries.allSatisfy({
                $0.provider == adapter.provider && Self.isTerminalThreadStatus($0.status)
            }) else {
                return nil
            }
            if hasSession {
                terminalAdapters.append(adapter)
            }
        }
        return terminalAdapters
    }

    /// Must be called with mirrorEventLock and lock held, in that order.
    private func purgeDeletedThreadRuntimeLocked(_ threadId: AgentThreadID) {
        let runIds = Set(
            runThreadOwnership.compactMap { $0.value == threadId ? $0.key : nil }
                + lateRunAdmissionClaims.compactMap { $0.value.lease.threadId == threadId ? $0.key : nil }
        ).sorted { $0.value.uuidString < $1.value.uuidString }

        providerTurnScopes.removeValue(forKey: threadId)
        streamEventsSincePrune.removeValue(forKey: threadId)
        pendingStreamWrites.removeValue(forKey: threadId)
        pendingStreamRunIds.removeValue(forKey: threadId)
        pendingStreamPrunes.remove(threadId)
        lastStreamFlushMs.removeValue(forKey: threadId)
        mirrorPersistenceFailures.removeValue(forKey: threadId)
        autoContinuationCounts.removeValue(forKey: threadId)
        networkRetryCounts.removeValue(forKey: threadId)
        autoContinuationTokens.removeValue(forKey: threadId)
        lastPersistedAssistantContent.removeValue(forKey: threadId)
        preparationStates.removeValue(forKey: threadId)
        pendingProviderStarts.removeValue(forKey: threadId)
        pendingThreadStops.remove(threadId)
        reservedProviderStarts = reservedProviderStarts.filter { $0.value != threadId }
        cancelledProviderStartRuns = cancelledProviderStartRuns.filter { $0.value != threadId }
        if lastCheckpointRevertUndo?.threadId == threadId {
            lastCheckpointRevertUndo = nil
        }
        for runId in runIds { purgeRunRuntimeLocked(runId) }
    }

    /// Must be called with `lock` held. Removes only state owned by one rejected
    /// callback run, preserving any active or foreign run on the same thread.
    private func purgeRunRuntimeLocked(_ runId: AgentRunID) {
        active.removeValue(forKey: runId)
        activeDelegationCapabilities.removeValue(forKey: runId)
        activeRunMetadata.removeValue(forKey: runId)
        activeTurnIds.removeValue(forKey: runId)
        latestTokenUsage.removeValue(forKey: runId)
        reconciledTokenUsage.removeValue(forKey: runId)
        receiptUsageFinalizationInFlight.remove(runId)
        receiptUsageEnrichmentRetryScheduled.remove(runId)
        pendingReceiptFinalizations.removeValue(forKey: runId)
        receiptFinalizationRetryScheduled.remove(runId)
        latestRunErrorMessages.removeValue(forKey: runId)
        orchestrationDeadlineWorkItems.removeValue(forKey: runId)?.cancel()
        externalReceiptLeaseWorkItems.removeValue(forKey: runId)?.cancel()
        activeAssistantMessageIds.removeValue(forKey: runId)
        replyOnlyPrimaryRuns.remove(runId)
        replyOnlyAssistantItemIDs.removeValue(forKey: runId)
        finishingRuns.remove(runId)
        pendingTerminalEvents.removeValue(forKey: runId)
        terminalRetryScheduled.remove(runId)
        pendingStartFailures.removeValue(forKey: runId)
        startFailureRetryScheduled.remove(runId)
        awaitingTerminationRuns.remove(runId)
        providerTerminatedRuns.remove(runId)
        pendingGracefulStopFallbacks.remove(runId)
        callbackMutationsInFlight.removeValue(forKey: runId)
        seq.removeValue(forKey: runId)
        runThreadOwnership.removeValue(forKey: runId)
        lateRunAdmissionClaims.removeValue(forKey: runId)
        runCallbackAdmissionLeases.removeValue(forKey: runId)
    }

    private enum DurableRunGraphStatus {
        case present
        case threadAbsent
        case runAbsent
    }

    /// Owned callbacks never reach SQLite. Once normal ownership has drained,
    /// the exact durable run-to-thread graph becomes the admission authority.
    private func admitRunCallback(
        runId: AgentRunID,
        threadId: AgentThreadID
    ) -> RunCallbackAdmissionLease? {
        let start = lock.withLock { () -> (lease: RunCallbackAdmissionLease?, generation: UInt64?) in
            if lateRunAdmissionClaims[runId] != nil { return (nil, nil) }
            if let owner = runThreadOwnership[runId], owner != threadId {
                return (nil, nil)
            }
            if deletedThreadRetirementsInFlight.contains(threadId) {
                return (nil, nil)
            }
            if runThreadOwnership[runId] == threadId {
                if let lease = runCallbackAdmissionLeases[runId], lease.threadId == threadId {
                    return (lease, nil)
                }
                lateRunAdmissionGeneration &+= 1
                let lease = RunCallbackAdmissionLease(
                    threadId: threadId,
                    generation: lateRunAdmissionGeneration
                )
                runCallbackAdmissionLeases[runId] = lease
                return (lease, nil)
            }
            guard lateRunAdmissionClaims.count < Self.pendingLateRunValidationLimit else {
                if !lateRunValidationCapacityLogged {
                    lateRunValidationCapacityLogged = true
                    let pendingCount = lateRunAdmissionClaims.count
                    agentRunLog.error(
                        "late_validation.capacity_exhausted pending=\(pendingCount, privacy: .public)"
                    )
                }
                return (nil, nil)
            }
            lateRunAdmissionGeneration &+= 1
            let generation = lateRunAdmissionGeneration
            let lease = RunCallbackAdmissionLease(threadId: threadId, generation: generation)
            lateRunAdmissionClaims[runId] = LateRunAdmissionClaim(
                lease: lease,
                validationPending: false
            )
            return (nil, generation)
        }
        if let lease = start.lease { return lease }
        guard let generation = start.generation else { return nil }

        do {
            let status = try durableRunGraphStatus(runId: runId, threadId: threadId)
            #if DEBUG
            if case .present = status {
                lateRunAdmissionDidReadPresentForTesting?(runId, threadId)
            }
            #endif
            return resolveLateRunGraphStatus(
                status,
                runId: runId,
                threadId: threadId,
                generation: generation
            )
        } catch {
            let lease = lock.withLock { () -> RunCallbackAdmissionLease? in
                guard var claim = lateRunAdmissionClaims[runId],
                      claim.matches(threadId: threadId, generation: generation) else {
                    return nil
                }
                claim.validationPending = true
                lateRunAdmissionClaims[runId] = claim
                runCallbackAdmissionLeases[runId] = claim.lease
                rememberRunThreadOwnershipLocked(runId: runId, threadId: threadId)
                return claim.lease
            }
            if lease != nil {
                scheduleLateRunValidationSweep()
            }
            return lease
        }
    }

    private func durableRunGraphStatus(
        runId: AgentRunID,
        threadId: AgentThreadID
    ) throws -> DurableRunGraphStatus {
        #if DEBUG
        if let presence = lateRunAdmissionPresenceOverrideForTesting {
            return try presence(runId, threadId) ? .present : .runAbsent
        }
        #endif
        guard try threadRepo.status(of: threadId) != nil else { return .threadAbsent }
        guard try runRepo.threadId(of: runId) == threadId else {
            return .runAbsent
        }
        return .present
    }

    private func resolveLateRunGraphStatus(
        _ status: DurableRunGraphStatus,
        runId: AgentRunID,
        threadId: AgentThreadID,
        generation: UInt64
    ) -> RunCallbackAdmissionLease? {
        switch status {
        case .present:
            return lock.withLock {
                guard let claim = lateRunAdmissionClaims[runId],
                      claim.matches(threadId: threadId, generation: generation),
                      runThreadOwnership[runId].map({ $0 == threadId }) ?? true else {
                    return nil
                }
                lateRunAdmissionClaims.removeValue(forKey: runId)
                runCallbackAdmissionLeases[runId] = claim.lease
                rememberRunThreadOwnershipLocked(runId: runId, threadId: threadId)
                noteLateRunValidationCapacityRecoveryLocked()
                return claim.lease
            }
        case .threadAbsent:
            purgeRejectedLateRun(
                runId: runId,
                threadId: threadId,
                generation: generation,
                threadAbsent: true
            )
        case .runAbsent:
            purgeRejectedLateRun(
                runId: runId,
                threadId: threadId,
                generation: generation,
                threadAbsent: false
            )
        }
        return nil
    }

    private func callbackAdmissionLeaseIsValidLocked(
        _ lease: RunCallbackAdmissionLease,
        runId: AgentRunID
    ) -> Bool {
        runCallbackAdmissionLeases[runId] == lease
            && runThreadOwnership[runId] == lease.threadId
            && !deletedThreadRetirementsInFlight.contains(lease.threadId)
    }

    private func beginAdmittedCallbackMutation(
        _ lease: RunCallbackAdmissionLease,
        runId: AgentRunID
    ) -> Bool {
        lock.withLock {
            guard callbackAdmissionLeaseIsValidLocked(lease, runId: runId) else {
                return false
            }
            callbackMutationsInFlight[runId, default: 0] += 1
            return true
        }
    }

    private func endAdmittedCallbackMutation(runId: AgentRunID) {
        lock.withLock {
            if let count = callbackMutationsInFlight[runId], count > 1 {
                callbackMutationsInFlight[runId] = count - 1
            } else {
                callbackMutationsInFlight.removeValue(forKey: runId)
            }
            discardRunThreadOwnershipIfReleasedLocked(runId)
        }
    }

    private func noteLateRunValidationCapacityRecoveryLocked() {
        guard lateRunValidationCapacityLogged,
              lateRunAdmissionClaims.count < Self.pendingLateRunValidationLimit else { return }
        lateRunValidationCapacityLogged = false
        let pendingCount = lateRunAdmissionClaims.count
        agentRunLog.info(
            "late_validation.capacity_recovered pending=\(pendingCount, privacy: .public)"
        )
    }

    private func purgeRejectedLateRun(
        runId: AgentRunID,
        threadId: AgentThreadID,
        generation: UInt64,
        threadAbsent: Bool
    ) {
        mirrorEventLock(for: threadId).lock()
        lock.lock()
        defer {
            lock.unlock()
            mirrorEventLock(for: threadId).unlock()
        }
        guard let claim = lateRunAdmissionClaims[runId],
              claim.matches(threadId: threadId, generation: generation) else {
            return
        }
        // A run that became active during the durable read owns its state. The
        // next callback will use normal ownership rather than this late path.
        guard active[runId] == nil,
              !activeThreads.values.contains(runId),
              callbackMutationsInFlight[runId] == nil else { return }
        purgeRunRuntimeLocked(runId)
        noteLateRunValidationCapacityRecoveryLocked()
        if threadAbsent, !hasUnsafeInMemoryOwnershipLocked(threadId) {
            purgeDeletedThreadRuntimeLocked(threadId)
        }
    }

    private func scheduleLateRunValidationSweep() {
        lock.lock()
        guard lateRunValidationSweepTask == nil,
              lateRunAdmissionClaims.values.contains(where: \.validationPending) else {
            lock.unlock()
            return
        }
        #if DEBUG
        lateRunValidationSweepStartsForTesting += 1
        #endif
        let task = Task.detached { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let delay = self?.lateRunValidationRetryDelay(attempt: attempt) else {
                    return
                }
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled else { return }
                let claims = self.lock.withLock {
                    self.lateRunAdmissionClaims
                        .filter { $0.value.validationPending }
                        .sorted { $0.key.value.uuidString < $1.key.value.uuidString }
                        .prefix(Self.pendingLateRunValidationLimit)
                }
                var readFailed = false
                var resolvedAny = false
                for (runId, claim) in claims {
                    let status: DurableRunGraphStatus
                    do {
                        status = try self.durableRunGraphStatus(
                            runId: runId,
                            threadId: claim.lease.threadId
                        )
                    } catch {
                        readFailed = true
                        continue
                    }
                    _ = self.resolveLateRunGraphStatus(
                        status,
                        runId: runId,
                        threadId: claim.lease.threadId,
                        generation: claim.lease.generation
                    )
                    resolvedAny = true
                }
                let shouldContinue = self.lock.withLock { () -> Bool in
                    let hasPending = self.lateRunAdmissionClaims.values.contains {
                        $0.validationPending
                    }
                    if readFailed && !self.lateRunValidationOutageLogged {
                        self.lateRunValidationOutageLogged = true
                        agentRunLog.error(
                            "late_validation.read_error pending=\(self.lateRunAdmissionClaims.count, privacy: .public)"
                        )
                    } else if resolvedAny && self.lateRunValidationOutageLogged {
                        self.lateRunValidationOutageLogged = false
                        agentRunLog.info(
                            "late_validation.recovered pending=\(self.lateRunAdmissionClaims.count, privacy: .public)"
                        )
                    }
                    if !hasPending {
                        self.lateRunValidationSweepTask = nil
                    }
                    return hasPending
                }
                guard shouldContinue else { return }
                attempt = readFailed ? min(attempt + 1, 5) : 0
            }
        }
        lateRunValidationSweepTask = task
        lock.unlock()
    }

    private func lateRunValidationRetryDelay(attempt: Int) -> UInt64 {
        #if DEBUG
        let baseDelay = lock.withLock {
            lateRunValidationRetryDelayNanosecondsForTesting
                ?? Self.lateRunValidationRetryBaseDelayNanoseconds
        }
        #else
        let baseDelay = Self.lateRunValidationRetryBaseDelayNanoseconds
        #endif
        return min(
            baseDelay * UInt64(1 << min(attempt, 5)),
            Self.lateRunValidationRetryMaximumDelayNanoseconds
        )
    }

    /// Classifies the local initiator for a terminal transition (plan-final T1–T3).
    public static func terminalInitiator(
        status: AgentRunStatus,
        providerTerminalAcknowledged: Bool,
        errorMessage: String? = nil
    ) -> TerminalTransitionInitiator {
        if status == .cancelled && !providerTerminalAcknowledged {
            return .userStop
        }
        if status == .interrupted {
            return .relaunchReconcile
        }
        let lower = (errorMessage ?? "").lowercased()
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("requesttimedout") {
            return .rpcTimeout
        }
        // completed without authoritative provider terminal is never provider_completed
        if status == .completed && !providerTerminalAcknowledged {
            return .processDeath
        }
        if status == .failed && !providerTerminalAcknowledged {
            return .processDeath
        }
        return .providerTerminal
    }

    /// Pure: durable/UI status after TerminalTransitionPolicy (must match persist rows).
    public static func durableTerminalStatus(
        requested: AgentRunStatus,
        providerTerminalAcknowledged: Bool,
        errorMessage: String? = nil
    ) -> (status: AgentRunStatus, initiator: TerminalTransitionInitiator, errorMessage: String?) {
        let initiator = terminalInitiator(
            status: requested,
            providerTerminalAcknowledged: providerTerminalAcknowledged,
            errorMessage: errorMessage
        )
        let reason = TerminalTransitionReason.classify(
            requestedStatus: requested,
            initiator: initiator
        )
        var status = TerminalTransitionPolicy.reconciledStatus(requested: requested, reason: reason)
        if status == .completed {
            let probe = TerminalTransitionRecord(
                runId: "",
                threadId: "",
                reason: reason,
                initiator: initiator,
                requestedStatus: .completed
            )
            if !TerminalTransitionPolicy.allowsCompletedPresentation(probe) {
                status = reason.durableStatus
            }
        }
        let msg = errorMessage ?? (status == requested ? nil : reason.durableErrorMessage)
        return (status, initiator, msg)
    }

    /// Write-before-UI terminal transition. Applies `TerminalTransitionPolicy` so
    /// false `completed` cannot be presented. Returns the presentation status.
    @discardableResult
    public func recordTerminalTransition(
        runId: AgentRunID,
        threadId: AgentThreadID,
        requestedStatus: AgentRunStatus,
        initiator: TerminalTransitionInitiator,
        providerPid: Int32? = nil,
        exitStatus: Int32? = nil,
        eventSequence: Int64? = nil
    ) -> AgentRunStatus {
        let eventTime = Date()
        return recordTerminalTransition(
            runId: runId,
            threadId: threadId,
            requestedStatus: requestedStatus,
            initiator: initiator,
            providerPid: providerPid,
            exitStatus: exitStatus,
            eventSequence: eventSequence,
            eventTime: eventTime,
            commitTime: Date(),
            presentTime: Date()
        )
    }

    @discardableResult
    private func recordTerminalTransition(
        runId: AgentRunID,
        threadId: AgentThreadID,
        requestedStatus: AgentRunStatus,
        initiator: TerminalTransitionInitiator,
        providerPid: Int32?,
        exitStatus: Int32?,
        eventSequence: Int64?,
        eventTime: Date,
        commitTime: Date,
        presentTime: Date
    ) -> AgentRunStatus {
        let reason = TerminalTransitionReason.classify(
            requestedStatus: requestedStatus,
            initiator: initiator
        )
        var presentation = TerminalTransitionPolicy.reconciledStatus(
            requested: requestedStatus,
            reason: reason
        )
        // Hard gate: completed presentation requires provider-completed reason.
        if presentation == .completed {
            let probe = TerminalTransitionRecord(
                runId: runId.value.uuidString,
                threadId: threadId.value.uuidString,
                reason: reason,
                initiator: initiator,
                requestedStatus: .completed
            )
            if !TerminalTransitionPolicy.allowsCompletedPresentation(probe) {
                presentation = reason.durableStatus
            }
        }
        let record = TerminalTransitionRecord(
            runId: runId.value.uuidString,
            threadId: threadId.value.uuidString,
            reason: reason,
            initiator: initiator,
            requestedStatus: requestedStatus,
            providerPid: providerPid,
            exitStatus: exitStatus,
            eventSequence: eventSequence,
            bootId: TerminalTransitionLedger.currentBootId(),
            eventTime: eventTime,
            commitTime: commitTime,
            presentTime: presentTime
        )
        if let ledger = terminalTransitionLedger {
            _ = try? ledger.append(record)
        }
        return presentation
    }

    private func markStopRequested(threadId: AgentThreadID, runId: AgentRunID?) {
        // S5: always revoke generation-owned prep/spawn permits on Stop.
        lock.lock()
        _ = applyPreparationLocked(threadId: threadId, event: .stopRequested)
        lock.unlock()
        // F17: handle.cancel() can finish the run synchronously (the codex adapter
        // emits .finished(.cancelled) inside cancel), and the .finished path has
        // then already run the FULL terminal sequence — run row, thread row,
        // didFinish observers and onRunFinished. Re-broadcasting here would
        // double-fire didChangeStatus/onRunFinished for the same run (duplicate
        // notifications, two concurrent queue drains), so a run that is already
        // terminal is done.
        //
        // Exception: durable terminal + leftover in-memory ownership (partial
        // finish / multi-process reconcile race). Release the ghost active run so
        // Stop/Working cannot stick after finishedAt is already set.
        if let runId, let row = try? runRepo.terminal(of: runId), row.finishedAt != nil {
            _ = releaseStaleInMemoryOwnershipIfDurableTerminal(
                runId: runId,
                threadId: threadId,
                preferredStatus: row.status,
                finalMessage: nil,
                providerThreadId: nil
            )
            if let adapter = try? adapterForThread(threadId), adapter.hasSession(threadId: threadId) {
                try? adapter.stopSession(threadId: threadId)
            }
            return
        }
        if let runId {
            // A user Stop is a terminal event and must cross the same durability
            // barrier as provider completion. Claim the terminal slot atomically:
            // a provider terminal already in flight wins; otherwise cancellation
            // becomes the retained event and retries until the buffered stream tail
            // commits. This prevents Stop-first from evicting active ownership or
            // publishing `.cancelled` while SQLite still holds uncommitted events.
            lock.lock()
            if pendingTerminalEvents[runId] != nil {
                // Provider (or a prior Stop) already owns the durability slot.
                // Do not replace a retained `.completed` with `.cancelled` — see
                // test_stopCannotOvertakeTerminalWaitingForDurabilityBarrier.
                // Re-arm retry so a stuck flush cannot leave activeThreads owned.
                lock.unlock()
                scheduleTerminalDurabilityRetry(runId: runId, threadId: threadId)
                return
            }

            // finishingRuns alone must NOT block user cancel. That flag is also
            // set while final-response wire rendering runs (before any
            // pendingTerminalEvent exists); treating it as durabilityPending made
            // Stop a no-op until humanize returned — Working/Stopping stuck.
            finishingRuns.insert(runId)
            // User Stop is a legitimate silent ending — never invent an error_message.
            pendingTerminalEvents[runId] = PendingTerminalEvent(
                status: .cancelled,
                finalMessage: nil,
                providerThreadId: nil,
                assistantMessage: nil,
                finishedAt: Date(),
                providerTerminalAcknowledged: false,
                errorMessage: nil,
                terminalReason: TerminalTransitionReason.userStop.rawValue
            )
            lock.unlock()
            handle(
                event: .finished(.cancelled, finalMessage: nil, providerThreadId: nil),
                runId: runId,
                threadId: threadId,
                deduplicatesInFlightFinish: false,
                providerTerminalAcknowledged: false
            )
            return
        }
        let stoppedRunId = runId ?? AgentRunID()
        if let runId {
            try? runRepo.markStopped(id: runId, status: .cancelled)
        }
        // Status + unread + updated_at only. A leftover 26-column + routing
        // `get` then `upsert` hitchs Stop when there is no live handle.
        try? threadRepo.cancelIfActive(
            id: threadId,
            hasUnread: Self.hasUnread(for: .cancelled)
        )
        try? providerSessionRepo?.markStopped(threadId: threadId)
        // PERF-MAC_AGENT-007: drain buffered stream writes for the genuine active
        // run before tearing it down, so a cancel does not drop the buffered tail.
        // The seq attribution requires the real runId, so only the runId-bearing
        // stop path flushes (the nil-runId paths had no live buffered events).
        let streamFlushError = runId.flatMap {
            flushPendingStreamWrites(runId: $0, threadId: threadId)
        }
        lock.lock()
        var activeProjection: ActiveRunProjection?
        if let runId {
            active.removeValue(forKey: runId)
            activeDelegationCapabilities.removeValue(forKey: runId)
            if activeThreads.removeValue(forKey: threadId) != nil {
                activeProjection = activeRunProjectionLocked()
            }
            delegatedRuns.removeValue(forKey: runId)
            activeRunMetadata.removeValue(forKey: runId)
            activeTurnIds.removeValue(forKey: runId)
            activeAssistantMessageIds.removeValue(forKey: runId)
            finishingRuns.remove(runId)
            // Do not clear seq while a failed flush still owns a retryable batch.
            // Clearing here reissued seq 1 for late Grok ACP events (e.g.
            // prompt_complete after servers_updated) and blocked the next start.
            if streamFlushError == nil {
                seq.removeValue(forKey: runId)
            } else {
                clearStreamSequenceIfReleasedLocked(runId: runId, threadId: threadId)
            }
            pendingThreadStops.remove(threadId)
            discardRunThreadOwnershipIfReleasedLocked(runId)
        }
        if streamFlushError == nil {
            streamEventsSincePrune.removeValue(forKey: threadId)
            pendingStreamWrites.removeValue(forKey: threadId)
            pendingStreamRunIds.removeValue(forKey: threadId)
            pendingStreamPrunes.remove(threadId)
            lastStreamFlushMs.removeValue(forKey: threadId)
            if let runId {
                discardRunThreadOwnershipIfReleasedLocked(runId)
            }
        }
        // PERF-MAC_AGENT-008: thread closed -> evict the dedup cache entry so
        // cancelled threads do not retain their final-answer text indefinitely.
        lastPersistedAssistantContent.removeValue(forKey: threadId)
        // UX-MAC_AGENT-BG-AWAIT: a stop ends the streak and invalidates the token,
        // so any scheduled auto-continuation for this thread aborts when it fires.
        autoContinuationCounts.removeValue(forKey: threadId)
        networkRetryCounts.removeValue(forKey: threadId)
        autoContinuationTokens[threadId] = (autoContinuationTokens[threadId] ?? 0) + 1
        lock.unlock()
        if let activeProjection {
            onActiveRunProjectionChanged?(activeProjection, .finished(.cancelled))
        }
        for observer in observersSnapshot() {
            observer.runCoordinator(self, didChangeStatus: .cancelled, runId: stoppedRunId, threadId: threadId)
        }
        onRunFinished?(threadId, stoppedRunId, .cancelled)
    }

    /// F9: drop a deleted thread's residual per-thread coordinator state (the
    /// auto-continuation streak counter and its generation token). These are the
    /// only per-thread maps not already evicted at run finish/stop, so without this
    /// they accumulate one Int entry per thread that ever ran for the life of the
    /// process. Safe to call on delete: a deleted thread can never auto-continue —
    /// any scheduled continuation fails its validity check once the token is gone
    /// and the thread row no longer reports `.completed`.
    public func forgetThread(_ threadId: AgentThreadID) {
        lock.lock()
        autoContinuationCounts.removeValue(forKey: threadId)
        networkRetryCounts.removeValue(forKey: threadId)
        autoContinuationTokens.removeValue(forKey: threadId)
        lock.unlock()
    }

    /// Scan in-memory active ownership against durable agent_runs and release any
    /// ghost where `finishedAt` is already set. Surfaces call this on rail reload
    /// so "Threads · N active" / Working cannot stick after a missed or filtered
    /// terminal callback (durable completion is authoritative for that runId).
    ///
    /// Returns the number of runs released. Generation-safe: only the exact
    /// (threadId, runId) pair still owned in memory and durable-terminal is freed;
    /// a newer live run B on the same thread is untouched.
    @discardableResult
    public func reconcileStaleActiveOwnershipWithDurableState() -> Int {
        lock.lock()
        let snapshot = activeThreads
        lock.unlock()
        var released = 0
        for (threadId, runId) in snapshot {
            guard let row = try? runRepo.terminal(of: runId), row.finishedAt != nil else { continue }
            if releaseStaleInMemoryOwnershipIfDurableTerminal(
                runId: runId,
                threadId: threadId,
                preferredStatus: row.status,
                finalMessage: nil,
                providerThreadId: nil
            ) {
                released += 1
            }
        }
        return released
    }

    /// When SQLite already has a terminal run row but this process still lists the
    /// run in `active` / `activeThreads`, release in-memory ownership and fan out
    /// `didFinish` exactly once. No-op when the run is not owned in memory (avoids
    /// double-notifying a fully completed finish path).
    @discardableResult
    private func releaseStaleInMemoryOwnershipIfDurableTerminal(
        runId: AgentRunID,
        threadId: AgentThreadID,
        preferredStatus: AgentRunStatus?,
        finalMessage: String?,
        providerThreadId: String?
    ) -> Bool {
        lock.lock()
        guard !terminalCheckpointAttempts.contains(runId) else {
            lock.unlock()
            return false
        }
        let ownsRun = active[runId] != nil || activeThreads[threadId] == runId
        guard ownsRun else {
            lock.unlock()
            return false
        }
        // Cancel any still-registered handle so provider processes do not outlive
        // the durable terminal row (Stop-after-partial-finish path).
        let handle = active.removeValue(forKey: runId)
        activeDelegationCapabilities.removeValue(forKey: runId)
        if activeThreads[threadId] == runId {
            activeThreads.removeValue(forKey: threadId)
        }
        delegatedRuns.removeValue(forKey: runId)
        activeRunMetadata.removeValue(forKey: runId)
        latestTokenUsage.removeValue(forKey: runId)
        reconciledTokenUsage.removeValue(forKey: runId)
        receiptUsageFinalizationInFlight.remove(runId)
        receiptUsageEnrichmentRetryScheduled.remove(runId)
        latestRunErrorMessages.removeValue(forKey: runId)
        activeTurnIds.removeValue(forKey: runId)
        activeAssistantMessageIds.removeValue(forKey: runId)
        finishingRuns.remove(runId)
        pendingTerminalEvents.removeValue(forKey: runId)
        terminalRetryScheduled.remove(runId)
        pendingGracefulStopFallbacks.remove(runId)
        awaitingTerminationRuns.remove(runId)
        providerTerminatedRuns.remove(runId)
        pendingThreadStops.remove(threadId)
        orchestrationDeadlineWorkItems.removeValue(forKey: runId)?.cancel()
        externalReceiptLeaseWorkItems.removeValue(forKey: runId)?.cancel()
        seq.removeValue(forKey: runId)
        discardRunThreadOwnershipIfReleasedLocked(runId)
        lastPersistedAssistantContent.removeValue(forKey: threadId)
        autoContinuationCounts.removeValue(forKey: threadId)
        networkRetryCounts.removeValue(forKey: threadId)
        autoContinuationTokens[threadId] = (autoContinuationTokens[threadId] ?? 0) + 1
        let projection = activeRunProjectionLocked()
        lock.unlock()

        handle?.cancel()
        let status = preferredStatus
            ?? (try? runRepo.status(of: runId))
            ?? .cancelled
        reconcileProviderSessionAfterDurableTerminal(
            threadId: threadId,
            status: status,
            providerThreadId: providerThreadId
        )
        agentRunLog.info(
            "run.stale_ownership_released thread=\(threadId.value.uuidString, privacy: .public) run=\(runId.value.uuidString, privacy: .public) status=\(status.rawValue, privacy: .public)"
        )
        onActiveRunProjectionChanged?(projection, .finished(status))
        for observer in observersSnapshot() {
            observer.runCoordinator(
                self,
                didFinish: runId,
                threadId: threadId,
                status: status,
                finalMessage: finalMessage,
                providerThreadId: providerThreadId
            )
        }
        onRunFinished?(threadId, runId, status)
        return true
    }

    #if DEBUG
    // Test-only seam for the F9 per-thread eviction: seed and observe the
    // auto-continuation bookkeeping without driving a full stalled autonomous run.
    func seedAutoContinuationStateForTesting(_ threadId: AgentThreadID) {
        lock.lock(); autoContinuationCounts[threadId] = 1; autoContinuationTokens[threadId] = 1; lock.unlock()
    }

    func backgroundAwaitContinuationStillValidForTesting(
        _ threadId: AgentThreadID,
        token: Int
    ) -> Bool {
        backgroundAwaitContinuationStillValid(threadId: threadId, token: token)
    }

    func incompleteTurnContinuationRequestForTesting(
        threadId: AgentThreadID,
        provider: AgentProvider = .codex,
        model: String = "fake-model",
        cwd: String = "/tmp",
        reason: IncompleteTurnContinuationReason = .backgroundAwait
    ) -> AgentRunRequest {
        incompleteTurnContinuationRequest(
            threadId: threadId,
            runMetadata: (
                provider: provider,
                providerInstanceId: provider.rawValue,
                model: model,
                cwd: cwd,
                serviceTier: .auto,
                runtimeMode: .fullAccess,
                interactionMode: .default,
                adapterKey: "test",
                binaryIdentity: nil,
                reasoningEffort: nil,
                distillMainEffort: nil,
                distillReasoningEffort: nil,
                distillMode: .normal
            ),
            resumeCursor: nil,
            reason: reason
        )
    }
    var autoContinuationThreadIdsForTesting: Set<AgentThreadID> {
        lock.lock(); defer { lock.unlock() }
        return Set(autoContinuationCounts.keys).union(autoContinuationTokens.keys)
    }

    /// Seeds the terminal/buffered state that can survive a database-cascaded
    /// delete. It intentionally does not create active ownership: retirement
    /// must clear these retry paths without emitting a run lifecycle event.
    @discardableResult
    func seedDeletedThreadRuntimeStateForTesting(_ threadId: AgentThreadID) -> AgentRunID {
        let runId = AgentRunID()
        let request = AgentRunRequest(
            runId: runId,
            threadId: threadId,
            provider: .codex,
            model: "test-model",
            cwd: "/tmp",
            prompt: "test"
        )
        var batch = StreamWriteBatch()
        batch.append(StreamWriteItem(seq: 1, kind: "test", payloadJSON: "{}", providerEvent: nil))
        lock.lock()
        providerTurnScopes[threadId] = ProviderTurnScope(environment: [:])
        streamEventsSincePrune[threadId] = 1
        pendingStreamWrites[threadId] = batch
        pendingStreamRunIds[threadId] = runId
        pendingStreamPrunes.insert(threadId)
        lastStreamFlushMs[threadId] = 1
        mirrorPersistenceFailures[threadId] = NSError(domain: "test", code: 1)
        autoContinuationCounts[threadId] = 1
        autoContinuationTokens[threadId] = 1
        lastPersistedAssistantContent[threadId] = "retained assistant text"
        rememberRunThreadOwnershipLocked(runId: runId, threadId: threadId)
        pendingReceiptFinalizations[runId] = PendingOrchestrationReceiptFinalization(
            runId: runId,
            threadId: threadId,
            status: .failed,
            usage: nil,
            qualityOutcome: "test"
        )
        pendingTerminalEvents[runId] = PendingTerminalEvent(
            status: .failed,
            finalMessage: nil,
            providerThreadId: nil,
            assistantMessage: nil,
            finishedAt: Date(),
            providerTerminalAcknowledged: true,
            errorMessage: "test"
        )
        pendingStartFailures[runId] = PendingStartFailure(
            request: request,
            adapterKey: "test",
            binaryIdentity: nil,
            preserveRecoverableSession: false,
            otherRunActive: false,
            message: "test",
            event: .error(message: "test", recoverable: true),
            streamEvent: AgentRunRepository.StreamWriteIntent(
                seq: 1,
                kind: "test",
                payloadJSON: "{}",
                providerEvent: nil
            ),
            finishedAt: Date()
        )
        orchestrationDeadlineWorkItems[runId] = DispatchWorkItem {}
        externalReceiptLeaseWorkItems[runId] = DispatchWorkItem {}
        lock.unlock()
        return runId
    }

    var deletedThreadRuntimeResidueForTesting: Set<AgentThreadID> {
        lock.lock(); defer { lock.unlock() }
        var ids = Set(providerTurnScopes.keys)
        ids.formUnion(streamEventsSincePrune.keys)
        ids.formUnion(pendingStreamWrites.keys)
        ids.formUnion(pendingStreamRunIds.keys)
        ids.formUnion(pendingStreamPrunes)
        ids.formUnion(lastStreamFlushMs.keys)
        ids.formUnion(mirrorPersistenceFailures.keys)
        ids.formUnion(autoContinuationCounts.keys)
        ids.formUnion(autoContinuationTokens.keys)
        ids.formUnion(lastPersistedAssistantContent.keys)
        ids.formUnion(pendingStartFailures.values.map { $0.request.threadId })
        ids.formUnion(pendingReceiptFinalizations.values.map(\.threadId))
        ids.formUnion(runThreadOwnership.values)
        return ids
    }

    func recordLateCumulativeUsageForTesting(
        runId: AgentRunID,
        threadId: AgentThreadID,
        totalTokens: Int
    ) {
        recordReconciledTokenUsage(
            AssistantTokenUsage(totalTokens: totalTokens, semantics: .cumulative),
            runId: runId,
            threadId: threadId
        )
    }

    func handleRunEventForTesting(
        _ event: AgentRunEvent,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {
        handle(event: event, runId: runId, threadId: threadId)
    }

    var pendingLateRunValidationIDsForTesting: Set<AgentRunID> {
        lock.withLock { Set(lateRunAdmissionClaims.keys) }
    }

    var runThreadOwnershipForTesting: [AgentRunID: AgentThreadID] {
        lock.withLock { runThreadOwnership }
    }

    var lateReceiptRunResidueForTesting: Set<AgentRunID> {
        lock.withLock {
            Set(latestTokenUsage.keys)
                .union(reconciledTokenUsage.keys)
                .union(receiptUsageFinalizationInFlight)
                .union(receiptUsageEnrichmentRetryScheduled)
                .union(pendingReceiptFinalizations.keys)
                .union(receiptFinalizationRetryScheduled)
        }
    }
    #endif

    // MARK: - Background-await auto-continuation (UX-MAC_AGENT-BG-AWAIT)

    private func resetAutoContinuationStreak(_ threadId: AgentThreadID) {
        lock.lock(); autoContinuationCounts[threadId] = 0; networkRetryCounts[threadId] = nil; lock.unlock()
    }

    /// F37: bump the thread's continuation token so any pending scheduled
    /// auto-continuation aborts its validity check when it fires. Called on
    /// user-initiated starts; markStopRequested does the same on stop.
    private func invalidateScheduledAutoContinuation(_ threadId: AgentThreadID) {
        lock.lock()
        autoContinuationTokens[threadId] = (autoContinuationTokens[threadId] ?? 0) + 1
        lock.unlock()
    }

    /// Decide, at run finish, whether a full-access run ended incomplete (background
    /// await or multi-phase workflow handoff) and should be auto-nudged; if so,
    /// schedule a bounded re-invocation with a reason-specific delay/prompt.
    private func maybeScheduleBackgroundAwaitContinuation(
        threadId: AgentThreadID,
        status: AgentRunStatus,
        finalMessage: String?,
        runMetadata: RunMetadata?,
        resumeCursor: String?
    ) {
        let isAutonomous = (runMetadata?.runtimeMode ?? (try? threadRepo.permissionMode(of: threadId))) == .fullAccess
        lock.lock()
        let prior = autoContinuationCounts[threadId] ?? 0
        lock.unlock()
        guard let reason = IncompleteTurnContinuation.shouldAutoContinue(
            status: status,
            finalMessage: finalMessage,
            isAutonomous: isAutonomous,
            priorAutoContinuations: prior
        ) else {
            // A completed run that did NOT stall (real progress, or non-autonomous)
            // clears the streak so a later genuine stall gets the full budget.
            if status == .completed { resetAutoContinuationStreak(threadId) }
            return
        }
        guard let runMetadata else { return }
        lock.lock()
        autoContinuationCounts[threadId] = prior + 1
        let token = (autoContinuationTokens[threadId] ?? 0) + 1
        autoContinuationTokens[threadId] = token
        lock.unlock()
        let attempt = prior + 1
        let delay = IncompleteTurnContinuation.delay(
            for: reason,
            backgroundDelay: backgroundAwaitContinuationDelay
        )
        let request = incompleteTurnContinuationRequest(
            threadId: threadId,
            runMetadata: runMetadata,
            resumeCursor: resumeCursor,
            reason: reason
        )
        agentRunLog.info("run.autoContinue.scheduled thread=\(threadId.value.uuidString, privacy: .public) attempt=\(attempt, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64((delay * 1_000_000_000).rounded()))
            }
            guard self.backgroundAwaitContinuationStillValid(threadId: threadId, token: token) else { return }
            if let claim = self.autoContinuationClaimsBotVM {
                guard await claim(threadId, request.runId) else { return }
            }
            do {
                _ = try await self.startRun(request, isAutoContinuation: true)
            } catch {
                await self.autoContinuationReleasesBotVM?(request.runId)
            }
        }
    }

    /// A turn interrupted by a network error or an owned guest process exit
    /// is resumed automatically on the same session, a
    /// bounded number of times with backoff, instead of stopping on a red
    /// "Retry" the user must press.
    private func maybeScheduleNetworkRetry(
        threadId: AgentThreadID,
        status: AgentRunStatus,
        errorMessage: String?,
        runMetadata: RunMetadata?,
        resumeCursor: String?
    ) {
        if status == .completed {
            lock.lock(); networkRetryCounts[threadId] = nil; lock.unlock()
            return
        }
        guard status == .failed,
              let runMetadata,
              TransientNetworkRetry.isRetryableInterruption(errorMessage) else { return }
        lock.lock()
        let attempt = (networkRetryCounts[threadId] ?? 0) + 1
        guard attempt <= networkRetryDelays.count else {
            lock.unlock()
            return
        }
        networkRetryCounts[threadId] = attempt
        let token = (autoContinuationTokens[threadId] ?? 0) + 1
        autoContinuationTokens[threadId] = token
        let delay = networkRetryDelays[attempt - 1]
        lock.unlock()
        let identity = try? threadRepo.identity(of: threadId)
        let request = AgentRunRequest(
            threadId: threadId,
            provider: runMetadata.provider,
            providerInstanceId: runMetadata.providerInstanceId,
            model: runMetadata.model,
            cwd: runMetadata.cwd,
            prompt: TransientNetworkRetry.prompt,
            userMessageContent: TransientNetworkRetry.prompt,
            providerThreadId: resumeCursor,
            permissionMode: runMetadata.runtimeMode,
            reasoningEffort: runMetadata.reasoningEffort,
            reasoningModel: identity?.reasoningModel,
            distillMainEffortSelection: runMetadata.distillMainEffort,
            distillReasoningEffortSelection: runMetadata.distillReasoningEffort,
            distillExecutionMode: runMetadata.distillMode,
            serviceTier: runMetadata.serviceTier,
            interactionMode: runMetadata.interactionMode,
            runAsUser: identity?.runAsUser
        )
        agentRunLog.info("run.networkRetry.scheduled thread=\(threadId.value.uuidString, privacy: .public) attempt=\(attempt, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64((delay * 1_000_000_000).rounded()))
            }
            guard self.networkRetryStillValid(threadId: threadId, token: token) else { return }
            if let claim = self.autoContinuationClaimsBotVM {
                guard await claim(threadId, request.runId) else { return }
            }
            do {
                _ = try await self.startRun(request, isAutoContinuation: true)
            } catch {
                await self.autoContinuationReleasesBotVM?(request.runId)
            }
        }
    }

    /// Same guard as the background-await nudge, but the thread must still be
    /// in the failed state the retry was scheduled for.
    private func networkRetryStillValid(threadId: AgentThreadID, token: Int) -> Bool {
        lock.lock()
        let ok = autoContinuationTokens[threadId] == token
            && activeThreads[threadId] == nil
            && !pendingThreadStops.contains(threadId)
        lock.unlock()
        guard ok else { return false }
        return (try? threadRepo.status(of: threadId)) == .failed
    }

    /// True iff the scheduled continuation is still the latest one for the thread
    /// (token unchanged), the thread is idle (no live run), no stop is pending, and
    /// the user has not already driven the thread to a non-completed state.
    private func backgroundAwaitContinuationStillValid(threadId: AgentThreadID, token: Int) -> Bool {
        lock.lock()
        let ok = autoContinuationTokens[threadId] == token
            && activeThreads[threadId] == nil
            && !pendingThreadStops.contains(threadId)
        lock.unlock()
        guard ok else { return false }
        return (try? threadRepo.status(of: threadId)) == .completed
    }

    private func incompleteTurnContinuationRequest(
        threadId: AgentThreadID,
        runMetadata: RunMetadata,
        resumeCursor: String?,
        reason: IncompleteTurnContinuationReason
    ) -> AgentRunRequest {
        let prompt = IncompleteTurnContinuation.prompt(for: reason)
        let identity = try? threadRepo.identity(of: threadId)
        return AgentRunRequest(
            threadId: threadId,
            provider: runMetadata.provider,
            providerInstanceId: runMetadata.providerInstanceId,
            model: runMetadata.model,
            cwd: runMetadata.cwd,
            prompt: prompt,
            userMessageContent: prompt,
            providerThreadId: resumeCursor,
            permissionMode: runMetadata.runtimeMode,
            reasoningEffort: runMetadata.reasoningEffort,
            reasoningModel: identity?.reasoningModel,
            distillMainEffortSelection: runMetadata.distillMainEffort,
            distillReasoningEffortSelection: runMetadata.distillReasoningEffort,
            distillExecutionMode: runMetadata.distillMode,
            serviceTier: runMetadata.serviceTier,
            interactionMode: runMetadata.interactionMode,
            runAsUser: identity?.runAsUser
        )
    }

    private func markStartFailure(
        _ error: Error,
        request: AgentRunRequest,
        runId: AgentRunID,
        adapterKey: String,
        binaryIdentity: String?,
        preserveRecoverableSession: Bool
    ) {
        let message = String(describing: error)
        // RUN-LIFECYCLE-STREAM-002: if a DIFFERENT run is already live on this
        // thread (e.g. this start lost a race and the adapter rejected it as a
        // duplicate in-flight turn), do not clobber the live run's thread row,
        // provider session, or broadcast a false terminal status. Record only a
        // run-scoped failure so the survivor keeps streaming.
        lock.lock()
        let otherRunActive = activeThreads[request.threadId].map { $0 != runId } ?? false
        lock.unlock()
        let event = AssistantEvent.error(
            message: message,
            recoverable: !otherRunActive && preserveRecoverableSession
        )
        let payloadJSON: String
        do {
            let data = try encodeStreamEvent(event)
            guard let json = String(data: data, encoding: .utf8) else {
                throw NSError(
                    domain: "RemoteCode.AgentRunCoordinator",
                    code: 422,
                    userInfo: [NSLocalizedDescriptionKey: "Start failure event JSON was not UTF-8."]
                )
            }
            payloadJSON = json
        } catch {
            recordMirrorPersistenceFailure(error, threadId: request.threadId)
            emitPersistenceIssue("run.start_failure.encode", error: error, runId: runId, threadId: request.threadId)
            return
        }

        lock.lock()
        rememberRunThreadOwnershipLocked(runId: runId, threadId: request.threadId)
        let eventSequence = allocateStreamSequenceLocked(runId: runId, threadId: request.threadId)
        pendingStartFailures[runId] = PendingStartFailure(
            request: request,
            adapterKey: adapterKey,
            binaryIdentity: binaryIdentity,
            preserveRecoverableSession: preserveRecoverableSession,
            otherRunActive: otherRunActive,
            message: message,
            event: event,
            streamEvent: AgentRunRepository.StreamWriteIntent(
                seq: eventSequence,
                kind: event.debugDescription,
                payloadJSON: payloadJSON,
                providerEvent: nil
            ),
            finishedAt: Date()
        )
        lock.unlock()

        retryStartFailureCommit(runId: runId)
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        let adapter = try adapterForThread(threadId)
        try await adapter.respondToRequest(threadId: threadId, requestId: requestId, response: response)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) async throws {
        let adapter = try adapterForThread(threadId)
        try adapter.respondToUserInput(threadId: threadId, requestId: requestId, verbatimText: text, outboundText: text)
    }

    public func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {
        let adapter = try adapterForThread(threadId)
        try adapter.cancelUserInput(threadId: threadId, requestId: requestId)
    }

    public func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        let adapter = try adapterForThread(threadId)
        try await recoverAdapterSessionIfNeeded(threadId: threadId, adapter: adapter)
        return Self.boundedHotReplay(try await adapter.readThread(threadId: threadId))
    }

    public static func boundedHotReplay(
        _ events: [AssistantEvent],
        countLimit: Int = hotReplayEventCount,
        byteLimit: Int64 = hotReplayEventBytes
    ) -> [AssistantEvent] {
        var retained: [AssistantEvent] = []
        retained.reserveCapacity(min(events.count, max(1, countLimit)))
        var bytes: Int64 = 0
        // Walk newest→oldest so budget pressure drops older history first and
        // the live tail always wins. Never replace a large frame with a
        // recoverable "omitted" error — skip frames that cannot fit alone.
        for event in events.reversed() {
            guard retained.count < max(1, countLimit) else { break }
            // PERF: estimatedHotQueueBytes avoids JSONEncoder per retained frame.
            let eventBytes = Int64(max(1, event.estimatedHotQueueBytes))
            if eventBytes > max(1, byteLimit) {
                // Pathological single frame larger than the whole window: keep
                // walking older events rather than blocking the newest paint.
                continue
            }
            if bytes + eventBytes > max(1, byteLimit) { break }
            retained.append(event)
            bytes += eventBytes
        }
        retained.reverse()
        return retained
    }

    /// Correctness-critical state is stored in the compact provider-session row,
    /// independently of the evictable stream transcript.
    public func durableActiveThreadState(threadId: AgentThreadID) -> AgentActiveThreadState? {
        guard let providerSessionRepo else { return nil }
        // Cursor + payload JSON only. A leftover 16-column session `get`
        // (including cwd/model/status/error) hitchs thread-select rehydrate
        // just to restore plan/approval state.
        guard let chrome = try? providerSessionRepo.activeChrome(of: threadId) else { return nil }
        let payload = ProviderSessionRuntimePayload.decode(chrome.runtimePayloadJSON)
        return AgentActiveThreadState(
            resumeCursor: chrome.resumeCursor ?? payload.providerThreadId,
            activeTurnId: payload.activeTurnId,
            activePlan: payload.activePlan,
            pendingApprovalRequestIds: payload.pendingApprovalRequestIds,
            pendingUserInputRequestIds: payload.pendingUserInputRequestIds
        )
    }

    @discardableResult
    public func forkThread(
        sourceThreadId: AgentThreadID,
        childThread: AgentThread
    ) async throws -> AgentThread {
        try await forkThreadReturningPrunedThreadIDs(
            sourceThreadId: sourceThreadId,
            childThread: childThread
        ).thread
    }

    public func forkThreadReturningPrunedThreadIDs(
        sourceThreadId: AgentThreadID,
        childThread: AgentThread
    ) async throws -> AgentThreadForkResult {
        try threadRepo.requireUnscopedForkSource(sourceThreadId)
        guard sourceThreadId != childThread.id else {
            throw AgentProviderAdapterError.unsupported("fork child must have a distinct local thread identity")
        }
        guard let sourceProvider = try threadRepo.provider(of: sourceThreadId) else {
            throw AgentProviderAdapterError.sessionNotFound(sourceThreadId)
        }
        guard sourceProvider == childThread.provider else {
            throw AgentProviderAdapterError.unsupported("fork child must use the parent provider")
        }
        guard childThread.providerThreadId == nil else {
            throw AgentProviderAdapterError.unsupported("fork child provider identity must be assigned by the durable fork operation")
        }
        let adapter = try adapterForThread(sourceThreadId)
        guard (await ProviderCLIProbe.runOffCooperativePool { adapter.forkSafety(threadId: sourceThreadId) }).supportsDurableFork else {
            throw AgentProviderAdapterError.unsupported(
                "provider fork is not crash-safe: keyed idempotency and idempotent compensation are required"
            )
        }
        if let workspaceId = childThread.workspaceId {
            try threadRepo.preflightWorkspaceThreadInsertion(
                workspaceId: workspaceId,
                prospectiveThreadId: childThread.id,
                excludedVictimIDs: [sourceThreadId]
            )
        }
        try beginExclusiveThreadMutation(sourceThreadId, operation: "provider fork", requiresIdleThread: true)
        defer { endExclusiveThreadMutation(sourceThreadId) }
        try await recoverAdapterSessionIfNeeded(threadId: sourceThreadId, adapter: adapter)
        guard (await ProviderCLIProbe.runOffCooperativePool { adapter.forkSafety(threadId: sourceThreadId) }).supportsDurableFork else {
            throw AgentProviderAdapterError.unsupported(
                "provider fork schema changed after session recovery; keyed reconciliation is unavailable"
            )
        }
        let idempotencyKey = "remotecode-thread-fork:\(childThread.id.value.uuidString.lowercased())"
        let intent = try threadRepo.prepareForkIntent(
            sourceThreadId: sourceThreadId,
            childThread: childThread,
            idempotencyKey: idempotencyKey
        )
        return try await reconcileForkIntent(intent, adapter: adapter)
    }

    /// Replays every non-terminal fork intent. Provider calls are repeated only
    /// with the original stable key on adapters that guarantee idempotency.
    /// Local graph commit and the `local_committed` transition share one SQLite
    /// transaction, so neither can become visible without the other.
    public func reconcileForkIntentsOnLaunch() async {
        let intents: [AgentThreadForkIntent]
        do {
            intents = try threadRepo.listRecoverableForkIntents()
        } catch {
            agentRunLog.error("fork.reconcile.list_failed error=\(String(describing: error), privacy: .public)")
            return
        }
        for intent in intents {
            do { try threadRepo.requireUnscopedForkSource(intent.sourceThreadId) }
            catch {
                recordForkLaunchRecoveryError(childThreadId: intent.childThread.id, error: String(describing: error))
                continue
            }
            let adapter = providerAdapterSnapshot(for: intent.provider)
            guard let adapter, (await ProviderCLIProbe.runOffCooperativePool { adapter.forkSafety(threadId: intent.sourceThreadId) }).supportsDurableFork else {
                recordForkLaunchRecoveryError(
                    childThreadId: intent.childThread.id,
                    error: "Provider no longer exposes crash-safe fork recovery."
                )
                continue
            }
            await reconcileForkIntentOnLaunch(intent, adapter: adapter)
        }
    }

    private func reconcileForkIntentOnLaunch(
        _ intent: AgentThreadForkIntent,
        adapter: AgentProviderAdapter
    ) async {
        do {
            try beginExclusiveThreadMutation(intent.sourceThreadId, operation: "fork recovery", requiresIdleThread: true)
        } catch {
            agentRunLog.info(
                "fork.launch_recovery.deferred child=\(intent.childThread.id.value.uuidString, privacy: .public) reason=mutation_busy"
            )
            recordForkLaunchRecoveryError(
                childThreadId: intent.childThread.id,
                error: String(describing: error)
            )
            return
        }
        defer { endExclusiveThreadMutation(intent.sourceThreadId) }
        var committedPrunedThreadIDs: [AgentThreadID] = []
        do {
            if intent.state == .prepared, let workspaceID = intent.childThread.workspaceId {
                try threadRepo.preflightWorkspaceThreadInsertion(
                    workspaceId: workspaceID,
                    prospectiveThreadId: intent.childThread.id,
                    excludedVictimIDs: [intent.sourceThreadId]
                )
            }
            if intent.state != .compensating,
               try threadRepo.status(of: intent.sourceThreadId) != nil {
                try await recoverAdapterSessionIfNeeded(threadId: intent.sourceThreadId, adapter: adapter)
            }
            guard (await ProviderCLIProbe.runOffCooperativePool { adapter.forkSafety(threadId: intent.sourceThreadId) }).supportsDurableFork else {
                throw AgentProviderAdapterError.unsupported(
                    "provider fork recovery schema is no longer compatible"
                )
            }
            committedPrunedThreadIDs = try await reconcileForkIntent(intent, adapter: adapter).prunedThreadIDs
        } catch {
            recordForkLaunchRecoveryError(
                childThreadId: intent.childThread.id,
                error: String(describing: error)
            )
            agentRunLog.error(
                "fork.reconcile.failed child=\(intent.childThread.id.value.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return
        }
        if !committedPrunedThreadIDs.isEmpty {
            await onRecoveredForkPrunedThreadIDs?(committedPrunedThreadIDs)
        }
    }

    private func recordForkLaunchRecoveryError(
        childThreadId: AgentThreadID,
        error: String
    ) {
        do {
            try threadRepo.recordForkIntentError(
                childThreadId: childThreadId,
                error: error
            )
            agentRunLog.info(
                "fork.launch_recovery.error_persistence child=\(childThreadId.value.uuidString, privacy: .public) result=recorded"
            )
        } catch {
            agentRunLog.error(
                "fork.launch_recovery.error_persistence child=\(childThreadId.value.uuidString, privacy: .public) result=failed"
            )
        }
    }

    /// Side question against a thread's live provider session.
    public func btwThread(threadId: AgentThreadID, question: String) async throws -> String {
        let adapter = try adapterForThread(threadId)
        return try await adapter.btw(threadId: threadId, question: question)
    }

    /// Closes an ephemeral side thread: compensates the provider child and deletes
    /// the local row. Closing a missing or non-ephemeral thread is a no-op.
    public func closeSideThread(threadId: AgentThreadID) async throws {
        guard let thread = try? threadRepo.get(id: threadId), thread.isEphemeral else { return }
        if let providerThreadId = thread.providerThreadId, !providerThreadId.isEmpty,
           let adapter = providerAdapterSnapshot(for: thread.provider) {
            let request = AgentProviderForkRequest(
                sourceThreadId: thread.parentThreadId ?? threadId,
                childThreadId: threadId,
                idempotencyKey: "remotecode-thread-fork:\(threadId.value.uuidString.lowercased())",
                workingDirectory: thread.worktreePath,
                sourceProviderThreadId: nil
            )
            try? await adapter.compensateFork(request, providerChildThreadId: providerThreadId)
        }
        stopRun(threadId: threadId)
        try threadRepo.delete(id: threadId)
    }

    /// Deletes ephemeral side threads left by a previous launch and compensates
    /// their provider children. Runs once at launch, before any new side thread
    /// can exist, so it never deletes live work.
    public func sweepEphemeralThreadsOnLaunch() async {
        let rows = (try? threadRepo.ephemeralThreadSweepRows()) ?? []
        guard !rows.isEmpty else { return }
        _ = try? threadRepo.deleteEphemeralThreads()
        for row in rows {
            guard let providerThreadId = row.providerThreadId,
                  let adapter = providerAdapterSnapshot(for: row.provider) else { continue }
            guard (await ProviderCLIProbe.runOffCooperativePool { adapter.forkSafety(threadId: row.parentThreadId ?? row.id) }).supportsDurableFork else {
                continue
            }
            let request = AgentProviderForkRequest(
                sourceThreadId: row.parentThreadId ?? row.id,
                childThreadId: row.id,
                idempotencyKey: "remotecode-thread-fork:\(row.id.value.uuidString.lowercased())",
                workingDirectory: row.worktreePath,
                sourceProviderThreadId: nil
            )
            try? await adapter.compensateFork(request, providerChildThreadId: providerThreadId)
        }
    }

    private func beginExclusiveThreadMutation(
        _ threadId: AgentThreadID,
        operation: String,
        requiresIdleThread: Bool = false
    ) throws {        lock.lock(); defer { lock.unlock() }
        guard !exclusiveThreadMutations.contains(threadId),
              !requiresIdleThread || activeThreads[threadId] == nil else {
            throw AgentProviderAdapterError.unsupported(
                "\(operation) cannot begin while another provider mutation is active for this thread"
            )
        }
        exclusiveThreadMutations.insert(threadId)
    }

    private func endExclusiveThreadMutation(_ threadId: AgentThreadID) {
        lock.lock(); defer { lock.unlock() }
        exclusiveThreadMutations.remove(threadId)
    }

    private func providerAdapterSnapshot(for provider: AgentProvider) -> AgentProviderAdapter? {
        lock.lock(); defer { lock.unlock() }
        return providers[provider]
    }

    private func reconcileForkIntent(
        _ initialIntent: AgentThreadForkIntent,
        adapter: AgentProviderAdapter
    ) async throws -> AgentThreadForkResult {
        try threadRepo.requireUnscopedForkSource(initialIntent.sourceThreadId)
        var intent = try threadRepo.getForkIntent(childThreadId: initialIntent.childThread.id) ?? initialIntent
        // Cheap existence + cursor. First-time fork misses the child; a 26-column
        // + routing get would only compile nil. Load the full row only to return
        // the idempotent committed child.
        if let persistedProviderThreadId = try threadRepo.providerThreadId(of: intent.childThread.id) {
            let persistedCursor = persistedProviderThreadId.isEmpty ? nil : persistedProviderThreadId
            guard intent.state == .localCommitted,
                  persistedCursor == intent.providerChildThreadId else {
                throw AgentThreadForkPersistenceError.childThreadConflict
            }
            guard let child = try threadRepo.get(id: intent.childThread.id) else {
                throw AgentThreadForkPersistenceError.childThreadConflict
            }
            return AgentThreadForkResult(thread: child, prunedThreadIDs: [])
        }
        guard intent.state != .localCommitted else {
            throw AgentThreadForkPersistenceError.childThreadConflict
        }
        let request = AgentProviderForkRequest(
            sourceThreadId: intent.sourceThreadId,
            childThreadId: intent.childThread.id,
            idempotencyKey: intent.idempotencyKey,
            workingDirectory: intent.childThread.worktreePath,
            // Cursor only. A leftover 26-column + routing `get` hitchs fork
            // recovery just to copy provider_thread_id.
            sourceProviderThreadId: try threadRepo.providerThreadId(of: intent.sourceThreadId)
                .flatMap { $0.isEmpty ? nil : $0 },
            sourceWorkingDirectory: ((try? providerSessionRepo?.get(threadId: intent.sourceThreadId)) ?? nil)?
                .cwd.flatMap { $0.isEmpty ? nil : $0 }
        )

        if intent.state == .compensated {
            throw AgentProviderAdapterError.unsupported("provider fork was compensated after local commit became impossible")
        }
        if intent.state == .abandoned {
            throw AgentProviderAdapterError.unsupported("provider fork was abandoned before provider creation")
        }
        if intent.state == .compensating {
            guard let providerChildThreadId = intent.providerChildThreadId else {
                throw AgentThreadForkPersistenceError.corruptIntent
            }
            try await adapter.compensateFork(request, providerChildThreadId: providerChildThreadId)
            try threadRepo.markForkCompensated(childThreadId: intent.childThread.id)
            throw AgentProviderAdapterError.unsupported("provider fork was compensated after local commit became impossible")
        }

        if intent.state == .prepared {
            guard try threadRepo.status(of: intent.sourceThreadId) != nil else {
                if !intent.providerCreationAttempted {
                    try threadRepo.markPreparedForkAbandoned(
                        childThreadId: intent.childThread.id,
                        error: "Source thread disappeared before provider creation."
                    )
                }
                throw AgentThreadForkPersistenceError.sourceThreadNotFound
            }
            intent = try threadRepo.markForkProviderCreationAttempted(
                childThreadId: intent.childThread.id
            )
            let providerChildThreadId: String
            do {
                providerChildThreadId = try await adapter.forkThread(request)
            } catch AgentProviderAdapterError.forkRejected(let reason) {
                // Nothing was created: retire the intent so the next fork works.
                try? threadRepo.retireRejectedForkIntent(childThreadId: intent.childThread.id)
                throw AgentProviderAdapterError.forkRejected(reason)
            } catch {
                try? threadRepo.recordForkIntentError(
                    childThreadId: intent.childThread.id,
                    error: String(describing: error)
                )
                throw error
            }
            let sourceProviderThreadId = try threadRepo.providerThreadId(of: intent.sourceThreadId)
                .flatMap { $0.isEmpty ? nil : $0 }
            guard !providerChildThreadId.isEmpty,
                  providerChildThreadId != sourceProviderThreadId else {
                throw AgentProviderAdapterError.unsupported("provider-native fork did not return a distinct child session")
            }
            intent = try threadRepo.recordForkProviderCreated(
                childThreadId: intent.childThread.id,
                providerChildThreadId: providerChildThreadId
            )
        }

        guard intent.state == .providerCreated,
              let providerChildThreadId = intent.providerChildThreadId else {
            throw AgentThreadForkPersistenceError.invalidIntentState(intent.state)
        }
        var persistedChild = intent.childThread
        persistedChild.providerThreadId = providerChildThreadId
        persistedChild.status = .completed
        persistedChild.hasUnread = false
        persistedChild.updatedAt = Date()
        let sourceRuntime = try providerSessionRepo?.forkSourceIdentity(of: intent.sourceThreadId)
        let childRuntime = providerSessionRepo.map { _ in
            ProviderSessionRuntime(
                threadId: persistedChild.id,
                provider: persistedChild.provider,
                providerInstanceId: persistedChild.providerInstanceId,
                adapterKey: sourceRuntime?.adapterKey ?? providerAdapterKey(adapter),
                binaryIdentity: sourceRuntime?.binaryIdentity ?? providerBinaryIdentity(persistedChild.provider, adapter: adapter),
                status: .completed,
                resumeCursor: providerChildThreadId,
                cwd: sourceRuntime?.cwd ?? persistedChild.worktreePath,
                model: persistedChild.model,
                serviceTier: persistedChild.serviceTier,
                runtimeMode: persistedChild.permissionMode,
                lastEventKind: "thread/forked",
                updatedAt: persistedChild.updatedAt
            )
        }
        do {
            let prunedThreadIDs = try threadRepo.persistForkedChildGraphReturningPrunedThreadIDs(
                sourceThreadId: intent.sourceThreadId,
                childThread: persistedChild,
                providerSession: childRuntime,
                forkIntentChildThreadId: intent.childThread.id
            )
            // The local graph transaction has committed. Retire only its returned
            // victims now; fork intent transitions and lifecycle publication stay
            // with their existing callers.
            retireDeletedThreads(prunedThreadIDs)
            return AgentThreadForkResult(thread: persistedChild, prunedThreadIDs: prunedThreadIDs)
        } catch {
            let forkPersistenceRequiresCompensation: Bool
            if let forkError = error as? AgentThreadForkPersistenceError {
                forkPersistenceRequiresCompensation = forkError == .sourceThreadNotFound
                    || forkError == .childThreadConflict
                    || forkError == .intentConflict
            } else {
                forkPersistenceRequiresCompensation = false
            }
            if forkPersistenceRequiresCompensation || error is AgentThreadCapacityError {
                _ = try threadRepo.markForkCompensating(
                    childThreadId: intent.childThread.id,
                    error: String(describing: error)
                )
                try await adapter.compensateFork(request, providerChildThreadId: providerChildThreadId)
                try threadRepo.markForkCompensated(childThreadId: intent.childThread.id)
                throw error
            }
            try? threadRepo.recordForkIntentError(
                childThreadId: intent.childThread.id,
                error: String(describing: error)
            )
            throw error
        }
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        let adapter = try adapterForThread(threadId)
        try await recoverAdapterSessionIfNeeded(threadId: threadId, adapter: adapter)
        try await adapter.rollbackThread(threadId: threadId, toTurnId: toTurnId)
    }

    @discardableResult
    public func revertThreadToCheckpoint(threadId: AgentThreadID, checkpointTurnCount: Int, cwd: String) async throws -> AgentTurnCheckpointSummary {
        guard let checkpointRepo else {
            throw AgentProviderAdapterError.unsupported("checkpoint repository is unavailable")
        }
        guard let checkpoint = try checkpointRepo.get(threadId: threadId, checkpointTurnCount: checkpointTurnCount) else {
            throw AgentProviderAdapterError.unsupported("checkpoint \(checkpointTurnCount) not found")
        }
        guard checkpoint.status == .ready else {
            throw AgentProviderAdapterError.unsupported("checkpoint \(checkpointTurnCount) is \(checkpoint.status.rawValue)")
        }
        guard !checkpoint.fileSnapshots.isEmpty || checkpoint.files.isEmpty else {
            throw AgentProviderAdapterError.unsupported("checkpoint \(checkpointTurnCount) has no restorable file snapshot")
        }
        guard GitDiff.isGit(cwd) else {
            throw AgentProviderAdapterError.unsupported("checkpoint revert requires a git workspace")
        }

        let newer = try checkpointRepo.listAfter(threadId: threadId, checkpointTurnCount: checkpointTurnCount)
        try validateRestorableSnapshots(in: checkpoint, newerCheckpoints: newer, cwd: cwd)
        // UX-MAC-CHECKPOINT-REVERT-UNDO: capture the forward state the revert is
        // about to DESTROY — pre-revert on-disk bytes for every affected path and
        // the message rows about to be deleted — BEFORE restoreWorkspace + the
        // deletes run. This must happen here (post-validate, pre-mutation) or it
        // would snapshot the reverted state. Pure read + store; revert behavior
        // below is unchanged.
        captureCheckpointRevertUndo(threadId: threadId, target: checkpoint, newer: newer, cwd: cwd)
        try await rollbackThread(threadId: threadId, toTurnId: checkpoint.turnId)
        try restoreWorkspace(to: checkpoint, newerCheckpoints: newer, cwd: cwd)
        try messageRepo.delete(ids: newer.compactMap(\.assistantMessageId))
        try checkpointRepo.deleteAfter(threadId: threadId, checkpointTurnCount: checkpointTurnCount)
        // PERF-MAC_AGENT-006: assistant rows were just deleted — drop the dedup
        // cache so a re-run can legitimately re-persist matching text.
        lock.lock(); lastPersistedAssistantContent.removeValue(forKey: threadId); lock.unlock()
        return checkpoint
    }

    /// Hot replay is bounded independently by encoded bytes and row count. Durable
    /// messages and compact ActiveThreadState preserve completed output and resume
    /// correctness when the evictable event prefix is outside this window.
    /// Was 16_384 / 256 MiB; 4_096 / 32 MiB still rehydrates recent Full Access /
    /// Chrome turns without multi-hundred-MB event arrays (memory-loop tip).
    public static let hotReplayEventCount = 4_096
    public static let hotReplayEventBytes: Int64 = 32 * 1_024 * 1_024

    public func latestStreamEvents(threadId: AgentThreadID) -> [AssistantEvent] {
        (try? runRepo.listLatestStreamEvents(
            threadId: threadId,
            limit: Self.hotReplayEventCount,
            maxPayloadBytes: Self.hotReplayEventBytes
        )) ?? []
    }

    /// Cheap COUNT(*) for UI change detection. Prefer this over
    /// `latestStreamEvents(...).count` so idle live-polls avoid full payload decode.
    public func countStreamEvents(threadId: AgentThreadID) -> Int {
        (try? runRepo.countStreamEvents(threadId: threadId)) ?? 0
    }

    public func streamEventCursor(threadId: AgentThreadID) -> AgentRunRepository.StreamEventCursor {
        (try? runRepo.streamEventCursor(threadId: threadId))
            ?? AgentRunRepository.StreamEventCursor(
                count: 0,
                rowId: nil,
                runId: nil,
                sequence: 0,
                mutationId: nil
            )
    }

    public struct StreamEventSuffix: Sendable, Equatable {
        public let events: [AssistantEvent]
        public let decodedPayloadBytes: Int64

        public init(events: [AssistantEvent], decodedPayloadBytes: Int64) {
            self.events = events
            self.decodedPayloadBytes = decodedPayloadBytes
        }
    }

    /// Decode only after every replay-view mutation covered by the cursor has
    /// been proven to be the expected contiguous suffix of one run. An extra
    /// external row, a sequence gap, corruption, or an oversized suffix returns
    /// nil so callers fail closed to a full hot replay.
    public func attestedStreamEventSuffix(
        threadId: AgentThreadID,
        afterMutationId: Int64,
        throughMutationId: Int64,
        runId: AgentRunID,
        startingSequence: Int,
        count: Int
    ) -> StreamEventSuffix? {
        guard count > 0,
              count <= Self.hotReplayEventCount,
              throughMutationId > afterMutationId else { return nil }
        do {
            let metadata = try runRepo.listStreamEventMutations(
                threadId: threadId,
                afterMutationId: afterMutationId,
                throughMutationId: throughMutationId,
                limit: count + 1
            )
            guard metadata.count == count,
                  metadata.last?.mutationId == throughMutationId,
                  metadata.enumerated().allSatisfy({ offset, row in
                      row.runId == runId && row.sequence == startingSequence + offset
                  }) else { return nil }
            let bytes = metadata.reduce(Int64(0)) { $0 + $1.payloadBytes }
            guard bytes <= Self.hotReplayEventBytes else { return nil }
            let events = try runRepo.listStreamEventsByIds(
                metadata.map(\.id),
                strictDecoding: true,
                remainingByteBudget: Self.hotReplayEventBytes
            )
            guard events.count == count else { return nil }
            return StreamEventSuffix(
                events: events,
                decodedPayloadBytes: bytes
            )
        } catch {
            return nil
        }
    }

    public func hotReplayIsPartial(threadId: AgentThreadID) -> Bool {
        ((try? runRepo.streamHistoryWasPruned(threadId: threadId)) ?? false)
            || ((try? runRepo.countStreamEvents(threadId: threadId)) ?? 0) > Self.hotReplayEventCount
            || ((try? runRepo.streamEventPayloadBytes(threadId: threadId)) ?? 0) > Self.hotReplayEventBytes
    }

    /// Returns the exact locally-processed AssistantEvent snapshot while
    /// preventing a matching EventBus publication from crossing the caller's
    /// watermark capture. This is the recovery contract used by iOS; unlike
    /// `readThread`, it never races a fresh provider-side mutable snapshot.
    ///
    /// - Parameter limit: Max newest rows to load from SQLite (default unbounded).
    ///   Callers that need a count-truncation probe should pass `eventLimit + 1`.
    ///   Prefer `withMirrorEventSnapshotForThreadReadV1` for byte-capped recovery.
    public func withMirrorEventSnapshot<T>(
        threadId: AgentThreadID,
        limit: Int = .max,
        _ body: ([AssistantEvent]) -> T
    ) throws -> T {
        try withMirrorEventLock(threadId: threadId) {
            body(try runRepo.listLatestStreamEvents(
                threadId: threadId,
                limit: limit,
                strictDecoding: true
            ))
        }
    }

    /// Metadata-first bounded snapshot for `agent.thread.read` response_version=1.
    /// Never decodes a newest row whose stored `payload_json` exceeds `maxPayloadBytes`,
    /// and never materializes full history under the mirror lock.
    public func withMirrorEventSnapshotForThreadReadV1<T>(
        threadId: AgentThreadID,
        eventLimit: Int,
        maxPayloadBytes: Int64,
        _ body: (AgentRunRepository.BoundedStreamEventSelection) throws -> T
    ) throws -> T {
        try withMirrorEventLock(threadId: threadId) {
            try body(try runRepo.listLatestStreamEventsForThreadReadV1(
                threadId: threadId,
                eventLimit: eventLimit,
                maxPayloadBytes: maxPayloadBytes,
                strictDecoding: true
            ))
        }
    }

    /// Shared lock + flush so watermark capture cannot race a concurrent append.
    /// Persistence diagnostics for a failed barrier flush fire only after the lock
    /// is released (callback fan-out must not run under `mirrorEventLock`).
    private enum MirrorEventLockOutcome<T> {
        case value(T)
        case failure(Error, deferred: DeferredPersistenceIssue?)
    }

    private func withMirrorEventLock<T>(
        threadId: AgentThreadID,
        _ body: () throws -> T
    ) throws -> T {
        let outcome: MirrorEventLockOutcome<T> = {
            mirrorEventLock(for: threadId).lock()
            defer { mirrorEventLock(for: threadId).unlock() }
            lock.lock()
            let priorFailure = mirrorPersistenceFailures[threadId]
            lock.unlock()
            if let priorFailure { return .failure(priorFailure, deferred: nil) }
            lock.lock()
            let bufferedRunId = pendingStreamRunIds[threadId]
            lock.unlock()
            if let runId = bufferedRunId ?? activeRunId(threadId: threadId) {
                let attempt = flushPendingStreamWritesResult(runId: runId, threadId: threadId)
                if let error = attempt.error {
                    return .failure(error, deferred: attempt.deferredIssue)
                }
            }
            do {
                return .value(try body())
            } catch {
                return .failure(error, deferred: nil)
            }
        }()
        switch outcome {
        case .value(let value):
            return value
        case .failure(let error, let deferred):
            if let deferred {
                emitPersistenceIssue(
                    deferred.operation,
                    error: deferred.error,
                    runId: deferred.runId,
                    threadId: deferred.threadId
                )
            }
            throw error
        }
    }

    public func activeThreadIdsSnapshot() -> Set<AgentThreadID> {
        lock.lock(); defer { lock.unlock() }
        return Set(activeThreads.keys)
    }

    /// Active threads excluding delegated child runs (bot peers consulted by a
    /// primary agent). The sidebar Active Threads badge/window and Pet count
    /// these; delegated workers surface in the Subagents panel instead.
    public func primaryActiveThreadIdsSnapshot() -> Set<AgentThreadID> {
        lock.lock(); defer { lock.unlock() }
        return Self.primaryActiveThreadIds(
            activeThreads: activeThreads,
            delegatedRunParents: delegatedRuns.mapValues(\.parentRunId)
        )
    }

    /// Pure seam for the snapshot filter (unit-testable without a coordinator).
    nonisolated static func primaryActiveThreadIds(
        activeThreads: [AgentThreadID: AgentRunID],
        delegatedRunParents: [AgentRunID: AgentRunID]
    ) -> Set<AgentThreadID> {
        Set(activeThreads.compactMap { threadId, runId in
            delegatedRunParents[runId] == nil ? threadId : nil
        })
    }

    public func isDelegatedRun(_ runId: AgentRunID, threadId: AgentThreadID, parentRunId: AgentRunID? = nil) -> Bool {
        lock.withLock {
            guard let delegated = delegatedRuns[runId], delegated.threadId == threadId else { return false }
            return parentRunId == nil || delegated.parentRunId == parentRunId
        }
    }

    public func delegatedParentRunId(_ runId: AgentRunID, threadId: AgentThreadID) -> AgentRunID? {
        lock.withLock {
            guard let delegated = delegatedRuns[runId], delegated.threadId == threadId else { return nil }
            return delegated.parentRunId
        }
    }

    /// Marks `runId` (on `threadId`) as a delegated child of `parentRunId` — a
    /// bot peer run started on behalf of a primary run. Registration happens
    /// before dispatch so the badge filter and the Stop cascade cover the child
    /// even while its provider start is still in preflight (thread-based stop
    /// arms `pendingThreadStops`, so a not-yet-started child cannot spawn
    /// orphaned). Idempotent; self-parenting is refused.
    public func registerDelegatedRun(
        _ runId: AgentRunID,
        threadId: AgentThreadID,
        parentRunId: AgentRunID
    ) {
        guard runId != parentRunId else { return }
        lock.lock()
        delegatedRuns[runId] = DelegatedRunLink(parentRunId: parentRunId, threadId: threadId)
        // Bound the map: registrations whose child run never started (failed
        // dispatch) have no teardown hook, so cap-prune dead rows here.
        if delegatedRuns.count > 512 {
            let live = Set(activeThreads.values).union(active.keys)
            delegatedRuns = delegatedRuns.filter {
                live.contains($0.key) || $0.key == runId
            }
        }
        lock.unlock()
    }

    /// Stops delegated descendants owned by this thread without stopping the
    /// parent run itself. Snapshot parent IDs before resolving their durable routes.
    public func stopDelegatedRunsForThread(threadId: AgentThreadID) throws {
        lock.lock()
        let parentRunIds = Set(delegatedRuns.values.map(\.parentRunId))
        lock.unlock()
        for parentRunId in parentRunIds {
            guard try runRepo.route(of: parentRunId)?.threadId == threadId else { continue }
            stopDelegatedChildRuns(of: parentRunId)
        }
    }

    private func stopDelegatedChildRuns(of runId: AgentRunID) {
        lock.lock()
        guard !cascadeStopsInFlight.contains(runId) else {
            lock.unlock()
            return
        }
        var visited: Set<AgentRunID> = [runId]
        var frontier = [runId]
        var descendantRunIds: [AgentRunID] = []
        while let parentRunId = frontier.popLast() {
            for (childRunId, link) in delegatedRuns where link.parentRunId == parentRunId {
                guard visited.insert(childRunId).inserted else { continue }
                frontier.append(childRunId)
                descendantRunIds.append(childRunId)
            }
        }
        let ownedStops = visited.subtracting(cascadeStopsInFlight)
        cascadeStopsInFlight.formUnion(ownedStops)
        lock.unlock()
        defer {
            lock.lock()
            cascadeStopsInFlight.subtract(ownedStops)
            lock.unlock()
        }
        descendantRunIds.forEach { stopRun($0) }
    }

    private func activeRunProjectionLocked() -> ActiveRunProjection {
        // User-facing projection (Pet, Live Activity): primary runs only.
        // Delegated bot-peer workers surface in the Subagents panel instead.
        ActiveRunProjection(runs: activeThreads.compactMap {
            guard delegatedRuns[$0.value] == nil else { return nil }
            return ActiveRunProjection.Run(threadId: $0.key, runId: $0.value)
        })
    }

    /// Returns true when the thread was relaunch-interrupted and still has a
    /// recoverable provider session that the inline Continue action can resume.
    /// WHY: coordinator owns providerSessionRepo; surface should not reach
    /// through to the repo directly.
    ///
    /// Completed/cancelled/failed threads must never surface Continue even when
    /// a stale session row still has a resume cursor or an `interrupted` status
    /// left behind by launch reconciliation of a leftover running session.
    public func hasRecoverableContext(threadId: AgentThreadID) -> Bool {
        guard (try? threadRepo.status(of: threadId)) == .interrupted else {
            return false
        }
        guard let repo = providerSessionRepo else { return false }
        // recoveryState treats completed+cursor as recoverable for multi-turn
        // startRun resume. Continue is only for relaunch-interrupted sessions.
        switch (try? repo.recoveryState(threadId: threadId)) ?? .unrecoverable("no repo") {
        case .recoverable(let session):
            return session.status == .interrupted
        default:
            return false
        }
    }

    /// Terminal thread statuses that are not relaunch-interrupt recovery targets.
    nonisolated static func isTerminalThreadStatus(_ status: AgentRunStatus) -> Bool {
        switch status {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        case .pending, .running:
            return false
        }
    }

    public func stopAllProviderSessions() {
        lock.lock()
        let adapters = Array(providers.values)
        lock.unlock()
        adapters.forEach { $0.stopAll() }
    }

    public func stopAllProviderSessionsForAppTermination() {
        lock.lock()
        // activeThreads: threadId -> runId
        let livePairs = Array(activeThreads)
        let adapters = Array(providers.values)
        lock.unlock()
        for (threadId, runId) in livePairs {
            _ = recordTerminalTransition(
                runId: runId,
                threadId: threadId,
                requestedStatus: .interrupted,
                initiator: .appTermination
            )
        }
        adapters.forEach { $0.stopAllForAppTermination() }
    }

    /// Pick the adapter by durable provider only. A full 26-column + routing
    /// `get` is wasted on send/queue `hasProviderSession` and fork/stop probes.
    private func adapterForThread(_ threadId: AgentThreadID) throws -> AgentProviderAdapter {
        guard let provider = try threadRepo.listChrome(ids: [threadId])[threadId]?.provider else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        lock.lock()
        let adapter = providers[provider]
        lock.unlock()
        guard let adapter else {
            throw AgentRunError.missingBinary(provider.rawValue)
        }
        return adapter
    }

    public func resumeCursorForRun(_ request: AgentRunRequest) throws -> String? {
        let cursor = try recoverableResumeContext(for: request)?.resumeCursor
        if request.provider == .distill, let cursor {
            guard let providerSessionRepo else {
                throw AgentProviderAdapterError.unsupported("Scoped provider recovery metadata is unavailable.")
            }
            let payload = ProviderSessionRuntimePayload.decode(try providerSessionRepo.runtimePayloadJSON(of: request.threadId) ?? nil)
            guard payload.distillRetiredSessionIds?.contains(cursor) != true else {
                throw AgentProviderAdapterError.unsupported("Scoped provider history was retired; explicit repair is required.")
            }
            let previousModel = payload.distillSessionId == cursor ? payload.distillSessionModel
                : try providerSessionRepo.sessionModel(of: request.threadId, resumeCursor: cursor)
            guard !DistillACPAdapter.isCrossModelFamilySwitch(from: previousModel, to: request.model) else {
                throw AgentProviderAdapterError.unsupported("Scoped provider history cannot change model family implicitly.")
            }
        }
        return cursor
    }

    private func recoverableResumeContext(for request: AgentRunRequest) throws -> ProviderRecoveryContext? {
        if let liveSession = liveAdapterSession(for: request) {
            return ProviderRecoveryContext(resumeCursor: liveSession.providerThreadId)
        }
        guard let providerSessionRepo else { return nil }
        switch try providerSessionRepo.recoveryState(threadId: request.threadId) {
        case .recoverable(let session) where session.provider == request.provider:
            return ProviderRecoveryContext(session: session)
        case .active(let session) where session.provider == request.provider:
            if session.resumeCursor?.isEmpty == false {
                return ProviderRecoveryContext(session: session)
            }
            if let cursor = try threadRepo.providerThreadId(of: request.threadId), !cursor.isEmpty {
                throw AgentProviderAdapterError.unsupported("Provider session is marked active but no live provider session or resume cursor is available; restart recovery cannot safely continue this thread.")
            }
            return nil
        case .stopped(let session) where session.provider == request.provider:
            if session.resumeCursor?.isEmpty != false,
               let cursor = try threadRepo.providerThreadId(of: request.threadId),
               cursor.isEmpty {
                return nil
            }
            throw AgentProviderAdapterError.unsupported("Session was stopped. Tap Continue to resume from the last checkpoint, or start a new thread.")
        case .unrecoverable(let reason):
            if let cursor = try threadRepo.providerThreadId(of: request.threadId), !cursor.isEmpty {
                throw AgentProviderAdapterError.unsupported(reason)
            }
            return nil
        default:
            return nil
        }
    }

    private func liveAdapterSession(for request: AgentRunRequest) -> AgentProviderSessionSummary? {
        lock.lock()
        let adapter = providers[request.provider]
        lock.unlock()
        return adapter?.listSessions().first { session in
            session.threadId == request.threadId && session.provider == request.provider
        }
    }

    private func providerAdapterKey(_ adapter: AgentProviderAdapter) -> String {
        let adapterType = String(describing: type(of: adapter))
        if let oneShot = adapter as? OneShotProviderAdapter {
            return "\(adapterType):\(String(describing: type(of: oneShot.runner)))"
        }
        return adapterType
    }

    private func refreshProviderProcessIfScopeChanged(
        _ adapter: AgentProviderAdapter,
        request: AgentRunRequest
    ) throws {
        if request.attachToProviderPromptId != nil {
            // Adopting a wake turn must never recycle the process holding the
            // scheduler and its buffered wake; no live session fails closed.
            guard adapter.hasSession(threadId: request.threadId) else {
                throw AgentProviderAdapterError.sessionNotFound(request.threadId)
            }
            return
        }
        guard adapter.hasSession(threadId: request.threadId) else { return }
        let nextScope = ProviderTurnScope(environment: request.environment)
        lock.lock()
        let priorScope = providerTurnScopes[request.threadId]
        lock.unlock()
        let scopeChanged = priorScope.map { $0 != nextScope }
            ?? nextScope.carriesHostScope
        guard scopeChanged else { return }
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported(
                "Provider process scope changed before a durable provider thread id was available; refusing to reuse a stale provider process scope."
            )
        }
        try adapter.stopSession(threadId: request.threadId)
        lock.lock()
        providerTurnScopes.removeValue(forKey: request.threadId)
        lock.unlock()
    }

    public enum SchedulerResumeError: LocalizedError {
        case guestSessionNotLive
        public var errorDescription: String? {
            "Bot loops resume when the bot's next turn starts"
        }
    }

    /// Reloads the provider session of a finished thread so its in-process scheduler (Distill `/loop`) re-arms.
    public func resumeSessionForScheduler(threadId: AgentThreadID) async throws {
        let adapter = try adapterForThread(threadId)
        try await recoverAdapterSessionIfNeeded(threadId: threadId, adapter: adapter, allowTerminalStatus: true)
        // Guest (bot) recovery opens nothing, so success alone does not prove the scheduler re-armed.
        if let distill = adapter as? DistillACPAdapter, !distill.hasLiveSession(threadId: threadId) {
            throw SchedulerResumeError.guestSessionNotLive
        }
    }

    private func recoverAdapterSessionIfNeeded(
        threadId: AgentThreadID,
        adapter: AgentProviderAdapter,
        allowTerminalStatus: Bool = false
    ) async throws {
        guard !adapter.hasSession(threadId: threadId) else { return }
        guard let thread = try threadRepo.adapterRecovery(of: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        // Terminal completed/failed/cancelled: never spin recovery on open/read.
        // A stale provider_sessions resume_cursor after unclean shutdown used to
        // re-start a recovery run and bump thread.updatedAt → rail date "now"
        // while multipass-reloading the transcript. Interrupted keeps recovery
        // for the explicit Continue path.
        switch thread.status {
        case .completed, .failed, .cancelled:
            if !allowTerminalStatus { return }
        case .pending, .running, .interrupted:
            break
        }
        guard let session = try providerSessionRepo?.adapterRecoverySession(of: threadId),
              session.provider == thread.provider,
              let resumeCursor = session.resumeCursor,
              !resumeCursor.isEmpty else {
            return
        }
        let cwd = session.cwd ?? thread.worktreePath
        guard let cwd, !cwd.isEmpty else {
            throw AgentProviderAdapterError.unsupported("Provider session recovery requires cwd")
        }
        let activeTurnId = session.activeTurnId
        // Recovered sessions are rebuilt here, bypassing the app shell's
        // providerEnvironment, so re-derive the host environment (Subagents
        // telemetry) and always keep the provider tag.
        let recoveryRunID = AgentRunID()
        let recoveryEventRunId = try recoveryEventRunId(session: session, thread: thread, threadId: threadId)
        var environment = await recoveryEnvironmentProvider?(thread.provider, threadId) ?? [:]
        environment["REMOTE_CODE_AGENT_PROVIDER"] = thread.provider.rawValue
        // Resume bypasses providerEnvironment; stamp the attempt identity so
        // nested worker inheritance matches a normal startRun path.
        let recoveryAttempt = recoveryRunID.value.uuidString
        environment["RC_REMOTE_CODE_ROOT_RUN_ID"] = recoveryEventRunId.value.uuidString
        environment["RC_REMOTE_CODE_ATTEMPT_ID"] = recoveryAttempt
        let request = AgentRunRequest(
            runId: recoveryRunID,
            threadId: threadId,
            provider: thread.provider,
            providerInstanceId: thread.providerInstanceId,
            model: session.model ?? thread.model,
            cwd: cwd,
            prompt: "",
            providerThreadId: resumeCursor,
            permissionMode: session.runtimeMode,
            reasoningEffort: thread.reasoningEffort,
            reasoningModel: thread.reasoningModel,
            serviceTier: session.serviceTier,
            interactionMode: .default,
            environment: environment,
            extraArgs: activeTurnId.map { ["remotecode.recovery.activeTurnId=\($0)"] } ?? [],
            runAsUser: thread.runAsUser
        )
        try await adapter.recoverSession(request) { [weak self] event in
            self?.handle(event: event, runId: recoveryEventRunId, threadId: threadId)
        }
        lock.lock()
        providerTurnScopes[threadId] = ProviderTurnScope(environment: request.environment)
        lock.unlock()
        // A recovery spawned a process for this thread: count it as use, or the
        // idle reaper releases an old row's fresh process on its next tick.
        try? providerSessionRepo?.stampUsed(threadId: threadId)
    }

    private func recoveryEventRunId(
        session: ProviderSessionRuntimeRepository.AdapterRecoverySession,
        thread: AgentThreadRepository.AdapterRecoveryChrome,
        threadId: AgentThreadID
    ) throws -> AgentRunID {
        if let runId = session.lastRunId, try runRepo.status(of: runId) != nil {
            return runId
        }
        let runId = AgentRunID()
        let status: AgentRunStatus = switch session.status {
        case .pending, .running: .interrupted
        default: session.status
        }
        try runRepo.upsert(AgentRun(
            id: runId,
            threadId: threadId,
            provider: thread.provider,
            providerInstanceId: thread.providerInstanceId,
            model: session.model ?? thread.model,
            status: status
        ))
        // last_run_id + updated_at only. A leftover 16-column session `get`
        // then `upsert` hitchs recovery just to stamp the minted run,
        // rewriting cwd/model/status/error and `runtime_payload_json`.
        try providerSessionRepo?.stampLastRunId(threadId: threadId, lastRunId: runId)
        return runId
    }

    private func providerBinaryIdentity(_ provider: AgentProvider, adapter: AgentProviderAdapter) -> String? {
        guard adapter is OneShotProviderAdapter else { return providerAdapterKey(adapter) }
        let binaryName = provider.rawValue
        let resolvedBinary = provider == .distill
            ? ProcessLocator.resolveDistillAgent(binaryName)
            : ProcessLocator.resolve(binaryName)
        if let path = resolvedBinary {
            return "\(binaryName):\(path)"
        }
        return "\(binaryName):unresolved"
    }

    // PERF-MAC_AGENT-007 / AG-001: a snapshot of stream-event writes plus whether
    // a prune is due. The live buffer is acknowledged only after the repository
    // transaction commits, so a failed flush remains retryable byte-for-byte.
    private struct BatchFlush {
        var items: [StreamWriteItem]
        var pruneDue: Bool
    }

    /// Must be called with `lock` held. Snapshots without draining; commit
    /// acknowledgement removes this exact prefix later.
    private func takeStreamFlushLocked(threadId: AgentThreadID, pruneDue: Bool, nowMs: Int64) -> BatchFlush? {
        let effectivePruneDue = pruneDue || pendingStreamPrunes.contains(threadId)
        guard let batch = pendingStreamWrites[threadId], !batch.isEmpty else {
            if effectivePruneDue { return BatchFlush(items: [], pruneDue: true) }
            return nil
        }
        lastStreamFlushMs[threadId] = nowMs
        return BatchFlush(items: batch.snapshot(), pruneDue: effectivePruneDue)
    }

    /// Deferred host/observer diagnostic. Emitted only after `mirrorEventLock` is
    /// released so snapshot capture cannot deadlock on main/UI fan-out.
    private struct DeferredPersistenceIssue {
        let operation: String
        let error: Error
        let runId: AgentRunID
        let threadId: AgentThreadID
    }

    /// Commits a batch atomically, then acknowledges the exact in-memory prefix.
    /// Repository writes are idempotent so a retry after an ambiguous boundary
    /// cannot duplicate a previously committed sequence.
    ///
    /// Never calls `emitPersistenceIssue` — callers must publish diagnostics after
    /// releasing `mirrorEventLock` (this method often runs while that lock is held).
    @discardableResult
    private func flushStreamWrites(
        _ flush: BatchFlush,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) -> DeferredPersistenceIssue? {
        do {
            try runRepo.persistStreamBatch(
                runId: runId,
                threadId: threadId,
                items: flush.items.map {
                    AgentRunRepository.StreamWriteIntent(
                        seq: $0.seq,
                        kind: $0.kind,
                        payloadJSON: $0.payloadJSON,
                        providerEvent: $0.providerEvent
                    )
                },
                shouldPruneStreamEvents: flush.pruneDue
            )
            if let lastKind = flush.items.last?.kind {
                try providerSessionRepo?.updateDiagnostics(threadId: threadId, lastEventKind: lastKind, lastErrorMessage: nil)
            }
            lock.lock()
            guard var batch = pendingStreamWrites[threadId],
                  batch.acknowledge(flush.items) else {
                lock.unlock()
                let error = NSError(
                    domain: "RemoteCode.AgentRunCoordinator",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "Committed stream batch no longer matches its in-memory prefix."]
                )
                recordMirrorPersistenceFailure(error, threadId: threadId)
                return DeferredPersistenceIssue(
                    operation: "run.stream_event.acknowledge",
                    error: error,
                    runId: runId,
                    threadId: threadId
                )
            }
            pendingStreamWrites[threadId] = batch
            if flush.pruneDue { pendingStreamPrunes.remove(threadId) }
            if batch.isEmpty {
                pendingStreamRunIds.removeValue(forKey: threadId)
                discardRunThreadOwnershipIfReleasedLocked(runId)
            }
            lock.unlock()
            return nil
        } catch {
            // The repository transaction rolled back the entire batch. Keep the
            // in-memory prefix and owner intact so snapshot/start/terminal barriers
            // can retry. This is a transient durability failure, not a known gap.
            return DeferredPersistenceIssue(
                operation: "run.stream_event.append",
                error: error,
                runId: runId,
                threadId: threadId
            )
        }
    }

    /// Drain and persist any buffered stream writes for a thread immediately. Used
    /// on terminal/stop paths so the tail of a fast stream is never stranded in the
    /// buffer once the run is no longer producing events.
    /// Emits persistence diagnostics only when the caller is not already holding
    /// `mirrorEventLock` (this entry point does not nest under that lock).
    @discardableResult
    private func flushPendingStreamWrites(runId: AgentRunID, threadId: AgentThreadID) -> Error? {
        let result = flushPendingStreamWritesResult(runId: runId, threadId: threadId)
        if let deferred = result.deferredIssue {
            emitPersistenceIssue(
                deferred.operation,
                error: deferred.error,
                runId: deferred.runId,
                threadId: deferred.threadId
            )
        }
        return result.error
    }

    private struct StreamFlushAttempt {
        let error: Error?
        /// Set only for SQLite/ack failures that previously emitted under the lock.
        let deferredIssue: DeferredPersistenceIssue?
    }

    /// Serializes durability under `mirrorEventLock` but never fans out diagnostics
    /// or host callbacks while that lock is held.
    private func flushPendingStreamWritesResult(
        runId: AgentRunID,
        threadId: AgentThreadID
    ) -> StreamFlushAttempt {
        mirrorEventLock(for: threadId).lock()
        defer { mirrorEventLock(for: threadId).unlock() }
        lock.lock()
        if let bufferedRunId = pendingStreamRunIds[threadId], bufferedRunId != runId {
            lock.unlock()
            let error = NSError(
                domain: "RemoteCode.AgentRunCoordinator",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "Buffered mirror events changed run ownership."]
            )
            recordMirrorPersistenceFailure(error, threadId: threadId)
            return StreamFlushAttempt(error: error, deferredIssue: nil)
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let flush = takeStreamFlushLocked(threadId: threadId, pruneDue: false, nowMs: nowMs)
        lock.unlock()
        if let flush, !flush.items.isEmpty {
            if let deferred = flushStreamWrites(flush, runId: runId, threadId: threadId) {
                return StreamFlushAttempt(error: deferred.error, deferredIssue: deferred)
            }
        }
        return StreamFlushAttempt(error: nil, deferredIssue: nil)
    }

    /// Updates provider session runtime payload. Never emits diagnostics; callers
    /// that hold `mirrorEventLock` must defer fan-out until after unlock.
    @discardableResult
    private func updateProviderRuntimePayload(
        threadId: AgentThreadID,
        runId: AgentRunID,
        mutate: (inout ProviderSessionRuntimePayload) -> Void
    ) -> DeferredPersistenceIssue? {
        do {
            guard let repo = providerSessionRepo else { return nil }
            // Payload JSON + updated_at only. A leftover 16-column session
            // `get` then `upsert` hitchs every turn/request/plan stream
            // event, rewriting cwd/model/status/error just to mutate
            // `runtime_payload_json`.
            try repo.stampRuntimePayload(threadId: threadId) { json in
                var payload = ProviderSessionRuntimePayload.decode(json)
                mutate(&payload)
                json = payload.encoded()
            }
            return nil
        } catch {
            return DeferredPersistenceIssue(
                operation: "provider_session.runtime_payload.update",
                error: error,
                runId: runId,
                threadId: threadId
            )
        }
    }

    @discardableResult
    private func updateProviderRuntimePayloadFromProviderEvent(
        _ event: ProviderRuntimeEvent,
        threadId: AgentThreadID,
        runId: AgentRunID
    ) -> DeferredPersistenceIssue? {
        if event.provider == .distill, event.method == ProviderRuntimeEvent.distillSessionStateMethod {
            guard let data = event.payloadJSON.data(using: .utf8),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = state["sessionId"] as? String, !sessionId.isEmpty else {
                return nil
            }
            return updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                if let model = state["acceptedModel"] as? String, !model.isEmpty {
                    payload.distillSessionId = sessionId
                    payload.distillSessionModel = model
                }
                let retired = payload.distillRetiredSessionIds ?? []
                if state["historyRejected"] as? Bool == true, !retired.contains(sessionId) {
                    payload.distillRetiredSessionIds = Array(
                        (retired + [sessionId]).suffix(ProviderSessionRuntimePayload.distillRetiredSessionLimit)
                    )
                }
                payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            }
        }
        guard event.provider == .claude,
              event.method == "claude.session.snapshot",
              let data = event.payloadJSON.data(using: .utf8),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
            if let providerThreadId = snapshot["providerThreadId"] as? String ?? snapshot["resume"] as? String {
                payload.providerThreadId = providerThreadId
            }
            if let lastCompletedTurnId = snapshot["lastCompletedTurnId"] as? String {
                payload.lastCompletedTurnId = lastCompletedTurnId
            }
            if let turnCount = snapshot["turnCount"] as? Int {
                payload.turnCount = max(payload.turnCount, turnCount)
            }
            if let model = snapshot["model"] as? String {
                payload.model = model
            }
            payload.activeTurnId = snapshot["activeTurnId"] as? String
            payload.claudeResumeSessionAt = snapshot["resumeSessionAt"] as? String
                ?? snapshot["lastAssistantUuid"] as? String
                ?? payload.claudeResumeSessionAt
            payload.claudeInFlightToolIds = Self.boundedRuntimeIdentifiers(
                snapshot["inFlightToolIds"] as? [String] ?? payload.claudeInFlightToolIds
            )
            payload.pendingApprovalRequestIds = Self.boundedRuntimeIdentifiers(
                snapshot["pendingApprovalRequestIds"] as? [String] ?? payload.pendingApprovalRequestIds
            )
            payload.pendingUserInputRequestIds = Self.boundedRuntimeIdentifiers(
                snapshot["pendingUserInputRequestIds"] as? [String] ?? payload.pendingUserInputRequestIds
            )
            payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    private struct PersistAssistantOutcome {
        let message: AgentMessage?
        let deferredIssue: DeferredPersistenceIssue?
        /// Message that was newly appended and still needs host `onMessageAppended`
        /// after any outer mirror lock is released.
        let pendingMessageAppendNotification: AgentMessage?
    }

    /// Persists a final assistant message when missing. Never emits diagnostics or
    /// host callbacks; callers defer those until after `mirrorEventLock` release.
    private func persistAssistantIfMissing(
        _ text: String,
        threadId: AgentThreadID,
        runId: AgentRunID
    ) -> PersistAssistantOutcome {
        let text = AssistantTimelineState.cappedText(
            sanitizeFinalAssistantText(text)
        )
        guard !text.isEmpty else {
            return PersistAssistantOutcome(message: nil, deferredIssue: nil, pendingMessageAppendNotification: nil)
        }
        // One run owns one deterministic assistant-message identity. Provider
        // callbacks may repeat the same final for that run, but two distinct
        // turns are allowed to return byte-identical prose and must remain two
        // independently toggleable transcript rows. Never dedupe by content.
        let messageId = Self.terminalAssistantMessageId(runId: runId)
        let existing: AgentMessage?
        do {
            existing = try messageRepo.get(id: messageId)
        } catch {
            return PersistAssistantOutcome(
                message: nil,
                deferredIssue: DeferredPersistenceIssue(
                    operation: "message.get.assistant",
                    error: error,
                    runId: runId,
                    threadId: threadId
                ),
                pendingMessageAppendNotification: nil
            )
        }
        if let existing {
            guard existing.threadId == threadId,
                  existing.role == .assistant,
                  existing.content == text else {
                return PersistAssistantOutcome(
                    message: nil,
                    deferredIssue: DeferredPersistenceIssue(
                        operation: "message.identity.assistant",
                        error: SQLiteError.execute(
                            "Conflicting assistant message identity \(messageId.value.uuidString)."
                        ),
                        runId: runId,
                        threadId: threadId
                    ),
                    pendingMessageAppendNotification: nil
                )
            }
            return PersistAssistantOutcome(
                message: existing,
                deferredIssue: nil,
                pendingMessageAppendNotification: nil
            )
        }
        let message = AgentMessage(
            id: messageId,
            threadId: threadId,
            role: .assistant,
            content: text
        )
        do {
            try messageRepo.append(message)
        } catch {
            return PersistAssistantOutcome(
                message: nil,
                deferredIssue: DeferredPersistenceIssue(
                    operation: "message.append.assistant",
                    error: error,
                    runId: runId,
                    threadId: threadId
                ),
                pendingMessageAppendNotification: nil
            )
        }
        // PERF-MAC_AGENT-008: only cache if the entry is within the byte cap;
        // oversized entries skip the cache and rely on the full-history scan for
        // dedup, bounding per-entry retained memory for very long responses.
        let byteCount = text.utf8.count
        if !Self.shouldEvictLastPersistedContent(threadClosed: false, entryByteCount: byteCount) {
            lock.lock(); lastPersistedAssistantContent[threadId] = text; lock.unlock()
        }
        return PersistAssistantOutcome(
            message: message,
            deferredIssue: nil,
            pendingMessageAppendNotification: message
        )
    }

    private func sanitizeFinalAssistantText(_ text: String) -> String {
        // Shared provider-agnostic choke point for final assistant text: strip
        // leaked model control tokens (e.g. Grok `<|eos|>`), unresolved CCR
        // handles, then raw tool-invocation markup (leaving the uncalled-tool
        // incomplete-turn signal). Covers claude / codex / grok.
        AssistantToolMarkupSanitizer.sanitize(
            RetrieveHandleSanitizer.strip(
                ProviderControlTokenSanitizer.strip(text)
            )
        )
    }

    private func sanitizeFinalAssistantText(_ text: String?) -> String? {
        text.map { sanitizeFinalAssistantText($0) }
    }

    /// Stable identity for a final message synthesized from a provider terminal
    /// payload. The transform is one-to-one for run UUIDs and cannot equal the
    /// same run's deterministic user-message ID.
    private static func terminalAssistantMessageId(runId: AgentRunID) -> AgentMessageID {
        var bytes = runId.value.uuid
        bytes.0 ^= 0xA5
        return AgentMessageID(UUID(uuid: bytes))
    }

    private func sanitizeFinalAssistantEvent(
        _ ev: AssistantEvent,
        runId: AgentRunID
    ) -> AssistantEvent? {
        let suppress = lock.withLock { replyOnlyPrimaryRuns.contains(runId) }
        if suppress {
            switch ev {
            case .itemStarted(let item) where item.type == .assistantMessage:
                _ = lock.withLock {
                    replyOnlyAssistantItemIDs[runId, default: []].insert(item.id)
                }
                return nil
            case .itemDelta(let itemId, _, _, _),
                 .itemState(let itemId, _),
                 .itemProgress(let itemId, _),
                 .itemCompleted(let itemId, _),
                 .itemHostMetadata(_, let itemId, _, _):
                if lock.withLock({ replyOnlyAssistantItemIDs[runId]?.contains(itemId) == true }) {
                    return nil
                }
            case .turnCompleted(let turnId, _):
                return .turnCompleted(turnId: turnId, finalMessage: nil)
            default:
                break
            }
        }
        switch ev {
        case .turnCompleted(let turnId, let finalMessage):
            return .turnCompleted(
                turnId: turnId,
                finalMessage: finalMessage.map { sanitizeFinalAssistantText($0) }
            )
        case .itemHostMetadata:
            // Decode-only: host Distill attestations are no longer minted, and
            // providers and parsers never own this authority.
            return nil
        case .itemStarted(let item):
            guard item.distillApplied != nil else { return ev }
            return .itemStarted(item: item.withoutHostMetadata())
        case .itemDelta(let itemId, let bodyAppend, let outputAppend, let summary):
            // Defense in depth for live stream: drop leaked control tokens from
            // body deltas without trimming (preserves inter-chunk whitespace).
            guard let bodyAppend, ProviderControlTokenSanitizer.containsControlToken(bodyAppend) else {
                return ev
            }
            let cleaned = ProviderControlTokenSanitizer.stripStreamingChunk(bodyAppend)
            if cleaned.isEmpty, outputAppend == nil, summary == nil {
                // Token-only delta — emit a no-op empty body so callers keep
                // item identity without flashing `<|eos|>`.
                return .itemDelta(itemId: itemId, bodyAppend: "", outputAppend: nil, summary: nil)
            }
            return .itemDelta(
                itemId: itemId,
                bodyAppend: cleaned.isEmpty ? nil : cleaned,
                outputAppend: outputAppend,
                summary: summary
            )
        default:
            return ev
        }
    }

    private func recordReconciledTokenUsage(
        _ usage: AssistantTokenUsage,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {
        guard let lease = admitRunCallback(runId: runId, threadId: threadId) else { return }
        #if DEBUG
        runCallbackDidAdmitBeforeMutationForTesting?(runId, threadId)
        #endif
        recordAdmittedReconciledTokenUsage(
            usage,
            runId: runId,
            threadId: threadId,
            lease: lease
        )
    }

    private func recordAdmittedReconciledTokenUsage(
        _ usage: AssistantTokenUsage,
        runId: AgentRunID,
        threadId: AgentThreadID,
        lease: RunCallbackAdmissionLease
    ) {
        guard beginAdmittedCallbackMutation(lease, runId: runId) else { return }
        defer { endAdmittedCallbackMutation(runId: runId) }
        lock.lock()
        rememberRunThreadOwnershipLocked(runId: runId, threadId: threadId)
        var accumulator = reconciledTokenUsage[runId] ?? ReconciledTokenUsageAccumulator()
        accumulator.record(usage)
        let effective = accumulator.effective
        reconciledTokenUsage[runId] = accumulator
        latestTokenUsage[runId] = effective
        let finalizationInFlight = receiptUsageFinalizationInFlight.contains(runId)
        lock.unlock()

        // A late independent request cannot be distinguished from a replay
        // because providers do not attach a stable usage-event ID. Legitimate
        // incremental charges precede terminal delivery; only authoritative
        // cumulative snapshots may enrich an already-finalized receipt.
        guard usage.resolvedSemantics == .cumulative,
              !finalizationInFlight,
              effective != nil else {
            return
        }
        attemptFinalizedReceiptUsageEnrichment(runId: runId, threadId: threadId)
    }

    private func attemptFinalizedReceiptUsageEnrichment(
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {
        lock.lock()
        guard !receiptUsageFinalizationInFlight.contains(runId),
              let usage = latestTokenUsage[runId] else {
            lock.unlock()
            return
        }
#if DEBUG
        let enrichmentOverride = receiptUsageEnrichmentOverrideForTesting
#endif
        lock.unlock()

        do {
            let enriched: Bool?
#if DEBUG
            if let enrichmentOverride {
                enriched = try enrichmentOverride(runId, usage)
            } else {
                enriched = try orchestrationRuntime?.enrichFinalizedReceiptUsage(
                    runId: runId,
                    usage: usage
                )
            }
#else
            enriched = try orchestrationRuntime?.enrichFinalizedReceiptUsage(
                runId: runId,
                usage: usage
            )
#endif
            if enriched == true {
                lock.lock()
                let current = latestTokenUsage[runId]
                let isCovered = current.map {
                    $0.totalTokens <= usage.totalTokens
                        && ($0.reportedCostMicros ?? 0) <= (usage.reportedCostMicros ?? 0)
                } ?? true
                if isCovered {
                    reconciledTokenUsage.removeValue(forKey: runId)
                    latestTokenUsage.removeValue(forKey: runId)
                    receiptUsageEnrichmentRetryScheduled.remove(runId)
                    discardRunThreadOwnershipIfReleasedLocked(runId)
                }
                lock.unlock()
                if !isCovered {
                    scheduleReceiptUsageEnrichmentRetry(runId: runId, threadId: threadId)
                }
            }
        } catch {
            emitPersistenceIssue(
                "orchestration.receipt.enrich_usage",
                error: error,
                runId: runId,
                threadId: threadId
            )
            scheduleReceiptUsageEnrichmentRetry(runId: runId, threadId: threadId)
        }
    }

    private func scheduleReceiptUsageEnrichmentRetry(
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {
        lock.lock()
        guard latestTokenUsage[runId] != nil,
              receiptUsageEnrichmentRetryScheduled.insert(runId).inserted else {
            lock.unlock()
            return
        }
        lock.unlock()

        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            let stillPending = self.lock.withLock {
                self.receiptUsageEnrichmentRetryScheduled.remove(runId)
                let pending = self.latestTokenUsage[runId] != nil
                self.discardRunThreadOwnershipIfReleasedLocked(runId)
                return pending
            }
            if stillPending {
                self.attemptFinalizedReceiptUsageEnrichment(
                    runId: runId,
                    threadId: threadId
                )
            }
        }
    }

    @discardableResult
    private func finalizeOrRetryReceipt(
        _ pending: PendingOrchestrationReceiptFinalization
    ) -> Bool {
        lock.withLock {
            rememberRunThreadOwnershipLocked(
                runId: pending.runId,
                threadId: pending.threadId
            )
        }
        do {
            try orchestrationRuntime?.finalizeReceipt(
                runId: pending.runId,
                status: pending.status,
                usage: pending.usage,
                qualityOutcome: pending.qualityOutcome
            )
            let completionState = lock.withLock { () -> (hasLateUsage: Bool, leaseWorkItem: DispatchWorkItem?) in
                pendingReceiptFinalizations.removeValue(forKey: pending.runId)
                receiptFinalizationRetryScheduled.remove(pending.runId)
                receiptUsageFinalizationInFlight.remove(pending.runId)
                discardRunThreadOwnershipIfReleasedLocked(pending.runId)
                return (
                    latestTokenUsage[pending.runId] != nil,
                    externalReceiptLeaseWorkItems.removeValue(forKey: pending.runId)
                )
            }
            completionState.leaseWorkItem?.cancel()
            if completionState.hasLateUsage {
                attemptFinalizedReceiptUsageEnrichment(
                    runId: pending.runId,
                    threadId: pending.threadId
                )
            }
            return true
        } catch {
            lock.withLock {
                rememberRunThreadOwnershipLocked(
                    runId: pending.runId,
                    threadId: pending.threadId
                )
                pendingReceiptFinalizations[pending.runId] = pending
                receiptUsageFinalizationInFlight.insert(pending.runId)
            }
            emitPersistenceIssue(
                "orchestration.receipt.finalize",
                error: error,
                runId: pending.runId,
                threadId: pending.threadId
            )
            scheduleReceiptFinalizationRetry(runId: pending.runId)
            return false
        }
    }

    private func scheduleReceiptFinalizationRetry(runId: AgentRunID) {
        let shouldSchedule = lock.withLock {
            pendingReceiptFinalizations[runId] != nil
                && receiptFinalizationRetryScheduled.insert(runId).inserted
        }
        guard shouldSchedule else { return }

        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            let pending = self.lock.withLock { () -> PendingOrchestrationReceiptFinalization? in
                self.receiptFinalizationRetryScheduled.remove(runId)
                let pending = self.pendingReceiptFinalizations[runId]
                self.discardRunThreadOwnershipIfReleasedLocked(runId)
                return pending
            }
            if let pending {
                self.finalizeOrRetryReceipt(pending)
            }
        }
    }

    private func handle(
        event: AgentRunEvent,
        runId: AgentRunID,
        threadId: AgentThreadID,
        deduplicatesInFlightFinish: Bool = true,
        providerTerminalAcknowledged: Bool = true,
        isDurabilityRetry: Bool = false
    ) {
        guard let lease = admitRunCallback(runId: runId, threadId: threadId) else { return }
        #if DEBUG
        runCallbackDidAdmitBeforeMutationForTesting?(runId, threadId)
        #endif
        guard beginAdmittedCallbackMutation(lease, runId: runId) else { return }
        defer { endAdmittedCallbackMutation(runId: runId) }
        switch event {
        case .event(let rawEvent):
            // The adapter already counted the chunk as turn activity; storing it
            // would evict real tool items from the replay window.
            if case .providerRuntime(let runtime) = rawEvent, runtime.isToolCallArgumentChunk { return }
            guard let ev = sanitizeFinalAssistantEvent(rawEvent, runId: runId) else { return }
            persistProviderNativeSubagentLifecycle(
                from: ev,
                parentRunId: runId,
                threadId: threadId
            )
            if case .tokenUsage(let usage) = ev {
                recordAdmittedReconciledTokenUsage(
                    usage,
                    runId: runId,
                    threadId: threadId,
                    lease: lease
                )
            }
            // Encode/compact outside the mirror lock. Sequence allocation and
            // buffer ownership still require the lock; encoding does not.
            let data: Data?
            do {
                data = try encodeStreamEvent(ev)
            } catch {
                recordMirrorPersistenceFailure(error, threadId: threadId)
                emitPersistenceIssue("run.stream_event.encode", error: error, runId: runId, threadId: threadId)
                data = nil
            }
            let preparedWrite: (payloadJSON: String, providerEvent: ProviderRuntimeEvent?)?
            if let data, let json = String(data: data, encoding: .utf8) {
                do {
                    // S3: bound via repository so originals above the 16 MiB
                    // presentation ceiling are stored before presentation loss.
                    // Store failure propagates — never discard the original silently.
                    let payloadJSON = try runRepo.boundPayloadForPersistence(
                        json,
                        byteLimit: Self.maximumBufferedEventBytes
                    )
                    let providerEvent: ProviderRuntimeEvent?
                    if case .providerRuntime(let runtimeEvent) = ev {
                        let boundedPayload = try runRepo.boundPayloadForPersistence(
                            runtimeEvent.payloadJSON,
                            byteLimit: Self.maximumBufferedEventBytes
                        )
                        if boundedPayload == runtimeEvent.payloadJSON {
                            providerEvent = runtimeEvent
                        } else {
                            providerEvent = ProviderRuntimeEvent(
                                id: runtimeEvent.id,
                                provider: runtimeEvent.provider,
                                source: runtimeEvent.source,
                                method: runtimeEvent.method,
                                providerTurnId: runtimeEvent.providerTurnId,
                                providerItemId: runtimeEvent.providerItemId,
                                providerRequestId: runtimeEvent.providerRequestId,
                                payloadJSON: boundedPayload,
                                receivedAtMs: runtimeEvent.receivedAtMs
                            )
                        }
                    } else {
                        providerEvent = nil
                    }
                    preparedWrite = (payloadJSON, providerEvent)
                } catch {
                    recordMirrorPersistenceFailure(error, threadId: threadId)
                    emitPersistenceIssue("run.stream_event.bound_payload", error: error, runId: runId, threadId: threadId)
                    preparedWrite = nil
                }
            } else {
                preparedWrite = nil
            }

            // Hold mirrorEventLock only for durability + resume-cursor serialization.
            // Never notify observers / onAssistantEvent (or stopRun) while the lock
            // is held: host callbacks can block on main-queue work, and the HTTP
            // mirror snapshot path waits on this same lock on the main actor.
            enum MirrorEventPostAction {
                case publish(persistenceIssues: [DeferredPersistenceIssue], appendedMessages: [AgentMessage])
                case saturatedRetry(Error, deferred: DeferredPersistenceIssue?)
                case ownerConflict(Error)
                case activePlanBudget(Error)
                case resumeCursorFailure(Error)
                /// S3: store-before-loss failed — do not allocate seq or notify observers.
                case storeBeforeLossFailure(Error)
            }
            let postAction: MirrorEventPostAction = {
                mirrorEventLock(for: threadId).lock()
                defer { mirrorEventLock(for: threadId).unlock() }

                var deferredPersistenceIssues: [DeferredPersistenceIssue] = []
                var appendedMessages: [AgentMessage] = []

                // S3: when encode succeeded but reversible store/bound failed,
                // never allocate a sequence or publish an undurable event.
                if data != nil, preparedWrite == nil {
                    let error = NSError(
                        domain: "RemoteCode.AgentRunCoordinator",
                        code: 507,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Authoritative stream payload could not be stored before presentation loss."]
                    )
                    recordMirrorPersistenceFailure(error, threadId: threadId)
                    return .storeBeforeLossFailure(error)
                }

                lock.lock()
                let priorBufferedRunId = pendingStreamRunIds[threadId].flatMap { owner in
                    owner == runId ? nil : owner
                }
                lock.unlock()
                if let priorBufferedRunId {
                    let priorAttempt = flushPendingStreamWritesResult(
                        runId: priorBufferedRunId,
                        threadId: threadId
                    )
                    if let issue = priorAttempt.deferredIssue {
                        deferredPersistenceIssues.append(issue)
                    }
                }
                // A failed SQLite flush must not turn the retry prefix into an
                // unbounded spool. Before accepting another provider event, retry a
                // prefix that already reached either high-water mark. If it is still
                // locked, stop the provider at the durable resume cursor and fail
                // loud; the retained prefix remains available for a later retry.
                lock.lock()
                let saturatedRetry = pendingStreamWrites[threadId].map {
                    Self.shouldFlushStreamBatch(
                        pendingCount: $0.count,
                        pendingBytes: $0.encodedByteCount,
                        sinceLastFlushMs: 0
                    )
                } ?? false
                lock.unlock()
                if saturatedRetry {
                    let retryAttempt = flushPendingStreamWritesResult(runId: runId, threadId: threadId)
                    if let retryError = retryAttempt.error {
                        recordMirrorPersistenceFailure(retryError, threadId: threadId)
                        return .saturatedRetry(retryError, deferred: retryAttempt.deferredIssue)
                    }
                }

                lock.lock()
                let s = allocateStreamSequenceLocked(runId: runId, threadId: threadId)
                lock.unlock()
                // PERF-MAC_AGENT-007: buffer the per-event writes (stream event +
                // optional provider-event log) and flush them in batches instead of
                // 2-3 synchronous transactions per delta. Prune cadence and diagnostics
                // are coalesced into the flush.
                if let preparedWrite {
                    lock.lock()
                    if let owner = pendingStreamRunIds[threadId], owner != runId {
                        lock.unlock()
                        let error = NSError(
                            domain: "RemoteCode.AgentRunCoordinator",
                            code: 409,
                            userInfo: [NSLocalizedDescriptionKey: "Buffered mirror events changed run ownership."]
                        )
                        recordMirrorPersistenceFailure(error, threadId: threadId)
                        return .ownerConflict(error)
                    }
                    var batch = pendingStreamWrites[threadId] ?? StreamWriteBatch()
                    batch.append(StreamWriteItem(
                        seq: s,
                        kind: ev.debugDescription,
                        payloadJSON: preparedWrite.payloadJSON,
                        providerEvent: preparedWrite.providerEvent
                    ))
                    pendingStreamWrites[threadId] = batch
                    pendingStreamRunIds[threadId] = runId
                    // Prune at most once per `streamEventPruneInterval` events per thread.
                    let pruneCount = (streamEventsSincePrune[threadId] ?? 0) + 1
                    let pruneDue = pruneCount >= Self.streamEventPruneInterval
                    streamEventsSincePrune[threadId] = pruneDue ? 0 : pruneCount
                    if pruneDue { pendingStreamPrunes.insert(threadId) }
                    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                    let lastMs = lastStreamFlushMs[threadId] ?? nowMs
                    lastStreamFlushMs[threadId] = lastStreamFlushMs[threadId] ?? nowMs
                    var flushNow: BatchFlush?
                    if Self.shouldFlushStreamBatch(
                        pendingCount: batch.count,
                        pendingBytes: batch.encodedByteCount,
                        sinceLastFlushMs: nowMs - lastMs
                    ) || pruneDue {
                        flushNow = takeStreamFlushLocked(threadId: threadId, pruneDue: pruneDue, nowMs: nowMs)
                    }
                    lock.unlock()
                    if let flushNow {
                        if let issue = flushStreamWrites(flushNow, runId: runId, threadId: threadId) {
                            deferredPersistenceIssues.append(issue)
                        }
                    }
                }

                var resumeCursorFailure: Error?
                switch ev {
                case .threadStarted(let eventThreadId, let providerThreadId):
                    let resumeCursor = providerThreadId ?? eventThreadId
                    do {
                        // Resume cursor + payload.providerThreadId only. A leftover
                        // 16-column session `get` then `upsert` hitchs every
                        // `.threadStarted` event, rewriting cwd/model/status/error
                        // and Swift-decoding `runtime_payload_json`.
                        try providerSessionRepo?.stampResumeCursor(
                            threadId: threadId,
                            resumeCursor: resumeCursor
                        )
                        // Cursor + updated_at only. A leftover 26-column + routing
                        // `get` then `upsert` hitchs every `.threadStarted` event.
                        try threadRepo.updateProviderThreadId(
                            id: threadId,
                            providerThreadId: resumeCursor
                        )
                    } catch {
                        resumeCursorFailure = error
                    }
                case .providerRuntime(let runtimeEvent):
                    if let issue = updateProviderRuntimePayloadFromProviderEvent(runtimeEvent, threadId: threadId, runId: runId) {
                        deferredPersistenceIssues.append(issue)
                    }
                case .turnStarted(let turnId):
                    lock.lock()
                    activeTurnIds[runId] = turnId
                    lock.unlock()
                    let issue = updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                        payload.activeTurnId = turnId
                        payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    }
                    if let issue { deferredPersistenceIssues.append(issue) }
                case .requestOpened(let request):
                    let issue = updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                        payload.pendingApprovalRequestIds = Self.boundedRuntimeIdentifiers(
                            existing: payload.pendingApprovalRequestIds,
                            adding: request.id
                        )
                        payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    }
                    if let issue { deferredPersistenceIssues.append(issue) }
                case .requestResolved(let requestId, _):
                    let issue = updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                        payload.pendingApprovalRequestIds.removeAll { $0 == requestId }
                        payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    }
                    if let issue { deferredPersistenceIssues.append(issue) }
                case .userInputRequested(let request):
                    let issue = updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                        payload.pendingUserInputRequestIds = Self.boundedRuntimeIdentifiers(
                            existing: payload.pendingUserInputRequestIds,
                            adding: request.id
                        )
                        payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    }
                    if let issue { deferredPersistenceIssues.append(issue) }
                case .userInputResolved(let requestId, _):
                    let issue = updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                        payload.pendingUserInputRequestIds.removeAll { $0 == requestId }
                        payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    }
                    if let issue { deferredPersistenceIssues.append(issue) }
                case .turnCompleted(let turnId, let finalMessage):
                    lock.lock()
                    activeTurnIds[runId] = turnId
                    lock.unlock()
                    if let msg = finalMessage {
                        let outcome = persistAssistantIfMissing(msg, threadId: threadId, runId: runId)
                        if let issue = outcome.deferredIssue { deferredPersistenceIssues.append(issue) }
                        if let message = outcome.pendingMessageAppendNotification { appendedMessages.append(message) }
                        if let persisted = outcome.message {
                            lock.lock()
                            activeAssistantMessageIds[runId] = persisted.id
                            lock.unlock()
                        }
                    }
                    if finalMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        let issue = updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                            payload.activePlan = nil
                            payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                        }
                        if let issue { deferredPersistenceIssues.append(issue) }
                    }
                case .activePlanUpdated(let plan):
                    guard Self.activePlanFitsCompactBudget(plan) else {
                        return .activePlanBudget(NSError(
                            domain: "RemoteCode.AgentRunCoordinator",
                            code: 413,
                            userInfo: [NSLocalizedDescriptionKey: "Active plan exceeds the compact recovery-state budget."]
                        ))
                    }
                    let issue = updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                        payload.activePlan = plan
                        payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    }
                    if let issue { deferredPersistenceIssues.append(issue) }
                case .error(let message, _):
                    // Same durable reason seam as AgentRunEvent.error — stream-level
                    // error rows must also fill agent_runs.error_message on terminal.
                    lock.lock()
                    latestRunErrorMessages[runId] = message
                    lock.unlock()
                default:
                    break
                }

                if let resumeCursorFailure {
                    return .resumeCursorFailure(resumeCursorFailure)
                }
                return .publish(persistenceIssues: deferredPersistenceIssues, appendedMessages: appendedMessages)
            }()

            switch postAction {
            case .saturatedRetry(let error, let deferred):
                if let deferred {
                    emitPersistenceIssue(deferred.operation, error: deferred.error, runId: deferred.runId, threadId: deferred.threadId)
                }
                // Lock saturation must not terminate a live turn (plan-final W1 T-path).
                // Keep the run alive with a deferred-persistence issue; retry later.
                emitPersistenceIssue("run.stream_event.retry_saturated", error: error, runId: runId, threadId: threadId)
                return
            case .storeBeforeLossFailure(let error):
                // S3: never publish an undurable event. mirrorPersistenceFailures is
                // already set so terminal/snapshot barriers fail closed until cleared.
                emitPersistenceIssue("run.stream_event.store_before_loss", error: error, runId: runId, threadId: threadId)
                return
            case .ownerConflict(let error):
                emitPersistenceIssue("run.stream_event.owner", error: error, runId: runId, threadId: threadId)
                return
            case .activePlanBudget(let error):
                // Budget overflow is a persistence degradation, not a user-visible cancel.
                emitPersistenceIssue("provider_session.active_plan.budget", error: error, runId: runId, threadId: threadId)
                return
            case .resumeCursorFailure(let error):
                emitPersistenceIssue("provider_session.resume_cursor.update", error: error, runId: runId, threadId: threadId)
            case .publish(let persistenceIssues, let appendedMessages):
                for issue in persistenceIssues {
                    emitPersistenceIssue(issue.operation, error: issue.error, runId: issue.runId, threadId: issue.threadId)
                }
                for message in appendedMessages {
                    onMessageAppended?(message)
                }
            }

            for observer in observersSnapshot() {
                observer.runCoordinator(self, didReceive: ev, run: runId, threadId: threadId)
            }
            // Preserve prior EventBus contract: publish whenever encode produced
            // Data (even if UTF-8 conversion failed and no buffer row was written).
            // Store-before-loss failures return above and never reach this path.
            if data != nil {
                onAssistantEvent?(ev, threadId, runId)
            }
        case .status(let st):
            for observer in observersSnapshot() {
                observer.runCoordinator(self, didChangeStatus: st, runId: runId, threadId: threadId)
            }
        case .finished(let reportedStatus, let rawFinalMessage, let providerThreadId):
            let rawFinalMessage = lock.withLock { replyOnlyPrimaryRuns.contains(runId) }
                ? nil
                : rawFinalMessage
            // AG-002: mark the provider-side terminal acknowledgement before the
            // durable-row dedupe guard. stopRun may already have marked the row
            // cancelled, but destructive callers still need proof the provider
            // callback arrived before deleting the thread and its caches.
            lock.lock()
            if providerTerminalAcknowledged,
               (awaitingTerminationRuns.contains(runId)
                || pendingGracefulStopFallbacks.contains(runId)) {
                providerTerminatedRuns.insert(runId)
            }
            lock.unlock()
            if providerTerminalAcknowledged {
                onProviderIdle?(threadId)
            }
            if let row = try? runRepo.terminal(of: runId), row.finishedAt != nil {
                // Durable row is terminal (possibly written by another process's
                // launch reconciliation or a partial finish). If this process still
                // owns the run in memory, release it and fan out didFinish once so
                // Working/Stop cannot stick after finishedAt is set.
                _ = releaseStaleInMemoryOwnershipIfDurableTerminal(
                    runId: runId,
                    threadId: threadId,
                    preferredStatus: reportedStatus,
                    finalMessage: sanitizeFinalAssistantText(rawFinalMessage),
                    providerThreadId: providerThreadId
                )
                return
            }
            lock.lock()
            let finishAlreadyInFlight = finishingRuns.contains(runId)
            if finishAlreadyInFlight && deduplicatesInFlightFinish {
                lock.unlock()
                return
            }
            if !finishAlreadyInFlight {
                finishingRuns.insert(runId)
            }
            lock.unlock()

            let finalMessage = rawFinalMessage.map {
                sanitizeFinalAssistantText($0)
            }
            lock.lock()
            let needsTerminalClaim = pendingTerminalEvents[runId] == nil
            let producedAssistantOutput =
                replyOnlyPrimaryRuns.contains(runId)
                || (finalMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                || activeAssistantMessageIds[runId] != nil
            let providerFromMeta = activeRunMetadata[runId]?.provider
            let observedFromMemory = latestRunErrorMessages[runId]
            let assistantMessageIdHint = activeAssistantMessageIds[runId]
            // Snapshot usage while ownership is still held. A concurrent stale-
            // ownership release (a Stop or a duplicate `.finished` landing in the
            // lock-free persist window below) can remove `latestTokenUsage[runId]`
            // before the second lock region reads it; this early snapshot is the
            // fallback so the finalized receipt never loses usage.
            let capturedTokenUsage = latestTokenUsage[runId]
            lock.unlock()

            if needsTerminalClaim {
                let provider = providerFromMeta
                    ?? (try? threadRepo.listChrome(ids: [threadId])[threadId]?.provider)
                    ?? .codex
                // Error text only. A leftover 16-column session `get`
                // (including `runtime_payload_json`) hitchs terminal claim
                // just to copy last_error_message for stderr classification.
                let observedDetail = observedFromMemory
                    ?? (try? providerSessionRepo?.lastErrorMessage(of: threadId))
                let resolved = ProviderStderrClassifier.resolveTerminal(
                    provider: provider,
                    status: reportedStatus,
                    observedDetail: observedDetail,
                    producedAssistantOutput: producedAssistantOutput
                )
                let assistantMessage: AgentMessage?
                if resolved.status == .completed, let finalMessage, !finalMessage.isEmpty {
                    assistantMessage = AgentMessage(
                        id: assistantMessageIdHint
                            ?? Self.terminalAssistantMessageId(runId: runId),
                        threadId: threadId,
                        role: .assistant,
                        content: AssistantTimelineState.cappedText(finalMessage)
                    )
                } else {
                    assistantMessage = nil
                }
                lock.lock()
                // Cancel may have claimed the durability slot while we resolved.
                if pendingTerminalEvents[runId] == nil {
                    pendingTerminalEvents[runId] = PendingTerminalEvent(
                        status: resolved.status,
                        finalMessage: finalMessage,
                        providerThreadId: providerThreadId,
                        assistantMessage: assistantMessage,
                        finishedAt: Date(),
                        providerTerminalAcknowledged: providerTerminalAcknowledged,
                        errorMessage: resolved.errorMessage
                    )
                }
                lock.unlock()
            }

            lock.lock()
            let pendingTerminal = pendingTerminalEvents[runId]
            let commitOwnedElsewhere = isDurabilityRetry && terminalCommitsInFlight.contains(runId)
            if isDurabilityRetry, pendingTerminal != nil, !commitOwnedElsewhere {
                terminalCommitsInFlight.insert(runId)
            }
            lock.unlock()
            guard var pendingTerminal, !commitOwnedElsewhere else {
                // Slot vanished (ownership released elsewhere), or another retry owns the
                // commit: it either publishes this terminal or releases the lease and
                // re-schedules, so nothing retained here can be dropped.
                return
            }
            // Policy BEFORE durable persist: run/thread/session rows must match
            // presentation status (never durable completed while UI says interrupted).
            let requestedStatus = pendingTerminal.status
            let durable = Self.durableTerminalStatus(
                requested: requestedStatus,
                providerTerminalAcknowledged: pendingTerminal.providerTerminalAcknowledged,
                errorMessage: pendingTerminal.errorMessage
            )
            let status = durable.status
            let initiator = durable.initiator
            let reason = TerminalTransitionReason.classify(
                requestedStatus: requestedStatus,
                initiator: initiator
            )
            if status != pendingTerminal.status
                || durable.errorMessage != pendingTerminal.errorMessage
                || pendingTerminal.terminalReason != reason.rawValue {
                pendingTerminal.status = status
                if let msg = durable.errorMessage {
                    pendingTerminal.errorMessage = msg
                }
                pendingTerminal.terminalReason = reason.rawValue
                // Keep retry map consistent if durability flushes later.
                lock.lock()
                pendingTerminalEvents[runId] = pendingTerminal
                lock.unlock()
            }
            // PERF-MAC_AGENT-007: drain any buffered stream writes before the run
            // tears down, so the tail of a fast stream is durably persisted (and
            // visible to latestStreamEvents/reload) once the run finishes.
            var streamFlushError = flushPendingStreamWrites(runId: runId, threadId: threadId)
            if streamFlushError != nil {
                // A provider terminal event is a durability barrier. SQLite's busy
                // timeout may expire while another process still owns the writer;
                // retry once before persisting/broadcasting terminal state so the
                // final status can never overtake its buffered provider events.
                streamFlushError = flushPendingStreamWrites(runId: runId, threadId: threadId)
            }
            if streamFlushError != nil {
                if isDurabilityRetry {
                    lock.lock()
                    terminalCommitsInFlight.remove(runId)
                    lock.unlock()
                }
                scheduleTerminalDurabilityRetry(runId: runId, threadId: threadId)
                return
            }
            lock.lock()
            terminalCheckpointAttempts.insert(runId)
            lock.unlock()
            let terminalPersistence: TerminalPersistenceContext
            do {
                // pendingTerminal.status is already policy-reconciled.
                terminalPersistence = try persistTerminalGraph(
                    pendingTerminal,
                    runId: runId,
                    threadId: threadId
                )
            } catch {
                lock.lock()
                terminalCheckpointAttempts.remove(runId)
                if isDurabilityRetry { terminalCommitsInFlight.remove(runId) }
                lock.unlock()
                emitPersistenceIssue("run.terminal_graph.commit", error: error, runId: runId, threadId: threadId)
                scheduleTerminalDurabilityRetry(runId: runId, threadId: threadId)
                return
            }
            let terminalGraphCommitTime = Date()
            lock.lock()
            // Prefer the current value — this captures out-of-band usage (e.g.
            // Codex delivers usage as an independent notification that can arrive
            // during the persist window) — and fall back to the pre-persist
            // snapshot if a concurrent stale-release already removed the entry.
            receiptUsageFinalizationInFlight.insert(runId)
            let usage = latestTokenUsage.removeValue(forKey: runId) ?? capturedTokenUsage
            reconciledTokenUsage.removeValue(forKey: runId)
            lock.unlock()
            _ = finalizeOrRetryReceipt(
                PendingOrchestrationReceiptFinalization(
                    runId: runId,
                    threadId: threadId,
                    status: status,
                    usage: usage,
                    qualityOutcome: AgentOrchestrationRuntime.qualityOutcome(
                        status: status,
                        finalMessage: pendingTerminal.finalMessage
                    )
                )
            )
            let runMetadata = terminalPersistence.runMetadata
            let completedTurnId = terminalPersistence.completedTurnId
            let assistantMessageId = terminalPersistence.assistantMessageId
            let resumeCursor = terminalPersistence.resumeCursor
            // The record is only written after the terminal graph has committed and
            // immediately before the first host presentation callback. The retained
            // pending event supplies one stable event time across durability retries.
            _ = recordTerminalTransition(
                runId: runId,
                threadId: threadId,
                requestedStatus: requestedStatus,
                initiator: initiator,
                providerPid: nil,
                exitStatus: nil,
                eventSequence: nil,
                eventTime: pendingTerminal.finishedAt,
                commitTime: terminalGraphCommitTime,
                presentTime: Date()
            )
            if terminalPersistence.insertedAssistantMessage,
               let assistantMessage = pendingTerminal.assistantMessage {
                onMessageAppended?(assistantMessage)
            }
            let minimalCheckpoint = status == .completed
                ? persistMinimalCheckpointIdentity(
                    threadId: threadId,
                    runId: runId,
                    turnId: completedTurnId,
                    assistantMessageId: assistantMessageId
                )
                : nil
            let minimalCheckpointFailed = status == .completed
                && checkpointRepo != nil
                && minimalCheckpoint == nil
            let callbackFinalMessage = minimalCheckpointFailed ? nil : finalMessage
            let callbackProviderThreadId = minimalCheckpointFailed ? nil : providerThreadId
            lock.lock()
            orchestrationDeadlineWorkItems.removeValue(forKey: runId)?.cancel()
            externalReceiptLeaseWorkItems.removeValue(forKey: runId)?.cancel()
            active.removeValue(forKey: runId)
            activeDelegationCapabilities.removeValue(forKey: runId)
            activeThreads.removeValue(forKey: threadId)
            activeRunMetadata.removeValue(forKey: runId)
            activeTurnIds.removeValue(forKey: runId)
            activeAssistantMessageIds.removeValue(forKey: runId)
            latestRunErrorMessages.removeValue(forKey: runId)
            finishingRuns.remove(runId)
            pendingTerminalEvents.removeValue(forKey: runId)
            terminalRetryScheduled.remove(runId)
            terminalCheckpointAttempts.remove(runId)
            if isDurabilityRetry { terminalCommitsInFlight.remove(runId) }
            pendingThreadStops.remove(threadId)
            // PERF-MAC_AGENT-005: flush a final prune at run end so events queued
            // since the last cadence-prune don't linger unbounded.
            let pendingPrune = streamFlushError == nil && (streamEventsSincePrune[threadId] ?? 0) > 0
            if streamFlushError == nil {
                streamEventsSincePrune.removeValue(forKey: threadId)
                // The transactional flush committed and acknowledged the buffer;
                // only now may terminal cleanup release its ownership metadata.
                pendingStreamWrites.removeValue(forKey: threadId)
                pendingStreamRunIds.removeValue(forKey: threadId)
                pendingStreamPrunes.remove(threadId)
                lastStreamFlushMs.removeValue(forKey: threadId)
                seq.removeValue(forKey: runId)
            } else {
                clearStreamSequenceIfReleasedLocked(runId: runId, threadId: threadId)
            }
            // PERF-MAC_AGENT-008: thread closed -> evict the dedup cache entry so
            // finished threads do not retain their final-answer text indefinitely.
            lastPersistedAssistantContent.removeValue(forKey: threadId)
            discardRunThreadOwnershipIfReleasedLocked(runId)
            let activeProjection = activeRunProjectionLocked()
            lock.unlock()
            // Durable terminal is committed and in-memory ownership released.
            // Align any adapter still reporting a live turn (Stop path).
            reconcileProviderSessionAfterDurableTerminal(
                threadId: threadId,
                status: status,
                providerThreadId: providerThreadId
            )
            // UX-MAC_AGENT-BG-AWAIT / incomplete-turn: schedule only AFTER the
            // finishing run is removed from activeThreads. Zero-delay workflow
            // continuations would otherwise fail the idle validity check and
            // never start (silent green "completed").
            maybeScheduleBackgroundAwaitContinuation(
                threadId: threadId,
                status: status,
                finalMessage: finalMessage,
                runMetadata: runMetadata,
                resumeCursor: resumeCursor
            )
            maybeScheduleNetworkRetry(
                threadId: threadId,
                status: status,
                errorMessage: pendingTerminal.errorMessage,
                runMetadata: runMetadata,
                resumeCursor: resumeCursor
            )
            onActiveRunProjectionChanged?(activeProjection, .finished(status))
            if pendingPrune {
                do {
                    try runRepo.pruneStreamEvents(threadId: threadId)
                } catch {
                    emitPersistenceIssue("run.stream_event.prune.finish", error: error, runId: runId, threadId: threadId)
                }
            }
            // PERF-MAC_AGENT-009: prune provider event logs unconditionally at run
            // finish so they are bounded to the default 10,000 per thread. Provider
            // events are written at lower frequency than stream events, so a per-event
            // cadence gate is not needed; one DELETE at run-end is cheap and bounded.
            do {
                try runRepo.pruneProviderEventLogs(threadId: threadId)
            } catch {
                emitPersistenceIssue("run.provider_event.prune.finish", error: error, runId: runId, threadId: threadId)
            }
            let durationMs = (try? runRepo.timing(of: runId)).flatMap { timing -> Int64? in
                guard let finished = timing.finishedAt else { return nil }
                return Int64(finished.timeIntervalSince(timing.startedAt) * 1000)
            } ?? -1
            agentRunLog.info("run.finished thread=\(threadId.value.uuidString, privacy: .public) run=\(runId.value.uuidString, privacy: .public) status=\(status.rawValue, privacy: .public) durationMs=\(durationMs, privacy: .public)")
            // S5: terminalize generation-owned prep so the next accept is not poisoned.
            // Only this run's own generation: activeThreads was released above,
            // so a zero-delay auto-continuation or a new send may already have
            // accepted a newer generation, and terminalizing that one revokes its
            // spawn permit (it then ends cancelled before reaching the provider).
            lock.lock()
            if let prep = preparationStates[threadId],
               prep.draftMessageId == runId.value.uuidString {
                let prepReason: ProviderPreparationTerminalReason = {
                    switch status {
                    case .completed: return .completed
                    case .cancelled: return .cancelled
                    case .failed, .interrupted: return .providerFailure
                    case .pending, .running: return .completed
                    }
                }()
                _ = applyPreparationLocked(
                    threadId: threadId,
                    event: .providerFinished(generation: prep.generation, reason: prepReason)
                )
            }
            lock.unlock()
            for observer in observersSnapshot() {
                observer.runCoordinator(
                    self,
                    didFinish: runId,
                    threadId: threadId,
                    status: status,
                    finalMessage: callbackFinalMessage,
                    providerThreadId: callbackProviderThreadId
                )
            }
            onRunFinished?(threadId, runId, status)
            if let minimalCheckpoint {
                Task { [weak self] in
                    await self?.enrichCheckpoint(
                        minimalCheckpoint,
                        cwd: runMetadata?.cwd
                    )
                }
            }
        case .error(let m):
            // F22: route the error through the .event path so it is PERSISTED as a
            // stream event (same batched appendStreamEvent flow as every other
            // timeline event) before notifying observers. Without this, a failed
            // run left no explanation after a thread switch or relaunch — replay
            // (latestStreamEvents) only restores persisted events, and errors for
            // non-selected threads were dropped entirely. Observer/onAssistantEvent
            // broadcasting is unchanged: the .event path performs both.
            // Provider callbacks may arrive concurrently. Serialize the resume
            // cursor read with `.threadStarted` persistence so a crash cannot be
            // mislabeled unrecoverable while its durable cursor is being stored.
            lock.lock()
            latestRunErrorMessages[runId] = m
            lock.unlock()
            mirrorEventLock(for: threadId).lock()
            // Cursor only. A leftover 16-column session `get` (including
            // `runtime_payload_json`) hitchs the error path under
            // `mirrorEventLock` just to copy resume_cursor for recoverable.
            let persistedCursor = try? providerSessionRepo?.resumeCursor(of: threadId)
            // Cursor only. A leftover 26-column + routing `get` hitchs the
            // error path just to copy provider_thread_id for recoverable.
            let threadCursor = (try? threadRepo.providerThreadId(of: threadId))
                .flatMap { $0.isEmpty ? nil : $0 }
            mirrorEventLock(for: threadId).unlock()
            let resumeCursor = (persistedCursor ?? threadCursor)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let recoverable = resumeCursor?.isEmpty == false
            handle(
                event: .event(.error(message: m, recoverable: recoverable)),
                runId: runId,
                threadId: threadId
            )
            try? providerSessionRepo?.updateDiagnostics(threadId: threadId, lastEventKind: "error", lastErrorMessage: m)
        }
    }

    private func persistTerminalGraph(
        _ pending: PendingTerminalEvent,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) throws -> TerminalPersistenceContext {
        lock.lock()
        let runMetadata = activeRunMetadata[runId]
        let completedTurnId = activeTurnIds[runId]
        let priorAssistantMessageId = activeAssistantMessageIds[runId]
        lock.unlock()

        // Status + adapter-recovery chrome only. A leftover 10-column run
        // `get` (including `error_message`) and 26-column + routing thread
        // `get` hitch every finish just to stamp terminal columns.
        guard try runRepo.status(of: runId) != nil else {
            throw NSError(
                domain: "RemoteCode.AgentRunCoordinator",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Run row missing while committing terminal state."]
            )
        }
        guard let chrome = try threadRepo.adapterRecovery(of: threadId) else {
            throw NSError(
                domain: "RemoteCode.AgentRunCoordinator",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Thread row missing while committing terminal state."]
            )
        }

        let finishedProvider = runMetadata?.provider ?? chrome.provider
        let finishedProviderInstanceId = runMetadata?.providerInstanceId
            ?? chrome.providerInstanceId
        let finishedModel = runMetadata?.model ?? chrome.model
        // Persist the resolved reason for abnormal ends. User cancel leaves this nil.
        let terminalReason = pending.terminalReason
            ?? TerminalTransitionReason.classify(
                requestedStatus: pending.status,
                initiator: Self.terminalInitiator(
                    status: pending.status,
                    providerTerminalAcknowledged: pending.providerTerminalAcknowledged,
                    errorMessage: pending.errorMessage
                )
            ).rawValue
        let run = AgentRun(
            id: runId,
            threadId: threadId,
            provider: finishedProvider,
            providerInstanceId: finishedProviderInstanceId,
            model: finishedModel,
            status: pending.status,
            finishedAt: pending.finishedAt,
            errorMessage: pending.errorMessage,
            terminalReason: terminalReason
        )
        let resumeCursor: String?
        if let pendingCursor = pending.providerThreadId, !pendingCursor.isEmpty {
            resumeCursor = pendingCursor
        } else {
            resumeCursor = try threadRepo.providerThreadId(of: threadId)
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        let thread = AgentThread(
            id: threadId,
            title: "",
            provider: finishedProvider,
            providerInstanceId: finishedProviderInstanceId,
            model: finishedModel,
            providerThreadId: pending.providerThreadId,
            status: pending.status,
            updatedAt: pending.finishedAt,
            hasUnread: Self.hasUnread(for: pending.status)
        )

        let providerSession: ProviderSessionRuntime?
        if let providerSessionRepo {
            // Payload JSON only. A leftover 16-column session `get`
            // (including cwd/model/status/error) hitchs every finish just
            // to copy `runtime_payload_json` into the terminal upsert.
            let existingPayload = try providerSessionRepo.runtimePayloadJSON(of: threadId) ?? nil
            let runtimePayload = providerSessionRuntimePayloadJSON(
                existingPayload,
                status: pending.status,
                resumeCursor: resumeCursor,
                completedTurnId: completedTurnId,
                model: finishedModel,
                serviceTier: runMetadata?.serviceTier ?? .auto,
                runtimeMode: runMetadata?.runtimeMode ?? .supervised,
                interactionMode: runMetadata?.interactionMode ?? .default,
                activeTurnId: nil,
                updatedAt: pending.finishedAt
            )
            providerSession = ProviderSessionRuntime(
                threadId: threadId,
                provider: finishedProvider,
                providerInstanceId: finishedProviderInstanceId,
                adapterKey: runMetadata?.adapterKey,
                binaryIdentity: runMetadata?.binaryIdentity,
                status: pending.status,
                resumeCursor: resumeCursor,
                cwd: runMetadata?.cwd,
                model: finishedModel,
                serviceTier: runMetadata?.serviceTier ?? .auto,
                runtimeMode: runMetadata?.runtimeMode ?? .supervised,
                lastRunId: runId,
                lastEventKind: "run.finished",
                runtimePayloadJSON: runtimePayload,
                updatedAt: pending.finishedAt
            )
        } else {
            providerSession = nil
        }

        let result = try runRepo.persistTerminalGraph(
            assistantMessage: pending.assistantMessage,
            finalMessageId: pending.assistantMessage?.id ?? priorAssistantMessageId,
            run: run,
            thread: thread,
            providerSession: providerSession
        )

        lock.lock()
        if let assistantMessageId = result.assistantMessageId {
            activeAssistantMessageIds[runId] = assistantMessageId
        }
        if let assistantMessage = pending.assistantMessage,
           !Self.shouldEvictLastPersistedContent(
                threadClosed: false,
                entryByteCount: assistantMessage.content.utf8.count
           ) {
            // Update the memo only after the transaction commits. A failed
            // assistant INSERT must remain retryable and cannot poison dedup.
            lastPersistedAssistantContent[threadId] = assistantMessage.content
        }
        let assistantMessageId = result.assistantMessageId ?? priorAssistantMessageId
        lock.unlock()

        return TerminalPersistenceContext(
            runMetadata: runMetadata,
            completedTurnId: completedTurnId,
            assistantMessageId: assistantMessageId,
            resumeCursor: resumeCursor,
            insertedAssistantMessage: result.insertedAssistantMessage
        )
    }

    private func retryStartFailureCommit(runId: AgentRunID) {
        lock.lock()
        guard let pending = pendingStartFailures[runId] else {
            lock.unlock()
            return
        }
        let bufferedRunId = pendingStreamRunIds[pending.request.threadId]
        lock.unlock()

        if bufferedRunId == runId,
           flushPendingStreamWrites(runId: runId, threadId: pending.request.threadId) != nil {
            scheduleStartFailureDurabilityRetry(runId: runId)
            return
        }
        if let bufferedRunId, bufferedRunId != runId, !pending.otherRunActive {
            let error = NSError(
                domain: "RemoteCode.AgentRunCoordinator",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey:
                    "A start failure cannot overtake another run's buffered mirror events."]
            )
            emitPersistenceIssue(
                "run.start_failure.stream_owner",
                error: error,
                runId: runId,
                threadId: pending.request.threadId
            )
            scheduleStartFailureDurabilityRetry(runId: runId)
            return
        }

        do {
            guard try runRepo.status(of: runId) != nil else {
                throw NSError(
                    domain: "RemoteCode.AgentRunCoordinator",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Run row missing while committing start failure."]
                )
            }
            let threadStatus: AgentRunStatus = pending.preserveRecoverableSession ? .interrupted : .failed
            let run = AgentRun(
                id: runId,
                threadId: pending.request.threadId,
                provider: pending.request.provider,
                providerInstanceId: pending.request.providerInstanceId,
                model: pending.request.model,
                status: .failed,
                finishedAt: pending.finishedAt,
                errorMessage: pending.message
            )

            var terminalThread: AgentThread?
            var providerSession: ProviderSessionRuntime?
            if !pending.otherRunActive {
                guard try threadRepo.status(of: pending.request.threadId) != nil else {
                    throw NSError(
                        domain: "RemoteCode.AgentRunCoordinator",
                        code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "Thread row missing while committing start failure."]
                    )
                }
                terminalThread = AgentThread(
                    id: pending.request.threadId,
                    title: "",
                    provider: pending.request.provider,
                    providerInstanceId: pending.request.providerInstanceId,
                    model: pending.request.model,
                    status: threadStatus,
                    updatedAt: pending.finishedAt,
                    hasUnread: Self.hasUnread(for: threadStatus)
                )

                if let providerSessionRepo {
                    // Payload JSON only. A leftover 16-column session `get`
                    // (including cwd/model/status/error) hitchs start-failure
                    // commit just to copy `runtime_payload_json` into the
                    // terminal upsert.
                    let existingPayload = try providerSessionRepo.runtimePayloadJSON(of: pending.request.threadId) ?? nil
                    providerSession = ProviderSessionRuntime(
                        threadId: pending.request.threadId,
                        provider: pending.request.provider,
                        providerInstanceId: pending.request.providerInstanceId,
                        adapterKey: pending.adapterKey,
                        binaryIdentity: pending.binaryIdentity,
                        status: pending.preserveRecoverableSession ? .interrupted : .failed,
                        resumeCursor: pending.request.providerThreadId,
                        cwd: pending.request.cwd,
                        model: pending.request.model,
                        serviceTier: pending.request.serviceTier,
                        runtimeMode: pending.request.permissionMode,
                        lastRunId: runId,
                        lastEventKind: pending.preserveRecoverableSession
                            ? "run.resume_start_failed"
                            : "run.start_failed",
                        lastErrorMessage: pending.message,
                        runtimePayloadJSON: existingPayload,
                        updatedAt: pending.finishedAt
                    )
                }
            }

            _ = try runRepo.persistTerminalGraph(
                assistantMessage: nil,
                run: run,
                thread: terminalThread,
                providerSession: providerSession,
                streamEvent: pending.streamEvent
            )
            // A provider-start failure is terminal only after its run/thread/session
            // graph commits. Write the forensic row before any status or error callback;
            // failed durability attempts return above and therefore cannot append rows.
            _ = recordTerminalTransition(
                runId: runId,
                threadId: pending.request.threadId,
                requestedStatus: .failed,
                initiator: .providerStartFailure,
                providerPid: nil,
                exitStatus: nil,
                eventSequence: nil,
                eventTime: pending.finishedAt,
                commitTime: Date(),
                presentTime: Date()
            )
            lock.lock()
            receiptUsageFinalizationInFlight.insert(runId)
            let usage = latestTokenUsage.removeValue(forKey: runId)
            reconciledTokenUsage.removeValue(forKey: runId)
            lock.unlock()
            _ = finalizeOrRetryReceipt(
                PendingOrchestrationReceiptFinalization(
                    runId: runId,
                    threadId: pending.request.threadId,
                    status: .failed,
                    usage: usage,
                    qualityOutcome: AgentOrchestrationRuntime.qualityOutcome(status: .failed, finalMessage: nil)
                )
            )
        } catch {
            emitPersistenceIssue(
                "run.start_failure.terminal_graph.commit",
                error: error,
                runId: runId,
                threadId: pending.request.threadId
            )
            scheduleStartFailureDurabilityRetry(runId: runId)
            return
        }

        lock.lock()
        pendingStartFailures.removeValue(forKey: runId)
        startFailureRetryScheduled.remove(runId)
        clearStreamSequenceIfReleasedLocked(runId: runId, threadId: pending.request.threadId)
        discardRunThreadOwnershipIfReleasedLocked(runId)
        lock.unlock()

        if !pending.otherRunActive {
            for observer in observersSnapshot() {
                observer.runCoordinator(
                    self,
                    didChangeStatus: .failed,
                    runId: runId,
                    threadId: pending.request.threadId
                )
            }
        }
        for observer in observersSnapshot() {
            observer.runCoordinator(
                self,
                didReceive: pending.event,
                run: runId,
                threadId: pending.request.threadId
            )
        }
        onAssistantEvent?(pending.event, pending.request.threadId, runId)
        if !pending.otherRunActive {
            onRunFinished?(pending.request.threadId, runId, .failed)
        }
    }

    private func scheduleStartFailureDurabilityRetry(runId: AgentRunID) {
        lock.lock()
        guard pendingStartFailures[runId] != nil,
              startFailureRetryScheduled.insert(runId).inserted else {
            lock.unlock()
            return
        }
        lock.unlock()

        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.lock.lock()
            self.startFailureRetryScheduled.remove(runId)
            let stillPending = self.pendingStartFailures[runId] != nil
            self.discardRunThreadOwnershipIfReleasedLocked(runId)
            self.lock.unlock()
            if stillPending {
                self.retryStartFailureCommit(runId: runId)
            }
        }
    }

    /// Provider-native collaboration (Grok child sessions and Codex
    /// collabAgentToolCall state) bypasses the nested-CLI PATH proxy. Persist it
    /// into the same receipt ledger so the Subagents surface has one durable,
    /// provider-neutral source for native and cross-provider workers.
    private func persistProviderNativeSubagentLifecycle(
        from event: AssistantEvent,
        parentRunId: AgentRunID,
        threadId: AgentThreadID
    ) {
        guard let orchestrationRuntime else { return }
        guard ProviderNativeSubagentLifecycle.isPotentialLifecycleEvent(event) else { return }
        lock.lock()
        let metadata = activeRunMetadata[parentRunId]
        lock.unlock()
        // Grok `x.ai/session_update` shares this method with subagent lifecycle
        // payloads. Parse first: ordinary session chunks must not decode the
        // orchestration ledger (live freeze sampled 570 receipt scans / 8s).
        var parentProvider = metadata?.provider
        var updates = ProviderNativeSubagentLifecycle.updates(
            from: event,
            parentProvider: parentProvider ?? .grok
        )
        if updates.isEmpty {
            if parentProvider != .codex, case .itemDelta = event {
                let parentReceipt = try? orchestrationRuntime.receipt(runId: parentRunId)
                // Provider only. A leftover 10-column `get` (including
                // `error_message`) hitchs Codex-shaped itemDelta reparse.
                parentProvider = parentReceipt?.provider
                    ?? (try? runRepo.provider(of: parentRunId))
                if let parentProvider {
                    updates = ProviderNativeSubagentLifecycle.updates(
                        from: event,
                        parentProvider: parentProvider
                    )
                }
            }
            guard !updates.isEmpty else { return }
        }

        let parentReceipt = metadata == nil
            ? (try? orchestrationRuntime.receipt(runId: parentRunId))
            : nil
        parentProvider = parentProvider
            ?? parentReceipt?.provider
            ?? (metadata == nil ? (try? runRepo.provider(of: parentRunId)) : nil)
        guard let parentProvider else { return }
        let parentProviderInstanceId = metadata?.providerInstanceId
            ?? parentReceipt?.providerInstanceId
            ?? parentProvider.rawValue
        let parentModel = metadata?.model
            ?? parentReceipt?.model
            ?? (metadata == nil ? (try? runRepo.model(of: parentRunId)) : nil)
            ?? "unknown"
        for update in updates {
            do {
                _ = try orchestrationRuntime.recordProviderNativeChild(
                    runId: update.childRunId,
                    threadId: threadId,
                    provider: update.provider,
                    providerInstanceId: update.provider == parentProvider
                        ? parentProviderInstanceId
                        : update.provider.rawValue,
                    model: update.provider == parentProvider ? parentModel : "unknown",
                    // Provider-native lifecycle events do not acknowledge the
                    // child's actual effort. Keep it unknown instead of
                    // presenting the parent's request as provider evidence.
                    reasoningEffort: nil,
                    nodeId: update.nodeId,
                    parentRunId: parentRunId
                )
                switch update.phase {
                case .unknown:
                    try orchestrationRuntime.markReceiptUnknown(runId: update.childRunId)
                case .completed:
                    try orchestrationRuntime.finalizeReceipt(
                        runId: update.childRunId,
                        status: .completed
                    )
                case .failed:
                    try orchestrationRuntime.finalizeReceipt(
                        runId: update.childRunId,
                        status: .failed
                    )
                case .cancelled:
                    try orchestrationRuntime.finalizeReceipt(
                        runId: update.childRunId,
                        status: .cancelled
                    )
                case .active:
                    break
                }
            } catch {
                emitPersistenceIssue(
                    "subagent.lifecycle",
                    error: error,
                    runId: parentRunId,
                    threadId: threadId
                )
            }
        }
    }

    private func scheduleTerminalDurabilityRetry(runId: AgentRunID, threadId: AgentThreadID) {
        lock.lock()
        guard pendingTerminalEvents[runId] != nil,
              terminalRetryScheduled.insert(runId).inserted else {
            lock.unlock()
            return
        }
        lock.unlock()

        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            let pending = self.takePendingTerminalRetry(runId: runId)
            guard let pending else { return }
            self.handle(
                event: .finished(
                    pending.status,
                    finalMessage: pending.finalMessage,
                    providerThreadId: pending.providerThreadId
                ),
                runId: runId,
                threadId: threadId,
                deduplicatesInFlightFinish: false,
                providerTerminalAcknowledged: pending.providerTerminalAcknowledged,
                isDurabilityRetry: true
            )
        }
    }

    private func takePendingTerminalRetry(runId: AgentRunID) -> PendingTerminalEvent? {
        lock.lock()
        defer { lock.unlock() }
        terminalRetryScheduled.remove(runId)
        let pending = pendingTerminalEvents[runId]
        discardRunThreadOwnershipIfReleasedLocked(runId)
        return pending
    }

    private static func hasUnread(for status: AgentRunStatus) -> Bool {
        switch status {
        case .completed, .failed, .interrupted:
            true
        case .pending, .running, .cancelled:
            false
        }
    }

    private func persistMinimalCheckpointIdentity(
        threadId: AgentThreadID,
        runId: AgentRunID,
        turnId rawTurnId: String?,
        assistantMessageId: AgentMessageID?
    ) -> AgentTurnCheckpointSummary? {
        guard let checkpointRepo else { return nil }
        let turnId = rawTurnId?.isEmpty == false ? rawTurnId! : "run-\(runId.value.uuidString)"
        let count: Int
        do {
            count = try checkpointRepo.nextTurnCount(threadId: threadId)
        } catch {
            emitPersistenceIssue("checkpoint.next_turn_count", error: error, runId: runId, threadId: threadId)
            return nil
        }
        let summary = AgentTurnCheckpointSummary(
            threadId: threadId,
            runId: runId,
            turnId: turnId,
            checkpointTurnCount: count,
            checkpointRef: "local-diff:\(runId.value.uuidString):\(turnId)",
            status: .missing,
            files: [],
            assistantMessageId: assistantMessageId
        )
        do {
            try checkpointRepo.upsert(summary)
            agentRunLog.info("checkpoint.identity_captured thread=\(threadId.value.uuidString, privacy: .public) run=\(runId.value.uuidString, privacy: .public) count=\(count, privacy: .public)")
            return summary
        } catch {
            emitPersistenceIssue("checkpoint.upsert", error: error, runId: runId, threadId: threadId)
            return nil
        }
    }

    private func enrichCheckpoint(
        _ identity: AgentTurnCheckpointSummary,
        cwd: String?
    ) async {
        guard let checkpointRepo else { return }
#if DEBUG
        if let barrier = checkpointEnrichmentBarrierForTesting {
            await barrier(identity.runId)
        }
#endif
        let summary: AgentTurnCheckpointSummary
        if let cwd, !cwd.isEmpty {
            let gitSummary = GitDiff.summary(in: cwd)
            if let gitSummary, gitSummary.isGitRepo {
                let files = gitSummary.files.map {
                    AgentTurnCheckpointFile(
                        path: $0.path,
                        kind: $0.status.rawValue,
                        additions: $0.additions,
                        deletions: $0.deletions
                    )
                }
                summary = AgentTurnCheckpointSummary(
                    threadId: identity.threadId,
                    runId: identity.runId,
                    turnId: identity.turnId,
                    checkpointTurnCount: identity.checkpointTurnCount,
                    checkpointRef: identity.checkpointRef,
                    status: .ready,
                    files: files,
                    fileSnapshots: captureFileSnapshots(files: files, cwd: cwd),
                    diffPatch: GitDiff.diff(in: cwd, path: nil),
                    fileDiffs: captureFileDiffs(files: files, cwd: cwd),
                    assistantMessageId: identity.assistantMessageId,
                    completedAt: identity.completedAt
                )
            } else if gitSummary == nil {
                // A timed-out probe is not an empty change list: never `.ready`.
                summary = AgentTurnCheckpointSummary(
                    threadId: identity.threadId,
                    runId: identity.runId,
                    turnId: identity.turnId,
                    checkpointTurnCount: identity.checkpointTurnCount,
                    checkpointRef: identity.checkpointRef,
                    status: .error,
                    files: [],
                    assistantMessageId: identity.assistantMessageId,
                    errorMessage: GitDiff.summaryTimedOutMessage,
                    completedAt: identity.completedAt
                )
            } else {
                summary = AgentTurnCheckpointSummary(
                    threadId: identity.threadId,
                    runId: identity.runId,
                    turnId: identity.turnId,
                    checkpointTurnCount: identity.checkpointTurnCount,
                    checkpointRef: identity.checkpointRef,
                    status: .missing,
                    files: [],
                    assistantMessageId: identity.assistantMessageId,
                    errorMessage: "Not a git repository.",
                    completedAt: identity.completedAt
                )
            }
        } else {
            summary = AgentTurnCheckpointSummary(
                threadId: identity.threadId,
                runId: identity.runId,
                turnId: identity.turnId,
                checkpointTurnCount: identity.checkpointTurnCount,
                checkpointRef: identity.checkpointRef,
                status: .missing,
                files: [],
                assistantMessageId: identity.assistantMessageId,
                errorMessage: "Run workspace is missing.",
                completedAt: identity.completedAt
            )
        }
        do {
            try checkpointRepo.upsert(summary)
            agentRunLog.info("checkpoint.enriched thread=\(identity.threadId.value.uuidString, privacy: .public) run=\(identity.runId.value.uuidString, privacy: .public) count=\(identity.checkpointTurnCount, privacy: .public) status=\(summary.status.rawValue, privacy: .public) files=\(summary.files.count, privacy: .public)")
        } catch {
            emitPersistenceIssue(
                "checkpoint.enrichment.upsert",
                error: error,
                runId: identity.runId,
                threadId: identity.threadId
            )
        }
    }

    private func captureFileSnapshots(files: [AgentTurnCheckpointFile], cwd: String) -> [AgentTurnCheckpointFileSnapshot] {
        // CKPT-BUDGET: the per-file cap alone still let one turn write a
        // multi-MiB row when it touched many ~1 MiB text files. Budget the
        // whole checkpoint instead; files that no longer fit take the same
        // nil-content marker path as oversized/binary ones.
        var remainingBudget = Self.checkpointSnapshotTotalByteCap
        return files.map { file in
            guard file.kind != GitFileStatus.deleted.rawValue,
                  let url = safeWorkspaceURL(cwd: cwd, relativePath: file.path),
                  let data = Self.readCheckpointSnapshotPrefix(from: url) else {
                return AgentTurnCheckpointFileSnapshot(path: file.path, kind: file.kind, contentsBase64: nil)
            }
            // P2: cap transient allocation + DB row size. Large or binary files
            // are not base64'd into the checkpoint; we store a nil-content marker
            // (same restore path as a deleted file -> restore from HEAD) and log
            // a content hash so the skip is diagnosable. Oversized files hash
            // only the FileHandle prefix (CKPT-READ).
            let decision = Self.checkpointSnapshotBudgetDecision(
                byteCount: data.count,
                isBinary: Self.dataLooksBinary(data),
                remainingBudget: remainingBudget,
                cap: Self.checkpointSnapshotByteCap,
                hash: { Self.sha256Hex(data) }
            )
            switch decision {
            case .snapshot:
                remainingBudget -= data.count
                return AgentTurnCheckpointFileSnapshot(path: file.path, kind: file.kind, contentsBase64: data.base64EncodedString())
            case .skipMarker(let hash):
                agentRunLog.info("checkpoint.snapshot.skipped path=\(file.path, privacy: .public) bytes=\(data.count, privacy: .public) budget_remaining=\(remainingBudget, privacy: .public) hash=\(hash, privacy: .public)")
                return AgentTurnCheckpointFileSnapshot(path: file.path, kind: file.kind, contentsBase64: nil)
            }
        }
    }

    /// P2: per-file checkpoint snapshot decision. Pure + nonisolated so it is
    /// directly unit-testable without standing up a coordinator. A file is only
    /// base64-snapshotted when it is text AND within the byte cap; otherwise the
    /// caller stores a content-hash skip marker instead of the bytes.
    enum CheckpointSnapshotDecision: Equatable {
        case snapshot
        case skipMarker(hash: String)
    }

    /// 1 MiB. Files at or under this (and not binary) are snapshotted inline.
    nonisolated static let checkpointSnapshotByteCap = 1 << 20

    /// CKPT-BUDGET: 1 MiB of snapshot bytes per checkpoint (raw file bytes; the
    /// stored base64 JSON is ~4/3 of it). Without a total, a turn touching many
    /// at-cap text files wrote a multi-MiB row every turn: the live store showed
    /// 66 checkpoints over 500 KB carrying 66% of a 176 MB snapshot column.
    nonisolated static let checkpointSnapshotTotalByteCap = 1 << 20

    /// FileHandle prefix of `cap + 1` bytes. The extra byte distinguishes
    /// at-cap (snapshot) from over-cap (skip) without a full-file `Data`.
    nonisolated static func readCheckpointSnapshotPrefix(
        from url: URL,
        cap: Int = checkpointSnapshotByteCap
    ) -> Data? {
        GitDiff.readFilePrefix(at: url, maxBytes: cap + 1)
    }

    nonisolated static func checkpointSnapshotDecision(
        byteCount: Int,
        isBinary: Bool,
        cap: Int,
        hash: () -> String
    ) -> CheckpointSnapshotDecision {
        if isBinary || byteCount > cap {
            return .skipMarker(hash: hash())
        }
        return .snapshot
    }

    /// CKPT-BUDGET: the P2 per-file rule plus the checkpoint-wide byte budget.
    /// A file that does not fit the remaining budget is skipped even when it is
    /// small text, so one turn can never write more than the total. Later
    /// smaller files still snapshot: the budget only rejects what does not fit.
    nonisolated static func checkpointSnapshotBudgetDecision(
        byteCount: Int,
        isBinary: Bool,
        remainingBudget: Int,
        cap: Int,
        hash: () -> String
    ) -> CheckpointSnapshotDecision {
        if byteCount > remainingBudget {
            return .skipMarker(hash: hash())
        }
        return checkpointSnapshotDecision(byteCount: byteCount, isBinary: isBinary, cap: cap, hash: hash)
    }

    /// Matches the repo's text/binary convention (GitDiff): a NUL byte anywhere
    /// means the content cannot be treated as text.
    nonisolated static func dataLooksBinary(_ data: Data) -> Bool {
        data.contains(0)
    }

    /// PERF: nibble table instead of per-byte `String(format:)` so checkpoint
    /// skip-marker digests on large/binary files avoid 32 formatter calls while
    /// keeping the same CryptoKit lowercase hex contract.
    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    nonisolated static func sha256Hex(_ data: Data) -> String {
        hexDigest(SHA256.hash(data: data))
    }

    private nonisolated static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    // PERF-MAC_AGENT-007: fast streaming was emitting 2-3 synchronous SQLite
    // writes per stream event (appendStreamEvent + optional appendProviderEventLog
    // + updateDiagnostics), each its own transaction. We now buffer those writes
    // and flush them on a cadence. The buffer + the flush decision are pure and
    // unit-testable so the batching latency/size bounds are pinned by tests.
    struct StreamWriteItem {
        var seq: Int
        var kind: String
        var payloadJSON: String
        var providerEvent: ProviderRuntimeEvent?

        var encodedByteCount: Int {
            kind.utf8.count + payloadJSON.utf8.count + (providerEvent?.payloadJSON.utf8.count ?? 0)
        }
    }

    struct StreamWriteBatch {
        private var items: [StreamWriteItem] = []
        /// Running total so flush decisions do not re-reduce utf8 lengths each tick.
        private(set) var encodedByteCount: Int = 0
        /// Running max so seq allocation skips the per-call map+max scan.
        private(set) var highestSeq: Int = 0

        var isEmpty: Bool { items.isEmpty }
        var count: Int { items.count }

        mutating func append(_ item: StreamWriteItem) {
            items.append(item)
            encodedByteCount += item.encodedByteCount
            if item.seq > highestSeq { highestSeq = item.seq }
        }

        func snapshot() -> [StreamWriteItem] {
            items
        }

        /// Remove only the exact prefix that the repository committed. A mismatch
        /// means another lifecycle path changed ownership and must fail loud.
        mutating func acknowledge(_ committed: [StreamWriteItem]) -> Bool {
            guard committed.count <= items.count else { return false }
            for (current, persisted) in zip(items.prefix(committed.count), committed) {
                guard current.seq == persisted.seq,
                      current.kind == persisted.kind,
                      current.payloadJSON == persisted.payloadJSON,
                      current.providerEvent?.id == persisted.providerEvent?.id else {
                    return false
                }
            }
            for item in items.prefix(committed.count) {
                encodedByteCount -= item.encodedByteCount
            }
            items.removeFirst(committed.count)
            if items.isEmpty {
                encodedByteCount = 0
                highestSeq = 0
            }
            return true
        }

        mutating func drain() -> [StreamWriteItem] {
            let snapshot = items
            items.removeAll(keepingCapacity: true)
            encodedByteCount = 0
            highestSeq = 0
            return snapshot
        }
    }

    /// Next durable stream sequence for `runId`.
    ///
    /// Must be called with `lock` held. Uses the higher of the in-memory counter,
    /// any still-buffered seq for this run, and durable MAX(seq) when the
    /// in-memory counter was cleared (finish/stop) so a late Grok event cannot
    /// reissue seq 1 for a different event kind (which
    /// `persistStreamEventIdempotently` rejects as a conflicting identity).
    private func allocateStreamSequenceLocked(runId: AgentRunID, threadId: AgentThreadID) -> Int {
        var high = seq[runId] ?? 0
        if seq[runId] == nil {
            // Finish/stop clear `seq` while durable rows remain. Re-seed before
            // the next allocate so late providerRuntime/turnStarted cannot steal
            // an already-committed identity.
            high = max(high, (try? runRepo.maxStreamEventSeq(runId: runId)) ?? 0)
        }
        if pendingStreamRunIds[threadId] == runId,
           let batch = pendingStreamWrites[threadId] {
            high = max(high, batch.highestSeq)
        }
        let next = high + 1
        seq[runId] = next
        return next
    }

    /// Drop in-memory sequence only when this run no longer owns a retryable
    /// stream buffer. Must be called with `lock` held.
    private func clearStreamSequenceIfReleasedLocked(runId: AgentRunID, threadId: AgentThreadID) {
        if pendingStreamRunIds[threadId] == runId,
           let batch = pendingStreamWrites[threadId],
           !batch.isEmpty {
            return
        }
        seq.removeValue(forKey: runId)
        discardRunThreadOwnershipIfReleasedLocked(runId)
    }

    // PERF-MAC_AGENT-008: the lastPersistedAssistantContent dedup cache stores one
    // String per thread and is only removed on revertThreadToCheckpoint. In
    // multi-thread sessions the dead entries accumulate and can retain MBs of final-
    // answer text. Evict the entry on thread close/idle (finished or cancelled) and
    // refuse to cache entries whose UTF-8 byte count exceeds the cap (they fall back
    // to the full-history dedup scan, which is correct and rare).
    //
    // lastPersistedAssistantContentSizeCap: entries larger than this are not held in
    // the cache, bounding the per-entry overhead for extremely long responses.
    nonisolated static let lastPersistedAssistantContentSizeCap = 32_768

    /// Pure eviction decision for the lastPersistedAssistantContent dedup cache.
    /// Evict when the thread is no longer active (closed/idle) OR when the entry
    /// is oversized. nonisolated so it is directly unit-testable.
    nonisolated static func shouldEvictLastPersistedContent(
        threadClosed: Bool,
        entryByteCount: Int,
        sizeCapBytes: Int = lastPersistedAssistantContentSizeCap
    ) -> Bool {
        threadClosed || entryByteCount > sizeCapBytes
    }

    /// How many buffered stream events force a flush. Bounds both the in-memory
    /// buffer and the lock-held replay size on a single flush.
    nonisolated static let streamFlushCountThreshold = 16
    /// Large provider frames (Chrome dumps, shell output) flush by bytes before
    /// the count threshold so the in-memory batch stays bounded.
    /// Was 8 MiB; 2 MiB keeps the in-memory batch small under multi-thread streams.
    nonisolated static let streamFlushByteThreshold = 2 * 1_024 * 1_024
    /// Absolute per-frame ceiling. Frames under this limit always admit; older
    /// history is reclaimed by retention prune. Only pathological frames above
    /// this are soft-truncated — never replaced with a recoverable "omitted"
    /// error banner. Was 16 MiB, then 8 MiB; 4 MiB still exceeds
    /// streamFlushByteThreshold (2 MiB).
    nonisolated static let maximumBufferedEventBytes = 4 * 1_024 * 1_024
    /// Max latency (ms) a buffered stream event may wait before being flushed,
    /// so a slow trickle still reaches the DB (and survives reload/crash).
    nonisolated static let streamFlushTimeThresholdMs: Int64 = 250

    /// Soft-truncate without store (tests / fallback). Production stream writes
    /// use `AgentRunRepository.boundPayloadForPersistence` so originals are
    /// stored before presentation loss (S3).
    nonisolated static func softTruncateUTF8Payload(
        _ payloadJSON: String,
        byteLimit: Int
    ) -> String {
        // nil store: pure presentation truncate (no I/O); never throws.
        (try? AgentRunRepository.softTruncateUTF8Payload(payloadJSON, byteLimit: byteLimit, reversibleStore: nil))
            ?? payloadJSON
    }

    nonisolated static func boundedPersistedStreamPayload(
        _ payloadJSON: String,
        byteLimit: Int = maximumBufferedEventBytes
    ) -> String {
        Self.softTruncateUTF8Payload(payloadJSON, byteLimit: byteLimit)
    }

    nonisolated static func boundedProviderRuntimeEvent(
        _ event: ProviderRuntimeEvent,
        byteLimit: Int = maximumBufferedEventBytes
    ) -> ProviderRuntimeEvent {
        let bounded = Self.softTruncateUTF8Payload(event.payloadJSON, byteLimit: byteLimit)
        guard bounded != event.payloadJSON else { return event }
        return ProviderRuntimeEvent(
            id: event.id,
            provider: event.provider,
            source: event.source,
            method: event.method,
            providerTurnId: event.providerTurnId,
            providerItemId: event.providerItemId,
            providerRequestId: event.providerRequestId,
            payloadJSON: bounded,
            receivedAtMs: event.receivedAtMs
        )
    }

    /// FIFO-set helper for correctness identifiers stored in the compact runtime
    /// payload. The newest identifier is always retained; old resolved/stale IDs
    /// are evicted from this diagnostic index, while their durable callback rows
    /// remain authoritative.
    nonisolated static func boundedRuntimeIdentifiers(
        existing: [String],
        adding identifier: String,
        countLimit: Int = 128,
        byteLimit: Int = 32 * 1_024
    ) -> [String] {
        boundedRuntimeIdentifiers(existing.filter { $0 != identifier } + [identifier], countLimit: countLimit, byteLimit: byteLimit)
    }

    nonisolated static func boundedRuntimeIdentifiers(
        _ identifiers: [String],
        countLimit: Int = 128,
        byteLimit: Int = 32 * 1_024
    ) -> [String] {
        var result = identifiers
        var bytes = result.reduce(0) { $0 + $1.utf8.count }
        while result.count > max(1, countLimit)
            || (bytes > max(1, byteLimit) && result.count > 1) {
            bytes -= result.removeFirst().utf8.count
        }
        return result
    }

    nonisolated static let compactActivePlanStepLimit = 512
    nonisolated static let compactActivePlanByteLimit = 256 * 1_024

    // PERF: activePlanUpdated previously JSON-encoded the plan solely for a byte
    // ceiling on every plan stream event. Use estimatedCompactJSONBytes (upper
    // bound of wire size) so admission stays O(payload) without JSONEncoder allocs.
    nonisolated static func activePlanFitsCompactBudget(
        _ plan: AssistantActivePlan,
        stepLimit: Int = compactActivePlanStepLimit,
        byteLimit: Int = compactActivePlanByteLimit
    ) -> Bool {
        guard plan.steps.count <= max(1, stepLimit) else { return false }
        // Upper-bound estimate: may reject a few edge-case plans that would still
        // fit true JSON size near the ceiling; never admits oversize recovery state.
        return plan.estimatedCompactJSONBytes <= max(1, byteLimit)
    }

    /// Pure flush-cadence decision: flush when there is pending work AND either the
    /// count cap is reached or the time budget has elapsed. nonisolated so it is
    /// directly unit-testable without standing up a coordinator.
    nonisolated static func shouldFlushStreamBatch(
        pendingCount: Int,
        pendingBytes: Int = 0,
        sinceLastFlushMs: Int64,
        countThreshold: Int = streamFlushCountThreshold,
        byteThreshold: Int = streamFlushByteThreshold,
        timeThresholdMs: Int64 = streamFlushTimeThresholdMs
    ) -> Bool {
        guard pendingCount > 0 else { return false }
        return pendingCount >= countThreshold
            || pendingBytes >= byteThreshold
            || sinceLastFlushMs >= timeThresholdMs
    }

    private func captureFileDiffs(files: [AgentTurnCheckpointFile], cwd: String) -> [AgentTurnCheckpointFileDiff] {
        let paths = files.map(\.path)
        let patchByPath = GitDiff.diffAll(in: cwd, paths: paths)
        return files.map { file in
            let patch = patchByPath[file.path] ?? ""
            return AgentTurnCheckpointFileDiff(path: file.path, patch: patch.isEmpty ? "Untracked file captured in checkpoint: \(file.path)" : patch)
        }
    }

    private func restoreWorkspace(to checkpoint: AgentTurnCheckpointSummary, newerCheckpoints: [AgentTurnCheckpointSummary], cwd: String) throws {
        let targetPaths = Set(checkpoint.fileSnapshots.map(\.path))
        let newerOnlyPaths = Set(newerCheckpoints.flatMap { $0.fileSnapshots.map(\.path) }).subtracting(targetPaths)
        for path in newerOnlyPaths {
            try restoreHeadOrRemove(path: path, cwd: cwd)
        }
        for snapshot in checkpoint.fileSnapshots {
            guard let url = safeWorkspaceURL(cwd: cwd, relativePath: snapshot.path) else {
                throw AgentProviderAdapterError.unsupported("checkpoint path escapes workspace: \(snapshot.path)")
            }
            if snapshot.kind == GitFileStatus.deleted.rawValue || snapshot.contentsBase64 == nil {
                try restoreHeadOrRemove(path: snapshot.path, cwd: cwd)
                continue
            }
            guard let encoded = snapshot.contentsBase64,
                  let data = Data(base64Encoded: encoded) else {
                throw AgentProviderAdapterError.unsupported("checkpoint snapshot is corrupt: \(snapshot.path)")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    /// UX-MAC-CHECKPOINT-REVERT-UNDO: snapshot the forward state a revert is
    /// about to destroy. Reads the CURRENT on-disk bytes for every affected path
    /// (nil = absent) and fetches the to-be-deleted message rows, then stores it
    /// under `lock`. Best-effort: a read failure for a single path records it as
    /// absent rather than aborting the revert.
    private func captureCheckpointRevertUndo(
        threadId: AgentThreadID,
        target: AgentTurnCheckpointSummary,
        newer: [AgentTurnCheckpointSummary],
        cwd: String
    ) {
        let paths = CheckpointRevertUndo.affectedPaths(target: target, newer: newer)
        let forwardFiles: [CheckpointRevertUndo.CapturedFile] = paths.sorted().map { path in
            guard let url = safeWorkspaceURL(cwd: cwd, relativePath: path),
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return CheckpointRevertUndo.CapturedFile(path: path, contentsBase64: nil)
            }
            return CheckpointRevertUndo.CapturedFile(path: path, contentsBase64: data.base64EncodedString())
        }
        let deletedMessages: [AgentMessage] = newer
            .compactMap(\.assistantMessageId)
            .compactMap { try? messageRepo.get(id: $0) }
        let undo = CheckpointRevertUndo(
            threadId: threadId,
            checkpointTurnCount: target.checkpointTurnCount,
            capturedAt: Date(),
            forwardFiles: forwardFiles,
            deletedCheckpoints: newer,
            deletedMessages: deletedMessages
        )
        lock.lock(); lastCheckpointRevertUndo = undo; lock.unlock()
    }

    /// UX-MAC-CHECKPOINT-REVERT-UNDO: reverse the most recent checkpoint revert,
    /// provided the undo window has not lapsed. Restores files (writing back
    /// captured bytes, or removing files that were absent pre-revert) and
    /// re-inserts the deleted checkpoint + message rows FK-safe (checkpoints
    /// before messages; both reference the still-existing thread). Throws if no
    /// matching undo exists or the window lapsed; on those paths nothing is
    /// mutated. Provider state is intentionally left as rolled-back — the DB and
    /// files move forward while the provider conversation stays at the target
    /// turn; this desync is the same best-effort stance as the thread-delete
    /// undo and is NOT reconciled here.
    public func undoLastCheckpointRevert(threadId: AgentThreadID, cwd: String, now: Date = Date()) throws {
        lock.lock()
        let stored = lastCheckpointRevertUndo
        lock.unlock()
        guard let undo = stored, undo.threadId == threadId else {
            throw AgentProviderAdapterError.unsupported("no checkpoint revert to undo for this thread")
        }
        guard CheckpointRevertUndo.isWithinUndoWindow(
            capturedAt: undo.capturedAt,
            now: now,
            window: Self.checkpointRevertUndoWindow
        ) else {
            throw AgentProviderAdapterError.unsupported("checkpoint revert undo window has lapsed")
        }
        // (a) FILES: write back pre-revert bytes, or remove files that were absent.
        for file in undo.forwardFiles {
            guard let url = safeWorkspaceURL(cwd: cwd, relativePath: file.path) else {
                throw AgentProviderAdapterError.unsupported("checkpoint path escapes workspace: \(file.path)")
            }
            if let encoded = file.contentsBase64 {
                guard let data = Data(base64Encoded: encoded) else {
                    throw AgentProviderAdapterError.unsupported("captured snapshot is corrupt: \(file.path)")
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        // (b) DB FK-safe: re-insert checkpoints first, then messages. agent_messages
        // and the checkpoint rows both reference agent_threads(id); the thread row
        // still exists, so the only ordering constraint is parent-before-child.
        for checkpoint in undo.deletedCheckpoints {
            try checkpointRepo?.upsert(checkpoint)
        }
        for message in undo.deletedMessages {
            try messageRepo.append(message)
        }
        lock.lock(); lastCheckpointRevertUndo = nil; lock.unlock()
    }

    private func validateRestorableSnapshots(in checkpoint: AgentTurnCheckpointSummary, newerCheckpoints: [AgentTurnCheckpointSummary], cwd: String) throws {
        let snapshots = checkpoint.fileSnapshots + newerCheckpoints.flatMap(\.fileSnapshots)
        for snapshot in snapshots {
            guard safeWorkspaceURL(cwd: cwd, relativePath: snapshot.path) != nil else {
                throw AgentProviderAdapterError.unsupported("checkpoint path escapes workspace: \(snapshot.path)")
            }
            if snapshot.kind != GitFileStatus.deleted.rawValue,
               let encoded = snapshot.contentsBase64,
               Data(base64Encoded: encoded) == nil {
                throw AgentProviderAdapterError.unsupported("checkpoint snapshot is corrupt: \(snapshot.path)")
            }
        }
    }

    private func restoreHeadOrRemove(path: String, cwd: String) throws {
        if GitDiff.restorePathToHead(in: cwd, path: path).ok { return }
        guard let url = safeWorkspaceURL(cwd: cwd, relativePath: path) else {
            throw AgentProviderAdapterError.unsupported("checkpoint path escapes workspace: \(path)")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func safeWorkspaceURL(cwd: String, relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: cwd).standardizedFileURL
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { return nil }
        return url
    }

    private func emitPersistenceIssue(_ operation: String, error: Error, runId: AgentRunID, threadId: AgentThreadID) {
        let message = "Persistence failure during \(operation): \(error)"
        for observer in observersSnapshot() {
            observer.runCoordinator(self, didReceive: .error(message: message, recoverable: false), run: runId, threadId: threadId)
        }
        // A persistence diagnostic is intentionally local-only. Publishing an
        // event that cannot enter the durable snapshot would let remote mirrors
        // advance their EventBus watermark past unrecoverable history.
        onPersistenceIssue?(message, threadId, runId)
    }

    /// Persists coordinator-synthesized events before publishing them. Provider
    /// stream events use the normal batch path; start failures cannot because a
    /// second run may already own the same thread buffer and a failed start is
    /// never registered in `activeThreads` for snapshot-triggered flushing.
    private func publishImmediateAssistantEvent(
        _ event: AssistantEvent,
        threadId: AgentThreadID,
        runId: AgentRunID
    ) {
        // Persist under the mirror lock, then release before observer / EventBus
        // fan-out. Host callbacks must not run while snapshot readers wait on
        // the same lock (see provider-event handle path).
        enum ImmediatePublishOutcome {
            case published
            case failed(operation: String, error: Error)
        }
        let outcome: ImmediatePublishOutcome = {
            mirrorEventLock(for: threadId).lock()
            defer { mirrorEventLock(for: threadId).unlock() }

            lock.lock()
            let eventSequence = allocateStreamSequenceLocked(runId: runId, threadId: threadId)
            lock.unlock()

            let data: Data
            do {
                data = try encodeStreamEvent(event)
            } catch {
                recordMirrorPersistenceFailure(error, threadId: threadId)
                return .failed(operation: "run.stream_event.encode", error: error)
            }
            guard let json = String(data: data, encoding: .utf8) else {
                let error = NSError(
                    domain: "RemoteCode.AgentRunCoordinator",
                    code: 422,
                    userInfo: [NSLocalizedDescriptionKey: "AssistantEvent JSON was not UTF-8."]
                )
                recordMirrorPersistenceFailure(error, threadId: threadId)
                return .failed(operation: "run.stream_event.encode", error: error)
            }
            do {
                try runRepo.appendStreamEvent(
                    runId: runId,
                    seq: eventSequence,
                    kind: event.debugDescription,
                    payloadJSON: json
                )
            } catch {
                recordMirrorPersistenceFailure(error, threadId: threadId)
                return .failed(operation: "run.stream_event.append", error: error)
            }
            do {
                try providerSessionRepo?.updateDiagnostics(
                    threadId: threadId,
                    lastEventKind: event.debugDescription,
                    lastErrorMessage: nil
                )
            } catch {
                // Diagnostics failure is non-fatal to publication; emit after unlock.
                return .failed(operation: "provider_session.diagnostics.update", error: error)
            }
            return .published
        }()

        switch outcome {
        case .failed(let operation, let error):
            emitPersistenceIssue(operation, error: error, runId: runId, threadId: threadId)
            // Diagnostics-only failures still publish the already-persisted event.
            if operation != "provider_session.diagnostics.update" {
                return
            }
        case .published:
            break
        }
        for observer in observersSnapshot() {
            observer.runCoordinator(self, didReceive: event, run: runId, threadId: threadId)
        }
        onAssistantEvent?(event, threadId, runId)
    }

    private func recordMirrorPersistenceFailure(_ error: Error, threadId: AgentThreadID) {
        lock.lock()
        if mirrorPersistenceFailures[threadId] == nil {
            mirrorPersistenceFailures[threadId] = error
        }
        lock.unlock()
    }

    private func observersSnapshot() -> [AgentRunObserver] {
        lock.lock()
        observerRefs.removeAll { $0.value == nil }
        let observers = observerRefs.compactMap(\.value)
        lock.unlock()
        return observers
    }

    private func providerSessionRuntimePayloadJSON(
        _ existingJSON: String?,
        status: AgentRunStatus,
        resumeCursor: String?,
        completedTurnId: String?,
        model: String,
        serviceTier: AgentServiceTier,
        runtimeMode: AgentPermissionMode,
        interactionMode: AgentInteractionMode,
        activeTurnId: String?,
        updatedAt: Date
    ) -> String? {
        var payload = ProviderSessionRuntimePayload.decode(existingJSON)
        if status == .completed, let completedTurnId, completedTurnId != payload.lastCompletedTurnId {
            payload.turnCount += 1
        }
        payload.providerThreadId = resumeCursor
        payload.lastCompletedTurnId = completedTurnId ?? payload.lastCompletedTurnId
        payload.model = model
        payload.serviceTier = serviceTier
        payload.runtimeMode = runtimeMode
        payload.interactionMode = interactionMode
        payload.activeTurnId = activeTurnId
        payload.updatedAtMs = Int64(updatedAt.timeIntervalSince1970 * 1000)
        return payload.encoded()
    }
}

private struct PendingTerminalEvent {
    var status: AgentRunStatus
    var finalMessage: String?
    var providerThreadId: String?
    var assistantMessage: AgentMessage?
    var finishedAt: Date
    var providerTerminalAcknowledged: Bool
    /// Durable `agent_runs.error_message` for this terminal (nil for cancel/success).
    var errorMessage: String?
    /// Durable `agent_runs.terminal_reason` (`TerminalTransitionReason.rawValue`).
    var terminalReason: String? = nil
}

private struct PendingStartFailure {
    var request: AgentRunRequest
    var adapterKey: String
    var binaryIdentity: String?
    var preserveRecoverableSession: Bool
    var otherRunActive: Bool
    var message: String
    var event: AssistantEvent
    var streamEvent: AgentRunRepository.StreamWriteIntent
    var finishedAt: Date
}

private struct TerminalPersistenceContext {
    var runMetadata: (provider: AgentProvider, providerInstanceId: String?, model: String, cwd: String, serviceTier: AgentServiceTier, runtimeMode: AgentPermissionMode, interactionMode: AgentInteractionMode, adapterKey: String, binaryIdentity: String?, reasoningEffort: AgentReasoningEffort?, distillMainEffort: AgentEffortSelection?, distillReasoningEffort: AgentEffortSelection?, distillMode: DistillExecutionMode)?
    var completedTurnId: String?
    var assistantMessageId: AgentMessageID?
    var resumeCursor: String?
    var insertedAssistantMessage: Bool
}

private struct ProviderRecoveryContext {
    var resumeCursor: String?
    var runtimeMode: AgentPermissionMode?
    var serviceTier: AgentServiceTier?
    var interactionMode: AgentInteractionMode?

    init(resumeCursor: String?) {
        self.resumeCursor = resumeCursor
    }

    init(session: ProviderSessionRuntime) {
        self.resumeCursor = session.resumeCursor
        self.runtimeMode = session.runtimeMode
        self.serviceTier = session.serviceTier
        self.interactionMode = ProviderSessionRuntimePayload.decode(session.runtimePayloadJSON).interactionMode
    }
}

private final class WeakAgentRunObserver {
    weak var value: AgentRunObserver?

    init(_ value: AgentRunObserver) {
        self.value = value
    }
}

private struct ProviderSessionRuntimePayload: Codable, Equatable {
    var providerThreadId: String?
    var lastCompletedTurnId: String?
    var turnCount: Int
    var model: String?
    var serviceTier: AgentServiceTier?
    var runtimeMode: AgentPermissionMode?
    var interactionMode: AgentInteractionMode?
    var activeTurnId: String?
    var activePlan: AssistantActivePlan?
    var pendingApprovalRequestIds: [String] = []
    var pendingUserInputRequestIds: [String] = []
    var claudeResumeSessionAt: String?
    var claudeInFlightToolIds: [String] = []
    var wireProtocolVersion: String?
    var updatedAtMs: Int64?
    /// Distill: the provider session that last accepted a prompt and the Main
    /// model that prompt ran. Written on acceptance (not from the pending
    /// upsert's requested `model`), so a failed or abandoned attempt cannot
    /// relabel the session's history.
    var distillSessionId: String?
    var distillSessionModel: String?
    /// Distill: sessions whose history the provider rejected. Survives restart
    /// so Retry opens a new session instead of loading the rejected one.
    var distillRetiredSessionIds: [String]?
    static let distillRetiredSessionLimit = 8

    private enum CodingKeys: String, CodingKey {
        case providerThreadId, lastCompletedTurnId, turnCount, model, serviceTier, runtimeMode, interactionMode, activeTurnId, activePlan, pendingApprovalRequestIds, pendingUserInputRequestIds, claudeResumeSessionAt, claudeInFlightToolIds, wireProtocolVersion, updatedAtMs, distillSessionId, distillSessionModel, distillRetiredSessionIds
    }

    init(turnCount: Int = 0) {
        self.turnCount = turnCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerThreadId = try container.decodeIfPresent(String.self, forKey: .providerThreadId)
        lastCompletedTurnId = try container.decodeIfPresent(String.self, forKey: .lastCompletedTurnId)
        turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount) ?? 0
        model = try container.decodeIfPresent(String.self, forKey: .model)
        serviceTier = try container.decodeIfPresent(AgentServiceTier.self, forKey: .serviceTier)
        runtimeMode = try container.decodeIfPresent(AgentPermissionMode.self, forKey: .runtimeMode)
        interactionMode = try container.decodeIfPresent(AgentInteractionMode.self, forKey: .interactionMode)
        activeTurnId = try container.decodeIfPresent(String.self, forKey: .activeTurnId)
        activePlan = try container.decodeIfPresent(AssistantActivePlan.self, forKey: .activePlan)
        pendingApprovalRequestIds = try container.decodeIfPresent([String].self, forKey: .pendingApprovalRequestIds) ?? []
        pendingUserInputRequestIds = try container.decodeIfPresent([String].self, forKey: .pendingUserInputRequestIds) ?? []
        claudeResumeSessionAt = try container.decodeIfPresent(String.self, forKey: .claudeResumeSessionAt)
        claudeInFlightToolIds = try container.decodeIfPresent([String].self, forKey: .claudeInFlightToolIds) ?? []
        wireProtocolVersion = try container.decodeIfPresent(String.self, forKey: .wireProtocolVersion)
        updatedAtMs = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMs)
        distillSessionId = try container.decodeIfPresent(String.self, forKey: .distillSessionId)
        distillSessionModel = try container.decodeIfPresent(String.self, forKey: .distillSessionModel)
        distillRetiredSessionIds = try container.decodeIfPresent([String].self, forKey: .distillRetiredSessionIds)
    }

    // PERF: turn lifecycle paths decode/encode this payload repeatedly (start,
    // stream status, terminal, recovery). JSONEncoder/JSONDecoder are not
    // thread-safe — share one pair under a short lock instead of allocating
    // per call. Output is default-formatted (same as prior per-call codecs).
    private static let codecLock = NSLock()
    private static let codecEncoder = JSONEncoder()
    private static let codecDecoder = JSONDecoder()

    static func decode(_ json: String?) -> ProviderSessionRuntimePayload {
        guard let json,
              let data = json.data(using: .utf8) else {
            return ProviderSessionRuntimePayload(turnCount: 0)
        }
        codecLock.lock()
        let payload = try? codecDecoder.decode(ProviderSessionRuntimePayload.self, from: data)
        codecLock.unlock()
        return payload ?? ProviderSessionRuntimePayload(turnCount: 0)
    }

    func encoded() -> String? {
        Self.codecLock.lock()
        let data = try? Self.codecEncoder.encode(self)
        Self.codecLock.unlock()
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Per-thread recursive mirror locks. Entries are kept for the coordinator's
/// lifetime (one small lock per thread touched), so a lock handed out is never
/// replaced while another caller may still hold it.
final class MirrorEventLockTable: @unchecked Sendable {
    private let guardLock = NSLock()
    private var locks: [AgentThreadID: NSRecursiveLock] = [:]

    func lock(for threadId: AgentThreadID) -> NSRecursiveLock {
        guardLock.lock()
        defer { guardLock.unlock() }
        if let existing = locks[threadId] { return existing }
        let created = NSRecursiveLock()
        locks[threadId] = created
        return created
    }
}
