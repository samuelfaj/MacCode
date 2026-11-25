import Foundation
import CoreModel
import CryptoKit
import Persistence

struct ClaudeSDKSessionRecord: Sendable, Equatable {
    let sessionId: String
    let customTitle: String?
}

protocol ClaudeSDKSessionMutating: Sendable {
    func listSessions() async throws -> [ClaudeSDKSessionRecord]
    func forkSession(sourceSessionId: String, title: String) async throws -> String
    func deleteSession(sessionId: String) async throws
}

enum ClaudeForkReconciliationError: Error, Equatable, CustomStringConvertible {
    case markerConflictCleaned(marker: String, childIds: [String])
    case invalidForkResult(childId: String)
    case cleanupFailed(marker: String, details: String)

    var description: String {
        switch self {
        case .markerConflictCleaned(let marker, let childIds):
            return "Claude fork marker conflict was cleaned for \(marker): \(childIds.joined(separator: ", "))"
        case .invalidForkResult(let childId):
            return "Claude native fork returned an invalid child session: \(childId)"
        case .cleanupFailed(let marker, let details):
            return "Claude fork cleanup failed for \(marker): \(details)"
        }
    }
}

public final class ClaudeAgentSDKBridgeAdapter: AgentProviderAdapter, @unchecked Sendable {
    // Pin stays on 0.3.157: the bridge launches the live `claude` binary via
    // pathToClaudeCodeExecutable, so CLI-side protocol (init errors, drain,
    // MCP wait) already follows the installed CLI. Bump only when a typed JS
    // API field is proven required (CLAUDE-SDK-002).
    static let defaultSDKPackageSpec = "@anthropic-ai/claude-agent-sdk@0.3.157"
    static let bridgeProtocolVersion = 3
    static let defaultSDKVersion = "0.3.157"
    // The SDK's real runtime dependencies are declared as peerDependencies plus
    // a platform-gated native optionalDependency (the ~205MB `claude` engine).
    // npm does NOT install these deterministically across versions/configs, so
    // we name them EXPLICITLY and pin the exact versions that
    // @anthropic-ai/claude-agent-sdk@<defaultSDKVersion> resolves to. These pins
    // are SDK-version-derived (identical on every machine) — NOT machine-specific.
    // The platform-native package name is computed from the running Node's
    // process.platform/arch at runtime (see nodePlatformArch), never hardcoded.
    static let defaultRuntimePeerSpecs = [
        "zod@4.4.3",
        "@anthropic-ai/sdk@0.98.0",
        "@modelcontextprotocol/sdk@1.29.0",
    ]
    static let minimumNodeMajorVersion = 18
    // Process-lifetime memoization for stable machine facts so provisioning
    // checks do not re-spawn `node`/`npm` or re-glob version-manager dirs on
    // every turn.
    private static let runtimeResolveLock = NSLock()
    private static var resolvedToolPaths: [String: String] = [:]
    private static var cachedPlatformArch: [String: String] = [:]
    private static var cachedPeerSpecs: [String: [String]] = [:]
    private static var cachedNodeMajor: [String: Int] = [:]
    // No-progress (stall) install timeout in seconds: the deadline resets on npm
    // output, so a slow-but-progressing 205MB fetch is not killed, while a truly
    // hung fetch is. Backstop bounds total wall-clock.
    nonisolated static func installStallSeconds() -> Double { 90 }
    nonisolated static func installBackstopSeconds() -> Double { 900 }

    private final class Session: @unchecked Sendable {
        let threadId: AgentThreadID
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        let parser = ClaudeParser()
        let lineBuffer = LineBuffer()
        // Serializes the stdout readabilityHandler against finishTerminated's
        // EOF drain: nil-ing a readabilityHandler does not wait for a callback
        // already running, and LineBuffer is not thread-safe. Taken BEFORE the
        // fd read so byte order is preserved across the two readers.
        let stdoutReadLock = NSLock()
        let writeQueue = DispatchQueue(label: "remotecode.claude-sdk.write")
        var events: [AssistantEvent] = []
        var status: AgentRunStatus = .running
        var providerThreadId: String?
        var model: String
        var permissionMode: AgentPermissionMode
        var interactionMode: AgentInteractionMode
        let reasoningEffort: AgentReasoningEffort?
        var activeTurnId: String?
        var completedTurnIds: [String] = []
        var inFlightRunId: AgentRunID?
        var onEvent: (@Sendable (AgentRunEvent) -> Void)?
        var sawError = false
        var pendingRequestIds = Set<String>()
        var pendingUserInputIds = Set<String>()
        var bridgeUserInputIds = Set<String>()
        var bridgeUserInputSchemas: [String: [String: Any]] = [:]
        var cancellationRequested = false
        let claudeExecutablePath: String?
        // Bounded raw stderr tail, retained so the terminal diagnostic can carry
        // the REAL Node failure reason (e.g. ERR_MODULE_NOT_FOUND / native binary
        // not found) instead of a bare "exited with status N". Caller guards
        // access with the adapter lock.
        var recentStderr = Data()
        func appendStderr(_ data: Data) {
            recentStderr.append(data)
            let cap = 8192
            if recentStderr.count > cap {
                recentStderr.removeFirst(recentStderr.count - cap)
            }
        }

        init(threadId: AgentThreadID,
             process: Process,
             stdinPipe: Pipe,
             stdoutPipe: Pipe,
             stderrPipe: Pipe,
             model: String,
             permissionMode: AgentPermissionMode,
             interactionMode: AgentInteractionMode,
             reasoningEffort: AgentReasoningEffort?,
             providerThreadId: String?,
             claudeExecutablePath: String?) {
            self.threadId = threadId
            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.model = model
            self.permissionMode = permissionMode
            self.interactionMode = interactionMode
            self.reasoningEffort = reasoningEffort
            self.providerThreadId = providerThreadId
            self.claudeExecutablePath = claudeExecutablePath
        }
    }

    public let provider: AgentProvider = .claude
    private let nodeBinary: String
    /// Optional explicit path (tests / RC_CLAUDE_AGENT_SDK_BRIDGE). Never store
    /// a compile-time `#filePath` default — that bakes CI absolute paths into
    /// release binaries and breaks customer machines.
    private let bridgeScriptPathOverride: String?
    private let binaryNameOverride: String?
    private let maxReadableEvents: Int
    private let interruptGracePeriod: TimeInterval
    private let sessionMutator: ClaudeSDKSessionMutating?
    /// Single-flight first-run `npm install` per cache directory + package spec
    /// so concurrent Claude starts cannot interleave node_modules.
    private static let sdkInstallTasksLock = NSLock()
    private static var sdkInstallTasks: [String: Task<Void, Error>] = [:]
    private let lock = NSLock()
    private let cancellationQueue = DispatchQueue(
        label: "io.remotecode.agent.claude-sdk-cancellation",
        qos: .userInitiated
    )
    private let bridgeCloseGracePeriod: TimeInterval = 0.25
    private var sessions: [AgentThreadID: Session] = [:]
    private var recoveredEvents: [AgentThreadID: [AssistantEvent]] = [:]
    private var rollbackResumeSessionAt: [AgentThreadID: String] = [:]
    private var rollbackProviderThreadIds: [AgentThreadID: String] = [:]

    public convenience init(
        nodeBinary: String = "node",
        bridgeScriptPath: String? = nil,
        binaryNameOverride: String? = nil,
        maxReadableEvents: Int = 5_000,
        interruptGracePeriod: TimeInterval = 2
    ) {
        self.init(
            nodeBinary: nodeBinary,
            bridgeScriptPath: bridgeScriptPath,
            binaryNameOverride: binaryNameOverride,
            maxReadableEvents: maxReadableEvents,
            interruptGracePeriod: interruptGracePeriod,
            sessionMutator: nil
        )
    }

    init(
        nodeBinary: String = "node",
        bridgeScriptPath: String? = nil,
        binaryNameOverride: String? = nil,
        maxReadableEvents: Int = 5_000,
        interruptGracePeriod: TimeInterval = 2,
        sessionMutator: ClaudeSDKSessionMutating?
    ) {
        self.nodeBinary = nodeBinary
        self.bridgeScriptPathOverride = bridgeScriptPath
            ?? ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_BRIDGE"]
        self.binaryNameOverride = binaryNameOverride
        self.maxReadableEvents = max(1, maxReadableEvents)
        self.interruptGracePeriod = max(0, interruptGracePeriod)
        self.sessionMutator = sessionMutator
    }

    /// Runtime-resolved source path for the Node bridge script.
    private var bridgeScriptPath: String {
        ClaudeAgentSDKBridgeLocator.resolvePath(override: bridgeScriptPathOverride)
            ?? ClaudeAgentSDKBridgeLocator.notFoundMessage(override: bridgeScriptPathOverride)
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await listModelsResult().models
    }

    public func listModelsResult(
        environment: [String: String] = [:],
        cwd: String = FileManager.default.currentDirectoryPath,
        runAsUser: AgentRunAsUser? = nil
    ) async -> ModelListResult {
        await ClaudeRunner(binaryNameOverride: binaryNameOverride).listModelsResult(
            environment: environment,
            cwd: cwd,
            runAsUser: runAsUser
        )
    }

    public var forkSafety: AgentProviderForkSafety {
        guard sessionMutator != nil || Self.installedForkProtocolSupported(bridgeScriptPath: bridgeScriptPathOverride) else {
            return .unsupported
        }
        return .keyedIdempotent(compensationSupported: true)
    }

    public func forkSafety(threadId: AgentThreadID) -> AgentProviderForkSafety {
        forkSafety
    }

    public func forkThread(threadId: AgentThreadID) async throws -> String {
        throw AgentProviderAdapterError.unsupported(
            "unkeyed Claude fork is unsafe; use the durable AgentProviderForkRequest path"
        )
    }

    public func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
        guard forkSafety(threadId: request.sourceThreadId).supportsDurableFork else {
            throw AgentProviderAdapterError.unsupported("Claude SDK fork reconciliation contract is unavailable")
        }
        let (sourceSessionId, hasActiveTurn) = forkSourceSnapshot(threadId: request.sourceThreadId)
        guard let sourceSessionId, !sourceSessionId.isEmpty else {
            throw AgentProviderAdapterError.sessionNotFound(request.sourceThreadId)
        }
        if let expectedSourceId = request.sourceProviderThreadId,
           !expectedSourceId.isEmpty,
           expectedSourceId != sourceSessionId {
            throw AgentProviderAdapterError.unsupported("Claude SDK recovered the wrong parent session for fork")
        }
        guard !hasActiveTurn else {
            throw AgentProviderAdapterError.unsupported("Claude SDK cannot fork while the parent turn is active")
        }

