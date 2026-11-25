import Foundation
import CoreModel
import Persistence

public protocol CodexAppServerControlling: AnyObject, Sendable {
    var terminationHandler: (@Sendable (Error) -> Void)? { get set }
    var forkProtocolSupport: CodexForkProtocolSupport { get }
    func initialize(clientName: String, clientTitle: String, clientVersion: String) async throws -> CodexAppServerInitializeResult
    func openThread(for request: AgentRunRequest) async throws -> CodexAppServerThreadOpenResult
    func startTurn(providerThreadId: String, for request: AgentRunRequest) async throws -> CodexAppServerClient.JSONObject
    func steerTurn(providerThreadId: String, expectedTurnId: String, for request: AgentRunRequest) async throws -> CodexAppServerClient.JSONObject
    func interruptTurn(providerThreadId: String, turnId: String) async throws
    func readThread(providerThreadId: String, includeTurns: Bool) async throws -> CodexAppServerClient.JSONObject
    func forkThread(providerThreadId: String, lastTurnId: String?) async throws -> String
    func forkThread(providerThreadId: String, lastTurnId: String?, threadSource: String) async throws -> CodexAppServerThreadSummary
    func listThreads(cursor: String?, archived: Bool) async throws -> CodexAppServerThreadPage
    func deleteThread(providerThreadId: String) async throws
    func rollbackThread(providerThreadId: String, beforeTurnId: String) async throws -> CodexAppServerClient.JSONObject
    func updateThreadSettings(providerThreadId: String, permissionMode: AgentPermissionMode) async throws
    func stop()
    func stopImmediatelyForAppTermination()
}

public extension CodexAppServerControlling {
    var forkProtocolSupport: CodexForkProtocolSupport { .unsupported }

    func steerTurn(providerThreadId: String, expectedTurnId: String, for request: AgentRunRequest) async throws -> CodexAppServerClient.JSONObject {
        throw AgentProviderAdapterError.unsupported("turn/steer")
    }

    func forkThread(providerThreadId: String, lastTurnId: String?, threadSource: String) async throws -> CodexAppServerThreadSummary {
        throw AgentProviderAdapterError.unsupported("Codex keyed fork RPC")
    }

    func listThreads(cursor: String?, archived: Bool) async throws -> CodexAppServerThreadPage {
        throw AgentProviderAdapterError.unsupported("Codex thread/list reconciliation RPC")
    }

    func deleteThread(providerThreadId: String) async throws {
        throw AgentProviderAdapterError.unsupported("Codex thread/delete compensation RPC")
    }

    func stopImmediatelyForAppTermination() {
        stop()
    }
}

extension CodexAppServerClient: CodexAppServerControlling {}

public enum CodexForkReconciliationError: Error, CustomStringConvertible {
    case markerConflictCleaned(marker: String, childIds: [String])
    case duplicateCleanupFailed(marker: String, details: String)
    case forkResponseMismatch(childId: String)
    case paginationCycle

    public var description: String {
        switch self {
        case .markerConflictCleaned(let marker, let childIds):
            return "Codex fork marker conflict was cleaned for \(marker): \(childIds.joined(separator: ", "))"
        case .duplicateCleanupFailed(let marker, let details):
            return "Codex fork marker cleanup failed for \(marker): \(details)"
        case .forkResponseMismatch(let childId):
            return "Codex fork response did not preserve parent/marker identity for \(childId)"
        case .paginationCycle:
            return "Codex thread/list repeated a cursor during fork reconciliation"
        }
    }
}

public final class CodexAppServerAdapter: AgentProviderAdapter, @unchecked Sendable {
    public let provider: AgentProvider = .codex

    public typealias ClientFactory = @Sendable (
        _ request: AgentRunRequest,
        _ notificationHandler: @escaping CodexAppServerClient.NotificationHandler,
        _ serverRequestHandler: @escaping CodexAppServerClient.ServerRequestHandler
    ) throws -> CodexAppServerControlling

    private struct Session {
        var runId: AgentRunID
        var client: CodexAppServerControlling
        var providerThreadId: String
        var activeTurnId: String?
        var threadStatusType: String?
        var pendingFinish: PendingFinish?
        /// Inactivity watchdog for a withheld finish (re-armed by live activity).
        /// No absolute wall-clock max — continuous thread/status or process output
        /// keeps the deferral alive; only true quiet flushes.
        var pendingFinishWatchdog: DispatchWorkItem?
        var status: AgentRunStatus
        var onEvent: (@Sendable (AgentRunEvent) -> Void)?
        var interactionMode: AgentInteractionMode
        var finalAssistantMessage: String
        // The assistant item the `finalAssistantMessage` buffer currently belongs
        // to. A turn can emit many assistant-message items (short preamble notes
        // before tool calls, then the actual answer); the final answer is the LAST
        // one, not the concatenation of every preamble. Tracking the item id lets
        // `appendFinalMessage` reset the buffer when a new item starts while still
        // accumulating multiple streamed deltas of the same item.
        var finalAssistantMessageItemId: String?
        var completedTurnIds: [String]
        var pendingApprovals: [String: PendingApproval]
        var pendingUserInputs: [String: PendingUserInput]
        var proposedPlanBuffers: [String: String]
        var emittedProposedPlanIds: Set<String>
        var startedItemIds: Set<String>
        var streamedItemIds: Set<String>
        var permissionMode: AgentPermissionMode
        /// Generation for the single active turn/read reconciliation loop so
        /// missing item/completed or turn/completed notifications cannot leave
        /// the coordinator owning a turn the server already considers finished.
        var turnReconcileGeneration: Int
        /// Shell-detached work the app-server does NOT track as an active thread:
        /// a command_execution item whose command backgrounds children with
        /// `&` / `nohup` / `setsid` / `disown`. When set at turn completion we
        /// prefix `[[RC_AWAITING]]` on the canonical final so the host's marker
        /// path surfaces awaiting + auto-nudge on both `.turnCompleted` and
        /// `.finished` — including the deferred PendingFinish release path.
        /// We still do NOT defer the terminal for detached work (Codex never
        /// auto-resumes shell-detached children; withholding would hang until
        /// thread status flips idle).
        ///
        /// Accepted false-positive: a turn that backgrounds a long-lived process
        /// as the deliverable (e.g. starts a dev server) is marked awaiting once;
        /// one bounded auto-nudge then clears the streak. Preferred over silently
        /// reporting orchestration threads as finished. Same class applies when
        /// a detached process already exited before turn end, or when the UI
        /// shows awaiting during an active-thread PendingFinish deferral.
        var sawDetachedShellSpawn: Bool
        /// Fresh destination created by recoverSession fallback; first sendTurn may seed.
        var pendingFreshFallbackSeed: Bool
        /// The app-server thread carries an active `/goal`. A goal loop ends each
        /// iteration with `thread/status idle` → `turn/completed` → `status active`
        /// → `turn/started`, all within the same second. That per-iteration
        /// `turn/completed` is NOT the end of the run: the finish is withheld until
        /// `thread/goal/cleared`, a non-active goal status, or an authoritative
        /// thread/read that shows no newer turn.
        var goalActive: Bool
        /// Fresh-fallback dest is not a durable resume identity until seeded startTurn is accepted.
        var awaitingSeedPublish: Bool
    }

    private struct OpenedClient {
        let client: CodexAppServerControlling
        let result: CodexAppServerThreadOpenResult
        let resumeFellBackToStart: Bool
    }

    private struct PendingFinish {
        let status: AgentRunStatus
        let finalMessage: String?
        let providerThreadId: String?
        let turnId: String?
        /// Wall-clock when the finish was withheld waiting for thread idle
        /// (forensics only; release is idle-driven, not absolute-max-driven).
        let deferredAt: Date
    }

    private struct PendingApproval {
        let continuation: CheckedContinuation<Any?, Error>
        let turnId: String?
        let itemId: String?
        let kind: AssistantRequestKind
        let responseKind: PendingApprovalResponseKind
        /// `nil` means the field was absent on the request; empty means Codex
        /// sent an authoritative empty allow-list (do not fall back to proposals).
        let availableDecisions: [Any]?
        let proposedExecpolicyAmendment: [String]
        let proposedNetworkPolicyAmendments: [[String: Any]]
    }

    private enum PendingApprovalResponseKind {
        case legacyDecision
        case permissions(requested: [String: Any])
    }

    private struct PendingUserInput {
        let continuation: CheckedContinuation<Any?, Error>
        let turnId: String?
        let itemId: String?
        let questionIds: [String]
        let questionPromptsById: [String: String]
        let multiSelectQuestionIds: Set<String>
        let responseKind: PendingUserInputResponseKind
    }

    private enum PendingUserInputResponseKind {
        case toolRequest
        case mcpElicitation(requestedSchema: [String: Any]?)
    }