        let marker = Self.forkMarker(for: request)
        let existing = try await forkMarkerMatches(marker)
        if !existing.isEmpty {
            if existing.count == 1, let child = existing.first, child.sessionId != sourceSessionId {
                return child.sessionId
            }
            try await cleanForkMarkerConflict(existing, marker: marker, protectedSessionId: sourceSessionId)
            throw ClaudeForkReconciliationError.markerConflictCleaned(
                marker: marker,
                childIds: existing.map(\.sessionId).sorted()
            )
        }

        let childId = try await nativeForkSession(sourceSessionId: sourceSessionId, title: marker)
        guard !childId.isEmpty, childId != sourceSessionId else {
            throw ClaudeForkReconciliationError.invalidForkResult(childId: childId)
        }
        let reconciled = try await forkMarkerMatches(marker)
        // Single-element check — avoids count + first double scan on this path.
        guard reconciled.count == 1, reconciled[reconciled.startIndex].sessionId == childId else {
            var cleanupTargets = reconciled
            if !cleanupTargets.contains(where: { $0.sessionId == childId }) {
                cleanupTargets.append(ClaudeSDKSessionRecord(sessionId: childId, customTitle: marker))
            }
            try await cleanForkMarkerConflict(cleanupTargets, marker: marker, protectedSessionId: sourceSessionId)
            throw ClaudeForkReconciliationError.invalidForkResult(childId: childId)
        }
        return childId
    }

    public func compensateFork(
        _ request: AgentProviderForkRequest,
        providerChildThreadId: String
    ) async throws {
        guard forkSafety(threadId: request.sourceThreadId).supportsCompensation else {
            throw AgentProviderAdapterError.unsupported("Claude SDK fork compensation contract is unavailable")
        }
        let sessions = try await nativeListSessions()
        let marker = Self.forkMarker(for: request)
        var targets = sessions.filter {
            $0.customTitle == marker && $0.sessionId != request.sourceProviderThreadId
        }
        if targets.isEmpty,
           let recorded = sessions.first(where: { $0.sessionId == providerChildThreadId }) {
            targets = [recorded]
        }
        for target in targets {
            do {
                try await nativeDeleteSession(sessionId: target.sessionId)
            } catch {
                throw ClaudeForkReconciliationError.cleanupFailed(
                    marker: marker,
                    details: "session \(target.sessionId) could not be deleted: \(error)"
                )
            }
        }
    }

    private static func forkMarker(for request: AgentProviderForkRequest) -> String {
        "MacCode fork \(request.idempotencyKey)"
    }

    private func forkSourceSnapshot(threadId: AgentThreadID) -> (sessionId: String?, hasActiveTurn: Bool) {
        lock.lock(); defer { lock.unlock() }
        let session = sessions[threadId]
        return (session?.providerThreadId, session?.inFlightRunId != nil)
    }

    public static func installedForkProtocolSupported(bridgeScriptPath: String? = nil) -> Bool {
        let configuredBridge = ClaudeAgentSDKBridgeLocator.resolvePath(
            override: bridgeScriptPath
                ?? ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_BRIDGE"]
        )
        guard let configuredBridge,
              bridgeSupportsNativeSessionMutation(at: configuredBridge) else { return false }
        let bridgeURL = URL(fileURLWithPath: configuredBridge)
        let localSDK = bridgeURL.deletingLastPathComponent()
            .appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk", isDirectory: true)
        if FileManager.default.fileExists(atPath: localSDK.appendingPathComponent("package.json").path) {
            return installedSDKForkContract(at: localSDK)
        }

        let cacheRoot: URL
        if let override = ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_CACHE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            cacheRoot = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            cacheRoot = root
                .appendingPathComponent("RemoteCode", isDirectory: true)
                .appendingPathComponent("AgentRuntime", isDirectory: true)
                .appendingPathComponent("ClaudeAgentSDKBridge", isDirectory: true)
        }
        return installedSDKForkContract(
            at: cacheRoot.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk", isDirectory: true)
        )
    }

    private static func bridgeSupportsNativeSessionMutation(at path: String) -> Bool {
        guard pinnedNPMVersion(in: sdkPackageSpec()) == "0.3.157",
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), let source = String(data: data, encoding: .utf8) else {
            return false
        }
        return source.contains("const BRIDGE_PROTOCOL_VERSION = 3")
            && source.contains("claudeSDK.forkSession")
            && source.contains("claudeSDK.listSessions")
            && source.contains("claudeSDK.deleteSession")
    }

    private static func installedSDKForkContract(at sdkDirectory: URL) -> Bool {
        guard installedSDKPackage(
            at: sdkDirectory.appendingPathComponent("package.json"),
            matches: sdkPackageSpec()
        ), let declarations = try? String(
            contentsOf: sdkDirectory.appendingPathComponent("sdk.d.ts"),
            encoding: .utf8
        ) else {
            return false
        }
        return declarations.contains("function forkSession")
            && declarations.contains("function listSessions")
            && declarations.contains("function deleteSession")
    }

    private func forkMarkerMatches(_ marker: String) async throws -> [ClaudeSDKSessionRecord] {
        try await nativeListSessions().filter { $0.customTitle == marker }
    }

    private func cleanForkMarkerConflict(
        _ sessions: [ClaudeSDKSessionRecord],
        marker: String,
        protectedSessionId: String
    ) async throws {
        for session in sessions where session.sessionId != protectedSessionId {
            do {
                try await nativeDeleteSession(sessionId: session.sessionId)
            } catch {
                throw ClaudeForkReconciliationError.cleanupFailed(
                    marker: marker,
                    details: "session \(session.sessionId) could not be deleted: \(error)"
                )
            }
        }
    }

    public func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    public func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try Self.validateAttachments(request.attachments)
        let session = try await sessionForAsync(request, provisioningCallback: onEvent)
        lock.lock()
        if session.inFlightRunId != nil {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK bridge already has an in-flight turn")
        }
        session.onEvent = onEvent
        session.inFlightRunId = request.runId
        session.sawError = false
        session.status = .running
        session.cancellationRequested = false
        lock.unlock()

        do {
            let writeTurn = {
                var payload: [String: Any] = [
                    "type": "rc_turn",
                    "prompt": request.providerPrompt,
                    "attachments": Self.attachmentPayload(request.attachments),
                    "session_id": session.providerThreadId ?? request.threadId.value.uuidString,
                    "mcp_servers": Self.botPeerMCPServers(environment: request.environment),
                    "allowed_tools": ClaudeRunner.automaticallyAllowedTools(environment: request.environment)
                ]
                if let turnContext = request.environment[BotPeerDelegation.turnContextEnvironmentKey]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !turnContext.isEmpty {
                    payload["turn_context"] = turnContext
                }
                try self.write(payload, to: session)
            }
            if let acceptancePermit = request.acceptancePermit {
                try acceptancePermit.withAcceptance(writeTurn)
            } else {
                try writeTurn()
            }
        } catch {
            lock.lock()
            if session.inFlightRunId == request.runId {
                session.inFlightRunId = nil
                session.onEvent = nil
                session.status = .failed
            }
            lock.unlock()
            invalidateSessionAfterControlWriteFailure(session)
            throw error
        }
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: session.process) { [weak self] in
            try? self?.requestCancellation(threadId: request.threadId)
        }
    }

    public func interruptTurn(threadId: AgentThreadID) throws {
        try requestCancellation(threadId: threadId)
    }

    private func requestCancellation(threadId: AgentThreadID) throws {
        lock.lock()
        let session = sessions[threadId]
        session?.cancellationRequested = true
        lock.unlock()
        guard let session else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        do {
            try write(["type": "rc_interrupt"], to: session)
        } catch {
            try? stopSession(threadId: threadId)
            throw error
        }
        cancellationQueue.asyncAfter(deadline: .now() + interruptGracePeriod) { [weak self, weak session] in
            guard let self, let session else { return }
            self.lock.lock()
            let stillRunning = self.sessions[threadId] === session && session.inFlightRunId != nil
            self.lock.unlock()
            if stillRunning { try? self.stopSession(threadId: threadId) }
        }
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard session.pendingRequestIds.contains(requestId) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK request not found: \(requestId)")
        }
        lock.unlock()
        var payload: [String: Any] = [
            "type": "permission_response",
            "request_id": requestId,
            "decision": Self.permissionDecision(for: response)
        ]
        if case .decline(let reason) = response, let reason, !reason.isEmpty {
            payload["message"] = reason
        }
        do {
            try write(payload, to: session)
        } catch {
            invalidateSessionAfterControlWriteFailure(session)
            throw error
        }
        lock.lock(); session.pendingRequestIds.remove(requestId); lock.unlock()
        let resolved = AssistantEvent.requestResolved(requestId: requestId, state: Self.requestState(for: response))
        record(resolved, session: session)
        emit(.event(resolved), session: session)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        try respondToUserInput(threadId: threadId, requestId: requestId, verbatimText: text, outboundText: text)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, verbatimText: String, outboundText: String) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard session.pendingUserInputIds.contains(requestId) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK user input request not found: \(requestId)")
        }
        let usesBridgeCallback = session.bridgeUserInputIds.contains(requestId)
        let requestedSchema = session.bridgeUserInputSchemas[requestId]
        lock.unlock()
        let bridgeContent = usesBridgeCallback
            ? try Self.elicitationContent(text: verbatimText, requestedSchema: requestedSchema)
            : nil
        do {
            if let bridgeContent {
                try write([
                    "type": "user_input_response",
                    "request_id": requestId,
                    "text": verbatimText,
                    "content": bridgeContent
                ], to: session)
            } else {
                try write(["type": "rc_turn", "prompt": outboundText], to: session)
            }
        } catch {
            invalidateSessionAfterControlWriteFailure(session)
            throw error
        }
        lock.lock()
        session.pendingUserInputIds.remove(requestId)
        session.bridgeUserInputIds.remove(requestId)
        session.bridgeUserInputSchemas.removeValue(forKey: requestId)
        lock.unlock()
        let resolved = AssistantEvent.userInputResolved(requestId: requestId, answer: verbatimText)
        record(resolved, session: session)
        emit(.event(resolved), session: session)
    }

    public func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard session.pendingUserInputIds.contains(requestId) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK user input request not found: \(requestId)")
        }
        lock.unlock()

        // Question cancellation is request-scoped. rc_interrupt is reserved for
        // cancelling the whole active turn and draining every pending callback.
        do {
            try write(["type": "user_input_cancel", "request_id": requestId], to: session)
        } catch {
            invalidateSessionAfterControlWriteFailure(session)
            throw error
        }
        lock.lock()
        session.pendingUserInputIds.remove(requestId)
        session.bridgeUserInputIds.remove(requestId)
        session.bridgeUserInputSchemas.removeValue(forKey: requestId)
        lock.unlock()
        let resolved = AssistantEvent.userInputResolved(requestId: requestId, answer: nil)
        record(resolved, session: session)
        emit(.event(resolved), session: session)
    }

    public func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        let session = sessions.removeValue(forKey: threadId)
        session?.cancellationRequested = true
        recoveredEvents.removeValue(forKey: threadId)
        rollbackResumeSessionAt.removeValue(forKey: threadId)
        rollbackProviderThreadIds.removeValue(forKey: threadId)
        lock.unlock()
        guard let session else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        terminate(session)
    }

    public func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK recovery requires providerThreadId")
        }
        let session = try await sessionForAsync(request, provisioningCallback: nil)
        lock.lock()
        session.onEvent = onEvent
        session.status = .completed
        lock.unlock()
    }

    public func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.map {
            AgentProviderSessionSummary(threadId: $0.threadId, provider: .claude, status: $0.status, providerThreadId: $0.providerThreadId)
        }
    }

    public func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId] != nil
    }

    public func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        lock.lock(); defer { lock.unlock() }
        if let session = sessions[threadId] {
            return Array(session.events.suffix(maxReadableEvents))
        }
        if let events = recoveredEvents[threadId] {
            return Array(events.suffix(maxReadableEvents))
        }
        throw AgentProviderAdapterError.sessionNotFound(threadId)
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard let index = session.events.lastIndex(where: { Self.completedTurnId($0) == toTurnId || Self.startedTurnId($0) == toTurnId }) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("rollbackThread target not found")
        }
        let prunedEvents = Array(session.events.prefix(through: index))
        let resumeSessionAt = Self.resumeSessionAt(in: prunedEvents)
        let providerThreadId = session.providerThreadId
        session.events = prunedEvents
        session.completedTurnIds = prunedEvents.compactMap(Self.completedTurnId)
        session.activeTurnId = nil
        recoveredEvents[threadId] = prunedEvents
        if let resumeSessionAt { rollbackResumeSessionAt[threadId] = resumeSessionAt }
        if let providerThreadId { rollbackProviderThreadIds[threadId] = providerThreadId }
        sessions.removeValue(forKey: threadId)
        // Prune stale recoveredEvents: entries that have no active session and no pending
        // rollback re-use cursor are abandoned — remove them to bound memory.
        let openIds = Set(sessions.keys)
        let pendingIds = Set(rollbackProviderThreadIds.keys).union(rollbackResumeSessionAt.keys)
        let staleKeys = Self.recoveredEventsPruneKeys(
            recoveredKeys: Set(recoveredEvents.keys),
            openIds: openIds,
            pendingIds: pendingIds
        )
        for key in staleKeys { recoveredEvents.removeValue(forKey: key) }
        lock.unlock()
        emitSessionSnapshot(session: session, reason: "thread_rolled_back")
        terminate(session)
    }

    public func stopAll() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        recoveredEvents.removeAll()
        rollbackResumeSessionAt.removeAll()
        rollbackProviderThreadIds.removeAll()
        lock.unlock()
        active.forEach(terminate)
    }

    public func stopAllForAppTermination() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        recoveredEvents.removeAll()
        rollbackResumeSessionAt.removeAll()
        rollbackProviderThreadIds.removeAll()
        lock.unlock()
        active.forEach(terminateImmediatelyForAppTermination)
    }

    public func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        session.onEvent = onEvent
        lock.unlock()
    }

    // Async path used by sendTurn and recoverSession (via Task+semaphore) — no Thread.sleep, no cooperative-pool pinning.
    private func sessionForAsync(_ request: AgentRunRequest,
                                 provisioningCallback: (@Sendable (AgentRunEvent) -> Void)?) async throws -> Session {
        let claudeExecutablePath = try resolveClaudeExecutable(request.providerBinary)
        let effectiveReasoningEffort = ClaudeRunner.normalizedReasoningEffort(
            request.reasoningEffort,
            model: request.model
        )
        lock.lock()
        if let existing = sessions[request.threadId] {
            // Model/permission changes switch live over the bridge (rc_set_model /
            // rc_set_permission), but effort is fixed for the life of the SDK query —
            // there is no live effort control — so an effort change is a runtime
            // switch: respawn with resume, mirroring ClaudeStreamingCLIAdapter.canReuse.
            // An in-flight turn keeps the session (sendTurn rejects it right after,
            // exactly as before; recoverSession just re-attaches).
            if (existing.reasoningEffort == effectiveReasoningEffort && existing.claudeExecutablePath == claudeExecutablePath) || existing.inFlightRunId != nil {
                lock.unlock()
                do {
                    try applyRuntimeSwitchIfNeeded(existing, request: request)
                    return existing
                } catch {
                    invalidateSessionAfterControlWriteFailure(existing)
                    throw error
                }
            }
            // Stash the live session id as the resume cursor for the respawn:
            // configurePayload/effectiveProviderThreadId consult this map whenever
            // the request itself carries no providerThreadId.
            if request.providerThreadId?.isEmpty != false,
               let resumeId = existing.providerThreadId, !resumeId.isEmpty {
                rollbackProviderThreadIds[request.threadId] = resumeId
            }
            sessions.removeValue(forKey: request.threadId)
            lock.unlock()
            terminate(existing)
            return try await startNewSession(request, provisioningCallback: provisioningCallback)
        }
        lock.unlock()
        return try await startNewSession(request, provisioningCallback: provisioningCallback)
    }

    private func startNewSession(_ request: AgentRunRequest,
                                 provisioningCallback: (@Sendable (AgentRunEvent) -> Void)? = nil) async throws -> Session {
        let bridgeScriptPath = try await resolvedBridgeScriptPath(onProgress: provisioningCallback)
        return try spawnSession(request, bridgeScriptPath: bridgeScriptPath)
    }

    private func nativeListSessions() async throws -> [ClaudeSDKSessionRecord] {
        if let sessionMutator {
            return try await sessionMutator.listSessions()
        }
        let response = try await executeSessionMutation([
            "type": "rc_list_sessions"
        ], expectedSubtype: "rc_list_sessions_result")
        let sessions = response["sessions"] as? [[String: Any]] ?? []
        return sessions.compactMap { session in
            guard let sessionId = session["session_id"] as? String, !sessionId.isEmpty else { return nil }
            let title = (session["custom_title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ClaudeSDKSessionRecord(sessionId: sessionId, customTitle: title)
        }
    }

    private func nativeForkSession(sourceSessionId: String, title: String) async throws -> String {
        if let sessionMutator {
            return try await sessionMutator.forkSession(sourceSessionId: sourceSessionId, title: title)
        }
        let response = try await executeSessionMutation([
            "type": "rc_fork_session",
            "source_session_id": sourceSessionId,
            "title": title
        ], expectedSubtype: "rc_fork_session_result")
        guard let sessionId = response["session_id"] as? String, !sessionId.isEmpty else {
            throw AgentProviderAdapterError.unsupported("Claude SDK fork response omitted session_id")
        }
        return sessionId
    }

    private func nativeDeleteSession(sessionId: String) async throws {
        if let sessionMutator {
            try await sessionMutator.deleteSession(sessionId: sessionId)
            return
        }
        _ = try await executeSessionMutation([
            "type": "rc_delete_session",
            "session_id": sessionId
        ], expectedSubtype: "rc_delete_session_result")
    }

    private func executeSessionMutation(
        _ operation: [String: Any],
        expectedSubtype: String
    ) async throws -> [String: Any] {
        let script = try await resolvedBridgeScriptPath()
        guard Self.bridgeSupportsNativeSessionMutation(at: script) else {
            throw AgentProviderAdapterError.unsupported("Claude SDK bridge session mutation schema is unavailable")
        }
        let node = try resolvedNodeForLaunch()
        let requestId = UUID().uuidString
        var operation = operation
        operation["request_id"] = requestId
        var configure: [String: Any] = [
            "type": "rc_configure",
            "bridge_protocol_version": Self.bridgeProtocolVersion,
            "session_id": UUID().uuidString
        ]
        if let expectedSDKVersion = Self.pinnedNPMVersion(in: Self.sdkPackageSpec()) {
            configure["expected_sdk_version"] = expectedSDKVersion
        }
        let input = try [configure, operation].map { object -> Data in
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0A)
            return data
        }.reduce(into: Data()) { $0.append($1) }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script]
        process.environment = CodexRunner.processEnvironment(overrides: [:], purpose: .supportProcess)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
            try stdinPipe.fileHandleForWriting.write(contentsOf: input)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }
        // Drain stderr concurrently: a child filling the stderr pipe before closing
        // stdout would otherwise block both processes forever.
        final class DrainedData: @unchecked Sendable { var data = Data() }
        let stderrReader = stderrPipe.fileHandleForReading
        let stderrDrain = DispatchQueue(label: "claude.sdk.session.stderr")
        let drainedStderr = DrainedData()
        stderrDrain.async { drainedStderr.data = stderrReader.readDataToEndOfFile() }
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stderrDrain.sync {}
        let stderr = drainedStderr.data
        process.waitUntilExit()

        let lines = String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if object["request_id"] as? String == requestId,
               object["type"] as? String == "sdk_error" {
                throw AgentProviderAdapterError.unsupported(
                    "Claude SDK session mutation failed: \(object["message"] as? String ?? "unknown error")"
                )
            }
            if object["request_id"] as? String == requestId,
               object["subtype"] as? String == expectedSubtype {
                return object
            }
        }
        let stderrText = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw AgentProviderAdapterError.unsupported(
            "Claude SDK bridge did not return \(expectedSubtype) (exit \(process.terminationStatus))\(stderrText.isEmpty ? "" : ": \(stderrText)")"
        )
    }

    // Shared session spawn logic — validates binary, wires pipes, starts process, registers session.
    private func spawnSession(_ request: AgentRunRequest, bridgeScriptPath: String) throws -> Session {
        guard FileManager.default.isReadableFile(atPath: bridgeScriptPath) else {
            throw AgentProviderAdapterError.unsupported(
                ClaudeAgentSDKBridgeLocator.notFoundMessage(override: bridgeScriptPathOverride)
            )
        }
        let node = try resolvedNodeForLaunch()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let isForeignUser = request.runAsUser.map { $0.uid != getuid() } == true
        let thinkingEnvironment = ClaudeRunner.thinkingEnvironment(request.environment)
        let baseEnv = CodexRunner.processEnvironment(overrides: thinkingEnvironment, purpose: .agentTurn(.claude))
        // CLAUDE-SDK-003: the bridge launches the live `claude` binary via
        // pathToClaudeCodeExecutable, so the same headless mcp-needs-auth cache
        // gate applies. Clear it with the same safeguards as the CLI adapter.
        ClaudeMCPAuthCacheReset.resetAndLog(
            home: baseEnv["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            isForeignUser: isForeignUser,
            environment: baseEnv
        )
        let askpass = isForeignUser
            ? RunAsUserProcessBootstrap.materializeAskpass(targetUser: request.runAsUser!.shortName)
            : nil
        let process = try ProviderSubprocessLauncher.makeProcess(
            provider: .claude,
            executablePath: node,
            arguments: [bridgeScriptPath] + request.extraArgs,
            currentDirectory: request.cwd,
            environment: thinkingEnvironment,
            runAsUser: request.runAsUser,
            askpassPath: askpass
        )
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let effectiveProviderThreadId = effectiveProviderThreadId(for: request)
        let claudeExecutablePath = try resolveClaudeExecutable(request.providerBinary)
        let session = Session(threadId: request.threadId,
                              process: process,
                              stdinPipe: stdinPipe,
                              stdoutPipe: stdoutPipe,
                              stderrPipe: stderrPipe,
                              model: request.model,
                              permissionMode: request.permissionMode,
                              interactionMode: request.interactionMode,
                              reasoningEffort: ClaudeRunner.normalizedReasoningEffort(
                                request.reasoningEffort,
                                model: request.model
                              ),
                              providerThreadId: effectiveProviderThreadId,
                              claudeExecutablePath: claudeExecutablePath)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak session] handle in
            guard let self, let session else { return }
            session.stdoutReadLock.lock()
            defer { session.stdoutReadLock.unlock() }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in session.lineBuffer.take(data) {
                self.handleLine(line, session: session)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self, weak session] handle in
            guard let self, let session else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.handleStderr(data, session: session)
        }
        process.terminationHandler = { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.finishTerminated(session)
        }
        do {
            try process.run()
            try ProcessSpawnTagger.tagProcess(process, provider: .claude)
        } catch {
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }
        lock.lock()
        sessions[request.threadId] = session
        lock.unlock()
        do {
            try write(configurePayload(for: request, claudeExecutablePath: claudeExecutablePath), to: session)
        } catch {
            lock.lock()
            if sessions[request.threadId] === session { sessions.removeValue(forKey: request.threadId) }
            lock.unlock()
            terminate(session)
            throw error
        }
        return session
    }

    // A machine-agnostic description of exactly what the runtime cache must
    // contain for the bridge to launch and run on THIS machine.
    struct RuntimeProvisionPlan {
        let cacheDir: URL
        let cachedBridgePath: String
        let sdkSpec: String
        let sdkVersion: String
        let nativePackageName: String   // @anthropic-ai/claude-agent-sdk-<platform>-<arch>
        let specs: [String]             // exact-pinned install argv: sdk + native + peers
    }

    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    static func cachedBridgeFileName(source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
        // PERF: nibble table avoids 32 String(format:) calls; same lowercase hex.
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for b in digest {
            out.append(Self.hexAlphabet[Int(b >> 4)])
            out.append(Self.hexAlphabet[Int(b & 0x0F)])
        }
        let hex = String(bytes: out, encoding: .utf8) ?? ""
        return "ClaudeAgentSDKBridge-\(hex).mjs"
    }

    private func resolvedBridgeScriptPath(onProgress: (@Sendable (AgentRunEvent) -> Void)? = nil) async throws -> String {
        guard let sourcePath = ClaudeAgentSDKBridgeLocator.resolvePath(override: bridgeScriptPathOverride) else {
            throw AgentProviderAdapterError.unsupported(
                ClaudeAgentSDKBridgeLocator.notFoundMessage(override: bridgeScriptPathOverride)
            )
        }
        guard let plan = try runtimeProvisionPlan(sourcePath: sourcePath) else {
            // Bridge sits beside a complete local node_modules (developer
            // checkout) — usable in place, no provisioning.
            return sourcePath
        }
        if !Self.runtimeTreeComplete(plan) {
            try await installRuntime(plan, onProgress: onProgress)
        }
        return plan.cachedBridgePath
    }

    /// Builds the provisioning plan, or nil when the bridge's source directory
    /// already carries a complete node_modules (used in place).
    private func runtimeProvisionPlan(sourcePath: String) throws -> RuntimeProvisionPlan? {
        let url = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        let source = ((try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap { String(data: $0, encoding: .utf8) }) ?? ""
        guard source.contains("@anthropic-ai/claude-agent-sdk") else { return nil }
        let localPackage = url.deletingLastPathComponent()
            .appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk/package.json")
        if FileManager.default.isReadableFile(atPath: localPackage.path) {
            return nil
        }
        let nodePath = try resolvedNodeForLaunch()
        guard let npmPath = resolveNpmExecutable() else {
            throw AgentRunError.missingBinary("npm")
        }
        let cache = try sdkRuntimeCacheDirectory()
        // Multiple RemoteCode builds may coexist. Keep the shared dependency
        // tree, but make bridge bytes immutable per content hash so an older app
        // cannot overwrite a newer bridge implementation during launch.
        let cachedBridge = cache.appendingPathComponent(Self.cachedBridgeFileName(source: source))
        if !FileManager.default.isReadableFile(atPath: cachedBridge.path)
            || (((try? Data(contentsOf: cachedBridge, options: .mappedIfSafe)).flatMap { String(data: $0, encoding: .utf8) }) != source) {
            try source.write(to: cachedBridge, atomically: true, encoding: .utf8)
        }
        let sdkSpec = Self.sdkPackageSpec()
        let sdkVersion = Self.pinnedNPMVersion(in: sdkSpec) ?? Self.defaultSDKVersion
        // Computed from Node's OWN platform/arch (matches the SDK's
        // getDefaultExecutable resolution) — never a hardcoded arch.
        let platformArch = Self.nodePlatformArch(nodePath: nodePath)
        let nativePackageName = "@anthropic-ai/claude-agent-sdk-\(platformArch)"
        var specs = [sdkSpec, "\(nativePackageName)@\(sdkVersion)"]
        specs.append(contentsOf: Self.runtimePeerSpecs(sdkSpec: sdkSpec, npmPath: npmPath))
        return RuntimeProvisionPlan(
            cacheDir: cache,
            cachedBridgePath: cachedBridge.path,
            sdkSpec: sdkSpec,
            sdkVersion: sdkVersion,
            nativePackageName: nativePackageName,
            specs: specs
        )
    }

    // MARK: Machine facts (resolved once per process)

    /// Node resolved against `minimumNodeMajorVersion`. The bridge is an ES
    /// module (`.mjs`); a Node older than that runs it through the CommonJS
    /// loader and dies with `ERR_REQUIRE_ESM` instead of a usable error — the
    /// crash a stale system/nvm Node produced on customer machines.
    enum NodeResolution: Equatable {
        case ok(String)                        // usable Node >= minimum
        case tooOld(path: String, major: Int)  // a Node exists but is too old
        case missing                           // no Node found at all
    }

    /// Returns a Node that can actually run the ES-module bridge. Prefers the
    /// PATH Node when it qualifies; otherwise falls back to the newest
    /// version-manager Node that qualifies; otherwise reports the newest too-old
    /// Node so the caller can tell the user to upgrade rather than surfacing a
    /// cryptic Node stack trace. Only a successful resolution is memoized, so a
    /// mid-session Node upgrade is picked up on the next turn.
    static func resolveNode(binary: String = "node") -> NodeResolution {
        let cacheKey = "node-ok:" + binary
        runtimeResolveLock.lock()
        if let cached = resolvedToolPaths[cacheKey] { runtimeResolveLock.unlock(); return .ok(cached) }
        runtimeResolveLock.unlock()
        let resolved = selectNode(candidates: nodeCandidatePaths(binary: binary),
                                  majorVersion: { nodeMajorVersion(at: $0) })
        if case .ok(let path) = resolved {
            runtimeResolveLock.lock(); resolvedToolPaths[cacheKey] = path; runtimeResolveLock.unlock()
        }
        return resolved
    }

    /// Ordered, de-duplicated Node candidates. An explicit path override is used
    /// as-is; otherwise EVERY `node` on the search path is enumerated in PATH
    /// order (not just the first — an old `node` earlier in PATH must not hide a
    /// modern one in a later dir like /opt/homebrew/bin), then the newest
    /// version-manager Node as a final fallback.
    static func nodeCandidatePaths(binary: String) -> [String] {
        if binary.contains("/") {
            return [ProcessLocator.resolve(binary)].compactMap { $0 }
        }
        let env = ProcessInfo.processInfo.environment["PATH"]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ProcessLocator.expandedPath(environmentPath: env, homeDirectory: home).split(separator: ":")
        var candidates: [String] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for dir in dirs {
            let path = String(dir) + "/" + binary
            if fm.isExecutableFile(atPath: path), seen.insert(path).inserted { candidates.append(path) }
        }
        if let vm = versionManagerBinary("node"), seen.insert(vm).inserted { candidates.append(vm) }
        return candidates
    }

    /// Pure selection over ordered candidate paths (PATH first, then
    /// version-manager). Returns the first candidate that meets the minimum;
    /// else the newest too-old candidate; else `.missing`. Extracted so the
    /// version-gate logic is unit-testable without spawning `node`.
    static func selectNode(candidates: [String], majorVersion: (String) -> Int?) -> NodeResolution {
        var newestTooOld: (path: String, major: Int)?
        for path in candidates {
            guard let major = majorVersion(path) else { continue }
            if major >= minimumNodeMajorVersion { return .ok(path) }
            if newestTooOld == nil || major > newestTooOld!.major { newestTooOld = (path, major) }
        }
        if let old = newestTooOld { return .tooOld(path: old.path, major: old.major) }
        return .missing
    }

    /// Major version of a Node binary via `node --version` (works on every Node,
    /// including too-old ones — it is not an ES-module invocation). Memoized per
    /// path so provisioning does not re-spawn `node` every turn.
    static func nodeMajorVersion(at path: String) -> Int? {
        runtimeResolveLock.lock()
        if let cached = cachedNodeMajor[path] { runtimeResolveLock.unlock(); return cached }
        runtimeResolveLock.unlock()
        guard let major = queryNodeMajorVersion(at: path) else { return nil }
        runtimeResolveLock.lock(); cachedNodeMajor[path] = major; runtimeResolveLock.unlock()
        return major
    }

    private static func queryNodeMajorVersion(at path: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.environment = CodexRunner.processEnvironment(overrides: [:], purpose: .supportProcess)
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return versionKey(text).first   // versionKey strips a leading 'v'
        } catch { return nil }
    }

    /// Actionable message shown when the only Node on the machine is too old to
    /// run the bridge — replaces the raw `ERR_REQUIRE_ESM` Node stack trace.
    static func nodeTooOldMessage(path: String, major: Int) -> String {
        "Claude needs Node.js \(minimumNodeMajorVersion) or newer, but the Node found on this Mac is v\(major) "
            + "(\(scrubPathsForDisplay(path))). Install a current Node — nodejs.org or `brew install node` — "
            + "then reopen the app."
    }

    /// Node path for launch, or a loud, actionable error. A too-old Node throws
    /// the upgrade message; a missing Node throws the standard missing-binary
    /// error. Never returns a Node that would crash the bridge.
    private func resolvedNodeForLaunch() throws -> String {
        switch Self.resolveNode(binary: nodeBinary) {
        case .ok(let path): return path
        case .tooOld(let path, let major):
            throw AgentProviderAdapterError.unsupported(Self.nodeTooOldMessage(path: path, major: major))
        case .missing:
            throw AgentRunError.missingBinary(nodeBinary)
        }
    }
    private func resolveNpmExecutable() -> String? { Self.resolveTool("npm", vmName: "npm") }

    static func resolveTool(_ name: String, vmName: String) -> String? {
        runtimeResolveLock.lock()
        if let cached = resolvedToolPaths[name] { runtimeResolveLock.unlock(); return cached }
        runtimeResolveLock.unlock()
        let path = ProcessLocator.resolve(name) ?? versionManagerBinary(vmName)
        if let path {
            runtimeResolveLock.lock(); resolvedToolPaths[name] = path; runtimeResolveLock.unlock()
        }
        return path
    }

    /// Discovers a real Node/npm BINARY from common version-manager install
    /// roots (nvm/volta/fnm) for GUI-launched apps whose PATH omits them.
    /// Enumerates installed binaries only — never executes a version-manager
    /// shim (a shim would re-exec a per-project pinned Node and could diverge
    /// from what the bridge later spawns).
    static func versionManagerBinary(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        let roots: [(URL, [String])] = [
            (home.appendingPathComponent(".nvm/versions/node"), ["bin"]),
            (home.appendingPathComponent(".volta/tools/image/node"), ["bin"]),
            (home.appendingPathComponent(".fnm/node-versions"), ["installation", "bin"]),
        ]
        var candidates: [(key: [Int], path: String)] = []
        for (root, tail) in roots {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                var dir = entry
                for component in tail { dir = dir.appendingPathComponent(component) }
                let binary = dir.appendingPathComponent(name)
                if fm.isExecutableFile(atPath: binary.path) {
                    candidates.append((versionKey(entry.lastPathComponent), binary.path))
                }
            }
        }
        return candidates.sorted { $0.key.lexicographicallyPrecedes($1.key) }.last?.path
    }

    static func versionKey(_ name: String) -> [Int] {
        let trimmed = name.hasPrefix("v") ? String(name.dropFirst()) : name
        return trimmed.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
    }

    /// Node's own platform-arch (e.g. "darwin-arm64"), matching the SDK's native
    /// package resolution. Memoized per process; falls back to the host values.
    static func nodePlatformArch(nodePath: String) -> String {
        runtimeResolveLock.lock()
        if let cached = cachedPlatformArch[nodePath] { runtimeResolveLock.unlock(); return cached }
        runtimeResolveLock.unlock()
        let computed = computeNodePlatformArch(nodePath: nodePath) ?? hostPlatformArch()
        runtimeResolveLock.lock(); cachedPlatformArch[nodePath] = computed; runtimeResolveLock.unlock()
        return computed
    }

    private static func computeNodePlatformArch(nodePath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = ["-p", "process.platform + '-' + process.arch"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.environment = CodexRunner.processEnvironment(overrides: [:], purpose: .supportProcess)
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0, value.contains("-") { return value }
        } catch {}
        return nil
    }

    static func hostPlatformArch() -> String {
        #if os(macOS)
        let platform = "darwin"
        #elseif os(Linux)
        let platform = "linux"
        #else
        let platform = "unknown"
        #endif
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x64"
        #else
        let arch = "unknown"
        #endif
        return "\(platform)-\(arch)"
    }

    /// Exact-pinned peer specs. For the default SDK these are the versions it
    /// resolves to. For an RC_CLAUDE_AGENT_SDK_PACKAGE override we resolve the
    /// overridden SDK's declared peer ranges to concrete versions via `npm view`
    /// (best-effort, bounded); on failure we fall back to the default pins so
    /// provisioning still runs and completeness fails loud rather than caching a
    /// broken tree. Memoized per process.
    static func runtimePeerSpecs(sdkSpec: String, npmPath: String) -> [String] {
        if sdkSpec == defaultSDKPackageSpec { return defaultRuntimePeerSpecs }
        runtimeResolveLock.lock()
        if let cached = cachedPeerSpecs[sdkSpec] { runtimeResolveLock.unlock(); return cached }
        runtimeResolveLock.unlock()
        let resolved = resolveOverridePeerSpecs(sdkSpec: sdkSpec, npmPath: npmPath) ?? defaultRuntimePeerSpecs
        runtimeResolveLock.lock(); cachedPeerSpecs[sdkSpec] = resolved; runtimeResolveLock.unlock()
        return resolved
    }

    private static func resolveOverridePeerSpecs(sdkSpec: String, npmPath: String) -> [String]? {
        guard let json = npmView(npmPath: npmPath, args: [sdkSpec, "peerDependencies", "--json"]),
              let data = json.data(using: .utf8),
              let ranges = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              !ranges.isEmpty else { return nil }
        var specs: [String] = []
        for (name, range) in ranges {
            guard let version = npmView(npmPath: npmPath, args: ["\(name)@\(range)", "version"])?
                .split(whereSeparator: \.isNewline).last.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !version.isEmpty else { return nil }
            specs.append("\(name)@\(version)")
        }
        return specs
    }

    private static func npmView(npmPath: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npmPath)
        process.arguments = ["view", "--fetch-timeout=15000"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.environment = CodexRunner.processEnvironment(overrides: [:], purpose: .supportProcess)
        let deadline = Date().addingTimeInterval(20)
        do {
            try process.run()
        } catch { return nil }
        let killer = Task.detached {
            while process.isRunning {
                if Date() > deadline { ProcessTerminator.terminateTree(process); break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: Completeness (checked every start; self-healing)

    /// True iff the cache already contains every required package at its pinned
    /// version AND the platform-matched native `claude` binary is present and
    /// executable. Cheap (a few package.json reads + one stat), so a partial /
    /// interrupted / omit-optional tree is never treated as complete; when it is
    /// not complete, provisioning re-runs `npm install` which reconciles the
    /// tree in place (no destructive wipe of a working install).
    static func runtimeTreeComplete(_ plan: RuntimeProvisionPlan) -> Bool {
        let modules = plan.cacheDir.appendingPathComponent("node_modules")
        for spec in plan.specs {
            guard let parsed = parseSpec(spec) else { continue }
            let packageJSON = modules.appendingPathComponent(parsed.name).appendingPathComponent("package.json")
            guard installedPackageVersion(at: packageJSON) == parsed.version else { return false }
        }
        let binary = modules.appendingPathComponent(plan.nativePackageName).appendingPathComponent("claude")
        return FileManager.default.isExecutableFile(atPath: binary.path)
    }

    /// Splits `name@version`, tolerating scoped names (@scope/name@version) by
    /// using the LAST '@'.
    static func parseSpec(_ spec: String) -> (name: String, version: String)? {
        guard let at = spec.lastIndex(of: "@"), at != spec.startIndex else { return nil }
        let name = String(spec[spec.startIndex..<at])
        let version = String(spec[spec.index(after: at)...])
        guard !name.isEmpty, !version.isEmpty else { return nil }
        return (name, version)
    }

    static func installedPackageVersion(at packageJSON: URL) -> String? {
        guard let data = try? Data(contentsOf: packageJSON, options: .mappedIfSafe),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? String
    }

    static func sdkPackageSpec() -> String {
        let package = ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_PACKAGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return package?.isEmpty == false ? package! : defaultSDKPackageSpec
    }

    static func installedSDKPackage(at packageJSON: URL, matches packageSpec: String) -> Bool {
        guard FileManager.default.isReadableFile(atPath: packageJSON.path) else { return false }
        guard let data = try? Data(contentsOf: packageJSON, options: .mappedIfSafe),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard let expectedVersion = pinnedNPMVersion(in: packageSpec) else {
            return true
        }
        return object["version"] as? String == expectedVersion
    }

    private static func pinnedNPMVersion(in packageSpec: String) -> String? {
        let prefix = "@anthropic-ai/claude-agent-sdk@"
        guard packageSpec.hasPrefix(prefix) else { return nil }
        let version = String(packageSpec.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.first?.isNumber == true else { return nil }
        return version
    }

    private func sdkRuntimeCacheDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_CACHE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let cache = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let package = cache.appendingPathComponent("package.json")
            if !FileManager.default.fileExists(atPath: package.path) {
                try (#"{"type":"module","private":true}"# + "\n").write(to: package, atomically: true, encoding: .utf8)
            }
            return cache
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let cache = root
            .appendingPathComponent("RemoteCode", isDirectory: true)
            .appendingPathComponent("AgentRuntime", isDirectory: true)
            .appendingPathComponent("ClaudeAgentSDKBridge", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let package = cache.appendingPathComponent("package.json")
        if !FileManager.default.fileExists(atPath: package.path) {
            try (#"{"type":"module","private":true}"# + "\n").write(to: package, atomically: true, encoding: .utf8)
        }
        return cache
    }

    // Async single-flight install (per cache dir + spec set) so concurrent
    // Claude starts within this process cannot interleave node_modules.
    private func installRuntime(_ plan: RuntimeProvisionPlan,
                                onProgress: (@Sendable (AgentRunEvent) -> Void)? = nil) async throws {
        let key = plan.cacheDir.standardizedFileURL.path + "\0" + plan.specs.joined(separator: " ")
        let task: Task<Void, Error> = {
            Self.sdkInstallTasksLock.lock()
            if let existing = Self.sdkInstallTasks[key] {
                Self.sdkInstallTasksLock.unlock()
                return existing
            }
            let created = Task {
                defer {
                    Self.sdkInstallTasksLock.lock()
                    Self.sdkInstallTasks[key] = nil
                    Self.sdkInstallTasksLock.unlock()
                }
                try await self.performRuntimeInstall(plan, onProgress: onProgress)
            }
            Self.sdkInstallTasks[key] = created
            Self.sdkInstallTasksLock.unlock()
            return created
        }()
        try await task.value
    }

    private func performRuntimeInstall(_ plan: RuntimeProvisionPlan,
                                       onProgress: (@Sendable (AgentRunEvent) -> Void)?) async throws {
        // Re-check after waiting for another installer's flight.
        if Self.runtimeTreeComplete(plan) { return }
        let (process, outputPipe, outputBuffer, lastProgress) = try Self.makeRuntimeInstallProcess(plan: plan, onProgress: onProgress)
        // Wait for termination via a continuation; the cooperative-pool thread is NOT blocked.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus != 0 {
                    let text = Self.npmInstallFailureText(buffered: outputBuffer, outputPipe: outputPipe)
                    continuation.resume(throwing: AgentProviderAdapterError.unsupported("Claude Agent SDK runtime install failed: \(text)"))
                } else {
                    continuation.resume()
                }
            }
            // No-progress (stall) watchdog: reset on npm output, absolute backstop.
            // The 205MB native binary can take minutes on a slow-but-working link,
            // so a flat wall-clock cap is wrong — only a genuinely hung fetch is killed.
            let proc = process
            let progress = lastProgress
            Task.detached {
                let stall = Self.installStallSeconds()
                let backstop = Self.installBackstopSeconds()
                let start = Date()
                while proc.isRunning {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !proc.isRunning { break }
                    let now = Date()
                    if now.timeIntervalSince(progress.value) > stall || now.timeIntervalSince(start) > backstop {
                        ProcessTerminator.terminateTree(proc)
                        break
                    }
                }
            }
        }
        // Post-verify: npm can exit 0 while silently skipping the optional native
        // binary (omit=optional / tolerated fetch failure). Never cache such a
        // tree as usable — fail LOUD with the captured npm output instead.
        guard Self.runtimeTreeComplete(plan) else {
            let text = Self.npmInstallFailureText(buffered: outputBuffer, outputPipe: outputPipe)
            throw AgentProviderAdapterError.unsupported(
                "Claude Agent SDK runtime incomplete after install (a required package or the native CLI binary is missing — check network / registry / npm optional-dependency settings). \(text)"
            )
        }
    }

    // Mutable, lock-guarded timestamp so the install watchdog can tell a slow but
    // progressing fetch from a genuinely hung one.
    final class LockedTimestamp: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var value: Date { lock.lock(); defer { lock.unlock() }; return date }
        func touch(_ date: Date) { lock.lock(); self.date = date; lock.unlock() }
    }

    // Builds the reconcile-install process: names the SDK + platform-matched
    // native package + exact-pinned peers, and forces optional inclusion so a
    // user .npmrc `omit=optional` cannot silently drop the native CLI binary.
    static func makeRuntimeInstallProcess(plan: RuntimeProvisionPlan,
                                          onProgress: (@Sendable (AgentRunEvent) -> Void)?)
        throws -> (Process, Pipe, LockedDataBuffer, LockedTimestamp) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resolvedNpmForInstall())
        process.arguments = ["install", "--no-fund", "--no-audit", "--ignore-scripts", "--include=optional"] + plan.specs
        process.currentDirectoryURL = plan.cacheDir
        process.environment = CodexRunner.processEnvironment(overrides: [:], purpose: .supportProcess)
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let outputBuffer = LockedDataBuffer()
        let lastProgress = LockedTimestamp(Date())
        // Always drain (even without onProgress) so the failure text and the
        // stall watchdog have the real npm output.
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputBuffer.append(data)
            lastProgress.touch(Date())
            guard let onProgress, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: "\n") {
                guard let parsed = NpmInstallProgressParser.parse(line: line) else { continue }
                onProgress(Self.provisioningEvent(payload: Self.provisioningPayload(stage: parsed.stage, progress: parsed.progress, packageSpec: plan.sdkSpec)))
            }
        }
        if let onProgress {
            onProgress(Self.provisioningEvent(payload: Self.provisioningPayload(stage: "starting", progress: 0.0, packageSpec: plan.sdkSpec)))
        }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }
        return (process, outputPipe, outputBuffer, lastProgress)
    }

    private static func resolvedNpmForInstall() throws -> String {
        guard let npm = resolveTool("npm", vmName: "npm") else { throw AgentRunError.missingBinary("npm") }
        return npm
    }

    /// Strips CI/build absolute paths (the Airton-class `/.gitlab-runner/builds/…`
    /// leak the locator redaction guards against) and the user's home prefix from
    /// free-form Node stderr before it is shown to the user.
    static func scrubPathsForDisplay(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(
            of: #"/[^\s'"]*\.gitlab-runner/builds/[^\s'"]*"#,
            with: "<build>",
            options: .regularExpression)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty { text = text.replacingOccurrences(of: home, with: "~") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Pure helper — returns the install timeout; extracted for testability.
    nonisolated static func sdkInstallTimeoutSeconds() -> Double { 120 }

    // Pure helper — returns the install timeout in nanoseconds for Task.sleep.
    nonisolated static func sdkInstallTimeoutNanoseconds() -> UInt64 {
        UInt64(sdkInstallTimeoutSeconds() * 1_000_000_000)
    }

    // Minimal locked byte accumulator for the npm install output.
    // Internal (not private) so the failure-text regression test can drive
    // makeNpmInstallProcess/npmInstallFailureText directly.
    final class LockedDataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    // Assembles the diagnostic text for a failed npm install: everything the
    // progress readabilityHandler already consumed (`buffered`) plus the
    // undelivered tail still in the pipe. Tail-only (the pre-fix behaviour)
    // was usually EMPTY because the progress handler had drained the pipe,
    // yielding "install failed: " with no explanation.
    static func npmInstallFailureText(buffered: LockedDataBuffer, outputPipe: Pipe) -> String {
        var data = buffered.value
        data.append(BoundedPipeDrain.readRemaining(
            from: outputPipe.fileHandleForReading,
            maxBytes: BoundedPipeDrain.defaultStdoutMaxBytes
        ))
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Shared npm install process setup (spawn only — caller awaits termination).
    // Internal + npmBinary injection so tests can exercise the streamed-output
    // buffering against a deterministic fake npm.
    static func makeNpmInstallProcess(in directory: URL,
                                      packageSpec: String,
                                      onProgress: (@Sendable (AgentRunEvent) -> Void)?,
                                      npmBinary: String = "npm") throws -> (Process, Pipe, LockedDataBuffer) {
        guard let npm = ProcessLocator.resolve(npmBinary) else {
            throw AgentRunError.missingBinary(npmBinary)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        // --ignore-scripts: do not run package lifecycle scripts from the
        // Application Support cache (same-user / PATH npm supply-chain residual).
        process.arguments = ["install", "--no-fund", "--no-audit", "--ignore-scripts", packageSpec]
        process.currentDirectoryURL = directory
        process.environment = CodexRunner.processEnvironment(overrides: [:], purpose: .supportProcess)
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let outputBuffer = LockedDataBuffer()
        if let onProgress {
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                // Keep every consumed chunk: on failure this buffer (plus the
                // pipe tail) is the only source of npm's real error text.
                outputBuffer.append(data)
                guard let text = String(data: data, encoding: .utf8) else { return }
                for line in text.components(separatedBy: "\n") {
                    guard let parsed = NpmInstallProgressParser.parse(line: line) else { continue }
                    let payload = Self.provisioningPayload(stage: parsed.stage, progress: parsed.progress, packageSpec: packageSpec)
                    onProgress(Self.provisioningEvent(payload: payload))
                }
            }
            onProgress(Self.provisioningEvent(payload: Self.provisioningPayload(stage: "starting", progress: 0.0, packageSpec: packageSpec)))
        }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }
        return (process, outputPipe, outputBuffer)
    }

    private static func provisioningPayload(stage: String, progress: Double, packageSpec: String) -> [String: Any] {
        [
            "stage": stage,
            "progress": progress,
            "package": packageSpec
        ]
    }

    private static func provisioningEvent(payload: [String: Any]) -> AgentRunEvent {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let payloadJSON = String(data: data, encoding: .utf8) else {
            return .event(.providerRuntime(ProviderRuntimeEvent(
                provider: .claude,
                source: "claude.agent-sdk.provisioning",
                method: "rc_provisioning",
                payloadJSON: "{}",
                receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            )))
        }
        return .event(.providerRuntime(ProviderRuntimeEvent(
            provider: .claude,
            source: "claude.agent-sdk.provisioning",
            method: "rc_provisioning",
            payloadJSON: payloadJSON,
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )))
    }

    private func applyRuntimeSwitchIfNeeded(_ session: Session, request: AgentRunRequest) throws {
        if session.model != request.model {
            try write(["type": "rc_set_model", "model": request.model, "session_id": session.providerThreadId ?? request.threadId.value.uuidString], to: session)
            lock.lock(); session.model = request.model; lock.unlock()
        }
        if session.permissionMode != request.permissionMode || session.interactionMode != request.interactionMode {
            try write([
                "type": "rc_set_permission",
                "permission_mode": request.permissionMode.rawValue,
                "interaction_mode": request.interactionMode.rawValue,
                "session_id": session.providerThreadId ?? request.threadId.value.uuidString
            ], to: session)
            lock.lock()
            session.permissionMode = request.permissionMode
            session.interactionMode = request.interactionMode
            lock.unlock()
        }
    }

    private static func attachmentPayload(_ attachments: [AgentAttachment]) -> [[String: Any]] {
        attachments.map {
            [
                "path": $0.path,
                "display_name": $0.displayName,
                "kind": $0.kind.rawValue,
                "mime_type": $0.mimeType ?? ""
            ]
        }
    }

    private static let supportedImageMIMETypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]

    static func validateAttachments(_ attachments: [AgentAttachment]) throws {
        for attachment in attachments where attachment.kind == .image {
            let mime = attachment.mimeType ?? ""
            guard supportedImageMIMETypes.contains(mime) else {
                throw AgentProviderAdapterError.unsupported("Unsupported Claude image attachment type: \(mime.isEmpty ? "unknown" : mime)")
            }
        }
    }

    private func resolveClaudeExecutable(_ requested: String?) throws -> String? {
        let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = binaryNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured = requested?.isEmpty == false ? requested : fallback,
              !configured.isEmpty else { return nil }
        guard let resolved = ProcessLocator.resolve(configured) else { throw AgentRunError.missingBinary(configured) }
        return resolved
    }

    private func configurePayload(for request: AgentRunRequest, claudeExecutablePath: String?) -> [String: Any] {
        let resumeSessionAt: String?
        let providerThreadId: String?
        lock.lock()
        resumeSessionAt = rollbackResumeSessionAt.removeValue(forKey: request.threadId)
        providerThreadId = request.providerThreadId ?? rollbackProviderThreadIds.removeValue(forKey: request.threadId)
        lock.unlock()
        var payload: [String: Any] = [
            "type": "rc_configure",
            "bridge_protocol_version": Self.bridgeProtocolVersion,
            "cwd": request.cwd,
            "model": request.model,
            "permission_mode": request.permissionMode.rawValue,
            "interaction_mode": request.interactionMode.rawValue,
            "provider_thread_id": providerThreadId ?? "",
            "session_id": request.threadId.value.uuidString,
            "environment": ClaudeRunner.thinkingEnvironment(request.environment)
        ]
        if let expectedSDKVersion = Self.pinnedNPMVersion(in: Self.sdkPackageSpec()) {
            payload["expected_sdk_version"] = expectedSDKVersion
        }
        if let resumeSessionAt, !resumeSessionAt.isEmpty {
            payload["resume_session_at"] = resumeSessionAt
        }
        if let claudeExecutablePath {
            payload["claude_executable_path"] = claudeExecutablePath
        }
        // Effort + ultracode settings: CLI keeps --effort ultracode; SDK
        // Options.effort is xhigh plus settings {"ultracode":true,...}.
        let normalizedEffort = ClaudeRunner.normalizedReasoningEffort(
            request.reasoningEffort,
            model: request.model
        )
        if let effort = ClaudeRunner.sdkEffortToken(normalizedEffort, model: request.model) {
            payload["effort"] = effort
        }
        if let settings = ClaudeRunner.ultracodeSettingsArgs(
            normalizedEffort,
            environment: request.environment
        ).last {
            payload["settings"] = settings
        }
        payload["system_prompt"] = Self.claudeSystemPrompt(environment: request.environment)
        payload["mcp_servers"] = Self.botPeerMCPServers(environment: request.environment)
        payload["allowed_tools"] = ClaudeRunner.automaticallyAllowedTools(environment: request.environment)
        return payload
    }

    /// Explicit SDK admission is required because `query(options.mcpServers:)`
    /// does not reliably inherit the managed server written to settings.json.
    /// The definition is rebuilt per turn so the MCP receives that turn's exact
    /// thread/run/socket authority without deriving anything from user prose.
    /// SDK-engine parity with the CLI route's `--mcp-config` (see
    /// ClaudeRunner.botPeerMCPConfigJSON).
    static func botPeerMCPServers(
        environment: [String: String],
        command: String? = nil
    ) -> [String: Any] {
        let resolved = command
            ?? AgentSkillInstaller.resolveServiceBinary()?.path
            ?? BotSelfConfigMCPAdmit.fallbackCommand
        var servers: [String: Any] = [
            BotSelfConfigMCPAdmit.serverName: BotSelfConfigMCPAdmit.claudeSDKServer(
                command: resolved,
                environment: environment
            )
        ]
        if environment[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey] == "1" {
            servers[ComputerUseMCPAdmit.serverName] = ComputerUseMCPAdmit.stdioConfig(command: resolved)
        }
        return servers
    }

    /// System prompt for the SDK session, set on every run (additive — the SDK's
    /// `systemPrompt` string does not introduce the `claude_code` preset; the agent
    /// behaviour rides on the separate `tools` preset, so this never strips it).
    ///
    /// Always carries the always-on Claude rules
    /// (`BackgroundAwaitContinuation.alwaysOnClaudeDirectives`: the background-await
    /// self-declaration marker + the MCP-tool-availability rule) so the agent marks
    /// any unavoidable wait with the recovery marker and does not preemptively refuse
    /// a connected MCP tool as "unauthenticated" in a non-interactive run.
    static func claudeSystemPrompt(environment: [String: String]) -> String {
        return AgentSkillInstaller.nestedAgentProviderPrompt(
            BackgroundAwaitContinuation.alwaysOnClaudeDirectives,
            environment: environment
        )
    }

    private func effectiveProviderThreadId(for request: AgentRunRequest) -> String? {
        lock.lock(); defer { lock.unlock() }
        return request.providerThreadId ?? rollbackProviderThreadIds[request.threadId]
    }

    /// Asked before an edit tool runs. Nil leaves Claude's own edits unchecked.
    public var preEditChecker: PreEditChecking?

    /// A bridge pre-edit check never reaches the transcript: the host answers it and the edit goes on or stops.
    private func answerLeaseCheck(_ line: String, session: Session) -> Bool {
        guard Self.isLeaseCheckRequest(line) else { return false }
        let checker = preEditChecker
        let threadId = session.threadId
        Task { [weak self, weak session] in
            guard let payload = await Self.leaseCheckResponse(forLine: line, threadId: threadId, checker: checker),
                  let self, let session else { return }
            try? self.write(payload, to: session)
        }
        return true
    }

    static func isLeaseCheckRequest(_ line: String) -> Bool {
        line.contains("lease_check_request") && jsonObject(from: line)?["type"] as? String == "lease_check_request"
    }

    /// The `lease_check_response` for a bridge request line; the edit is allowed when nothing can be checked.
    static func leaseCheckResponse(forLine line: String, threadId: AgentThreadID, checker: PreEditChecking?) async -> [String: Any]? {
        guard let object = jsonObject(from: line), object["type"] as? String == "lease_check_request",
              let requestId = object["request_id"] as? String else { return nil }
        let touches = ProviderFileTouchParser.claude(
            toolName: object["tool_name"] as? String,
            input: object["tool_input"] as? [String: Any]
        )
        var verdict = PreEditVerdict.allow
        if let checker, !touches.isEmpty {
            verdict = await checker.checkEdit(threadId: threadId, paths: touches.map(\.path), cwd: nil, enforce: true)
        }
        var payload: [String: Any] = ["type": "lease_check_response", "request_id": requestId]
        switch verdict {
        case .allow: payload["verdict"] = "allow"
        case .warn(let text): payload["verdict"] = "warn"; payload["message"] = text
        case .deny(let text): payload["verdict"] = "deny"; payload["message"] = text
        }
        return payload
    }

    private func handleLine(_ line: String, session: Session) {
        if answerLeaseCheck(line, session: session) { return }
        let interpretation = Self.interpretSDKLine(line, parser: session.parser)
        let bridgeUserInputRequest = interpretation.userInputRequest
        if interpretation.isSDKError { session.sawError = true }
        if let runtimeEvent = interpretation.runtimeEvent {
            let event = AssistantEvent.providerRuntime(runtimeEvent)
            record(event, session: session)
            emit(.event(event), session: session)
        }
        let parsed = interpretation.parsedEvents
        for event in parsed {
            // The SDK emits AskUserQuestion as an assistant tool block before
            // canUseTool has registered its callback. The bridge then emits the
            // authoritative user_input_request after registration. Publishing the
            // earlier parser event creates duplicate cards and lets an immediate
            // response race ahead of the callback map.
            if case .userInputRequested = event, bridgeUserInputRequest == nil {
                continue
            }
            if case .userInputRequested(let request) = event {
                lock.lock()
                session.pendingUserInputIds.insert(request.id)
                session.bridgeUserInputIds.insert(request.id)
                if let schema = bridgeUserInputRequest?.requestedSchema {
                    session.bridgeUserInputSchemas[request.id] = schema
                }
                lock.unlock()
            }
            record(event, session: session)
            emit(.event(event), session: session)
            if case .error(_, let recoverable) = event, !recoverable { session.sawError = true }
            if case .threadStarted(_, let providerThreadId) = event {
                lock.lock(); session.providerThreadId = providerThreadId; lock.unlock()
                emitSessionSnapshot(session: session, reason: "thread_started")
            }
            if case .turnStarted(let turnId) = event {
                lock.lock(); session.activeTurnId = turnId; lock.unlock()
                emitSessionSnapshot(session: session, reason: "turn_started")
            }
            if case .userInputRequested = event {
                emitSessionSnapshot(session: session, reason: "user_input_requested")
            }
            if case .requestOpened(let request) = event {
                lock.lock(); session.pendingRequestIds.insert(request.id); lock.unlock()
                emitSessionSnapshot(session: session, reason: "request_opened")
            }
            if case .requestResolved(let requestId, _) = event {
                lock.lock(); session.pendingRequestIds.remove(requestId); lock.unlock()
                emitSessionSnapshot(session: session, reason: "request_resolved")
            }
            if case .turnCompleted(let turnId, let finalMessage) = event {
                lock.lock()
                if !session.completedTurnIds.contains(turnId) { session.completedTurnIds.append(turnId) }
                session.activeTurnId = nil
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "turn_completed")
                // Ambient task-notification results are filtered in ClaudeParser
                // (no turnCompleted). Any turnCompleted here owns the lifecycle.
                finishActiveTurn(session, finalMessage: finalMessage)
            }
        }
    }

    private func handleStderr(_ data: Data, session: Session) {
        let raw = String(data: data, encoding: .utf8) ?? ""
        // Retain the raw tail (even lines the classifier drops) so the terminal
        // diagnostic can carry the real Node failure reason, not a bare status.
        lock.lock(); session.appendStderr(data); lock.unlock()
        // The bridge is a Node process: it prints Deprecation/Experimental
        // warnings to stderr during normal successful runs. Only lines the
        // classifier keeps may surface as a fatal error — the same gate as
        // ClaudeStreamingCLIAdapter.handleStderr / ClaudeRunner.
        guard let visible = ClaudeRunner.displayableStderr(raw) else { return }
        let event = AssistantEvent.providerRuntime(ProviderStderrClassifier.runtimeEvent(
            message: visible,
            provider: .claude,
            source: "claude.agent-sdk.stderr"
        ))
        record(event, session: session)
        emit(.event(event), session: session)
        emit(.error("[claude sdk stderr] " + visible), session: session)
    }

    private func finishTerminated(_ session: Session) {
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Drain under the lock: an in-flight readabilityHandler callback may
        // still be reading/parsing — the lock keeps LineBuffer access and fd
        // read order serialized so no final line is split or reordered.
        session.stdoutReadLock.lock()
        let tail = BoundedPipeDrain.readRemaining(
            from: session.stdoutPipe.fileHandleForReading,
            maxBytes: BoundedPipeDrain.defaultStdoutMaxBytes
        )
        for line in session.lineBuffer.take(tail) + session.lineBuffer.flush() {
            handleLine(line, session: session)
        }
        session.stdoutReadLock.unlock()
        // Mirror the stdout drain for stderr: a bridge that dies instantly
        // (missing module, ESM syntax error, auth failure) writes the only
        // explanation to stderr, and the async handler can lose the race with
        // the teardown above, leaving the bytes undelivered in the pipe.
        let stderrTail = BoundedPipeDrain.readRemaining(
            from: session.stderrPipe.fileHandleForReading,
            maxBytes: BoundedPipeDrain.defaultStderrMaxBytes
        )
        if !stderrTail.isEmpty {
            handleStderr(stderrTail, session: session)
        }
        for event in session.parser.finalize() {
            handleFinalizedEvent(event, session: session)
        }

        lock.lock()
        if sessions[session.threadId] === session { sessions.removeValue(forKey: session.threadId) }
        let shouldFinish = session.inFlightRunId != nil
        let callback = session.onEvent
        session.inFlightRunId = nil
        let status: AgentRunStatus = session.cancellationRequested ? .cancelled : .failed
        session.status = status
        session.onEvent = nil
        lock.unlock()
        if shouldFinish {
            if !session.cancellationRequested {
                let base: String
                if session.process.terminationReason == .uncaughtSignal {
                    base = "Claude Agent SDK bridge crashed with signal \(session.process.terminationStatus)."
                } else {
                    base = "Claude Agent SDK bridge exited with status \(session.process.terminationStatus)."
                }
                // Merge the real reason (scrubbed of CI/build + home absolute
                // paths) so the user never sees a bare "exited with status N".
                lock.lock(); let tailData = session.recentStderr; lock.unlock()
                let tail = Self.scrubPathsForDisplay(String(decoding: tailData, as: UTF8.self))
                let diagnostic = tail.isEmpty ? base : "\(base)\n\(tail)"
                callback?(.error(diagnostic))
            }
            callback?(.status(status))
            callback?(.finished(status, finalMessage: nil, providerThreadId: session.providerThreadId))
        }
    }

    private func handleFinalizedEvent(_ event: AssistantEvent, session: Session) {
        record(event, session: session)
        emit(.event(event), session: session)
        guard case .turnCompleted(let turnId, let finalMessage) = event else { return }

        lock.lock()
        if !session.completedTurnIds.contains(turnId) { session.completedTurnIds.append(turnId) }
        session.activeTurnId = nil
        lock.unlock()
        emitSessionSnapshot(session: session, reason: "turn_completed")

        finishActiveTurn(session, finalMessage: finalMessage)
    }

    /// Commits the resident session's idle state before publishing the terminal
    /// edge. Queue draining is triggered synchronously from `.finished`; emitting
    /// first leaves that consumer observing a stale `.running` session and makes
    /// progress depend on a later scheduler yield.
    private func finishActiveTurn(_ session: Session, finalMessage: String?) {
        lock.lock()
        let status: AgentRunStatus = session.cancellationRequested
            ? .cancelled
            : (session.sawError ? .failed : .completed)
        let callback = session.onEvent
        let providerThreadId = session.providerThreadId
        session.status = status
        session.inFlightRunId = nil
        session.onEvent = nil
        session.sawError = false
        session.pendingRequestIds.removeAll()
        session.pendingUserInputIds.removeAll()
        session.bridgeUserInputIds.removeAll()
        session.bridgeUserInputSchemas.removeAll()
        lock.unlock()

        callback?(.status(status))
        callback?(.finished(
            status,
            finalMessage: finalMessage,
            providerThreadId: providerThreadId
        ))
    }

    private func terminate(_ session: Session) {
        try? write(["type": "rc_close"], to: session)
        settlePendingRequests(session)
        settlePendingUserInputs(session)
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        if session.process.isRunning {
            let deadline = Date().addingTimeInterval(bridgeCloseGracePeriod)
            while session.process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if session.process.isRunning {
                ProcessTerminator.terminateTree(session.process)
            }
        }
    }

    private func terminateImmediatelyForAppTermination(_ session: Session) {
        try? write(["type": "rc_close"], to: session)
        settlePendingRequests(session)
        settlePendingUserInputs(session)
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        if session.process.isRunning {
            ProcessTerminator.terminateTreeImmediately(session.process)
        }
    }

    private func invalidateSessionAfterControlWriteFailure(_ session: Session) {
        lock.lock()
        let ownsSession = sessions[session.threadId] === session
        if ownsSession { sessions.removeValue(forKey: session.threadId) }
        lock.unlock()
        guard ownsSession else { return }
        terminate(session)
    }

    private func settlePendingRequests(_ session: Session) {
        lock.lock()
        let requestIds = Array(session.pendingRequestIds)
        session.pendingRequestIds.removeAll()
        lock.unlock()
        for requestId in requestIds {
            let resolved = AssistantEvent.requestResolved(requestId: requestId, state: .cancelled)
            record(resolved, session: session)
            emit(.event(resolved), session: session)
        }
        if !requestIds.isEmpty {
            emitSessionSnapshot(session: session, reason: "requests_settled")
        }
    }

    private func settlePendingUserInputs(_ session: Session) {
        lock.lock()
        let requestIds = Array(session.pendingUserInputIds)
        session.pendingUserInputIds.removeAll()
        session.bridgeUserInputIds.removeAll()
        session.bridgeUserInputSchemas.removeAll()
        lock.unlock()
        for requestId in requestIds {
            let resolved = AssistantEvent.userInputResolved(requestId: requestId, answer: nil)
            record(resolved, session: session)
            emit(.event(resolved), session: session)
        }
        if !requestIds.isEmpty {
            emitSessionSnapshot(session: session, reason: "user_inputs_settled")
        }
    }

    private func write(_ payload: [String: Any], to session: Session) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = data
        line.append(0x0A)
        try session.writeQueue.sync {
            try GuardedStdinWrite.write(line,
                                        to: session.stdinPipe.fileHandleForWriting,
                                        process: session.process,
                                        notFound: { AgentProviderAdapterError.sessionNotFound(session.threadId) })
        }
    }

    private func emit(_ event: AgentRunEvent, session: Session) {
        lock.lock(); let callback = session.onEvent; lock.unlock()
        callback?(event)
    }

    private func record(_ event: AssistantEvent, session: Session) {
        lock.lock()
        session.events.append(event)
        if let pruned = Self.prunedReadableEvents(
            session.events,
            cap: maxReadableEvents,
            slack: Self.readableEventPruneSlack
        ) {
            session.events = pruned
        }
        lock.unlock()
    }

    /// Keep the public readable window exact while allowing enough internal
    /// slack to amortize the suffix copy. Without slack, every streamed event
    /// after the cap copied all 5,000 retained events under the adapter lock.
    static let readableEventPruneSlack = 1_024

    /// Returns a new bounded suffix only after the internal buffer crosses its
    /// high-water mark. A nil result leaves the append O(1).
    nonisolated static func prunedReadableEvents(
        _ events: [AssistantEvent],
        cap: Int,
        slack: Int
    ) -> [AssistantEvent]? {
        let boundedCap = max(1, cap)
        let boundedSlack = max(0, slack)
        guard events.count > boundedCap + boundedSlack else { return nil }
        return Array(events.suffix(boundedCap))
    }

    private func emitSessionSnapshot(session: Session, reason: String) {
        lock.lock()
        var payload: [String: Any] = [
            "reason": reason,
            "provider": "claude",
            "sdk": "agent-sdk",
            "model": session.model,
            "turnCount": session.completedTurnIds.count,
            "pendingApprovalRequestIds": Array(session.pendingRequestIds).sorted(),
            "pendingUserInputRequestIds": Array(session.pendingUserInputIds).sorted()
        ]
        if let providerThreadId = session.providerThreadId {
            payload["providerThreadId"] = providerThreadId
            payload["resume"] = providerThreadId
        }
        if let activeTurnId = session.activeTurnId { payload["activeTurnId"] = activeTurnId }
        if let lastCompletedTurnId = session.completedTurnIds.last { payload["lastCompletedTurnId"] = lastCompletedTurnId }
        let providerTurnId = session.activeTurnId ?? session.completedTurnIds.last
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let payloadJSON = String(data: data, encoding: .utf8) else { return }
        emit(.event(.providerRuntime(ProviderRuntimeEvent(
            provider: .claude,
            source: "claude.agent-sdk.session",
            method: "claude.session.snapshot",
            providerTurnId: providerTurnId,
            payloadJSON: payloadJSON,
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ))), session: session)
    }

    /// One JSON decode of a Claude SDK stdout line. handleLine used to
    /// JSONSerialization separately for sdk_error, user_input_request,
    /// ProviderRuntimeEvent.fromJSONLine, and ClaudeParser.parseLine.
    static func jsonObject(from line: String) -> [String: Any]? {
#if DEBUG
        sdkLineJSONDecodeCountForTesting += 1
#endif
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

#if DEBUG
    static var sdkLineJSONDecodeCountForTesting = 0
#endif

    struct SDKLineInterpretation {
        let isSDKError: Bool
        let userInputRequest: (id: String, requestedSchema: [String: Any]?)?
        let runtimeEvent: ProviderRuntimeEvent?
        let parsedEvents: [AssistantEvent]
    }

    /// Decode once, then derive sdk_error / user-input / runtime / parser events.
    static func interpretSDKLine(_ line: String, parser: ClaudeParser) -> SDKLineInterpretation {
        let object = jsonObject(from: line)
        return SDKLineInterpretation(
            isSDKError: object?["type"] as? String == "sdk_error",
            userInputRequest: bridgeUserInputRequest(in: object),
            runtimeEvent: object.flatMap {
                ProviderRuntimeEvent.fromJSONObjectIfNeeded($0, provider: .claude, source: "claude.agent-sdk")
            },
            parsedEvents: object.map { parser.parseObject($0) } ?? []
        )
    }

    private static func bridgeUserInputRequest(
        in object: [String: Any]?
    ) -> (id: String, requestedSchema: [String: Any]?)? {
        guard let obj = object,
              (obj["type"] as? String) == "user_input_request" else {
            return nil
        }
        guard let id = obj["request_id"] as? String
            ?? obj["id"] as? String
            ?? obj["elicitation_id"] as? String else { return nil }
        return (id, obj["requested_schema"] as? [String: Any])
    }

    private static func elicitationContent(
        text: String,
        requestedSchema: [String: Any]?
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
        let names = properties.keys.sorted()
        for name in names {
            guard let property = properties[name] as? [String: Any] else { continue }
            let raw: Any?
            if let structuredValue = structured[name] {
                raw = structuredValue
            } else if names.count == 1 {
                raw = text
            } else {
                raw = nil
            }
            guard let raw,
                  let value = elicitationValue(raw, type: property["type"] as? String) else { continue }
            if let allowed = property["enum"] as? [Any],
               !allowed.contains(where: { String(describing: $0) == String(describing: value) }) {
                continue
            }
            content[name] = value
        }
        let required = requestedSchema?["required"] as? [String] ?? []
        if let missing = required.first(where: { content[$0] == nil }) {
            throw AgentProviderAdapterError.unsupported(
                "Claude elicitation requires a valid value for \(missing)"
            )
        }
        return content
    }

    private static func elicitationValue(_ raw: Any, type: String?) -> Any? {
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

    private static func permissionDecision(for response: AgentProviderRequestResponse) -> String {
        switch response {
        case .approve: return "approve"
        case .approveForSession: return "approve_for_session"
        case .decline: return "decline"
        case .cancel: return "cancel"
        }
    }

    private static func requestState(for response: AgentProviderRequestResponse) -> AssistantRequestState {
        switch response {
        case .approve, .approveForSession: return .approved
        case .decline: return .declined
        case .cancel: return .cancelled
        }
    }

    private static func startedTurnId(_ event: AssistantEvent?) -> String? {
        guard let event, case .turnStarted(let turnId) = event else { return nil }
        return turnId
    }

    private static func completedTurnId(_ event: AssistantEvent?) -> String? {
        guard let event, case .turnCompleted(let turnId, _) = event else { return nil }
        return turnId
    }

    private static func resumeSessionAt(in events: [AssistantEvent]) -> String? {
        for event in events.reversed() {
            guard case .providerRuntime(let runtime) = event,
                  runtime.method == "claude.session.snapshot",
                  let data = runtime.payloadJSON.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let value = payload["resumeSessionAt"] as? String, !value.isEmpty {
                return value
            }
            if let value = payload["lastAssistantUuid"] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    // Pure helper — returns recoveredEvents keys eligible for pruning.
    // A key is eligible when it has no open session and no pending rollback re-use cursor,
    // meaning the thread was rolled back but never resumed. Safe to call under lock.
    // Extracted as nonisolated static for direct unit-testability without instantiating the adapter.
    nonisolated static func recoveredEventsPruneKeys(
        recoveredKeys: Set<AgentThreadID>,
        openIds: Set<AgentThreadID>,
        pendingIds: Set<AgentThreadID>
    ) -> Set<AgentThreadID> {
        recoveredKeys.subtracting(openIds).subtracting(pendingIds)
    }
}