    /// Server-to-client methods in the Codex 0.154.0 app-server schema. Keep the
    /// inventory explicit so a protocol upgrade cannot silently fall through as
    /// an unknown callback with no ownership decision.
    static let currentServerRequestMethods: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/tool/requestUserInput",
        "mcpServer/elicitation/request",
        "item/permissions/requestApproval",
        "item/tool/call",
        "account/chatgptAuthTokens/refresh",
        "attestation/generate",
        "currentTime/read",
        "applyPatchApproval",
        "execCommandApproval"
    ]

    private let binaryNameOverride: String?
    private let clientFactory: ClientFactory
    private let usesCustomClientFactory: Bool
    private let forkProtocolSupportOverride: CodexForkProtocolSupport?
    private let lock = NSLock()
    private var sessions: [AgentThreadID: Session] = [:]
    // QA-011: blocking-bridge timeouts are injectable so tests can drive the
    // typed `unsupported(... timed out)` path deterministically instead of
    // coupling to the production 10s / 30s wall-clock waits. `openTimeout`
    // covers recover/read/settings; `rollbackTimeout` the longer rollback.
    private let openTimeout: TimeInterval
    private let rollbackTimeout: TimeInterval
    /// Bounded resume retries after a desynchronized `thread/resume` timeout.
    private let threadResumeRetryPolicy: CodexThreadResumeRetryPolicy
    /// Quiet bound for a withheld `.finished` while the thread is still active.
    /// Fully re-armed by live notifications (status, process output, items).
    /// There is no absolute wall-clock max — only true quiet flushes so goals
    /// with continuous app-server activity can run long, while wedged deferrals
    /// still release (and unblock follow-up sends).
    private let pendingFinishInactivityTimeout: TimeInterval
    public var contextSeedReceipts: ConversationContextSeedReceiptRepository?
    private var appliedContextSeeds: Set<String> = []

    // Model-list cache (guarded by `lock`).
    private var cachedModels: [AgentModelDescriptor]? = nil
    private var modelCacheLastFetchedAt: Date? = nil
    private let modelCacheTTL: TimeInterval
    // Injectable for tests; production default calls CodexAppServerModelDiscovery.
    private let modelListDiscovery: @Sendable () async -> ModelListResult

    public init(binaryNameOverride: String? = nil,
                clientFactory: ClientFactory? = nil,
                openTimeout: TimeInterval = 10,
                rollbackTimeout: TimeInterval = 30,
                modelCacheTTL: TimeInterval = 300,
                modelListDiscovery: (@Sendable () async -> [AgentModelDescriptor])? = nil,
                forkProtocolSupportOverride: CodexForkProtocolSupport? = nil,
                threadResumeRetryPolicy: CodexThreadResumeRetryPolicy = .production,
                pendingFinishInactivityTimeout: TimeInterval = 900) {
        self.binaryNameOverride = binaryNameOverride
        self.usesCustomClientFactory = clientFactory != nil
        self.forkProtocolSupportOverride = forkProtocolSupportOverride
        self.openTimeout = openTimeout
        self.rollbackTimeout = rollbackTimeout
        self.threadResumeRetryPolicy = threadResumeRetryPolicy
        self.pendingFinishInactivityTimeout = max(0.01, pendingFinishInactivityTimeout)
        self.modelCacheTTL = modelCacheTTL
        if let modelListDiscovery {
            self.modelListDiscovery = {
                ModelListResult(models: await modelListDiscovery(), isFallback: false)
            }
        } else {
            let nameOverride = binaryNameOverride
            self.modelListDiscovery = {
                let binary = nameOverride ?? "codex"
                return await CodexAppServerModelDiscovery.listModelsResult(
                    binary: binary,
                    cwd: FileManager.default.currentDirectoryPath
                )
            }
        }
        self.clientFactory = clientFactory ?? { request, notificationHandler, serverRequestHandler in
            let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? request.providerBinary!
                : (binaryNameOverride ?? "codex")
            let isForeignUser = request.runAsUser.map { $0.uid != getuid() } == true
            let askpass = isForeignUser
                ? RunAsUserProcessBootstrap.materializeAskpass(
                    targetUser: request.runAsUser!.shortName
                )
                : nil
            return try CodexAppServerClient(
                binary: binary,
                arguments: CodexRunner.appServerArguments(environment: request.environment),
                cwd: request.cwd,
                environment: request.environment,
                runAsUser: request.runAsUser,
                askpassPath: askpass,
                notificationHandler: notificationHandler,
                serverRequestHandler: serverRequestHandler
            )
        }
    }

    public var forkSafety: AgentProviderForkSafety {
        safety(for: configuredForkProtocolSupport())
    }

    public func forkSafety(threadId: AgentThreadID) -> AgentProviderForkSafety {
        if let session = sessionSnapshot(threadId: threadId) {
            return safety(for: session.client.forkProtocolSupport)
        }
        return forkSafety
    }

    private func configuredForkProtocolSupport() -> CodexForkProtocolSupport {
        if let forkProtocolSupportOverride {
            return forkProtocolSupportOverride
        }
        guard !usesCustomClientFactory else { return .unsupported }
        return CodexForkProtocolSupport.probe(binary: binaryNameOverride ?? "codex")
    }

    private func safety(for support: CodexForkProtocolSupport) -> AgentProviderForkSafety {
        support.isSupported
            ? .keyedIdempotent(compensationSupported: true)
            : .unsupported
    }

    public func listModels() async -> [AgentModelDescriptor] {
        return await listModelsResult().models
    }

    /// Like `listModels()` but carries the fallback signal (mirrors
    /// `ClaudeRunner.listModelsResult`): `isFallback == true` means live
    /// app-server discovery did not produce a current catalog, so callers can
    /// surface "model list failed" instead of presenting fallback data as live.
    public func listModelsResult() async -> ModelListResult {
        return await resolvedModelsResult(forceRefresh: false)
    }

    /// Force the next `listModels()` call to bypass the TTL and re-fetch from
    /// the live Codex app-server. Call when the user explicitly refreshes the
    /// model picker. The method itself triggers one fetch immediately.
    public func refreshModels() async -> [AgentModelDescriptor] {
        return await refreshModelsResult().models
    }

    /// `refreshModels()` with the fallback signal, see `listModelsResult()`.
    public func refreshModelsResult() async -> ModelListResult {
        return await resolvedModelsResult(forceRefresh: true)
    }

    private func resolvedModelsResult(forceRefresh: Bool) async -> ModelListResult {
        let now = Date()
        // Read cached value under lock.
        lock.lock()
        let cached = cachedModels
        let lastFetched = modelCacheLastFetchedAt
        lock.unlock()

        let needsFetch = forceRefresh || ModelListTTLDecision.shouldRefetch(
            lastFetchedAt: lastFetched,
            ttl: modelCacheTTL,
            now: now
        )

        if !needsFetch, let cached {
            // The cache stores successful current harness-backed discovery.
            return ModelListResult(models: cached, isFallback: false)
        }

        // Attempt live discovery.
        let discovery = await modelListDiscovery()
        let discovered = discovery.models

        if !discovered.isEmpty {
            if !discovery.isFallback {
                lock.lock()
                cachedModels = discovered
                modelCacheLastFetchedAt = now
                lock.unlock()
            }
            return discovery
        }

        // Fallback: return the hardcoded list from CodexRunner (always non-empty),
        // flagged so callers do not present it as live discovery.
        let fallback = await CodexRunner(binaryNameOverride: binaryNameOverride).listModels()
        return ModelListResult(models: fallback, isFallback: true)
    }

    public func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    public func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        // RUN-LIFECYCLE-STREAM-003: refuse a second concurrent turn on a thread
        // that already has a turn in flight (mirrors the Claude adapters). A live
        // turn has a non-nil activeTurnId (cleared on completion), so a normal
        // follow-up turn is still allowed; only a true concurrent start is
        // rejected, instead of silently replacing the session via recordSession
        // and misrouting the prior turn's events.
        //
        // Wedged pendingFinish (idle missed, reconcile stuck) must not permanently
        // block send: flush the withheld finish first (Claude new_turn parity),
        // then re-evaluate in-flight. Still reject while the app-server reports
        // the thread active.
        flushPendingFinishIfStillDeferred(
            threadId: request.threadId,
            expectedTurnId: nil,
            reason: "new_turn",
            onlyIfThreadInactive: true
        )
        lock.lock()
        let session = sessions[request.threadId]
        let hasInFlightTurn = session?.status == .running
            || session?.activeTurnId != nil
            || session?.pendingFinish != nil
            || Self.isActiveThreadStatus(session?.threadStatusType)
        let reusableSession: (client: CodexAppServerControlling, providerThreadId: String)?
        if var existing = session, !hasInFlightTurn {
            existing.runId = request.runId
            existing.status = .running
            existing.onEvent = onEvent
            existing.interactionMode = request.interactionMode
            existing.permissionMode = request.permissionMode
            sessions[request.threadId] = existing
            reusableSession = (existing.client, existing.providerThreadId)
        } else {
            reusableSession = nil
        }
        lock.unlock()
        if hasInFlightTurn {
            if let session,
               let expectedTurnId = session.activeTurnId,
               !expectedTurnId.isEmpty {
                // Steer first. Rebinding runId/onEvent before turn/steer returns
                // leaves the original handle unable to cancel, and live events
                // hit the abandoned follow-up callback on steer failure.
                _ = try await session.client.steerTurn(
                    providerThreadId: session.providerThreadId,
                    expectedTurnId: expectedTurnId,
                    for: request
                )
                lock.lock()
                sessions[request.threadId]?.runId = request.runId
                sessions[request.threadId]?.onEvent = onEvent
                lock.unlock()
                onEvent(.status(.running))
                return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
                    self?.cancel(threadId: request.threadId, runId: request.runId)
                }
            }
            throw AgentProviderAdapterError.unsupported("Codex session already has an in-flight turn")
        }

        let client: CodexAppServerControlling
        let providerThreadId: String
        let resumeFellBackToStart: Bool
        if let reusableSession {
            client = reusableSession.client
            providerThreadId = reusableSession.providerThreadId
            resumeFellBackToStart = false
        } else {
            let opened = try await openClientAndThread(for: request, onEvent: onEvent)
            client = opened.client
            providerThreadId = opened.result.providerThreadId
            resumeFellBackToStart = opened.resumeFellBackToStart
            recordSession(
                threadId: request.threadId,
                runId: request.runId,
                client: client,
                providerThreadId: providerThreadId,
                interactionMode: request.interactionMode,
                onEvent: onEvent,
                permissionMode: request.permissionMode,
                awaitingSeedPublish: opened.resumeFellBackToStart
                    && request.contextSnapshot?.items.isEmpty == false
            )
        }
        installTerminationHandler(for: client, threadId: request.threadId)
        let pendingRecoverSeed = sessionSnapshot(threadId: request.threadId)?.pendingFreshFallbackSeed == true
        let shouldSeed = resumeFellBackToStart || pendingRecoverSeed
        let hasPriorContext = request.contextSnapshot?.items.isEmpty == false
        let delayDestinationPublish = shouldSeed && hasPriorContext
        onEvent(.status(.running))
        if !delayDestinationPublish {
            publishProviderDestination(
                providerThreadId,
                discloseResumeFallback: resumeFellBackToStart,
                onEvent: onEvent
            )
        }
        var turnRequest = request
        if shouldSeed {
            do {
                turnRequest = try await applyContextSeedIfEligible(
                    request: request,
                    destinationProviderThreadId: providerThreadId
                )
            } catch {
                if let failedSession = removeSession(threadId: request.threadId) {
                    settlePendingCallbacks(session: failedSession)
                    failedSession.client.stop()
                }
                throw error
            }
            clearPendingFreshFallbackSeed(threadId: request.threadId)
        }

        do {
            // turn/start returns the turn object immediately; turn/started is
            // the notification that the turn is actually running. Activate and
            // emit .turnStarted only from that notification so turn/steer cannot
            // race a turn that has not started.
            _ = try await client.startTurn(providerThreadId: providerThreadId, for: turnRequest)
            if shouldSeed {
                acknowledgeContextSeed(turnRequest, lifecycle: .delivered)
            }
            if delayDestinationPublish {
                clearAwaitingSeedPublish(threadId: request.threadId)
                publishProviderDestination(
                    providerThreadId,
                    discloseResumeFallback: resumeFellBackToStart,
                    onEvent: onEvent
                )
            }
        } catch {
            if shouldSeed {
                acknowledgeContextSeed(turnRequest, lifecycle: .notDelivered)
            }
            if let failedSession = removeSession(threadId: request.threadId) {
                settlePendingCallbacks(session: failedSession)
                failedSession.client.stop()
            }
            throw error
        }

        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            self?.cancel(threadId: request.threadId, runId: request.runId)
        }
    }

    public func interruptTurn(threadId: AgentThreadID) throws {
        guard let snapshot = sessionSnapshot(threadId: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard let turnId = snapshot.activeTurnId else { return }
        Task {
            try? await snapshot.client.interruptTurn(providerThreadId: snapshot.providerThreadId, turnId: turnId)
        }
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        guard let pending = removePendingApproval(threadId: threadId, requestId: requestId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        let state: AssistantRequestState
        switch response {
        case .approve, .approveForSession:
            state = .approved
        case .decline:
            state = .declined
        case .cancel:
            state = .cancelled
        }
        var payload: [String: Any] = ["requestId": requestId]
        if let turnId = pending.turnId { payload["turnId"] = turnId }
        if let itemId = pending.itemId { payload["itemId"] = itemId }
        let providerResponse: [String: Any]
        switch pending.responseKind {
        case .legacyDecision:
            let decision = Self.codexDecision(response, pending: pending)
            payload["decision"] = decision
            providerResponse = ["decision": decision]
        case .permissions(let requested):
            providerResponse = Self.permissionsApprovalResponse(requested: requested, response: response)
            payload.merge(providerResponse) { _, new in new }
        }
        emit([
            runtimeEvent(method: "item/requestApproval/decision", payload: payload),
            .requestResolved(requestId: requestId, state: state)
        ], threadId: threadId)
        pending.continuation.resume(returning: providerResponse)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        try respondToUserInput(threadId: threadId, requestId: requestId, verbatimText: text, outboundText: text)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, verbatimText: String, outboundText: String) throws {
        guard let pending = removePendingUserInput(threadId: threadId, requestId: requestId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        let providerResponse: [String: Any]
        switch pending.responseKind {
        case .toolRequest:
            providerResponse = ["answers": Self.codexAnswers(
                questionIds: pending.questionIds,
                questionPromptsById: pending.questionPromptsById,
                multiSelectQuestionIds: pending.multiSelectQuestionIds,
                text: verbatimText
            )]
        case .mcpElicitation(let requestedSchema):
            do {
                providerResponse = [
                    "action": "accept",
                    "content": try Self.mcpElicitationContent(
                        requestedSchema: requestedSchema,
                        questionIds: pending.questionIds,
                        text: verbatimText
                    )
                ]
            } catch {
                recordPendingUserInput(threadId: threadId, requestId: requestId, pending: pending)
                throw error
            }
        }
        var payload: [String: Any] = ["requestId": requestId]
        payload.merge(providerResponse) { _, new in new }
        if let turnId = pending.turnId { payload["turnId"] = turnId }
        if let itemId = pending.itemId { payload["itemId"] = itemId }
        emit([
            runtimeEvent(method: "item/tool/requestUserInput/answered", payload: payload),
            .userInputResolved(requestId: requestId, answer: verbatimText)
        ], threadId: threadId)
        pending.continuation.resume(returning: providerResponse)
    }

    public func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {
        guard let pending = removePendingUserInput(threadId: threadId, requestId: requestId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        let providerResponse: [String: Any]
        switch pending.responseKind {
        case .toolRequest:
            providerResponse = ["answers": [String: Any]()]
        case .mcpElicitation:
            providerResponse = ["action": "cancel"]
        }
        var payload: [String: Any] = ["requestId": requestId]
        payload.merge(providerResponse) { _, new in new }
        if let turnId = pending.turnId { payload["turnId"] = turnId }
        if let itemId = pending.itemId { payload["itemId"] = itemId }
        emit([
            runtimeEvent(method: "item/tool/requestUserInput/cancelled", payload: payload),
            .userInputResolved(requestId: requestId, answer: nil)
        ], threadId: threadId)
        // Codex's requestUserInput response has no dedicated cancel variant.
        // Empty answers resolve only this callback and leave the app-server
        // thread/session alive for the model to choose its next step.
        pending.continuation.resume(returning: providerResponse)
    }

    public func stopSession(threadId: AgentThreadID) throws {
        guard let session = removeSession(threadId: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        stop(session)
    }

    public func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported("Codex app-server recovery requires providerThreadId")
        }
        var openedClient: OpenedClient?
        do {
            let opened = try await openClientAndThread(for: request, onEvent: onEvent)
            openedClient = opened
            let activeTurnId = opened.resumeFellBackToStart
                ? nil
                : Self.recoveryActiveTurnId(from: request.extraArgs)
            recordSession(
                threadId: request.threadId,
                runId: request.runId,
                client: opened.client,
                providerThreadId: opened.result.providerThreadId,
                interactionMode: request.interactionMode,
                onEvent: onEvent,
                permissionMode: request.permissionMode,
                status: activeTurnId == nil ? .completed : .running,
                awaitingSeedPublish: opened.resumeFellBackToStart
            )
            if let activeTurnId {
                setActiveTurn(threadId: request.threadId, turnId: activeTurnId)
            }
            if opened.resumeFellBackToStart {
                markPendingFreshFallbackSeed(threadId: request.threadId)
                onEvent(.event(.error(message: "Previous session could not be resumed; starting a new session.", recoverable: true)))
            } else {
                onEvent(.event(.threadStarted(threadId: opened.result.providerThreadId, providerThreadId: opened.result.providerThreadId)))
            }
        } catch {
            openedClient?.client.stop()
            throw error
        }
    }

    public func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return sessions.map { threadId, session in
            AgentProviderSessionSummary(
                threadId: threadId,
                provider: .codex,
                status: session.status,
                providerThreadId: session.awaitingSeedPublish ? nil : session.providerThreadId
            )
        }
    }

    public func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId] != nil
    }

    public func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        guard let snapshot = sessionSnapshot(threadId: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        let response = try await snapshot.client.readThread(providerThreadId: snapshot.providerThreadId, includeTurns: true)
        mergeCompletedTurnIds(threadId: threadId, turnIds: Self.turnIds(fromThreadReadResponse: response))
        return Self.events(fromThreadReadResponse: response, providerThreadId: snapshot.providerThreadId)
    }

    public func forkThread(threadId: AgentThreadID) async throws -> String {
        throw AgentProviderAdapterError.unsupported(
            "unkeyed Codex fork is unsafe; use the durable AgentProviderForkRequest path"
        )
    }

    public func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
        guard let snapshot = sessionSnapshot(threadId: request.sourceThreadId) else {
            throw AgentProviderAdapterError.sessionNotFound(request.sourceThreadId)
        }
        guard await ProviderCLIProbe.runOffCooperativePool({ self.forkSafety(threadId: request.sourceThreadId) }).supportsDurableFork else {
            throw AgentProviderAdapterError.unsupported("Codex fork reconciliation schema is unavailable")
        }
        if let expectedSourceId = request.sourceProviderThreadId,
           !expectedSourceId.isEmpty,
           expectedSourceId != snapshot.providerThreadId {
            throw AgentProviderAdapterError.unsupported("Codex app-server recovered the wrong parent thread for fork")
        }
        if Self.isFailedUnforkableThreadStatus(snapshot.threadStatusType) {
            throw AgentProviderAdapterError.unsupported("Codex app-server cannot fork a thread in systemError")
        }
        guard snapshot.activeTurnId == nil,
              snapshot.pendingFinish == nil,
              !Self.isActiveThreadStatus(snapshot.threadStatusType) else {
            throw AgentProviderAdapterError.unsupported("Codex app-server cannot fork while the parent turn is active")
        }

        let existing = try await forkMarkerMatches(
            client: snapshot.client,
            marker: request.idempotencyKey
        )
        if !existing.isEmpty {
            let matchingParent = existing.filter { $0.forkedFromId == snapshot.providerThreadId }
            if existing.count == 1, let child = matchingParent.first {
                guard child.id != snapshot.providerThreadId else {
                    throw AgentProviderAdapterError.unsupported("Codex fork reconciliation returned the parent identity")
                }
                return child.id
            }
            try await cleanForkMarkerConflict(
                existing,
                marker: request.idempotencyKey,
                protectedThreadId: snapshot.providerThreadId,
                client: snapshot.client
            )
            throw CodexForkReconciliationError.markerConflictCleaned(
                marker: request.idempotencyKey,
                childIds: existing.map(\.id).sorted()
            )
        }

        let created = try await snapshot.client.forkThread(
            providerThreadId: snapshot.providerThreadId,
            lastTurnId: nil,
            threadSource: request.idempotencyKey
        )
        guard created.id != snapshot.providerThreadId,
              created.forkedFromId == snapshot.providerThreadId,
              created.threadSource == request.idempotencyKey else {
            guard created.id != snapshot.providerThreadId else {
                throw CodexForkReconciliationError.forkResponseMismatch(childId: created.id)
            }
            do {
                try await snapshot.client.deleteThread(providerThreadId: created.id)
            } catch {
                throw CodexForkReconciliationError.duplicateCleanupFailed(
                    marker: request.idempotencyKey,
                    details: "invalid child \(created.id) could not be deleted: \(error)"
                )
            }
            throw CodexForkReconciliationError.forkResponseMismatch(childId: created.id)
        }
        return created.id
    }

    public func compensateFork(
        _ request: AgentProviderForkRequest,
        providerChildThreadId: String
    ) async throws {
        let client: CodexAppServerControlling
        let ownsClient: Bool
        if let snapshot = sessionSnapshot(threadId: request.sourceThreadId) {
            client = snapshot.client
            ownsClient = false
        } else {
            let maintenanceRequest = AgentRunRequest(
                threadId: request.sourceThreadId,
                provider: .codex,
                model: "",
                cwd: request.workingDirectory ?? FileManager.default.currentDirectoryPath,
                prompt: ""
            )
            let maintenanceClient = try clientFactory(
                maintenanceRequest,
                { _, _ in },
                { _, method, _ in
                    throw AgentProviderAdapterError.unsupported(
                        "unexpected Codex maintenance callback during \(method)"
                    )
                }
            )
            do {
                _ = try await maintenanceClient.initialize(
                    clientName: "remotecode",
                    clientTitle: "RemoteCode",
                    clientVersion: "0.0.0"
                )
            } catch {
                maintenanceClient.stop()
                throw error
            }
            client = maintenanceClient
            ownsClient = true
        }
        defer {
            if ownsClient { client.stop() }
        }
        guard client.forkProtocolSupport.isSupported else {
            throw AgentProviderAdapterError.unsupported("Codex fork compensation schema is unavailable")
        }

        let matches = try await forkMarkerMatches(client: client, marker: request.idempotencyKey)
            .filter { $0.id != request.sourceProviderThreadId }
        guard !matches.isEmpty else {
            // Absence is the success state. This makes a retry after a lost
            // thread/delete response safe without depending on provider error text.
            return
        }
        let ordered = matches.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
        }
        do {
            for child in ordered {
                try await client.deleteThread(providerThreadId: child.id)
            }
        } catch {
            throw CodexForkReconciliationError.duplicateCleanupFailed(
                marker: request.idempotencyKey,
                details: "compensation for \(providerChildThreadId) failed: \(error)"
            )
        }
    }

    private func forkMarkerMatches(
        client: CodexAppServerControlling,
        marker: String
    ) async throws -> [CodexAppServerThreadSummary] {
        var matches: [String: CodexAppServerThreadSummary] = [:]
        for archived in [false, true] {
            var cursor: String?
            var seenCursors: Set<String> = []
            repeat {
                let page = try await client.listThreads(cursor: cursor, archived: archived)
                for thread in page.threads where thread.threadSource == marker {
                    matches[thread.id] = thread
                }
                guard let nextCursor = page.nextCursor, !nextCursor.isEmpty else {
                    cursor = nil
                    continue
                }
                guard seenCursors.insert(nextCursor).inserted else {
                    throw CodexForkReconciliationError.paginationCycle
                }
                cursor = nextCursor
            } while cursor != nil
        }
        return Array(matches.values)
    }

    private func cleanForkMarkerConflict(
        _ children: [CodexAppServerThreadSummary],
        marker: String,
        protectedThreadId: String,
        client: CodexAppServerControlling
    ) async throws {
        var failures: [String] = []
        for child in children.sorted(by: { $0.id < $1.id }) where child.id != protectedThreadId {
            do {
                try await client.deleteThread(providerThreadId: child.id)
            } catch {
                failures.append("\(child.id): \(error)")
            }
        }
        if !failures.isEmpty {
            throw CodexForkReconciliationError.duplicateCleanupFailed(
                marker: marker,
                details: failures.joined(separator: "; ")
            )
        }
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        guard var snapshot = sessionSnapshot(threadId: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        // Reuse the first lookup — only re-scan after the refresh read.
        var targetIndex = snapshot.completedTurnIds.firstIndex(of: toTurnId)
        if targetIndex == nil {
            _ = try? await readThread(threadId: threadId)
            if let refreshed = sessionSnapshot(threadId: threadId) {
                snapshot = refreshed
                targetIndex = snapshot.completedTurnIds.firstIndex(of: toTurnId)
            }
        }
        guard let targetIndex else {
            throw AgentProviderAdapterError.unsupported("Codex app-server rollback target is not in completed turn history: \(toTurnId)")
        }
        let dropIndex = snapshot.completedTurnIds.index(after: targetIndex)
        guard dropIndex < snapshot.completedTurnIds.endIndex else { return }
        let beforeTurnId = snapshot.completedTurnIds[dropIndex]
        let client = snapshot.client
        let providerThreadId = snapshot.providerThreadId
        _ = try await client.rollbackThread(providerThreadId: providerThreadId, beforeTurnId: beforeTurnId)
        _ = try await readThread(threadId: threadId)
    }

    public func stopAll() {
        lock.lock()
        let stoppedSessions = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        stoppedSessions.forEach { session in
            settlePendingCallbacks(session: session)
            session.client.stop()
        }
    }

    public func stopAllForAppTermination() {
        lock.lock()
        let stoppedSessions = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        stoppedSessions.forEach { session in
            settlePendingCallbacks(session: session)
            session.client.stopImmediatelyForAppTermination()
        }
    }

    public func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {
        guard var session = sessionSnapshot(threadId: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        session.onEvent = onEvent
        lock.lock()
        sessions[threadId] = session
        lock.unlock()
    }

    private func clientFor(request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws -> CodexAppServerControlling {
        try clientFactory(
            request,
            { [weak self] method, params in
                self?.handleNotification(method: method, params: params, threadId: request.threadId)
            },
            { [weak self] requestId, method, params in
                guard let self else {
                    throw AgentProviderAdapterError.unsupported("Codex app-server adapter was released")
                }
                return try await self.handleServerRequest(
                    requestId: requestId,
                    method: method,
                    params: params,
                    threadId: request.threadId
                )
            }
        )
    }

    private func openClientAndThread(
        for request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> OpenedClient {
        let wantsResume = request.providerThreadId?.isEmpty == false
        // Only spend the multi-attempt resume budget when we are actually
        // resuming. A cold start still uses a single attempt.
        let maxResumeAttempts = wantsResume ? threadResumeRetryPolicy.maxAttempts : 1
        var resumeTimeoutAttempts = 0
        var lastResumeTimeout: Error?

        for attempt in 1...maxResumeAttempts {
            try Task.checkCancellation()
            if attempt > 1 {
                let delay = threadResumeRetryPolicy.backoffNanoseconds(beforeAttempt: attempt)
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                }
                try Task.checkCancellation()
            }

            let client = try clientFor(request: request, onEvent: onEvent)
            installTerminationHandler(for: client, threadId: request.threadId)
            do {
                _ = try await client.initialize(clientName: "remotecode", clientTitle: "RemoteCode", clientVersion: "0.0.0")
                let opened = try await client.openThread(for: request)
                return OpenedClient(
                    client: client,
                    result: opened,
                    resumeFellBackToStart: opened.resumeFellBackToStart
                )
            } catch is CancellationError {
                client.stop()
                throw CancellationError()
            } catch {
                client.stop()
                // Dead peer: do not burn the slow-resume budget. Surface the
                // typed death error immediately so the run fails fast.
                if CodexAppServerClient.isDeadAppServerFailure(error) {
                    throw error
                }
                guard wantsResume,
                      CodexAppServerClient.requiresFreshClientAfterThreadResumeFailure(error) else {
                    throw error
                }
                // Timeout desynchronized this client. Retry resume on a fresh
                // peer — `thread/resume` is safe to re-issue (same thread id).
                resumeTimeoutAttempts += 1
                lastResumeTimeout = error
            }
        }

        // Resume retries exhausted: last chance is a fresh thread/start so a
        // slow-but-recoverable peer does not destroy the user turn entirely.
        guard wantsResume, lastResumeTimeout != nil else {
            throw lastResumeTimeout ?? CodexAppServerError.responseTypeMismatch
        }

        try Task.checkCancellation()
        let freshRequest = Self.requestStartingFreshThread(from: request)
        let replacement = try clientFor(request: freshRequest, onEvent: onEvent)
        installTerminationHandler(for: replacement, threadId: request.threadId)
        do {
            _ = try await replacement.initialize(clientName: "remotecode", clientTitle: "RemoteCode", clientVersion: "0.0.0")
            let opened = try await replacement.openThread(for: freshRequest)
            return OpenedClient(client: replacement, result: opened, resumeFellBackToStart: true)
        } catch is CancellationError {
            replacement.stop()
            throw CancellationError()
        } catch {
            replacement.stop()
            if CodexAppServerClient.isDeadAppServerFailure(error) {
                throw error
            }
            // Both bounded resume retries and the start-fresh fallback failed.
            // Prefer an actionable resume-budget error over a bare timeout.
            throw CodexAppServerError.threadResumeUnavailable(
                attempts: resumeTimeoutAttempts,
                elapsedBound: threadResumeRetryPolicy.elapsedBoundHint
            )
        }
    }

    private static func requestStartingFreshThread(from request: AgentRunRequest) -> AgentRunRequest {
        var fresh = AgentRunRequest(
            runId: request.runId,
            threadId: request.threadId,
            provider: request.provider,
            providerInstanceId: request.providerInstanceId,
            model: request.model,
            cwd: request.cwd,
            prompt: request.prompt,
            userMessageContent: request.userMessageContent,
            attachments: request.attachments,
            providerThreadId: nil,
            permissionMode: request.permissionMode,
            reasoningEffort: request.reasoningEffort,
            serviceTier: request.serviceTier,
            interactionMode: request.interactionMode,
            providerBinary: request.providerBinary,
            environment: request.environment,
            extraArgs: request.extraArgs,
            runAsUser: request.runAsUser
        )
        fresh.acceptancePermit = request.acceptancePermit
        fresh.contextSnapshot = request.contextSnapshot
        fresh.preparedContextSeed = request.preparedContextSeed
        return fresh
    }

    private func applyContextSeedIfEligible(
        request: AgentRunRequest,
        destinationProviderThreadId: String
    ) async throws -> AgentRunRequest {
        guard let snapshot = request.contextSnapshot, !snapshot.items.isEmpty else {
            return request
        }
        let key = ConversationContextSeedApplication.applicationKey(
            runId: request.runId.value.uuidString,
            destinationProviderThreadId: destinationProviderThreadId,
            snapshotDigest: snapshot.digest
        )
        lock.lock()
        let alreadyApplied = appliedContextSeeds.contains(key)
        lock.unlock()
        if alreadyApplied { return request }
        if (try? contextSeedReceipts?.hasDelivered(
            runId: request.runId.value.uuidString,
            destinationProviderThreadId: destinationProviderThreadId,
            snapshotDigest: snapshot.digest
        )) == true {
            return request
        }
        let preparer = ConversationContextSeedPreparer()
        guard let prepared = preparer.prepare(
            snapshot: snapshot,
            request: request,
            destinationProviderThreadId: destinationProviderThreadId
        ) else {
            throw AgentProviderAdapterError.unsupported(
                "Unable to prepare a context seed for the fresh Codex session."
            )
        }
        do {
            try contextSeedReceipts?.persistPending(prepared.receipts)
        } catch {
            throw error
        }
        lock.lock()
        appliedContextSeeds.insert(key)
        lock.unlock()
        var next = request
        next.preparedContextSeed = prepared
        return next
    }

    private func acknowledgeContextSeed(
        _ request: AgentRunRequest,
        lifecycle: ConversationContextSeedReceipt.Lifecycle
    ) {
        guard let seed = request.preparedContextSeed else { return }
        let acks = seed.receipts.map {
            ConversationContextSeedAck(
                runId: $0.runId,
                destinationProviderThreadId: $0.destinationProviderThreadId,
                snapshotDigest: $0.snapshotDigest,
                sourceMessageId: $0.sourceMessageId,
                ordinal: $0.ordinal,
                lifecycle: lifecycle
            )
        }
        try? contextSeedReceipts?.acknowledge(acks)
        if lifecycle != .delivered, let dest = seed.receipts.first?.destinationProviderThreadId {
            let key = ConversationContextSeedApplication.applicationKey(
                runId: request.runId.value.uuidString,
                destinationProviderThreadId: dest,
                snapshotDigest: seed.document.snapshotDigest
            )
            lock.lock()
            appliedContextSeeds.remove(key)
            lock.unlock()
        }
    }

    private func markPendingFreshFallbackSeed(threadId: AgentThreadID) {
        lock.lock()
        sessions[threadId]?.pendingFreshFallbackSeed = true
        lock.unlock()
    }

    private func clearPendingFreshFallbackSeed(threadId: AgentThreadID) {
        lock.lock()
        sessions[threadId]?.pendingFreshFallbackSeed = false
        lock.unlock()
    }

    private func clearAwaitingSeedPublish(threadId: AgentThreadID) {
        lock.lock()
        sessions[threadId]?.awaitingSeedPublish = false
        lock.unlock()
    }

    private func isAwaitingSeedPublish(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.awaitingSeedPublish == true
    }

    private func publishedDestination(_ session: Session) -> String? {
        session.awaitingSeedPublish ? nil : session.providerThreadId
    }

    private func publishedDestination(threadId: AgentThreadID) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let session = sessions[threadId] else { return nil }
        return publishedDestination(session)
    }

    private func publishedDestination(_ providerThreadId: String?, threadId: AgentThreadID) -> String? {
        isAwaitingSeedPublish(threadId: threadId) ? nil : providerThreadId
    }

    private func publishProviderDestination(
        _ providerThreadId: String,
        discloseResumeFallback: Bool,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) {
        onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
        if discloseResumeFallback {
            onEvent(.event(.error(message: "Previous session could not be resumed; starting a new session.", recoverable: true)))
        }
    }

    private func handleServerRequest(
        requestId: String,
        method: String,
        params: Any?,
        threadId: AgentThreadID
    ) async throws -> Any? {
        let payload = params as? [String: Any] ?? [:]
        switch method {
        case "item/commandExecution/requestApproval", "item.commandExecution.requestApproval":
            return try await awaitApproval(
                requestId: requestId,
                method: method,
                payload: payload,
                threadId: threadId,
                kind: .commandExecution
            )
        case "item/fileRead/requestApproval", "item.fileRead.requestApproval":
            return try await awaitApproval(
                requestId: requestId,
                method: method,
                payload: payload,
                threadId: threadId,
                kind: .fileRead
            )
        case "item/fileChange/requestApproval", "item.fileChange.requestApproval":
            return try await awaitApproval(
                requestId: requestId,
                method: method,
                payload: payload,
                threadId: threadId,
                kind: .fileChange
            )
        case "item/permissions/requestApproval", "item.permissions.requestApproval":
            return try await awaitApproval(
                requestId: requestId,
                method: method,
                payload: payload,
                threadId: threadId,
                kind: .dynamic
            )
        case "applyPatchApproval":
            return try await awaitApproval(
                requestId: requestId,
                method: method,
                payload: payload,
                threadId: threadId,
                kind: .applyPatch
            )
        case "execCommandApproval":
            return try await awaitApproval(
                requestId: requestId,
                method: method,
                payload: payload,
                threadId: threadId,
                kind: .exec
            )
        case "item/tool/requestUserInput", "item.tool.requestUserInput", "mcpServer/elicitation/request":
            return try await awaitUserInput(
                requestId: requestId,
                method: method,
                payload: payload,
                threadId: threadId
            )
        case "item/tool/call", "account/chatgptAuthTokens/refresh", "attestation/generate":
            emit([runtimeEvent(method: method, payload: payload)], threadId: threadId)
            throw AgentProviderAdapterError.unsupported("Recognized Codex app-server request is not supported by this client: \(method)")
        case "currentTime/read":
            // Codex 0.150 restored this client-owned clock callback. Whole Unix
            // seconds; throwing unsupported fails the tool/turn that asked.
            return ["currentTimeAt": Int64(Date().timeIntervalSince1970)]
        default:
            emit([runtimeEvent(method: method, payload: payload)], threadId: threadId)
            throw AgentProviderAdapterError.unsupported("Unhandled Codex app-server request: \(method)")
        }
    }

    private func awaitApproval(
        requestId: String,
        method: String,
        payload: [String: Any],
        threadId: AgentThreadID,
        kind: AssistantRequestKind
    ) async throws -> Any? {
        let isPermissionsRequest = method == "item/permissions/requestApproval"
            || method == "item.permissions.requestApproval"
        let requestedPermissions = payload["permissions"] as? [String: Any]
        if isPermissionsRequest, requestedPermissions == nil {
            throw AgentProviderAdapterError.unsupported(
                "Codex permissions request omitted its required permission profile"
            )
        }
        if sessionPermissionMode(threadId: threadId) == .fullAccess {
            emit([runtimeEvent(method: method, payload: payload)], threadId: threadId)
            if isPermissionsRequest, let requestedPermissions {
                return ["permissions": requestedPermissions, "scope": "session"]
            }
            // Session auto-approve must use the method's decision dialect
            // (accept* vs ReviewDecision) or Codex 0.146 rejects the response.
            return ["decision": Self.sessionAutoApproveDecision(for: kind)]
        }
        // Key by the JSON-RPC request id so serverRequest/resolved can settle
        // the card when Codex clears it (interrupt / next turn / turn complete).
        let turnId = string(payload, "turnId")
            ?? string(payload, "turn_id")
            ?? Self.nestedString(payload, objectKey: "turn", field: "id")
            ?? activeTurnId(threadId: threadId)
        let itemId = string(payload, "itemId")
            ?? string(payload, "item_id")
            ?? Self.nestedString(payload, objectKey: "item", field: "id")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            recordPendingApproval(threadId: threadId, requestId: requestId, pending: PendingApproval(
                continuation: continuation,
                turnId: turnId,
                itemId: itemId,
                kind: kind,
                responseKind: isPermissionsRequest
                    ? .permissions(requested: requestedPermissions ?? [:])
                    : .legacyDecision,
                availableDecisions: Self.payloadOptionalMixedArray(
                    payload, camel: "availableDecisions", snake: "available_decisions"
                ),
                proposedExecpolicyAmendment: Self.payloadStringArray(
                    payload, camel: "proposedExecpolicyAmendment", snake: "proposed_execpolicy_amendment"
                ),
                proposedNetworkPolicyAmendments: Self.payloadObjectArray(
                    payload, camel: "proposedNetworkPolicyAmendments", snake: "proposed_network_policy_amendments"
                )
            ))
            emit([
                runtimeEvent(method: method, payload: payload),
                .requestOpened(AssistantPendingRequest(
                    id: requestId,
                    turnId: turnId,
                    kind: kind,
                    title: Self.approvalTitle(for: kind),
                    detail: Self.approvalDetailString(from: payload),
                    createdAtMs: now
                ))
            ], threadId: threadId)
        }
    }

    private func awaitUserInput(
        requestId: String,
        method: String,
        payload: [String: Any],
        threadId: AgentThreadID
    ) async throws -> Any? {
        let isMcpElicitation = method == "mcpServer/elicitation/request"
        let requestedSchema = payload["requestedSchema"] as? [String: Any]
        let turnId = string(payload, "turnId")
            ?? string(payload, "turn_id")
            ?? Self.nestedString(payload, objectKey: "turn", field: "id")
            ?? activeTurnId(threadId: threadId)
        let itemId = string(payload, "itemId")
            ?? string(payload, "item_id")
            ?? Self.nestedString(payload, objectKey: "item", field: "id")
        let questions = isMcpElicitation
            ? Self.mcpElicitationQuestions(from: requestedSchema)
            : Self.userInputQuestions(from: payload)
        let structuredQuestions = Self.structuredUserInputQuestions(from: questions)
        let questionIds = questions.compactMap { string($0, "id") }
        let effectiveQuestionIds = questionIds.isEmpty ? [requestId] : questionIds
        let prompt = isMcpElicitation
            ? (string(payload, "message") ?? Self.userInputPrompt(from: questions))
            : Self.userInputPrompt(from: questions)
        let options = Self.userInputOptions(from: questions)
        let allowsMultipleSelection = Self.userInputAllowsMultipleSelection(payload: payload, questions: questions)
        let isSecret = Self.userInputIsSecret(questions)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            recordPendingUserInput(threadId: threadId, requestId: requestId, pending: PendingUserInput(
                continuation: continuation,
                turnId: turnId,
                itemId: itemId,
                questionIds: effectiveQuestionIds,
                questionPromptsById: Dictionary(questions.compactMap { question in
                    guard let id = string(question, "id"), let prompt = string(question, "question") else { return nil }
                    return (id, prompt)
                }, uniquingKeysWith: { first, _ in first }),
                multiSelectQuestionIds: Self.userInputMultiSelectQuestionIds(
                    questions: questions,
                    fallbackQuestionIds: effectiveQuestionIds,
                    aggregateAllowsMultipleSelection: allowsMultipleSelection
                ),
                responseKind: isMcpElicitation
                    ? .mcpElicitation(requestedSchema: requestedSchema)
                    : .toolRequest
            ))
            emit([
                runtimeEvent(method: method, payload: payload),
                .userInputRequested(AssistantUserInputRequest(
                    id: requestId,
                    turnId: turnId,
                    prompt: prompt,
                    options: options,
                    allowsMultipleSelection: allowsMultipleSelection,
                    isSecret: isSecret,
                    questions: structuredQuestions,
                    createdAtMs: now
                ))
            ], threadId: threadId)
        }
    }

    /// Token-rate app-server methods already become `itemDelta` / `itemProgress`.
    /// Prepending `providerRuntime` used to `JSONSerialization.data(.sortedKeys)`
    /// the full payload, persist a second stream row + provider log, and EventBus-
    /// persist `agent.provider_runtime.event` on the delivery queue (~30 Hz).
    /// Grok ACP already omits runtime events on `agent_message_chunk`.
    static func shouldEmitProviderRuntime(for method: String) -> Bool {
        !isHighFrequencyStreamingMethod(method)
    }

    static func isHighFrequencyStreamingMethod(_ method: String) -> Bool {
        if method.hasSuffix("/delta") || method.hasSuffix(".delta") { return true }
        if method.contains("Delta") { return true }
        if method.hasSuffix("/progress") || method.hasSuffix(".progress") { return true }
        if method.contains("terminalInteraction") { return true }
        if method.contains("summaryPartAdded") { return true }
        if method.contains("patchUpdated") { return true }
        return false
    }

    private func handleNotification(method: String, params: Any?, threadId: AgentThreadID) {
        let payload = params as? [String: Any] ?? [:]
        let notificationProviderThreadId = string(payload, "threadId")
            ?? (payload["thread"] as? [String: Any]).flatMap { string($0, "id") }
        if let notificationProviderThreadId,
           let sessionProviderThreadId = providerThreadId(threadId: threadId),
           notificationProviderThreadId != sessionProviderThreadId {
            // A provider-native fork is announced on the parent's app-server
            // transport. Do not route child lifecycle events through the parent
            // local session; that would corrupt its identity or leave it active.
            return
        }
        var events: [AssistantEvent] = []
        if Self.shouldEmitProviderRuntime(for: method) {
            events.append(runtimeEvent(method: method, payload: payload))
        }
        var finished: AgentRunEvent?
        var dropProviderHandle = false
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func appendCompletedTool(summary: String, output: String?) {
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "\(summary.lowercased().replacingOccurrences(of: " ", with: "-"))-\(UUID().uuidString)"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: summary,
                output: output?.nilIfEmpty,
                startedAtMs: now,
                finishedAtMs: now
            )))
        }
        switch method {
        case "thread/started":
            if let providerThreadId = string(payload, "threadId") ?? (payload["thread"] as? [String: Any]).flatMap({ string($0, "id") }),
               !isAwaitingSeedPublish(threadId: threadId) {
                events.append(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId))
            }
        case "error":
            let error = payload["error"] as? [String: Any] ?? payload
            let message = string(error, "message") ?? string(payload, "message") ?? Self.jsonString(error) ?? "Codex error"
            let details = string(error, "additionalDetails") ?? string(error, "additional_details")
            let full = [message, details].compactMap { $0?.nilIfEmpty }.joined(separator: "\n")
            let willRetry = (payload["willRetry"] as? Bool) == true
            events.append(.error(message: full.nilIfEmpty ?? "Codex error", recoverable: willRetry))
            if let outcome = Self.classifyFatalOutcome(eventKind: "error", willRetry: willRetry, errorCode: Self.errorCode(from: payload, error: error)) {
                finished = Self.failedEvent(for: outcome, message: full.nilIfEmpty ?? "Codex error", providerThreadId: publishedDestination(threadId: threadId))
                markFinished(threadId: threadId, status: .failed, turnId: activeTurnId(threadId: threadId))
            }
        case "thread/status/changed", "thread.status.changed":
            let statusType = Self.threadStatusType(from: payload)
            let pending = statusType.flatMap { updateThreadStatus(threadId: threadId, statusType: $0) }
            let turnId = pending?.turnId ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = "thread-status-\(string(payload, "threadId") ?? providerThreadId(threadId: threadId) ?? threadId.value.uuidString)"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: "Thread status changed",
                output: Self.threadStatusDetail(from: payload),
                startedAtMs: now,
                finishedAtMs: now
            )))
            if let pending {
                finished = .finished(pending.status, finalMessage: pending.finalMessage, providerThreadId: publishedDestination(pending.providerThreadId, threadId: threadId))
                markFinished(threadId: threadId, status: pending.status, turnId: pending.turnId)
            }
        case "turn/started":
            if let turnId = string(payload, "turnId") ?? (payload["turn"] as? [String: Any]).flatMap({ string($0, "id") }) {
                dropPendingFinishForContinuingGoal(threadId: threadId, newTurnId: turnId)
                setActiveTurn(threadId: threadId, turnId: turnId)
                events.append(.turnStarted(turnId: turnId))
            }
        case "hook/started", "hook.started", "hook/completed", "hook.completed":
            // openai/codex HookStarted/CompletedNotification nests HookRunSummary under `run`
            // (camelCase wire). Keep legacy flat / hook / summary fallbacks for tests and older peers.
            let hook = payload["run"] as? [String: Any]
                ?? payload["hook"] as? [String: Any]
                ?? payload["summary"] as? [String: Any]
                ?? payload
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = string(hook, "id")
                ?? string(payload, "hookRunId")
                ?? string(payload, "hook_run_id")
                ?? "hook-\(UUID().uuidString)"
            let completed = method.contains("completed")
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: completed ? Self.itemState(for: string(hook, "status")) : .streaming,
                summary: completed ? "Hook completed" : "Hook started",
                output: Self.hookDetail(from: hook),
                startedAtMs: now,
                finishedAtMs: completed ? now : nil
            )))
        case "item/started", "item.started":
            let item = (payload["item"] as? [String: Any]) ?? payload
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = string(item, "id") ?? string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            let rawType = string(item, "type") ?? string(payload, "type") ?? "unknown"
            if Self.isUserMessageItem(item, type: rawType) { break }
            if markStartedItem(threadId: threadId, turnId: turnId, itemId: itemId) {
                events.append(.itemStarted(item: AssistantItem(
                    id: itemId,
                    turnId: turnId,
                    type: Self.assistantItemType(for: rawType),
                    state: .streaming,
                    summary: Self.summary(for: item, type: rawType),
                    startedAtMs: now
                )))
            }
            if Self.assistantItemType(for: rawType) == .commandExecution {
                trackDetachedShellSpawn(in: item, threadId: threadId)
                scheduleTurnReconciliation(threadId: threadId, turnId: turnId)
            }
            appendFileTouches(from: item, itemId: itemId, now: now, to: &events)
        case "item/autoApprovalReview/started", "item.autoApprovalReview.started", "item/autoApprovalReview/completed", "item.autoApprovalReview.completed":
            let review = payload["review"] as? [String: Any] ?? payload["autoApprovalReview"] as? [String: Any] ?? payload
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            // Upstream ItemGuardianApprovalReview*Notification uses reviewId + optional targetItemId
            // (camelCase). Prefer those before inventing a UUID so start/complete share one item id.
            let itemId = string(payload, "itemId")
                ?? string(payload, "item_id")
                ?? string(payload, "reviewId")
                ?? string(payload, "review_id")
                ?? string(payload, "targetItemId")
                ?? string(payload, "target_item_id")
                ?? string(review, "id")
                ?? "auto-approval-\(UUID().uuidString)"
            let completed = method.contains("completed")
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .review,
                state: completed ? Self.itemState(for: string(review, "status")) : .streaming,
                summary: "Auto approval review",
                output: Self.approvalReviewDetail(from: review),
                startedAtMs: now,
                finishedAtMs: completed ? now : nil
            )))
        case "item/completed", "item.completed":
            let item = (payload["item"] as? [String: Any]) ?? payload
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = string(item, "id") ?? string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            let rawType = string(item, "type") ?? string(payload, "type") ?? "unknown"
            if Self.isUserMessageItem(item, type: rawType) { break }
            let itemType = Self.assistantItemType(for: rawType)
            if itemType == .commandExecution {
                // Command text may only arrive on completed (started can omit it).
                trackDetachedShellSpawn(in: item, threadId: threadId)
            }
            let summary = Self.summary(for: item, type: rawType)
            if rawType == "plan",
               let body = Self.body(for: item, type: rawType),
               let markdown = Self.proposedPlanMarkdown(in: body) ?? body.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
               markProposedPlanEmitted(threadId: threadId, planId: itemId) {
                events.append(.proposedPlan(AssistantProposedPlan(id: itemId, turnId: turnId.isEmpty ? nil : turnId, markdown: markdown)))
            }
            if itemType == .contextCompaction {
                events.append(.itemStarted(item: AssistantItem(
                    id: itemId,
                    turnId: turnId,
                    type: .contextCompaction,
                    state: .completed,
                    summary: summary,
                    startedAtMs: now,
                    finishedAtMs: now
                )))
                events.append(.contextCompaction(summary: summary))
            } else if Self.isRawResponseItemType(rawType) {
                if markStartedItem(threadId: threadId, turnId: turnId, itemId: itemId) {
                    events.append(.itemStarted(item: AssistantItem(
                        id: itemId,
                        turnId: turnId,
                        type: itemType,
                        state: .completed,
                        summary: summary,
                        startedAtMs: now,
                        finishedAtMs: now
                    )))
                }
            }
            let alreadyStreamed = hasStreamedItem(threadId: threadId, turnId: turnId, itemId: itemId)
            if let body = Self.body(for: item, type: rawType), !body.isEmpty,
               itemType != .assistantMessage || !alreadyStreamed {
                if itemType == .assistantMessage {
                    appendFinalMessage(threadId: threadId, itemId: itemId, delta: body)
                }
                events.append(.itemDelta(
                    itemId: itemId,
                    bodyAppend: itemType == .assistantMessage ? body : nil,
                    outputAppend: itemType == .assistantMessage ? nil : body,
                    summary: summary
                ))
            }
            appendFileTouches(from: item, itemId: itemId, now: now, to: &events)
            events.append(.itemCompleted(itemId: itemId, finalState: Self.itemState(for: string(item, "status"))))
            // Codex can complete a final_answer item without ever emitting
            // turn/completed. Arm a single thread/read reconcile loop so the run
            // only finishes when the server authoritatively reports the turn idle.
            if Self.isFinalAnswerPhaseItem(item, type: rawType) {
                scheduleTurnReconciliation(threadId: threadId, turnId: turnId)
            }
        case "item/agentMessage/delta", "item.agentMessage.delta":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            ensureAssistantItem(threadId: threadId, turnId: turnId, itemId: itemId, now: now, events: &events)
            let delta = string(payload, "delta") ?? string(payload, "text") ?? ""
            appendFinalMessage(threadId: threadId, itemId: itemId, delta: delta)
            markStreamedItem(threadId: threadId, turnId: turnId, itemId: itemId)
            events.append(.itemDelta(itemId: itemId, bodyAppend: delta, outputAppend: nil, summary: nil))
        case "command/exec/outputDelta", "command.exec.outputDelta":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? string(payload, "commandId") ?? string(payload, "command_id") ?? "command-exec-\(UUID().uuidString)"
            let delta = string(payload, "delta") ?? string(payload, "text") ?? string(payload, "output") ?? Self.decodedBase64String(payload["deltaBase64"]) ?? ""
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: delta, summary: "Command output"))
        case "process/outputDelta", "process.outputDelta":
            let itemId = string(payload, "processHandle") ?? string(payload, "process_handle") ?? "process-\(UUID().uuidString)"
            let stream = string(payload, "stream") ?? "output"
            let delta = string(payload, "delta") ?? string(payload, "text") ?? Self.decodedBase64String(payload["deltaBase64"]) ?? ""
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: delta, summary: "Process \(stream)"))
        case "process/exited", "process.exited":
            let itemId = string(payload, "processHandle") ?? string(payload, "process_handle") ?? "process-\(UUID().uuidString)"
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let exitCode = Self.int(payload["exitCode"]) ?? Self.int(payload["exit_code"]) ?? 0
            let output = [string(payload, "stdout"), string(payload, "stderr")].compactMap { $0?.nilIfEmpty }.joined(separator: "\n")
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .commandExecution,
                state: exitCode == 0 ? .completed : .failed,
                summary: "Process exited \(exitCode)",
                output: output.nilIfEmpty,
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "item/commandExecution/outputDelta", "item/commandExecution/terminalInteraction":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            let delta = string(payload, "delta") ?? string(payload, "text") ?? string(payload, "output") ?? Self.jsonString(payload["interaction"]) ?? ""
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: delta, summary: "Command output"))
        case "item/fileChange/outputDelta", "item/fileChange/patchUpdated":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            let delta = string(payload, "delta") ?? string(payload, "text") ?? string(payload, "patch") ?? Self.jsonString(payload["changes"]) ?? ""
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: delta, summary: "File change"))
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .reasoning, state: .streaming, summary: "Reasoning", startedAtMs: now)))
            let delta = string(payload, "delta") ?? string(payload, "text") ?? Self.jsonString(payload["summary"]) ?? ""
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: delta, summary: "Reasoning"))
        case "item/mcpToolCall/progress":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            events.append(.itemProgress(itemId: itemId, progress: Self.double(payload["progress"]) ?? Self.double(payload["percent"])))
        case "item/plan/delta", "turn.proposed.delta", "turn/proposed/delta":
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? "plan-\(turnId)"
            let delta = string(payload, "delta") ?? string(payload, "text") ?? ""
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .plan, state: .streaming, summary: "Plan", startedAtMs: now)))
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: delta, summary: "Plan"))
            let buffered = appendProposedPlanDelta(threadId: threadId, planId: itemId, delta: delta)
            if let markdown = Self.proposedPlanMarkdown(in: buffered),
               markProposedPlanEmitted(threadId: threadId, planId: itemId) {
                events.append(.proposedPlan(AssistantProposedPlan(id: itemId, turnId: turnId.isEmpty ? nil : turnId, markdown: markdown)))
            }
        case "turn.proposed.completed", "turn/proposed/completed":
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let planId = string(payload, "planId") ?? string(payload, "plan_id") ?? "plan-\(turnId)"
            let buffered = proposedPlanBuffer(threadId: threadId, planId: planId)
            if let markdown = Self.proposedPlanMarkdown(from: payload, fallback: buffered),
               markProposedPlanEmitted(threadId: threadId, planId: planId) {
                events.append(.proposedPlan(AssistantProposedPlan(id: planId, turnId: turnId.isEmpty ? nil : turnId, markdown: markdown)))
            }
        case "turn/plan/updated", "turn.plan.updated":
            if let plan = Self.activePlan(from: payload, now: now) {
                events.append(.activePlanUpdated(plan))
            }
        case "thread/goal/updated", "thread.goal.updated":
            setGoalActive(threadId: threadId, Self.isNonTerminalGoalStatus(from: payload))
            let turnId = goalTurnId(threadId: threadId)
            let itemId = "goal-\(string(payload, "threadId") ?? providerThreadId(threadId: threadId) ?? threadId.value.uuidString)-\(turnId.isEmpty ? String(now) : turnId)"
            let detail = Self.goalDetail(from: payload)
            // The app-server re-sends the FULL goal state on every update, so the
            // detail rides in itemStarted's `output` (mirroring thread/status/changed):
            // the reducer's itemStarted merge then REPLACES the stale detail. An
            // outputAppend delta would glue consecutive state snapshots together.
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: "Goal updated",
                output: detail,
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "thread/goal/cleared", "thread.goal.cleared":
            setGoalActive(threadId: threadId, false)
            let turnId = goalTurnId(threadId: threadId)
            let itemId = "goal-cleared-\(string(payload, "threadId") ?? providerThreadId(threadId: threadId) ?? threadId.value.uuidString)-\(turnId.isEmpty ? String(now) : turnId)"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: "Goal cleared",
                output: "Goal cleared",
                startedAtMs: now,
                finishedAtMs: now
            )))
            // The goal loop is over; a finish withheld at the last iteration's
            // turn/completed is released now instead of waiting for reconcile.
            if let pending = takePendingFinish(threadId: threadId) {
                finished = .finished(pending.status, finalMessage: pending.finalMessage, providerThreadId: publishedDestination(pending.providerThreadId, threadId: threadId))
                markFinished(threadId: threadId, status: pending.status, turnId: pending.turnId)
            }
        case "turn/diff/updated", "turn.diff.updated":
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = "turn-diff-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let diff = string(payload, "diff") ?? Self.jsonString(payload["changes"]) ?? ""
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .fileChange,
                state: .completed,
                summary: "Turn diff updated",
                startedAtMs: now,
                finishedAtMs: now
            )))
            if !diff.isEmpty {
                events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: diff, summary: "Turn diff updated"))
            }
        case "serverRequest/resolved", "serverRequest.resolved":
            // Codex clears unanswered server→client requests with the JSON-RPC
            // request id (string or int64). Settle the pending card/continuation;
            // do not leave Agent App spinning after interrupt / next turn.
            if let requestId = Self.wireRequestId(from: payload["requestId"] ?? payload["request_id"]) {
                let settled = settlePendingRequest(threadId: threadId, requestId: requestId)
                    || settlePendingUserInput(threadId: threadId, requestId: requestId)
                if !settled {
                    events.append(.requestResolved(requestId: requestId, state: .resolved))
                }
            }
        case "thread/tokenUsage/updated", "thread.token-usage.updated":
            if let usage = Self.tokenUsage(from: payload) {
                events.append(.tokenUsage(usage))
            }
        case "thread/compacted", "thread.compacted", "thread.state.changed":
            let state = string(payload, "state")
            if method != "thread.state.changed" || state == "compacted" {
                let summary = string(payload, "summary") ?? string(payload, "detail") ?? "Context compacted"
                let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
                let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? "context-compaction-\(turnId.isEmpty ? UUID().uuidString : turnId)"
                events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .contextCompaction, state: .completed, summary: summary, startedAtMs: now, finishedAtMs: now)))
                events.append(.contextCompaction(summary: summary))
            }
        case "warning", "guardianWarning":
            let message = string(payload, "message") ?? string(payload, "summary") ?? Self.jsonString(payload) ?? "Codex warning"
            appendCompletedTool(summary: method == "guardianWarning" ? "Codex guardian warning" : "Codex warning", output: message)
        case "configWarning", "deprecationNotice":
            let summary = string(payload, "summary") ?? (method == "configWarning" ? "Codex config warning" : "Codex deprecation notice")
            let details = string(payload, "details") ?? string(payload, "path")
            appendCompletedTool(summary: summary, output: details)
        case "account/updated", "account.updated":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "account-updated-\(UUID().uuidString)"
            let detail = [
                string(payload, "authMode").map { "Auth: \($0)" },
                string(payload, "planType").map { "Plan: \($0)" }
            ].compactMap { $0 }.joined(separator: "\n")
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .completed, summary: "Account updated", output: detail.nilIfEmpty, startedAtMs: now, finishedAtMs: now)))
        case "account/rateLimits/updated", "account.rateLimits.updated":
            if let usage = Self.accountUsage(from: payload) {
                events.append(.accountUsage(usage))
            }
            if let warning = Self.rateLimitWarning(from: payload) {
                appendCompletedTool(summary: "Codex rate limit", output: warning)
            }
        case "mcpServer/oauthLogin/completed", "mcpServer.startupStatus.updated", "mcpServer/startupStatus/updated":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "name")
                ?? string(payload, "serverName")
                ?? string(payload, "server_name")
                ?? string(payload, "serverId")
                ?? "mcp-server-\(UUID().uuidString)"
            let status = string(payload, "status") ?? string(payload, "state") ?? "completed"
            let output = string(payload, "error") ?? Self.jsonString(payload)
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .mcpToolCall, state: status == "failed" ? .failed : .completed, summary: "MCP server status", output: output, startedAtMs: now, finishedAtMs: now)))
        case "model/rerouted", "model.rerouted":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "model-rerouted-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let reason = string(payload, "reason") ?? "unknown"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: "Model rerouted",
                output: "Model rerouted: \(reason)",
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "model/safetyBuffering/updated", "model.safetyBuffering.updated":
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = "model-safety-buffering-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let model = string(payload, "model") ?? string(payload, "fasterModel") ?? "unknown"
            let showUI = payload["showBufferingUi"] as? Bool ?? payload["showBufferingUI"] as? Bool
            let reasons = Self.joinedStrings(payload["reasons"]) ?? Self.joinedStrings(payload["useCases"]) ?? ""
            var output = "Model safety buffering: \(model)"
            if let showUI { output += showUI ? " (show UI)" : " (hide UI)" }
            if !reasons.isEmpty { output += " — \(reasons)" }
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: "Model safety buffering",
                output: output,
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "autoApprovalReview/strictReviewRequired", "autoApprovalReview.strictReviewRequired":
            // Terminal: item/autoApprovalReview/completed keys off reviewId, not
            // strict-review-<turnId>, so a streaming chip never settles (CODEX-APP-004).
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = "strict-review-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .review,
                state: .completed,
                summary: "Strict auto-approval review required",
                output: Self.jsonString(payload),
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "turn/moderationMetadata", "turn.moderationMetadata":
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = "turn-moderation-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let metadata = payload["metadata"] ?? payload
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: "Turn moderation metadata",
                output: Self.jsonString(metadata),
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "model/verification", "model.verification":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "model-verification-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let verification = Self.joinedStrings(payload["verifications"]) ?? string(payload, "verification") ?? "verified"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: "Model verification",
                output: "Model verification: \(verification)",
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "remoteControl/status/changed", "remoteControl.status.changed":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "remote-control-\(string(payload, "environmentId") ?? UUID().uuidString)"
            let status = string(payload, "status") ?? "unknown"
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .completed, summary: "Remote control status", output: status, startedAtMs: now, finishedAtMs: now)))
        case "thread/realtime/started", "thread.realtime.started":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "realtimeSessionId") ?? string(payload, "realtime_session_id") ?? "realtime-\(UUID().uuidString)"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .streaming,
                summary: "Realtime session started",
                output: Self.realtimeDetail(from: payload),
                startedAtMs: now
            )))
        case "thread/realtime/itemAdded", "thread.realtime.item-added",
             "thread/realtime/item/started", "thread.realtime.item.started":
            let item = payload["item"] as? [String: Any] ?? payload
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = string(item, "id") ?? string(payload, "itemId") ?? string(payload, "item_id") ?? "realtime-item-\(UUID().uuidString)"
            let rawType = string(item, "type") ?? string(payload, "type") ?? "realtime"
            let streaming = method.contains("started")
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: Self.assistantItemType(for: rawType),
                state: streaming ? .streaming : .completed,
                summary: "Realtime item added",
                output: Self.body(for: item, type: rawType) ?? Self.jsonString(item),
                startedAtMs: now,
                finishedAtMs: streaming ? nil : now
            )))
        case "thread/realtime/transcript/delta", "thread.realtime.transcript.delta",
             "thread/realtime/item/transcript/delta", "thread.realtime.item.transcript.delta":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? string(payload, "responseId") ?? string(payload, "response_id") ?? "realtime-transcript-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let delta = string(payload, "delta") ?? string(payload, "text") ?? ""
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, state: .streaming, summary: "Realtime transcript", startedAtMs: now)))
            events.append(.itemDelta(itemId: itemId, bodyAppend: delta, outputAppend: nil, summary: "Realtime transcript"))
        case "thread/realtime/transcript/done", "thread.realtime.transcript.done":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? string(payload, "responseId") ?? string(payload, "response_id") ?? "realtime-transcript-\(UUID().uuidString)"
            if let text = string(payload, "text") ?? string(payload, "transcript"), !text.isEmpty {
                events.append(.itemDelta(itemId: itemId, bodyAppend: text, outputAppend: nil, summary: "Realtime transcript"))
            }
            events.append(.itemCompleted(itemId: itemId, finalState: .completed))
        case "thread/realtime/item/completed", "thread.realtime.item.completed":
            let item = payload["item"] as? [String: Any] ?? [:]
            let itemId = string(item, "id")
                ?? string(payload, "itemId")
                ?? string(payload, "item_id")
                ?? string(payload, "responseId")
                ?? string(payload, "response_id")
                ?? "realtime-transcript-\(UUID().uuidString)"
            events.append(.itemCompleted(itemId: itemId, finalState: .completed))
        case "thread/realtime/outputAudio/delta", "thread.realtime.audio.delta":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? string(payload, "responseId") ?? string(payload, "response_id") ?? "realtime-audio-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let audio = string(payload, "audio") ?? string(payload, "delta") ?? string(payload, "audioDelta") ?? string(payload, "audio_delta") ?? ""
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .streaming, summary: "Realtime audio", output: audio, startedAtMs: now)))
        case "thread/realtime/sdp", "thread.realtime.sdp":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "realtimeSessionId") ?? string(payload, "realtime_session_id") ?? "realtime-sdp-\(UUID().uuidString)"
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .completed, summary: "Realtime SDP", output: string(payload, "sdp") ?? Self.jsonString(payload), startedAtMs: now, finishedAtMs: now)))
        case "thread/realtime/error", "thread.realtime.error":
            let message = string(payload, "message") ?? (payload["error"] as? [String: Any]).flatMap { string($0, "message") } ?? "Realtime error"
            events.append(.error(message: "Codex realtime error: \(message)", recoverable: true))
        case "thread/realtime/closed", "thread.realtime.closed":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "realtimeSessionId") ?? string(payload, "realtime_session_id") ?? "realtime-closed-\(UUID().uuidString)"
            let reason = string(payload, "reason") ?? string(payload, "message") ?? "closed"
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .completed, summary: "Realtime session closed", output: reason, startedAtMs: now, finishedAtMs: now)))
        case "thread/closed", "thread.closed", "thread/reverted", "thread.reverted":
            // Server dropped this thread. Settle hangable callbacks with the
            // same cancel dialect as serverRequest/resolved, drop the local
            // provider handle, and tell the UI the session is gone.
            let action = method.contains("reverted") ? "reverted" : "closed"
            events.append(.error(message: "Codex thread \(action).", recoverable: true))
            dropProviderHandle = true
        case "fs/changed", "fs.changed":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "fs-changed-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let paths = Self.joinedStrings(payload["changedPaths"]) ?? Self.joinedStrings(payload["paths"]) ?? Self.jsonString(payload["changedPaths"]) ?? ""
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .fileChange,
                state: .completed,
                summary: "Filesystem changed",
                output: paths,
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "turn/completed", "turn.completed":
            // Upstream (openai/codex app-server) emits only `turn/completed` for
            // terminal turns. Outcome lives on `turn.status` (wire camelCase:
            // completed|failed|interrupted|inProgress). Failed carries
            // `turn.error.message`. Do not treat failed/interrupted as success.
            let turn = payload["turn"] as? [String: Any]
            let turnId = string(payload, "turnId")
                ?? turn.flatMap({ string($0, "id") })
                ?? activeTurnId(threadId: threadId)
                ?? ""
            let wireStatus = Self.turnCompletedWireStatus(from: payload)
            if Self.isFailedTurnStatus(wireStatus) {
                let error = Self.turnFailedErrorPayload(from: payload)
                finished = finishTurnAsFailed(
                    threadId: threadId,
                    turnId: turnId,
                    payload: payload,
                    error: error,
                    eventKind: "turn/completed-failed",
                    events: &events
                )
            } else if Self.isInterruptedTurnStatus(wireStatus) {
                // Same terminal as the user-stop cancel path: cancelled, no final.
                finished = .finished(
                    .cancelled,
                    finalMessage: nil,
                    providerThreadId: publishedDestination(threadId: threadId)
                )
                markFinished(threadId: threadId, status: .cancelled, turnId: turnId.isEmpty ? nil : turnId)
            } else {
                // completed, missing status (back-compat), or other non-terminal
                // labels keep the existing success / PendingFinish deferral path.
                var final = Self.turnCompletedFinalMessage(from: payload) ?? finalMessage(threadId: threadId)
                if let markdown = Self.proposedPlanMarkdown(in: final) ?? planModeFinalMarkdown(threadId: threadId, final: final) {
                    let planId = "plan-\(turnId)"
                    if markProposedPlanEmitted(threadId: threadId, planId: planId) {
                        events.append(.proposedPlan(AssistantProposedPlan(id: planId, turnId: turnId.isEmpty ? nil : turnId, markdown: markdown)))
                    }
                }
                // Stamp [[RC_AWAITING]] whenever this turn observed shell-detached work.
                // PendingFinish deferral (thread still active) and detach evidence are
                // orthogonal: deferral answers "is the app-server THREAD still active?";
                // the marker answers "did the agent leave shell work the app-server
                // never tracks?". Both can be true. Stamp the one canonical `final` so
                // the marker rides both `.turnCompleted` and the later deferred
                // `.finished` release (which does not re-emit turnCompleted). Still do
                // NOT add deferral for detached work — Codex never auto-resumes a
                // detached process; withholding the terminal would hang until idle/
                // watchdog. Accepted false-positive: process already exited before
                // turn end still stamps; during deferral the UI may show awaiting
                // while Codex is still active (same class as non-deferred; bounded
                // nudge self-corrects on the next unmarked completion).
                // A goal iteration reports idle right BEFORE turn/completed, so the
                // active-status deferral alone lets the per-iteration turn end close
                // the run while Codex immediately starts the next turn (proven live
                // 2026-09-14: run marked completed, goal kept streaming for 10+ min).
                let deferring = shouldDeferFinishUntilIdle(threadId: threadId)
                    || hasActiveGoal(threadId: threadId)
                if sawDetachedShellSpawn(threadId: threadId) {
                    if let marked = BackgroundAwaitContinuation.prefixingAwaitingMarker(final.isEmpty ? nil : final) {
                        final = marked
                    }
                }
                events.append(.turnCompleted(turnId: turnId, finalMessage: final.isEmpty ? nil : final))
                let pending = PendingFinish(
                    status: .completed,
                    finalMessage: final.isEmpty ? nil : final,
                    providerThreadId: publishedDestination(threadId: threadId),
                    turnId: turnId,
                    deferredAt: Date()
                )
                if deferring {
                    recordPendingFinish(threadId: threadId, pending: pending)
                    // Ensure reconcile loop is armed even without command_execution /
                    // final_answer paths that normally schedule it.
                    scheduleTurnReconciliation(threadId: threadId, turnId: turnId)
                } else {
                    finished = .finished(pending.status, finalMessage: pending.finalMessage, providerThreadId: pending.providerThreadId)
                    markFinished(threadId: threadId, status: pending.status, turnId: pending.turnId)
                }
            }
        case "turn/failed", "turn.failed":
            // Legacy / non-wire path kept for peers that still emit turn/failed.
            // Live openai/codex 0.146+ uses turn/completed + turn.status only.
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? (payload["turn"] as? [String: Any]).flatMap({ string($0, "id") }) ?? activeTurnId(threadId: threadId) ?? ""
            let error = Self.turnFailedErrorPayload(from: payload)
            finished = finishTurnAsFailed(
                threadId: threadId,
                turnId: turnId,
                payload: payload,
                error: error,
                eventKind: "turn/failed",
                events: &events
            )
        default:
            break
        }
        emit(events, threadId: threadId)
        if dropProviderHandle {
            if let session = removeSession(threadId: threadId) {
                settlePendingCallbacks(session: session)
                session.client.stop()
                if session.status == .running {
                    session.onEvent?(.status(.cancelled))
                    session.onEvent?(.finished(
                        .cancelled,
                        finalMessage: nil,
                        providerThreadId: publishedDestination(session)
                    ))
                }
            }
        } else if let finished {
            // PERF: use onEventCallback to avoid a second full-Session copy for the terminal event.
            SessionEventEmitter(onEvent: onEventCallback(threadId: threadId))
                .broadcastEvent(finished)
        } else {
            // Live app-server activity while a finish is withheld re-arms the
            // quiet bound so progressive nested work is not force-finished.
            refreshPendingFinishWatchdog(threadId: threadId)
        }
    }

    private func runtimeEvent(method: String, payload: [String: Any]) -> AssistantEvent {
        Self.runtimeEvent(method: method, payload: payload)
    }

    private static func runtimeEvent(method: String, payload: [String: Any]) -> AssistantEvent {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return .providerRuntime(ProviderRuntimeEvent(
            provider: .codex,
            source: "codex.app-server",
            method: method,
            providerTurnId: Self.providerTurnId(from: payload),
            providerItemId: Self.providerItemId(from: payload),
            providerRequestId: Self.providerRequestId(from: payload),
            payloadJSON: String(data: data, encoding: .utf8) ?? "{}",
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ))
    }

    private func ensureAssistantItem(threadId: AgentThreadID, turnId: String, itemId: String, now: Int64, events: inout [AssistantEvent]) {
        guard markStartedItem(threadId: threadId, turnId: turnId, itemId: itemId) else { return }
        events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, state: .streaming, startedAtMs: now)))
    }

    private func markStartedItem(threadId: AgentThreadID, turnId: String, itemId: String) -> Bool {
        let key = "\(turnId):\(itemId)"
        lock.lock()
        let alreadyStarted = sessions[threadId]?.startedItemIds.contains(key) ?? false
        if !alreadyStarted {
            sessions[threadId]?.startedItemIds.insert(key)
        }
        lock.unlock()
        return !alreadyStarted
    }

    private func markStreamedItem(threadId: AgentThreadID, turnId: String, itemId: String) {
        let key = "\(turnId):\(itemId)"
        lock.lock()
        sessions[threadId]?.streamedItemIds.insert(key)
        lock.unlock()
    }

    private func hasStreamedItem(threadId: AgentThreadID, turnId: String, itemId: String) -> Bool {
        let key = "\(turnId):\(itemId)"
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.streamedItemIds.contains(key) ?? false
    }

    // PERF: extract only the onEvent closure under lock — avoids copying the full
    // Session struct (2 dicts + 3 sets + growing string) for every notification batch.
    private func onEventCallback(threadId: AgentThreadID) -> (@Sendable (AgentRunEvent) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.onEvent
    }

    private func emit(_ events: [AssistantEvent], threadId: AgentThreadID) {
        SessionEventEmitter(onEvent: onEventCallback(threadId: threadId))
            .broadcastEvents(events)
    }

    private func settlePendingCallbacks(session: Session) {
        let onEvent = session.onEvent
        for (requestId, pending) in session.pendingApprovals {
            onEvent?(.event(.requestResolved(requestId: requestId, state: .cancelled)))
            switch pending.responseKind {
            case .legacyDecision:
                // Use the same dialect as interactive cancel: ReviewDecision
                // methods need `"abort"`, accept-dialect needs `"cancel"`.
                pending.continuation.resume(returning: [
                    "decision": Self.codexDecision(.cancel, pending: pending)
                ])
            case .permissions:
                pending.continuation.resume(returning: [
                    "permissions": [String: Any](),
                    "scope": "turn"
                ])
            }
        }
        for (requestId, pending) in session.pendingUserInputs {
            onEvent?(.event(.userInputResolved(requestId: requestId, answer: nil)))
            switch pending.responseKind {
            case .toolRequest:
                pending.continuation.resume(returning: ["answers": Self.codexAnswers(
                    questionIds: pending.questionIds,
                    questionPromptsById: pending.questionPromptsById,
                    multiSelectQuestionIds: pending.multiSelectQuestionIds,
                    text: ""
                )])
            case .mcpElicitation:
                pending.continuation.resume(returning: ["action": "cancel"])
            }
        }
    }

    /// Settle one pending approval cleared by `serverRequest/resolved`.
    @discardableResult
    private func settlePendingRequest(threadId: AgentThreadID, requestId: String) -> Bool {
        guard let pending = removePendingApproval(threadId: threadId, requestId: requestId) else {
            return false
        }
        emit([.requestResolved(requestId: requestId, state: .cancelled)], threadId: threadId)
        switch pending.responseKind {
        case .legacyDecision:
            // Use the same dialect as interactive cancel: ReviewDecision
            // methods need `"abort"`, accept-dialect needs `"cancel"`.
            pending.continuation.resume(returning: [
                "decision": Self.codexDecision(.cancel, pending: pending)
            ])
        case .permissions:
            pending.continuation.resume(returning: [
                "permissions": [String: Any](),
                "scope": "turn"
            ])
        }
        return true
    }

    /// Settle one pending user-input / elicitation cleared by `serverRequest/resolved`.
    @discardableResult
    private func settlePendingUserInput(threadId: AgentThreadID, requestId: String) -> Bool {
        guard let pending = removePendingUserInput(threadId: threadId, requestId: requestId) else {
            return false
        }
        emit([.userInputResolved(requestId: requestId, answer: nil)], threadId: threadId)
        switch pending.responseKind {
        case .toolRequest:
            pending.continuation.resume(returning: ["answers": Self.codexAnswers(
                questionIds: pending.questionIds,
                questionPromptsById: pending.questionPromptsById,
                multiSelectQuestionIds: pending.multiSelectQuestionIds,
                text: ""
            )])
        case .mcpElicitation:
            pending.continuation.resume(returning: ["action": "cancel"])
        }
        return true
    }

    /// Normalize `serverRequest/resolved.requestId` (string | int64) to the pending-map key.
    private static func wireRequestId(from value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        if let int = value as? Int {
            return String(int)
        }
        if let int64 = value as? Int64 {
            return String(int64)
        }
        if let number = value as? NSNumber {
            // Avoid treating bool NSNumber as 0/1 request ids.
            let objCType = String(cString: number.objCType)
            if objCType == "c" || objCType == "B" { return nil }
            return number.stringValue
        }
        return nil
    }

    private func cancel(threadId: AgentThreadID, runId: AgentRunID) {
        let session: Session? = {
            lock.lock(); defer { lock.unlock() }
            guard sessions[threadId]?.runId == runId else { return nil }
            return sessions.removeValue(forKey: threadId)
        }()
        guard let session else { return }
        stop(session)
    }

    private func stop(_ session: Session) {
        // The coordinator already gives interruptTurn a graceful window.
        // Hard cancellation must close the exact client without awaiting another
        // RPC after removing it from sessions (force stop could no longer find it).
        session.pendingFinishWatchdog?.cancel()
        settlePendingCallbacks(session: session)
        session.client.stop()
        if session.status == .running || session.activeTurnId != nil || session.pendingFinish != nil {
            session.onEvent?(.status(.cancelled))
            session.onEvent?(.finished(.cancelled, finalMessage: nil, providerThreadId: publishedDestination(session)))
        }
    }

    private func installTerminationHandler(
        for client: CodexAppServerControlling,
        threadId: AgentThreadID
    ) {
        let clientIdentity = ObjectIdentifier(client)
        client.terminationHandler = { [weak self] error in
            self?.handleClientTermination(
                threadId: threadId,
                clientIdentity: clientIdentity,
                error: error
            )
        }
    }

    private func handleClientTermination(
        threadId: AgentThreadID,
        clientIdentity: ObjectIdentifier,
        error: Error
    ) {
        guard let session = removeSession(threadId: threadId, clientIdentity: clientIdentity) else { return }
        guard session.status == .running else { return }
        settlePendingCallbacks(session: session)
        let message = "Codex app-server process exited before completing the turn: \(error)"
        session.onEvent?(.event(runtimeEvent(method: "process/exited", payload: [
            "threadId": session.providerThreadId,
            "message": message
        ])))
        session.onEvent?(.error(message))
        session.onEvent?(.status(.failed))
        session.onEvent?(.finished(.failed, finalMessage: nil, providerThreadId: publishedDestination(session)))
    }

    private func recordSession(
        threadId: AgentThreadID,
        runId: AgentRunID,
        client: CodexAppServerControlling,
        providerThreadId: String,
        interactionMode: AgentInteractionMode,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void,
        permissionMode: AgentPermissionMode,
        status: AgentRunStatus = .running,
        awaitingSeedPublish: Bool = false
    ) {
        lock.lock()
        sessions[threadId] = Session(
            runId: runId,
            client: client,
            providerThreadId: providerThreadId,
            activeTurnId: nil,
            threadStatusType: nil,
            pendingFinish: nil,
            pendingFinishWatchdog: nil,
            status: status,
            onEvent: onEvent,
            interactionMode: interactionMode,
            finalAssistantMessage: "",
            finalAssistantMessageItemId: nil,
            completedTurnIds: [],
            pendingApprovals: [:],
            pendingUserInputs: [:],
            proposedPlanBuffers: [:],
            emittedProposedPlanIds: [],
            startedItemIds: [],
            streamedItemIds: [],
            permissionMode: permissionMode,
            turnReconcileGeneration: 0,
            sawDetachedShellSpawn: false,
            pendingFreshFallbackSeed: false,
            goalActive: false,
            awaitingSeedPublish: awaitingSeedPublish
        )
        lock.unlock()
    }

    private func sessionSnapshot(threadId: AgentThreadID) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]
    }

    private func planModeFinalMarkdown(threadId: AgentThreadID, final: String) -> String? {
        let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard sessions[threadId]?.interactionMode == .plan else { return nil }
        return trimmed
    }

    private func removeSession(threadId: AgentThreadID) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return sessions.removeValue(forKey: threadId)
    }

    private func removeSession(threadId: AgentThreadID, clientIdentity: ObjectIdentifier) -> Session? {
        lock.lock(); defer { lock.unlock() }
        guard let session = sessions[threadId], ObjectIdentifier(session.client) == clientIdentity else {
            return nil
        }
        return sessions.removeValue(forKey: threadId)
    }

    private func setActiveTurn(threadId: AgentThreadID, turnId: String) {
        lock.lock()
        if sessions[threadId]?.completedTurnIds.contains(turnId) == false {
            sessions[threadId]?.activeTurnId = turnId
            // New turn must not inherit a prior turn's shell-detach signal.
            sessions[threadId]?.sawDetachedShellSpawn = false
        }
        lock.unlock()
    }

    private func updateThreadStatus(threadId: AgentThreadID, statusType: String) -> PendingFinish? {
        lock.lock()
        sessions[threadId]?.threadStatusType = statusType
        if Self.isFailedUnforkableThreadStatus(statusType) {
            let existing = sessions[threadId]?.pendingFinish
            sessions[threadId]?.pendingFinish = nil
            sessions[threadId]?.pendingFinishWatchdog?.cancel()
            sessions[threadId]?.pendingFinishWatchdog = nil
            let turnId = existing?.turnId ?? sessions[threadId]?.activeTurnId
            let providerThreadId = existing?.providerThreadId ?? sessions[threadId]?.providerThreadId
            lock.unlock()
            return PendingFinish(
                status: .failed,
                finalMessage: existing?.finalMessage,
                providerThreadId: providerThreadId,
                turnId: turnId,
                deferredAt: existing?.deferredAt ?? Date()
            )
        }
        let pending = Self.isIdleThreadStatus(statusType) && sessions[threadId]?.goalActive != true
            ? sessions[threadId]?.pendingFinish
            : nil
        if pending != nil {
            sessions[threadId]?.pendingFinish = nil
            sessions[threadId]?.pendingFinishWatchdog?.cancel()
            sessions[threadId]?.pendingFinishWatchdog = nil
        }
        lock.unlock()
        return pending
    }

    private func shouldDeferFinishUntilIdle(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Self.isActiveThreadStatus(sessions[threadId]?.threadStatusType)
    }

    /// Pops a withheld finish (and its watchdog) so the caller can release it
    /// through the ordered `finished` path of the notification handler.
    private func takePendingFinish(threadId: AgentThreadID) -> PendingFinish? {
        lock.lock(); defer { lock.unlock() }
        guard let pending = sessions[threadId]?.pendingFinish else { return nil }
        sessions[threadId]?.pendingFinish = nil
        sessions[threadId]?.pendingFinishWatchdog?.cancel()
        sessions[threadId]?.pendingFinishWatchdog = nil
        return pending
    }

    private func hasActiveGoal(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.goalActive == true
    }

    private func setGoalActive(threadId: AgentThreadID, _ active: Bool) {
        lock.lock()
        sessions[threadId]?.goalActive = active
        lock.unlock()
    }

    /// A goal loop started its next iteration (`turn/started` with a new id, or
    /// thread/read shows a newer turn): the finish withheld at the previous
    /// iteration's `turn/completed` is stale. Drop it and invalidate the
    /// reconcile loop so neither can close the still-running goal run.
    /// Returns true when a pending finish was dropped.
    @discardableResult
    private func dropPendingFinishForContinuingGoal(threadId: AgentThreadID, newTurnId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var session = sessions[threadId],
              session.goalActive,
              let pending = session.pendingFinish,
              pending.turnId != newTurnId
        else { return false }
        session.pendingFinish = nil
        session.pendingFinishWatchdog?.cancel()
        session.pendingFinishWatchdog = nil
        session.turnReconcileGeneration &+= 1
        sessions[threadId] = session
        return true
    }

    /// Hold `.finished` until the thread reports idle, or until true quiet
    /// exceeds `pendingFinishInactivityTimeout`. No absolute wall-clock max:
    /// continuous app-server activity fully re-arms the quiet bound.
    private func recordPendingFinish(threadId: AgentThreadID, pending: PendingFinish) {
        lock.lock()
        sessions[threadId]?.pendingFinishWatchdog?.cancel()
        sessions[threadId]?.pendingFinish = pending
        lock.unlock()
        refreshPendingFinishWatchdog(threadId: threadId)
    }

    /// (Re)arm quiet bound for a withheld finish. No-op unless deferral is live.
    private func refreshPendingFinishWatchdog(threadId: AgentThreadID) {
        lock.lock()
        guard sessions[threadId]?.pendingFinish != nil else {
            lock.unlock()
            return
        }
        sessions[threadId]?.pendingFinishWatchdog?.cancel()
        let expectedTurnId = sessions[threadId]?.pendingFinish?.turnId
        let delay = pendingFinishInactivityTimeout
        let item = DispatchWorkItem { [weak self] in
            self?.flushPendingFinishIfStillDeferred(
                threadId: threadId,
                expectedTurnId: expectedTurnId,
                reason: "pending_finish_inactivity",
                onlyIfThreadInactive: false
            )
        }
        sessions[threadId]?.pendingFinishWatchdog = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Releases a withheld `.finished` using the original pending payload.
    /// - Parameter onlyIfThreadInactive: when true (new user turn), skip flush
    ///   while the app-server still reports the thread active so concurrent work
    ///   is not clobbered.
    private func flushPendingFinishIfStillDeferred(
        threadId: AgentThreadID,
        expectedTurnId: String?,
        reason: String,
        onlyIfThreadInactive: Bool
    ) {
        lock.lock()
        guard var session = sessions[threadId],
              let pending = session.pendingFinish else {
            lock.unlock()
            return
        }
        if let expectedTurnId, let pendingTurn = pending.turnId, expectedTurnId != pendingTurn {
            lock.unlock()
            return
        }
        if onlyIfThreadInactive, Self.isActiveThreadStatus(session.threadStatusType) {
            lock.unlock()
            return
        }
        session.pendingFinish = nil
        session.pendingFinishWatchdog?.cancel()
        session.pendingFinishWatchdog = nil
        sessions[threadId] = session
        let onEvent = session.onEvent
        lock.unlock()
        markFinished(threadId: threadId, status: pending.status, turnId: pending.turnId)
        SessionEventEmitter(onEvent: onEvent)
            .broadcastEvent(
                .finished(
                    pending.status,
                    finalMessage: pending.finalMessage,
                    providerThreadId: publishedDestination(pending.providerThreadId, threadId: threadId)
                )
            )
        if let onEvent {
            let data = (try? JSONSerialization.data(
                withJSONObject: ["reason": reason, "turnId": pending.turnId as Any],
                options: [.sortedKeys]
            )) ?? Data()
            onEvent(.event(.providerRuntime(ProviderRuntimeEvent(
                provider: .codex,
                source: "codex.app-server",
                method: "codex.pending_finish.inactivity",
                providerTurnId: pending.turnId,
                providerItemId: nil,
                payloadJSON: String(data: data, encoding: .utf8) ?? "{}",
                receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            ))))
        }
    }

    private func appendFileTouches(from item: [String: Any], itemId: String, now: Int64, to events: inout [AssistantEvent]) {
        if let event = ProviderFileTouchParser.runtimeEvent(
            provider: .codex,
            touches: ProviderFileTouchParser.codex(item: item),
            itemId: itemId,
            receivedAtMs: now
        ) {
            events.append(event)
        }
    }

    /// Observes command_execution items for shell-detached work. Uses the same
    /// command key fallbacks already used for approval/detail (`command`,
    /// `commandLine`, `cmd`).
    private func trackDetachedShellSpawn(in item: [String: Any], threadId: AgentThreadID) {
        let command = Self.string(item, "command")
            ?? Self.string(item, "commandLine")
            ?? Self.string(item, "cmd")
        guard let command, BackgroundAwaitContinuation.commandDetachesShellWork(command) else { return }
        lock.lock()
        sessions[threadId]?.sawDetachedShellSpawn = true
        lock.unlock()
    }

    private func sawDetachedShellSpawn(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.sawDetachedShellSpawn == true
    }

    private func activeTurnId(threadId: AgentThreadID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.activeTurnId
    }

    /// Turn to attach thread/goal notifications to. Goal events can arrive with
    /// no active turn (the server races the turn/start response; a goal cleared
    /// lands right after turn/completed). Falling back to the last completed
    /// turn keeps them rendering chronologically at the bottom of the transcript
    /// instead of merging into the reducer's first phantom ""-id turn; the
    /// callers also scope the goal item id by this turn so item ids stay unique
    /// across turns (reducer invariant).
    private func goalTurnId(threadId: AgentThreadID) -> String {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.activeTurnId ?? sessions[threadId]?.completedTurnIds.last ?? ""
    }

    private func providerThreadId(threadId: AgentThreadID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.providerThreadId
    }

    private func sessionPermissionMode(threadId: AgentThreadID) -> AgentPermissionMode? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.permissionMode
    }

    private func setSessionPermissionMode(threadId: AgentThreadID, permissionMode: AgentPermissionMode) {
        lock.lock()
        sessions[threadId]?.permissionMode = permissionMode
        lock.unlock()
    }

    private func appendFinalMessage(threadId: AgentThreadID, itemId: String, delta: String) {
        lock.lock()
        // A turn may emit several assistant-message items (preamble notes, then the
        // final answer). Keep only the latest item's text: reset the buffer when a
        // new item begins, but still concatenate multiple streamed deltas that share
        // the same item id. Otherwise the persisted/final answer becomes the whole
        // narration of the turn instead of the last message.
        if sessions[threadId]?.finalAssistantMessageItemId != itemId {
            sessions[threadId]?.finalAssistantMessage = delta
            sessions[threadId]?.finalAssistantMessageItemId = itemId
        } else {
            sessions[threadId]?.finalAssistantMessage += delta
        }
        lock.unlock()
    }

    private func finalMessage(threadId: AgentThreadID) -> String {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.finalAssistantMessage ?? ""
    }

    /// Wait briefly for the normal notification path, then authoritatively
    /// reconcile via thread/read. One generation remains active per turn, so a
    /// long command is polled without accumulating watchdog tasks.
    private func scheduleTurnReconciliation(threadId: AgentThreadID, turnId: String) {
        lock.lock()
        guard sessions[threadId] != nil else {
            lock.unlock()
            return
        }
        let generation = (sessions[threadId]?.turnReconcileGeneration ?? 0) &+ 1
        sessions[threadId]?.turnReconcileGeneration = generation
        lock.unlock()
        Task { [weak self] in
            // Let a racing item/completed or turn/completed win first.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while let self {
                let finished = await self.reconcileTurnIfStillOpen(
                    threadId: threadId,
                    expectedTurnId: turnId,
                    generation: generation
                )
                if finished { return }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    /// Returns true when this watchdog is obsolete or the turn was reconciled.
    private func reconcileTurnIfStillOpen(
        threadId: AgentThreadID,
        expectedTurnId: String,
        generation: Int
    ) async -> Bool {
        let snapshot: (client: CodexAppServerControlling, providerThreadId: String)? = {
            lock.lock(); defer { lock.unlock() }
            guard let session = sessions[threadId],
                  session.turnReconcileGeneration == generation,
                  session.status == .running || session.activeTurnId != nil
            else { return nil }
            return (session.client, session.providerThreadId)
        }()
        guard let snapshot else { return true }

        let response: CodexAppServerClient.JSONObject
        do {
            response = try await snapshot.client.readThread(
                providerThreadId: snapshot.providerThreadId,
                includeTurns: true
            )
        } catch {
            return false
        }

        let turnId = expectedTurnId.isEmpty
            ? (Self.turnIds(fromThreadReadResponse: response).last ?? "")
            : expectedTurnId
        guard !turnId.isEmpty,
              Self.turnIsAuthoritativelyTerminal(in: response, turnId: turnId)
        else {
            return false
        }
        if let newerTurnId = Self.turnIds(fromThreadReadResponse: response).last,
           newerTurnId != turnId,
           dropPendingFinishForContinuingGoal(threadId: threadId, newTurnId: newerTurnId) {
            // Active goal already moved to a newer turn: the completed turn we
            // were reconciling is a finished iteration, not the end of the run.
            return true
        }
        // turnIsAuthoritativelyTerminal only inspects the one completed iteration
        // turn, so a still-active goal between iterations (e.g. waiting minutes
        // on CI) reads as terminal here every time the next turn/started has not
        // landed yet within this poll's ~2-17s window — this loop re-polls every
        // 15s, so it would close the run out from under a slow-but-active goal
        // long before the inactivity watchdog ever gets a chance to. Keep polling
        // instead; `thread/goal/cleared` (or a goal/updated non-active status)
        // releases the withheld finish directly, and the watchdog remains the
        // backstop for a goal that never clears.
        if hasActiveGoal(threadId: threadId) {
            return false
        }

        // Prefer the withheld pending payload (preserves [[RC_AWAITING]] stamps).
        // When we deferred after turn/completed, turnCompleted was already
        // emitted — do not duplicate it on reconcile release.
        let release: (final: String?, skipTurnCompleted: Bool)? = {
            lock.lock(); defer { lock.unlock() }
            guard let live = sessions[threadId],
                  live.turnReconcileGeneration == generation,
                  live.status == .running || live.activeTurnId != nil || live.pendingFinish != nil
            else { return nil }
            if let pending = live.pendingFinish {
                return (pending.finalMessage, true)
            }
            let already = live.completedTurnIds.contains(turnId)
            return (live.finalAssistantMessage.isEmpty ? nil : live.finalAssistantMessage, already)
        }()
        guard let release else { return true }

        mergeCompletedTurnIds(threadId: threadId, turnIds: Self.turnIds(fromThreadReadResponse: response))
        let final = release.final
            ?? Self.finalMessageFromThreadRead(response, turnId: turnId)
        if !release.skipTurnCompleted {
            emit([.turnCompleted(turnId: turnId, finalMessage: final)], threadId: threadId)
        }
        markFinished(threadId: threadId, status: .completed, turnId: turnId)
        SessionEventEmitter(onEvent: onEventCallback(threadId: threadId))
            .broadcastEvent(
                .finished(
                    .completed,
                    finalMessage: final,
                    providerThreadId: publishedDestination(snapshot.providerThreadId, threadId: threadId)
                )
            )
        return true
    }

    /// Shared fatal-turn finish path for live `turn/completed`+failed and legacy `turn/failed`.
    private func finishTurnAsFailed(
        threadId: AgentThreadID,
        turnId: String,
        payload: [String: Any],
        error: [String: Any],
        eventKind: String,
        events: inout [AssistantEvent]
    ) -> AgentRunEvent {
        let message = string(error, "message")
            ?? string(payload, "message")
            ?? Self.jsonString(error)
            ?? "Codex turn failed"
        let outcome = Self.classifyFatalOutcome(
            eventKind: eventKind,
            willRetry: false,
            errorCode: Self.errorCode(from: payload, error: error)
        ) ?? .failed(isAuth: false)
        events.append(.error(message: message, recoverable: false))
        if case .failed(let isAuth) = outcome, isAuth {
            events.append(runtimeEvent(method: "remotecode/authRequired", payload: Self.authActionMetadata))
        }
        markFinished(threadId: threadId, status: .failed, turnId: turnId.isEmpty ? nil : turnId)
        return Self.failedEvent(
            for: outcome,
            message: message,
            providerThreadId: publishedDestination(threadId: threadId)
        )
    }

    private func markFinished(threadId: AgentThreadID, status: AgentRunStatus, turnId: String?) {
        lock.lock()
        sessions[threadId]?.status = status
        sessions[threadId]?.activeTurnId = nil
        if !Self.isFailedUnforkableThreadStatus(sessions[threadId]?.threadStatusType) {
            sessions[threadId]?.threadStatusType = nil
        }
        sessions[threadId]?.goalActive = false
        sessions[threadId]?.pendingFinish = nil
        sessions[threadId]?.pendingFinishWatchdog?.cancel()
        sessions[threadId]?.pendingFinishWatchdog = nil
        // Invalidate the pending reconciliation loop so it cannot finish a turn
        // that already completed via the normal notification path.
        if var session = sessions[threadId] {
            session.turnReconcileGeneration &+= 1
            sessions[threadId] = session
        }
        if let turnId, !turnId.isEmpty, sessions[threadId]?.completedTurnIds.contains(turnId) == false {
            sessions[threadId]?.completedTurnIds.append(turnId)
        }
        // PERF-007: per-turn buffers only matter within the turn they
        // accumulate in (final-message text, item-start/stream dedup keys,
        // proposed-plan deltas). Reset them on turn completion so a
        // long-lived session does not hold an ever-growing final message
        // and unbounded item-id sets for its whole lifetime. completedTurnIds
        // (rollback window) and emittedProposedPlanIds (proposed-plan dedup)
        // are intentionally retained.
        sessions[threadId]?.finalAssistantMessage = ""
        sessions[threadId]?.finalAssistantMessageItemId = nil
        sessions[threadId]?.startedItemIds.removeAll(keepingCapacity: false)
        sessions[threadId]?.streamedItemIds.removeAll(keepingCapacity: false)
        sessions[threadId]?.proposedPlanBuffers.removeAll(keepingCapacity: false)
        sessions[threadId]?.sawDetachedShellSpawn = false
        lock.unlock()
    }

    private func mergeCompletedTurnIds(threadId: AgentThreadID, turnIds: [String]) {
        guard !turnIds.isEmpty else { return }
        lock.lock()
        if var session = sessions[threadId] {
            for turnId in turnIds where !session.completedTurnIds.contains(turnId) {
                session.completedTurnIds.append(turnId)
            }
            sessions[threadId] = session
        }
        lock.unlock()
    }

    private func recordPendingApproval(threadId: AgentThreadID, requestId: String, pending: PendingApproval) {
        lock.lock()
        sessions[threadId]?.pendingApprovals[requestId] = pending
        lock.unlock()
    }

    private func removePendingApproval(threadId: AgentThreadID, requestId: String) -> PendingApproval? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.pendingApprovals.removeValue(forKey: requestId)
    }

    private func recordPendingUserInput(threadId: AgentThreadID, requestId: String, pending: PendingUserInput) {
        lock.lock()
        sessions[threadId]?.pendingUserInputs[requestId] = pending
        lock.unlock()
    }

    private func removePendingUserInput(threadId: AgentThreadID, requestId: String) -> PendingUserInput? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.pendingUserInputs.removeValue(forKey: requestId)
    }

    private func appendProposedPlanDelta(threadId: AgentThreadID, planId: String, delta: String) -> String {
        lock.lock()
        sessions[threadId]?.proposedPlanBuffers[planId, default: ""] += delta
        let buffered = sessions[threadId]?.proposedPlanBuffers[planId] ?? delta
        lock.unlock()
        return buffered
    }

    private func proposedPlanBuffer(threadId: AgentThreadID, planId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.proposedPlanBuffers[planId]
    }

    private func markProposedPlanEmitted(threadId: AgentThreadID, planId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard sessions[threadId]?.emittedProposedPlanIds.contains(planId) == false else { return false }
        sessions[threadId]?.emittedProposedPlanIds.insert(planId)
        return true
    }

    private func string(_ payload: [String: Any], _ key: String) -> String? {
        payload[key] as? String
    }

    /// Map a UI approval response to the Codex decision dialect for `kind`.
    ///
    /// Codex 0.146 splits dialects:
    /// - `item/commandExecution|fileChange|fileRead/...` → accept/acceptForSession/decline/cancel
    /// - legacy `applyPatchApproval` / `execCommandApproval` → ReviewDecision
    ///   (`approved` / `approved_for_session` / `{denied:{rejection}}` / `abort`)
    /// Command-execution Approve may return an offered amendment object instead
    /// of string accept when Codex included that offer on the request.
    private static func codexDecision(
        _ response: AgentProviderRequestResponse,
        pending: PendingApproval
    ) -> Any {
        if usesReviewDecisionDialect(pending.kind) {
            return reviewDecision(response)
        }
        return acceptDecision(response, pending: pending)
    }

    private static func usesReviewDecisionDialect(_ kind: AssistantRequestKind) -> Bool {
        switch kind {
        case .applyPatch, .exec:
            return true
        case .commandExecution, .fileRead, .fileChange, .toolUserInput, .dynamic, .authTokensRefresh:
            return false
        }
    }

    private static func acceptDecision(
        _ response: AgentProviderRequestResponse,
        pending: PendingApproval
    ) -> Any {
        switch response {
        case .approve:
            if let amendment = offeredCommandExecutionApproveDecision(pending) {
                return amendment
            }
            // When Codex sent availableDecisions, that allow-list is authoritative:
            // only emit string accept if it was offered. An empty list must not
            // invent accept after amendment lookup returned nil.
            if let available = pending.availableDecisions {
                if allowListContainsStringDecision(available, "accept") {
                    return "accept"
                }
                return "decline"
            }
            return "accept"
        case .approveForSession:
            if let available = pending.availableDecisions {
                if allowListContainsStringDecision(available, "acceptForSession") {
                    return "acceptForSession"
                }
                return "decline"
            }
            return "acceptForSession"
        case .decline:
            return "decline"
        case .cancel:
            return "cancel"
        }
    }

    private static func allowListContainsStringDecision(_ available: [Any], _ name: String) -> Bool {
        available.contains { raw in
            if let string = raw as? String { return string == name }
            return false
        }
    }

    /// Auto-select an offered command-execution amendment on plain Approve.
    /// Never invent payloads that were not on the request. Deny network rules
    /// are not an Approve of the command.
    private static func offeredCommandExecutionApproveDecision(_ pending: PendingApproval) -> Any? {
        guard pending.kind == .commandExecution else { return nil }
        if let availableDecisions = pending.availableDecisions {
            // Present allow-list is authoritative, including an empty array.
            for raw in availableDecisions {
                if let execpolicy = execpolicyAmendmentDecision(
                    from: raw,
                    proposed: pending.proposedExecpolicyAmendment
                ) {
                    return execpolicy
                }
            }
            for raw in availableDecisions {
                if let network = allowNetworkAmendmentDecision(from: raw) {
                    return network
                }
            }
            return nil
        }
        if !pending.proposedExecpolicyAmendment.isEmpty {
            return [
                "acceptWithExecpolicyAmendment": [
                    "execpolicy_amendment": pending.proposedExecpolicyAmendment
                ]
            ]
        }
        if let rule = pending.proposedNetworkPolicyAmendments.first(where: isAllowNetworkRule) {
            return [
                "applyNetworkPolicyAmendment": [
                    "network_policy_amendment": rule
                ]
            ]
        }
        return nil
    }

    private static func execpolicyAmendmentDecision(from raw: Any, proposed: [String]) -> [String: Any]? {
        guard let object = raw as? [String: Any],
              object["acceptWithExecpolicyAmendment"] != nil else {
            return nil
        }
        let inner = object["acceptWithExecpolicyAmendment"] as? [String: Any] ?? [:]
        let listed = stringArray(inner["execpolicy_amendment"])
        let commands = listed.isEmpty ? proposed : listed
        guard !commands.isEmpty else { return nil }
        return [
            "acceptWithExecpolicyAmendment": [
                "execpolicy_amendment": commands
            ]
        ]
    }

    private static func allowNetworkAmendmentDecision(from raw: Any) -> [String: Any]? {
        guard let object = raw as? [String: Any],
              let inner = object["applyNetworkPolicyAmendment"] as? [String: Any] else {
            return nil
        }
        let rule = (inner["network_policy_amendment"] as? [String: Any]) ?? inner
        guard isAllowNetworkRule(rule) else { return nil }
        return [
            "applyNetworkPolicyAmendment": [
                "network_policy_amendment": rule
            ]
        ]
    }

    private static func isAllowNetworkRule(_ rule: [String: Any]) -> Bool {
        guard let host = rule["host"] as? String, !host.isEmpty else { return false }
        guard let action = rule["action"] as? String else { return false }
        return action.caseInsensitiveCompare("allow") == .orderedSame
    }

    private static func payloadMixedArray(_ payload: [String: Any], camel: String, snake: String) -> [Any] {
        payloadOptionalMixedArray(payload, camel: camel, snake: snake) ?? []
    }

    /// Distinguishes a missing field (`nil`) from an explicit empty array (`[]`).
    private static func payloadOptionalMixedArray(
        _ payload: [String: Any],
        camel: String,
        snake: String
    ) -> [Any]? {
        guard payload[camel] != nil || payload[snake] != nil else { return nil }
        let raw = payload[camel] ?? payload[snake]
        return raw as? [Any] ?? []
    }

    private static func payloadStringArray(_ payload: [String: Any], camel: String, snake: String) -> [String] {
        stringArray(payload[camel] ?? payload[snake])
    }

    private static func payloadObjectArray(_ payload: [String: Any], camel: String, snake: String) -> [[String: Any]] {
        let raw = payload[camel] ?? payload[snake]
        if let objects = raw as? [[String: Any]] { return objects }
        guard let mixed = raw as? [Any] else { return [] }
        return mixed.compactMap { $0 as? [String: Any] }
    }

    private static func stringArray(_ raw: Any?) -> [String] {
        if let strings = raw as? [String] { return strings }
        guard let mixed = raw as? [Any] else { return [] }
        return mixed.compactMap { $0 as? String }
    }

    private static func reviewDecision(_ response: AgentProviderRequestResponse) -> Any {
        switch response {
        case .approve:
            return "approved"
        case .approveForSession:
            return "approved_for_session"
        case .decline(let reason):
            return ["denied": ["rejection": reason ?? "declined"]]
        case .cancel:
            return "abort"
        }
    }

    /// Full-access session auto-approve uses the same dialect as interactive decisions.
    private static func sessionAutoApproveDecision(for kind: AssistantRequestKind) -> String {
        usesReviewDecisionDialect(kind) ? "approved_for_session" : "acceptForSession"
    }

    /// Codex 0.146 dynamic-permission callbacks do not accept the legacy
    /// `{decision}` shape. Grant exactly the profile the provider requested;
    /// decline/cancel return an empty profile rather than widening the thread to
    /// full-access. Session approval is expressed by the protocol's own scope.
    private static func permissionsApprovalResponse(
        requested: [String: Any],
        response: AgentProviderRequestResponse
    ) -> [String: Any] {
        switch response {
        case .approve:
            return ["permissions": requested, "scope": "turn"]
        case .approveForSession:
            return ["permissions": requested, "scope": "session"]
        case .decline, .cancel:
            return ["permissions": [String: Any](), "scope": "turn"]
        }
    }

    private static func approvalTitle(for kind: AssistantRequestKind) -> String {
        switch kind {
        case .fileRead:
            return "File read approval"
        case .fileChange:
            return "File change approval"
        case .commandExecution:
            return "Command approval"
        default:
            return "Provider approval"
        }
    }

    static func codexAnswers(
        questionIds: [String],
        questionPromptsById: [String: String] = [:],
        multiSelectQuestionIds: Set<String> = [],
        text: String
    ) -> [String: [String: [String]]] {
        let structured = structuredAnswers(text)
        let answersById = structured.isEmpty
            ? splitUserInputAnswers(questionIds: questionIds, text: text)
            : Dictionary(questionIds.compactMap { id in
                let answer = structured[id] ?? questionPromptsById[id].flatMap { structured[$0] }
                return answer.map { (id, $0) }
            }, uniquingKeysWith: { first, _ in first })
        // Provider payloads can repeat a question id; first answer wins instead of trapping.
        return Dictionary(questionIds.map { id in
            let answer = answersById[id] ?? text
            return (id, ["answers": multiSelectQuestionIds.contains(id) ? splitMultiSelectAnswer(answer) : [answer]])
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func structuredAnswers(_ text: String) -> [String: String] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.compactMapValues { value in
            if let string = value as? String { return string }
            if let strings = value as? [String] { return strings.joined(separator: ", ") }
            return nil
        }
    }

    // PERF: multi-select user-input answers split on comma/semicolon/newline for
    // every Codex question resolve; share one separator CharacterSet instead of
    // allocating CharacterSet(charactersIn:) per answer.
    private static let multiSelectAnswerSeparators = CharacterSet(charactersIn: ",;\n")

    private static func splitMultiSelectAnswer(_ text: String) -> [String] {
        let parts = text.components(separatedBy: multiSelectAnswerSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text] : parts
    }

    private static func splitUserInputAnswers(questionIds: [String], text: String) -> [String: String] {
        guard questionIds.count > 1 else {
            return questionIds.first.map { [$0: text] } ?? [:]
        }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var mapped: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            let rawKey = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard questionIds.contains(rawKey), !value.isEmpty else { continue }
            mapped[rawKey] = value
        }
        if !mapped.isEmpty { return mapped }
        guard lines.count == questionIds.count else { return [:] }
        return Dictionary(Array(zip(questionIds, lines)), uniquingKeysWith: { first, _ in first })
    }

    private static func detailString(from payload: [String: Any]) -> String? {
        for key in ["command", "commandLine", "cmd", "path", "file", "summary"] {
            if let value = payload[key] as? String, !value.isEmpty { return value }
            if let values = payload[key] as? [String], !values.isEmpty { return values.joined(separator: " ") }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func approvalDetailString(from payload: [String: Any]) -> String? {
        for candidate in approvalPayloadCandidates(from: payload) {
            var fields: [(String, String)] = []
            if let command = approvalValue(candidate, keys: ["command", "commandLine", "cmd"]) {
                fields.append(("Command", command))
            }
            if let cwd = approvalValue(candidate, keys: ["cwd", "workingDirectory", "working_directory"]) {
                fields.append(("Cwd", cwd))
            }
            if let file = approvalValue(candidate, keys: ["path", "file"]) {
                fields.append(("File", file))
            }
            if let reason = approvalValue(candidate, keys: ["reason", "description", "summary"]) {
                fields.append(("Reason", reason))
            }
            if let changes = approvalValue(candidate, keys: ["changes", "patch"]) {
                fields.append(("Changes", changes))
            }
            if fields.count == 1 { return fields[0].1 }
            if !fields.isEmpty {
                return fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            }
        }
        return detailString(from: payload)
    }

    private static func realtimeDetail(from payload: [String: Any]) -> String? {
        let values = [
            string(payload, "realtimeSessionId").map { "Session: \($0)" },
            string(payload, "model").map { "Model: \($0)" },
            string(payload, "voice").map { "Voice: \($0)" }
        ].compactMap { $0 }
        return values.isEmpty ? jsonString(payload) : values.joined(separator: "\n")
    }

    private static func approvalPayloadCandidates(from payload: [String: Any]) -> [[String: Any]] {
        var candidates = [payload]
        for key in ["approval", "request", "action", "item", "command", "fileChange"] {
            if let nested = payload[key] as? [String: Any] {
                candidates.append(nested)
            }
        }
        return candidates
    }

    private static func approvalValue(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
            if let values = payload[key] as? [String], !values.isEmpty {
                return values.joined(separator: " ")
            }
            if let object = payload[key] as? [String: Any], let json = jsonString(object) {
                return json
            }
            if let array = payload[key] as? [Any], let json = jsonString(array) {
                return json
            }
        }
        return nil
    }

    private static func nestedString(_ payload: [String: Any], objectKey: String, field: String) -> String? {
        guard let object = payload[objectKey] as? [String: Any] else { return nil }
        return string(object, field)
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        if let value = value as? Int { return value != 0 }
        return nil
    }

    // P1: pure classifier mapping an app-server failure signal to a terminal
    // RunOutcome. Returns nil to keep the run alive (retry-able), or a `.failed`
    // outcome that the adapter turns into `finished(.failed)` immediately so a
    // fatal mid-turn error (e.g. auth death) does not leave a stuck spinner.
    // `isAuth` lets the UI surface a 'Sign in' CTA instead of a generic error.
    enum RunOutcome: Equatable {
        case failed(isAuth: Bool)
    }

    static func classifyFatalOutcome(eventKind: String, willRetry: Bool, errorCode: String?) -> RunOutcome? {
        switch eventKind {
        case "turn/failed", "turn.failed",
             "turn/completed-failed", "turn.completed-failed":
            // `turn/completed-failed` is the live wire path: app-server emits
            // turn/completed with turn.status=failed (not a separate method).
            return .failed(isAuth: isAuthErrorCode(errorCode))
        case "error":
            // Retry-able errors keep the run alive; the adapter still emits a
            // recoverable `.error` event for them.
            guard !willRetry else { return nil }
            return .failed(isAuth: isAuthErrorCode(errorCode))
        default:
            return nil
        }
    }

    /// Wire status on `turn/completed`: nested `turn.status` preferred, else top-level `status`.
    static func turnCompletedWireStatus(from payload: [String: Any]) -> String? {
        if let turn = payload["turn"] as? [String: Any],
           let status = string(turn, "status")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !status.isEmpty {
            return status
        }
        if let status = string(payload, "status")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !status.isEmpty {
            return status
        }
        return nil
    }

    static func isFailedTurnStatus(_ status: String?) -> Bool {
        status?.caseInsensitiveCompare("failed") == .orderedSame
    }

    static func isInterruptedTurnStatus(_ status: String?) -> Bool {
        status?.caseInsensitiveCompare("interrupted") == .orderedSame
    }

    /// Prefer nested `turn.error`, then top-level `error`, else the whole payload.
    static func turnFailedErrorPayload(from payload: [String: Any]) -> [String: Any] {
        if let turn = payload["turn"] as? [String: Any],
           let error = turn["error"] as? [String: Any] {
            return error
        }
        if let error = payload["error"] as? [String: Any] {
            return error
        }
        return payload
    }

    static func errorCode(from payload: [String: Any], error: [String: Any]) -> String? {
        for key in ["code", "errorCode", "error_code", "type", "kind", "status"] {
            if let value = error[key] as? String, !value.isEmpty { return value }
            if let value = payload[key] as? String, !value.isEmpty { return value }
            if let value = error[key] as? Int { return String(value) }
            if let value = payload[key] as? Int { return String(value) }
        }
        // Fall back to the human-readable message so auth death is still
        // recognized when no machine error code is provided.
        return (error["message"] as? String) ?? (payload["message"] as? String)
    }

    // P1: turns a terminal RunOutcome into the `finished(.failed)` event. For an
    // auth-class failure we prefix the message with a stable marker so the UI
    // layer can route to a 'Sign in' CTA instead of a generic failure banner.
    static func failedEvent(for outcome: RunOutcome, message: String, providerThreadId: String?) -> AgentRunEvent {
        switch outcome {
        case .failed(let isAuth):
            let finalMessage = isAuth ? "\(authFailureMarker) \(message)" : message
            return .finished(.failed, finalMessage: finalMessage, providerThreadId: providerThreadId)
        }
    }

    static let authFailureMarker = "[auth-required]"
    static let authActionMetadata: [String: Any] = [
        "kind": "signIn",
        "title": "Sign in",
        "command": "codex login"
    ]

    static func isAuthErrorCode(_ errorCode: String?) -> Bool {
        guard let errorCode else { return false }
        let normalized = errorCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let authMarkers = ["401", "unauthorized", "unauthenticated", "auth", "login", "credential", "token_expired", "expired_token", "invalid_api_key", "permission_denied", "forbidden", "403"]
        return authMarkers.contains { normalized.contains($0) }
    }

    private static func recoveryActiveTurnId(from extraArgs: [String]) -> String? {
        let prefix = "remotecode.recovery.activeTurnId="
        return extraArgs.compactMap { arg -> String? in
            guard arg.hasPrefix(prefix) else { return nil }
            let value = String(arg.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.first
    }

    private static func userInputPrompt(from questions: [[String: Any]]) -> String {
        let prompts = questions.compactMap { question -> String? in
            let header = question["header"] as? String
            let text = question["question"] as? String
            return [header, text]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ": ")
        }
        return prompts.isEmpty ? "Provider requested input." : prompts.joined(separator: "\n")
    }

    private static func mcpElicitationQuestions(from requestedSchema: [String: Any]?) -> [[String: Any]] {
        guard let properties = requestedSchema?["properties"] as? [String: Any] else { return [] }
        return properties.keys.sorted().compactMap { name in
            guard let schema = properties[name] as? [String: Any] else { return nil }
            let title = string(schema, "title") ?? name
            let description = string(schema, "description") ?? title
            var question: [String: Any] = [
                "id": name,
                "header": title,
                "question": description
            ]
            if let values = schema["enum"] as? [Any] {
                question["options"] = values.map { value in
                    ["label": String(describing: value), "description": String(describing: value)]
                }
            } else if string(schema, "type") == "boolean" {
                question["options"] = [
                    ["label": "true", "description": "Yes"],
                    ["label": "false", "description": "No"]
                ]
            }
            if let format = string(schema, "format") {
                question["inputType"] = format
            }
            return question
        }
    }

    private static func mcpElicitationContent(
        requestedSchema: [String: Any]?,
        questionIds: [String],
        text: String
    ) throws -> [String: Any] {
        let structured: [String: Any] = {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return object
        }()
        guard let properties = requestedSchema?["properties"] as? [String: Any],
              !properties.isEmpty else {
            return structured.isEmpty ? ["answer": text] : structured
        }
        var content: [String: Any] = [:]
        for name in questionIds {
            guard let property = properties[name] as? [String: Any] else { continue }
            let raw: Any?
            if let structuredValue = structured[name] {
                raw = structuredValue
            } else if questionIds.count == 1 {
                raw = text
            } else {
                raw = nil
            }
            guard let raw, let value = mcpElicitationValue(raw, type: string(property, "type")) else { continue }
            if let allowed = property["enum"] as? [Any],
               !allowed.contains(where: { String(describing: $0) == String(describing: value) }) {
                continue
            }
            content[name] = value
        }
        let required = requestedSchema?["required"] as? [String] ?? []
        if let missing = required.first(where: { content[$0] == nil }) {
            throw AgentProviderAdapterError.unsupported(
                "MCP elicitation requires a valid value for \(missing)"
            )
        }
        return content
    }

    private static func mcpElicitationValue(_ raw: Any, type: String?) -> Any? {
        switch type {
        case "boolean":
            if let value = raw as? Bool { return value }
            switch String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        case "integer":
            if let value = raw as? Int { return value }
            if let value = raw as? NSNumber { return value.intValue }
            return Int(String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines))
        case "number":
            if let value = raw as? NSNumber { return value.doubleValue }
            return Double(String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines))
        case "array":
            if let value = raw as? [Any] { return value }
            return String(describing: raw).split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        default:
            return raw is String ? raw : String(describing: raw)
        }
    }

    private static func userInputQuestions(from payload: [String: Any]) -> [[String: Any]] {
        for candidate in userInputPayloadCandidates(from: payload) {
            if let questions = candidate["questions"] as? [[String: Any]], !questions.isEmpty {
                return questions
            }
            if let question = candidate["question"] as? [String: Any] {
                return [question]
            }
            if let prompt = string(candidate, "prompt") ?? string(candidate, "question") {
                var question: [String: Any] = ["question": prompt]
                for key in ["id", "header", "options", "allowsMultipleSelection", "allowsMultiple", "multiple", "multiSelect", "isSecret", "secret", "sensitive", "inputType", "input_type", "type", "control"] {
                    if let value = candidate[key] {
                        question[key] = value
                    }
                }
                return [question]
            }
        }
        return []
    }

    private static func userInputPayloadCandidates(from payload: [String: Any]) -> [[String: Any]] {
        var candidates = [payload]
        for key in ["request", "input", "tool", "item", "params"] {
            if let nested = payload[key] as? [String: Any] {
                candidates.append(nested)
            }
        }
        return candidates
    }

    private static func userInputAllowsMultipleSelection(payload: [String: Any], questions: [[String: Any]]) -> Bool {
        let keys = ["allowsMultipleSelection", "allowsMultiple", "multiple", "multiSelect", "allows_multiple_selection", "allows_multiple", "multi_select"]
        for candidate in userInputPayloadCandidates(from: payload) + questions {
            for key in keys where boolValue(candidate[key]) == true {
                return true
            }
        }
        return false
    }

    private static func userInputMultiSelectQuestionIds(
        questions: [[String: Any]],
        fallbackQuestionIds: [String],
        aggregateAllowsMultipleSelection: Bool
    ) -> Set<String> {
        let keys = ["allowsMultipleSelection", "allowsMultiple", "multiple", "multiSelect", "allows_multiple_selection", "allows_multiple", "multi_select"]
        let explicit = Set(questions.compactMap { question -> String? in
            guard keys.contains(where: { boolValue(question[$0]) == true }) else { return nil }
            return string(question, "id")
        })
        if !explicit.isEmpty { return explicit }
        return aggregateAllowsMultipleSelection ? Set(fallbackQuestionIds) : []
    }

    private static func userInputOptions(from questions: [[String: Any]]) -> [String] {
        questions.flatMap { question -> [String] in
            guard let options = question["options"] as? [[String: Any]] else { return [] }
            return options.compactMap { $0["label"] as? String }
        }
    }

    private static func structuredUserInputQuestions(from questions: [[String: Any]]) -> [AssistantUserInputQuestion] {
        questions.enumerated().compactMap { index, question in
            guard let prompt = string(question, "question")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> AssistantUserInputOption? in
                guard let label = string(option, "label") else { return nil }
                return AssistantUserInputOption(label: label, detail: string(option, "description"))
            }
            return AssistantUserInputQuestion(
                id: string(question, "id") ?? "question-\(index)",
                prompt: prompt,
                header: string(question, "header"),
                options: options,
                allowsMultipleSelection: userInputAllowsMultipleSelection(payload: question, questions: [question])
            )
        }
    }

    private static func userInputIsSecret(_ questions: [[String: Any]]) -> Bool {
        questions.contains { question in
            if boolValue(question["isSecret"]) == true || boolValue(question["secret"]) == true || boolValue(question["sensitive"]) == true {
                return true
            }
            let raw = [
                string(question, "inputType"),
                string(question, "input_type"),
                string(question, "type"),
                string(question, "control")
            ]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return raw.contains("password") || raw.contains("secret") || raw.contains("token")
        }
    }

    private static func turnId(from response: CodexAppServerClient.JSONObject) -> String? {
        if let turn = response["turn"] as? [String: Any], let id = turn["id"] as? String {
            return id
        }
        return response["turnId"] as? String ?? response["turn_id"] as? String
    }

    private static func events(fromThreadReadResponse response: CodexAppServerClient.JSONObject, providerThreadId: String) -> [AssistantEvent] {
        let thread = response["thread"] as? [String: Any] ?? response
        let threadId = string(thread, "id") ?? string(thread, "threadId") ?? providerThreadId
        var events: [AssistantEvent] = [.threadStarted(threadId: threadId, providerThreadId: threadId)]
        if let usage = tokenUsage(from: thread) {
            events.append(.tokenUsage(usage))
        }
        if string(thread, "state") == "compacted" {
            events.append(.contextCompaction(summary: string(thread, "summary") ?? "Context compacted"))
        }
        let turns = thread["turns"] as? [[String: Any]] ?? []
        for turn in turns {
            guard let turnId = string(turn, "id") else { continue }
            events.append(runtimeEvent(method: "thread/read.turn", payload: ["turn": turn]))
            events.append(.turnStarted(turnId: turnId))
            let startedAtMs = milliseconds(fromSeconds: turn["startedAt"]) ?? Int64(Date().timeIntervalSince1970 * 1000)
            let items = turn["items"] as? [[String: Any]] ?? []
            var finalMessage: String?
            for item in items {
                events.append(runtimeEvent(method: "thread/read.item", payload: ["turnId": turnId, "item": item]))
                events.append(contentsOf: Self.events(fromThreadItem: item, turnId: turnId, startedAtMs: startedAtMs))
                if string(item, "type") == "plan",
                   let body = body(for: item, type: "plan"),
                   let markdown = proposedPlanMarkdown(in: body) {
                    let planId = string(item, "id") ?? "plan-\(turnId)"
                    events.append(.proposedPlan(AssistantProposedPlan(id: planId, turnId: turnId, markdown: markdown)))
                }
                let type = string(item, "type") ?? ""
                if isAssistantMessageItem(item, type: type),
                   let text = body(for: item, type: type),
                   !text.isEmpty {
                    finalMessage = text
                }
            }
            let status = string(turn, "status") ?? ""
            if status == "completed" || status == "failed" || status == "cancelled" || finalMessage != nil {
                events.append(.turnCompleted(turnId: turnId, finalMessage: finalMessage))
            }
        }
        return events
    }

    private static func turnIds(fromThreadReadResponse response: CodexAppServerClient.JSONObject) -> [String] {
        let thread = response["thread"] as? [String: Any] ?? response
        let turns = thread["turns"] as? [[String: Any]] ?? []
        return turns.compactMap { string($0, "id") }
    }

    private static func turnCompletedFinalMessage(from payload: [String: Any]) -> String? {
        for candidate in turnCompletedPayloadCandidates(from: payload) {
            if let text = stringBodyFallback(for: candidate)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
            if let items = candidate["items"] as? [[String: Any]] {
                for item in items.reversed() {
                    let type = string(item, "type") ?? ""
                    if isAssistantMessageItem(item, type: type),
                       let text = body(for: item, type: type)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty {
                        return text
                    }
                }
            }
        }
        return nil
    }

    private static func turnCompletedPayloadCandidates(from payload: [String: Any]) -> [[String: Any]] {
        var candidates = [payload]
        for key in ["turn", "message", "response", "result"] {
            if let nested = payload[key] as? [String: Any] {
                candidates.append(nested)
            }
        }
        return candidates
    }

    private static func events(fromThreadItem item: [String: Any], turnId: String, startedAtMs: Int64) -> [AssistantEvent] {
        let id = string(item, "id") ?? UUID().uuidString
        let type = string(item, "type") ?? "unknown"
        if isUserMessageItem(item, type: type) { return [] }
        let itemType = assistantItemType(for: type)
        let state = itemState(for: string(item, "status"))
        let summary = summary(for: item, type: type)
        let resourcePath: String? = {
            if itemType == .imageView { return string(item, "path") }
            if itemType == .fileChange {
                if let path = string(item, "path") ?? string(item, "file") { return path }
                if let changes = item["changes"] as? [[String: Any]],
                   let first = changes.first {
                    return string(first, "path") ?? string(first, "file")
                }
            }
            return nil
        }()
        var events: [AssistantEvent] = [
            .itemStarted(item: AssistantItem(
                id: id,
                turnId: turnId,
                type: itemType,
                state: state == .completed ? .streaming : state,
                summary: summary,
                resourcePath: resourcePath,
                startedAtMs: startedAtMs
            ))
        ]
        if let body = body(for: item, type: type), !body.isEmpty {
            if itemType == .assistantMessage {
                events.append(.itemDelta(itemId: id, bodyAppend: body, outputAppend: nil, summary: summary))
            } else {
                events.append(.itemDelta(itemId: id, bodyAppend: nil, outputAppend: body, summary: summary))
            }
        }
        events.append(.itemCompleted(itemId: id, finalState: state))
        if type == "contextCompaction" {
            events.append(.contextCompaction(summary: summary))
        }
        return events
    }

    private static func assistantItemType(for type: String) -> AssistantItemType {
        switch type {
        case "agentMessage", "assistantMessage", "agent_message", "assistant_message", "message": return .assistantMessage
        case "plan": return .plan
        case "reasoning", "reasoning_text", "summary_text": return .reasoning
        case "commandExecution", "command_execution", "local_shell_call", "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output": return .commandExecution
        case "fileChange", "file_change": return .fileChange
        case "mcpToolCall", "mcp_call": return .mcpToolCall
        case "dynamicToolCall", "imageGeneration": return .dynamicToolCall
        case "collabAgentToolCall": return .collabToolCall
        case "webSearch", "web_search_call", "tool_search_call", "tool_search_output", "search", "open_page", "find_in_page": return .webSearch
        case "imageView", "image_generation_call", "input_image": return .imageView
        case "enteredReviewMode", "exitedReviewMode": return .review
        case "contextCompaction", "context_compaction", "compaction", "compaction_trigger": return .contextCompaction
        default: return .tool
        }
    }

    private static func isUserMessageItem(_ item: [String: Any], type: String) -> Bool {
        switch type {
        case "userMessage", "user_message":
            return true
        case "message":
            return string(item, "role")?.caseInsensitiveCompare("user") == .orderedSame
        default:
            return false
        }
    }

    private static func isAssistantMessageItem(_ item: [String: Any], type: String) -> Bool {
        guard assistantItemType(for: type) == .assistantMessage else { return false }
        return !isUserMessageItem(item, type: type)
    }

    /// True only when Codex marks the item as the terminal final_answer phase.
    /// Never infer completion from ordinary assistantMessage text alone.
    nonisolated static func isFinalAnswerPhaseItem(_ item: [String: Any], type: String) -> Bool {
        guard isAssistantMessageItem(item, type: type) else { return false }
        let phase = (string(item, "phase") ?? string(item, "phaseType") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return phase.caseInsensitiveCompare("final_answer") == .orderedSame
            || phase.caseInsensitiveCompare("finalanswer") == .orderedSame
    }

    /// Authoritative turn terminal check from a thread/read response.
    nonisolated static func turnIsAuthoritativelyTerminal(
        in response: CodexAppServerClient.JSONObject,
        turnId: String
    ) -> Bool {
        let thread = response["thread"] as? [String: Any] ?? response
        let turns = thread["turns"] as? [[String: Any]] ?? []
        guard let turn = turns.first(where: { string($0, "id") == turnId }) else {
            // No turn id match: still allow idle thread status as authority.
            let state = (string(thread, "status") ?? string(thread, "state") ?? "").lowercased()
            return isIdleThreadStatus(state)
        }
        let status = (string(turn, "status") ?? "").lowercased()
        if status == "completed" || status == "failed" || status == "cancelled" || status == "interrupted" {
            return true
        }
        let state = (string(thread, "status") ?? string(thread, "state") ?? "").lowercased()
        return isIdleThreadStatus(state)
    }

    /// Final assistant text from an authoritative thread/read snapshot.
    nonisolated static func finalMessageFromThreadRead(
        _ response: CodexAppServerClient.JSONObject,
        turnId: String
    ) -> String? {
        let thread = response["thread"] as? [String: Any] ?? response
        let turns = thread["turns"] as? [[String: Any]] ?? []
        let turn = turns.first(where: { string($0, "id") == turnId }) ?? turns.last
        guard let turn else { return nil }
        let items = turn["items"] as? [[String: Any]] ?? []
        for item in items.reversed() {
            let type = string(item, "type") ?? ""
            if isAssistantMessageItem(item, type: type),
               let text = body(for: item, type: type)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func isRawResponseItemType(_ type: String) -> Bool {
        [
            "agentMessage", "assistantMessage", "agent_message", "assistant_message",
            "message", "reasoning", "reasoning_text", "summary_text",
            "local_shell_call", "function_call", "function_call_output",
            "custom_tool_call", "custom_tool_call_output", "mcp_call",
            "web_search_call", "tool_search_call", "tool_search_output",
            "search", "open_page", "find_in_page",
            "image_generation_call", "input_image",
            "context_compaction", "compaction", "compaction_trigger"
        ].contains(type)
    }

    private static func itemState(for status: String?) -> AssistantItemState {
        // Normalize camelCase / snake_case so wire enums match one switch.
        let normalized = status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        switch normalized {
        case "completed", "succeeded", "success", "approved":
            // GuardianApprovalReviewStatus.approved is a successful terminal review.
            return .completed
        case "failed", "blocked", "timedout", "errored", "error":
            // HookRunStatus.blocked and timed-out reviews are terminal failures.
            return .failed
        // User denial of command/fileChange approvals arrives as wire status
        // "declined" (openai/codex CommandExecutionStatus/PatchApplyStatus).
        // HookRunStatus.stopped and GuardianApprovalReviewStatus.aborted/denied
        // are user-or-system cancellations — not still-in-progress.
        // AssistantItemState has no .declined/.aborted; terminal cancel matches.
        case "cancelled", "canceled", "declined", "decline", "denied", "deny",
             "stopped", "aborted", "interrupted":
            return .cancelled
        default:
            // inProgress / running / pending / nil → keep streaming.
            return .streaming
        }
    }

    private static func summary(for item: [String: Any], type: String) -> String? {
        switch type {
        case "userMessage":
            return "User message"
        case "hookPrompt":
            return "Hook prompt"
        case "agentMessage", "assistantMessage", "agent_message", "assistant_message", "message":
            return "Assistant message"
        case "plan":
            return "Plan"
        case "reasoning", "reasoning_text", "summary_text":
            return joinedStrings(item["summary"]) ?? "Reasoning"
        case "commandExecution", "command_execution", "local_shell_call":
            return string(item, "command") ?? string(item, "status")
        case "function_call", "custom_tool_call":
            return string(item, "name") ?? string(item, "call_id") ?? "Tool call"
        case "function_call_output", "custom_tool_call_output":
            return string(item, "call_id") ?? "Tool output"
        case "fileChange", "file_change":
            if let changes = item["changes"] as? [[String: Any]] {
                return "\(changes.count) file change\(changes.count == 1 ? "" : "s")"
            }
            return "File change"
        case "mcpToolCall", "mcp_call":
            return [string(item, "server"), string(item, "tool"), string(item, "name")].compactMap { $0 }.joined(separator: ".")
        case "dynamicToolCall", "collabAgentToolCall":
            return string(item, "tool")
        case "webSearch", "web_search_call", "tool_search_call", "tool_search_output", "search", "open_page", "find_in_page":
            return string(item, "query") ?? string(item, "url") ?? string(item, "status") ?? "Web search"
        case "imageView":
            return string(item, "path").map { ($0 as NSString).lastPathComponent } ?? "Image"
        case "imageGeneration", "image_generation_call", "input_image":
            return string(item, "status") ?? "Image generation"
        case "enteredReviewMode", "exitedReviewMode":
            return "Review"
        case "contextCompaction", "context_compaction", "compaction", "compaction_trigger":
            return "Context compaction"
        default:
            return type
        }
    }

    private static func body(for item: [String: Any], type: String) -> String? {
        switch type {
        case "userMessage":
            return joinedStrings(item["content"]) ?? stringBodyFallback(for: item)
        case "hookPrompt":
            return joinedStrings(item["fragments"]) ?? stringBodyFallback(for: item)
        case "agentMessage", "assistantMessage", "agent_message", "assistant_message", "message", "plan":
            return string(item, "text")
                ?? joinedStrings(item["content"])
                ?? string(item, "planMarkdown")
                ?? string(item, "plan_markdown")
                ?? string(item, "markdown")
        case "reasoning", "reasoning_text", "summary_text":
            return joinedStrings(item["content"]) ?? stringBodyFallback(for: item)
        case "commandExecution", "command_execution", "local_shell_call":
            // aggregatedOutput is stdout and may be "" / omitted. Command stays
            // in summary; never copy it into the output body.
            if let aggregated = string(item, "aggregatedOutput") ?? string(item, "aggregated_output") {
                return aggregated
            }
            return stringBodyFallback(for: item)
        case "fileChange", "file_change":
            // Prefer human-readable patch/diff over opaque JSON so the Agent
            // App can paint a Cursor-style Edit card in the timeline.
            if let patch = string(item, "patch") ?? string(item, "diff") ?? string(item, "unified_diff"),
               !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return patch
            }
            if let changes = item["changes"] as? [[String: Any]] {
                var chunks: [String] = []
                for change in changes {
                    let path = string(change, "path") ?? string(change, "file") ?? "file"
                    if let diff = string(change, "diff") ?? string(change, "patch")
                        ?? string(change, "unified_diff") ?? string(change, "unifiedDiff"),
                       !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        chunks.append(diff)
                    } else if let oldS = string(change, "old_string"), let newS = string(change, "new_string") {
                        chunks.append("*** Update File: \(path)\n@@\n-\(oldS.replacingOccurrences(of: "\n", with: "\n-"))\n+\(newS.replacingOccurrences(of: "\n", with: "\n+"))")
                    }
                }
                if !chunks.isEmpty { return chunks.joined(separator: "\n") }
            }
            return jsonString(item["changes"]) ?? stringBodyFallback(for: item)
        case "mcpToolCall", "mcp_call":
            return jsonString(item["result"]) ?? (item["error"] as? [String: Any]).flatMap { string($0, "message") } ?? stringBodyFallback(for: item)
        case "function_call", "custom_tool_call":
            return jsonString(item["arguments"]) ?? string(item, "arguments") ?? stringBodyFallback(for: item)
        case "function_call_output", "custom_tool_call_output":
            return joinedStrings(item["output"]) ?? stringBodyFallback(for: item)
        case "dynamicToolCall":
            return jsonString(item["contentItems"]) ?? stringBodyFallback(for: item)
        case "collabAgentToolCall":
            return jsonString(item["agentsStates"]) ?? stringBodyFallback(for: item)
        case "webSearch", "web_search_call", "tool_search_call", "tool_search_output", "search", "open_page", "find_in_page":
            return jsonString(item["action"]) ?? stringBodyFallback(for: item)
        case "imageView":
            return nil
        case "imageGeneration", "image_generation_call", "input_image":
            return string(item, "result") ?? stringBodyFallback(for: item)
        case "enteredReviewMode", "exitedReviewMode":
            return string(item, "review") ?? stringBodyFallback(for: item)
        default:
            return stringBodyFallback(for: item) ?? jsonString(item)
        }
    }

    private static func stringBodyFallback(for item: [String: Any]) -> String? {
        for key in ["finalMessage", "final_message", "final", "answer", "text", "message", "output", "content", "result", "summary", "details", "detail", "path", "url", "query"] {
            if let value = joinedStrings(item[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func joinedStrings(_ value: Any?) -> String? {
        if let values = value as? [String] {
            return values.joined(separator: "\n")
        }
        if let values = value as? [[String: Any]] {
            let strings = values.compactMap { value -> String? in
                for key in ["text", "message", "content", "output", "summary"] {
                    if let text = joinedStrings(value[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty {
                        return text
                    }
                }
                return jsonString(value)
            }
            return strings.isEmpty ? nil : strings.joined(separator: "\n")
        }
        return value as? String
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func milliseconds(fromSeconds value: Any?) -> Int64? {
        if let value = value as? Double { return Int64(value * 1000) }
        if let value = value as? Int { return Int64(value * 1000) }
        return nil
    }

    private static func proposedPlanMarkdown(from payload: [String: Any], fallback: String?) -> String? {
        for key in ["planMarkdown", "plan_markdown", "markdown", "text"] {
            if let markdown = string(payload, key), !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return proposedPlanMarkdown(in: markdown) ?? markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let fallback else { return nil }
        return proposedPlanMarkdown(in: fallback) ?? fallback.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func proposedPlanMarkdown(in text: String) -> String? {
        guard let start = text.range(of: "<proposed_plan>"),
              let end = text.range(of: "</proposed_plan>", range: start.upperBound..<text.endIndex) else { return nil }
        let markdown = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return markdown.isEmpty ? nil : markdown
    }

    private static func activePlan(from payload: [String: Any], now: Int64) -> AssistantActivePlan? {
        let update = payload["update"] as? [String: Any]
        let rawSteps = payload["plan"] as? [[String: Any]]
            ?? payload["steps"] as? [[String: Any]]
            ?? update?["plan"] as? [[String: Any]]
            ?? update?["steps"] as? [[String: Any]]
        guard let rawSteps, !rawSteps.isEmpty else { return nil }
        let steps = rawSteps.enumerated().compactMap { index, raw -> AssistantPlanStep? in
            let title = string(raw, "step") ?? string(raw, "title") ?? string(raw, "text") ?? string(raw, "content") ?? ""
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let statusRaw = string(raw, "status") ?? "pending"
            let status = AssistantPlanStepStatus(rawValue: statusRaw)
                ?? (statusRaw == "inProgress" ? .inProgress : .pending)
            let id = string(raw, "id") ?? "\(index)-\(trimmed)"
            return AssistantPlanStep(id: id, title: trimmed, status: status)
        }
        guard !steps.isEmpty else { return nil }
        return AssistantActivePlan(
            explanation: string(payload, "explanation") ?? update.flatMap { string($0, "explanation") },
            steps: steps,
            updatedAtMs: now
        )
    }

    private static func providerTurnId(from payload: [String: Any]) -> String? {
        string(payload, "turnId")
            ?? string(payload, "turn_id")
            ?? nestedString(payload, objectKey: "turn", field: "id")
    }

    private static func providerItemId(from payload: [String: Any]) -> String? {
        string(payload, "itemId")
            ?? string(payload, "item_id")
            ?? nestedString(payload, objectKey: "item", field: "id")
    }

    private static func providerRequestId(from payload: [String: Any]) -> String? {
        string(payload, "requestId")
            ?? string(payload, "request_id")
            ?? nestedString(payload, objectKey: "request", field: "id")
    }

    private static func tokenUsage(from payload: [String: Any]) -> AssistantTokenUsage? {
        let container = payload["tokenUsage"] as? [String: Any] ?? payload["usage"] as? [String: Any] ?? payload
        let last = container["last"] as? [String: Any]
        let total = container["total"] as? [String: Any]
        // Prefer per-turn `last` for reported input/output/totalTokens (existing
        // cost accounting contract). Keep that source unchanged.
        let source = last ?? total ?? container
        let input = int(source["inputTokens"]) ?? int(source["input_tokens"]) ?? 0
        let output = int(source["outputTokens"]) ?? int(source["output_tokens"]) ?? 0
        let totalTokens = int(source["totalTokens"]) ?? int(source["total_tokens"]) ?? int(container["usedTokens"]) ?? (input + output)
        guard totalTokens > 0 || input > 0 || output > 0 else { return nil }
        let cached = int(source["cachedInputTokens"])
            ?? int(source["cached_input_tokens"])
            ?? int(total?["cachedInputTokens"])
            ?? int(total?["cached_input_tokens"])
            ?? int(container["cachedInputTokens"])
            ?? int(container["cached_input_tokens"])
            ?? 0
        let cacheWrite = int(source["cacheWriteInputTokens"])
            ?? int(source["cache_write_input_tokens"])
            ?? int(total?["cacheWriteInputTokens"])
            ?? int(total?["cache_write_input_tokens"])
            ?? int(container["cacheWriteInputTokens"])
            ?? int(container["cache_write_input_tokens"])
            ?? 0
        let contextWindow = int(container["modelContextWindow"]) ?? int(container["contextWindow"]) ?? int(container["maxTokens"])
        let reportedCostMicros = costMicros(from: source) ?? costMicros(from: container)
        // Context occupancy is always the per-turn `last` bucket when present.
        // Never use session-cumulative `total` (can be tens of millions).
        let contextTokens: Int?
        if let last {
            let lastInput = int(last["inputTokens"]) ?? int(last["input_tokens"]) ?? 0
            let lastOutput = int(last["outputTokens"]) ?? int(last["output_tokens"]) ?? 0
            let lastTotal = int(last["totalTokens"]) ?? int(last["total_tokens"]) ?? (lastInput + lastOutput)
            contextTokens = (lastTotal > 0 || lastInput > 0 || lastOutput > 0) ? lastTotal : nil
        } else if total == nil {
            // Flat per-request shape (no last/total split).
            contextTokens = totalTokens > 0 ? totalTokens : nil
        } else {
            contextTokens = nil
        }
        return AssistantTokenUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: totalTokens,
            contextWindow: contextWindow,
            compactsAutomatically: true,
            uncachedInputTokens: max(0, input - cached),
            cacheCreationInputTokens: cacheWrite,
            cacheReadInputTokens: cached,
            reportedCostMicros: reportedCostMicros,
            contextTokens: contextTokens,
            semantics: .cumulative
        )
    }

    /// `thread/goal/updated` carries the full goal state. Real wire values
    /// (openai/codex `v2::ThreadGoalStatus`, camelCase JSON): `active`, `paused`,
    /// `blocked`, `usageLimited`, `budgetLimited`, `complete` — verified against
    /// codex-rs/app-server-protocol/schema/typescript/v2/ThreadGoalStatus.ts and
    /// codex-rs/state/src/model/thread_goal.rs's `ThreadGoalStatus::is_terminal`
    /// (only `BudgetLimited` / `Complete` are terminal there). `paused`,
    /// `blocked`, and `usageLimited` are the goal runtime's own recoverable
    /// pauses (turn error, empty response, hitting a usage/rate limit —
    /// `stop_active_goal_for_turn` in codex-rs/ext/goal/src/runtime.rs) that it
    /// auto-resumes back to `active` (`continue_if_idle`) once cleared, so a
    /// goal in one of those states is NOT over. A missing status still means a
    /// goal exists. Name/allow-list previously guessed "running"/"inProgress"/
    /// "in_progress", none of which the real protocol ever sends, while
    /// treating the genuinely-recoverable `paused`/`blocked`/`usageLimited`
    /// wire values as "goal over" — undoing goalActive's whole point the
    /// moment a goal hit a rate limit mid-loop (live 2026-09-14).
    private static func isNonTerminalGoalStatus(from payload: [String: Any]) -> Bool {
        let goal = payload["goal"] as? [String: Any] ?? payload
        guard let status = string(goal, "status")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
        else { return true }
        return status != "complete" && status != "budgetlimited" && status != "budget_limited"
    }

    private static func goalDetail(from payload: [String: Any]) -> String {
        let goal = payload["goal"] as? [String: Any] ?? payload
        var lines: [String] = []
        if let objective = string(goal, "objective") {
            lines.append("Objective: \(objective)")
        }
        if let status = string(goal, "status") {
            lines.append("Status: \(status)")
        }
        if let tokensUsed = int(goal["tokensUsed"]) ?? int(goal["tokens_used"]) {
            if let tokenBudget = int(goal["tokenBudget"]) ?? int(goal["token_budget"]) {
                lines.append("Tokens: \(tokensUsed) / \(tokenBudget)")
            } else {
                lines.append("Tokens: \(tokensUsed)")
            }
        }
        if let seconds = int(goal["timeUsedSeconds"]) ?? int(goal["time_used_seconds"]) {
            lines.append("Time: \(seconds)s")
        }
        return lines.joined(separator: "\n").nilIfEmpty ?? (jsonString(goal) ?? "Goal updated")
    }

    private static func rateLimitWarning(from payload: [String: Any]) -> String? {
        let rateLimits = payload["rateLimits"] as? [String: Any] ?? payload["rate_limits"] as? [String: Any] ?? payload
        let snapshot = rateLimits["primary"] as? [String: Any] ?? rateLimits
        let reached = string(rateLimits, "rateLimitReachedType") ?? string(rateLimits, "rate_limit_reached_type")
        let limitName = string(rateLimits, "limitName") ?? string(rateLimits, "limit_name") ?? string(snapshot, "name")
        let reset = string(snapshot, "resetsAt") ?? string(snapshot, "resets_at")
        guard reached != nil || limitName != nil || reset != nil else { return nil }
        var message = "Codex rate limit update"
        if let reached { message += ": \(reached)" }
        if let limitName { message += " (\(limitName))" }
        if let reset { message += " resets \(reset)" }
        return message
    }

    private static func accountUsage(from payload: [String: Any]) -> AssistantAccountUsage? {
        AssistantAccountUsageParser.codex(from: payload)
    }

    private static func threadStatusDetail(from payload: [String: Any]) -> String {
        let status = payload["status"] as? [String: Any] ?? payload
        let type = string(status, "type") ?? string(payload, "status") ?? "unknown"
        let flags = joinedStrings(status["activeFlags"]) ?? joinedStrings(status["active_flags"])
        return [type, flags.map { "Flags: \($0)" }].compactMap { $0?.nilIfEmpty }.joined(separator: "\n")
    }

    private static func threadStatusType(from payload: [String: Any]) -> String? {
        let status = payload["status"] as? [String: Any] ?? payload
        return (string(status, "type") ?? string(payload, "status"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    private static func isActiveThreadStatus(_ statusType: String?) -> Bool {
        guard let statusType else { return false }
        return statusType == "active"
    }

    private static func isIdleThreadStatus(_ statusType: String) -> Bool {
        statusType == "idle"
    }

    private static func isFailedUnforkableThreadStatus(_ statusType: String?) -> Bool {
        statusType == "systemerror"
    }

    private static func hookDetail(from payload: [String: Any]) -> String? {
        let entries = payload["entries"] as? [[String: Any]]
        let entryText = entries?.compactMap { string($0, "text") }.joined(separator: "\n")
        let parts = [
            string(payload, "eventName").map { "Event: \($0)" },
            string(payload, "handlerType").map { "Handler: \($0)" },
            string(payload, "status").map { "Status: \($0)" },
            string(payload, "statusMessage"),
            entryText
        ]
        return parts.compactMap { $0?.nilIfEmpty }.joined(separator: "\n").nilIfEmpty
    }

    private static func approvalReviewDetail(from payload: [String: Any]) -> String? {
        let parts = [
            string(payload, "status").map { "Status: \($0)" },
            string(payload, "riskLevel").map { "Risk: \($0)" },
            string(payload, "userAuthorization").map { "User authorization: \($0)" },
            string(payload, "rationale")
        ]
        return parts.compactMap { $0?.nilIfEmpty }.joined(separator: "\n").nilIfEmpty
    }

    private static func decodedBase64String(_ value: Any?) -> String? {
        guard let encoded = value as? String,
              let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        return decoded
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func costMicros(from payload: [String: Any]) -> Int? {
        if let usd = double(payload["costUSD"] ?? payload["cost_usd"] ?? payload["totalCostUSD"] ?? payload["total_cost_usd"]),
           usd.isFinite, usd >= 0 {
            let micros = (usd * 1_000_000).rounded()
            guard micros <= Double(Int.max) else { return nil }
            return Int(micros)
        }
        if let ticks = double(payload["cost_in_usd_ticks"] ?? payload["costInUsdTicks"]),
           ticks.isFinite, ticks >= 0 {
            let micros = (ticks / 10_000).rounded()
            guard micros <= Double(Int.max) else { return nil }
            return Int(micros)
        }
        return nil
    }

    private static func string(_ payload: [String: Any], _ key: String) -> String? {
        payload[key] as? String
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
