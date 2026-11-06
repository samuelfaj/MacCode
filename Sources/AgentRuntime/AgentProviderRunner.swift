import Foundation
import Darwin
import CoreModel

// MARK: - Spawn tagging

/// Immutable record written when a provider process is spawned.
/// `pgid` retains the historical field name; it stores the exact provider root
/// PID. The persistent ownership sweep reconstructs its current descendant tree.
public struct ProviderProcessStartIdentity: Codable, Sendable, Equatable {
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }

    public static func read(pid: pid_t) -> ProviderProcessStartIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_start_tvsec > 0 else {
            return nil
        }
        return ProviderProcessStartIdentity(
            seconds: info.pbi_start_tvsec,
            microseconds: info.pbi_start_tvusec
        )
    }
}

public enum ManagedProcessKind: String, Codable, Sendable, Equatable {
    case provider
    /// Decode-only: older builds tagged Distill sidecar and Graphify CLI
    /// children with these. The ledger decodes the whole tag array, so the
    /// cases stay to keep old rows readable and their orphans reapable.
    case sidecar
    case graphify
}

public struct SpawnedProcessTag: Codable, Sendable, Equatable {
    public let pgid: pid_t
    public let spawnedAt: Date
    public let ownerPID: pid_t
    public let ownerStartIdentity: ProviderProcessStartIdentity?
    public let provider: AgentProvider?
    public let managedKind: ManagedProcessKind?
    public let executablePath: String
    public let startIdentity: ProviderProcessStartIdentity?
    /// Present only when the spawned root was verified as the leader of its own
    /// process group. The leader start identity above anchors that group to the
    /// exact provider lifetime recorded at spawn.
    public let isolatedProcessGroup: pid_t?

    public init(
        pgid: pid_t,
        spawnedAt: Date,
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        ownerStartIdentity: ProviderProcessStartIdentity? = nil,
        provider: AgentProvider? = nil,
        managedKind: ManagedProcessKind? = nil,
        executablePath: String = "",
        startIdentity: ProviderProcessStartIdentity? = nil,
        isolatedProcessGroup: pid_t? = nil
    ) {
        self.pgid = pgid
        self.spawnedAt = spawnedAt
        self.ownerPID = ownerPID
        self.ownerStartIdentity = ownerStartIdentity
        self.provider = provider
        self.managedKind = managedKind
        self.executablePath = executablePath
        self.startIdentity = startIdentity
        self.isolatedProcessGroup = isolatedProcessGroup
    }
}

/// Pure helpers for tagging a spawned provider process and deciding
/// reap eligibility. nonisolated static so tests run without @MainActor.
public enum ProcessSpawnTagger {
    /// Default minimum age before a tagged process is eligible for reap.
    public static let defaultMinAge: TimeInterval = 30.0

    /// Terminate one controller-owned process lifetime without command matching
    /// or PID-only signalling. Intended for bounded sidecar handoff and app quit.
    public static func terminateExactOwnedProcessAndWait(
        _ process: Process,
        expectedStartIdentity: ProviderProcessStartIdentity?,
        graceInterval: TimeInterval = 0.25,
        timeout: TimeInterval = 2.5
    ) -> Bool {
        guard process.isRunning else { return true }
        let pid = process.processIdentifier
        guard let expectedStartIdentity,
              ProviderProcessStartIdentity.read(pid: pid) == expectedStartIdentity else {
            return false
        }

        let exactTargets: () -> [(pid: pid_t, identity: ProviderProcessStartIdentity)] = {
            guard ProviderProcessStartIdentity.read(pid: pid) == expectedStartIdentity else {
                return []
            }
            return ProcessTerminator.processTreePIDs(root: pid).compactMap { target in
                ProviderProcessStartIdentity.read(pid: target).map { (target, $0) }
            }
        }
        var targets = exactTargets()
        guard targets.contains(where: { $0.pid == pid && $0.identity == expectedStartIdentity }) else {
            return false
        }
        for target in targets where ProviderProcessStartIdentity.read(pid: target.pid) == target.identity {
            _ = Darwin.kill(target.pid, SIGTERM)
        }

        let grace = max(0, min(graceInterval, timeout))
        let start = Date()
        let escalationAt = start.addingTimeInterval(grace)
        let deadline = start.addingTimeInterval(max(0, timeout))
        var escalated = false
        while Date() < deadline {
            if !escalated, Date() >= escalationAt {
                if ProviderProcessStartIdentity.read(pid: pid) == expectedStartIdentity {
                    let currentTargets = exactTargets()
                    let newTargets = currentTargets.filter { candidate in
                        !targets.contains {
                            $0.pid == candidate.pid && $0.identity == candidate.identity
                        }
                    }
                    targets += newTargets
                }
                for target in targets where ProviderProcessStartIdentity.read(pid: target.pid) == target.identity {
                    _ = Darwin.kill(target.pid, SIGKILL)
                }
                escalated = true
            }
            let survivors = targets.contains {
                ProviderProcessStartIdentity.read(pid: $0.pid) == $0.identity
            }
            if !survivors { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !targets.contains {
            ProviderProcessStartIdentity.read(pid: $0.pid) == $0.identity
        }
    }

    /// Call immediately after `process.run()` to persist exact ownership.
    /// Foundation exposes no pre-exec group hook, so the post-spawn `setpgid`
    /// attempt is accepted only when the kernel immediately certifies the root
    /// as its own group leader. Failure kills the tree before any ledger row is
    /// written; availability never overrides complete crash-recovery ownership.
    ///
    /// `foreignUserLaunch` relaxes the child-metadata reads for a provider run as
    /// another macOS user via `RunAsUserProcessBootstrap`: the spawned
    /// child is a root-owned helper, whose `proc_pidinfo`/`proc_pidpath` are
    /// unreadable to this non-root parent (EPERM). We keep the row anchored on the
    /// always-readable OWNER identity (this app's own pid) plus the child pid, and
    /// tolerate a nil child start identity / exec path / process group. Live
    /// teardown is handled separately: the helper process is signalled directly
    /// and its target-uid descendants are reaped via `ProcessTerminator`'s
    /// helper-routed path (a non-root app cannot signal a different-uid `claude`
    /// directly). The cost is only crash-recovery reach: the sweep fail-safes such
    /// a row (never signals a PID it cannot identify), so a cross-user orphan
    /// surviving an app crash is retained, never mis-reaped. For a same-user launch
    /// (`foreignUserLaunch: false`) every read stays a hard gate.
    @discardableResult
    public static func tagProcess(
        _ process: Process,
        provider: AgentProvider? = nil,
        managedKind: ManagedProcessKind = .provider,
        foreignUserLaunch: Bool = false,
        now: Date = Date()
    ) throws -> SpawnedProcessTag {
        let pid = process.processIdentifier
        guard pid > 0 else {
            ProcessTerminator.terminateTreeImmediately(process)
            throw ProviderProcessOwnershipError.startIdentityUnavailable(pid)
        }
        // The owner is always this app's own process, so its kernel metadata is
        // readable and anchors the row for crash recovery even when the child is not.
        let ownerPID = ProcessInfo.processInfo.processIdentifier
        guard let ownerStartIdentity = ProviderProcessStartIdentity.read(pid: ownerPID) else {
            ProcessTerminator.terminateTreeImmediately(process)
            throw ProviderProcessOwnershipError.startIdentityUnavailable(ownerPID)
        }
        let startIdentity = ProviderProcessStartIdentity.read(pid: pid)
        guard startIdentity != nil || foreignUserLaunch else {
            ProcessTerminator.terminateTreeImmediately(process)
            throw ProviderProcessOwnershipError.startIdentityUnavailable(pid)
        }
        // Prefer the durable launch path over a transient shebang interpreter.
        // `#!/usr/bin/env node` scripts (Codex via Homebrew, many npm CLIs) race
        // `proc_pidpath` toward `/usr/bin/env` or `node` before the scan; the
        // Process.executableURL is the operator-intended binary and survives that
        // re-exec for ownership corroboration.
        let livePath = ProviderProcessExecutablePath.read(pid: pid)
        let launchedPath = process.executableURL?.path
        let executablePath = Self.preferredOwnershipExecutablePath(
            livePath: livePath,
            launchedPath: launchedPath
        )
        guard executablePath != nil || foreignUserLaunch else {
            ProcessTerminator.terminateTreeImmediately(process)
            throw ProviderProcessOwnershipError.executablePathUnavailable(pid)
        }
        let processGroup: pid_t?
        do {
            processGroup = try certifyIsolatedProcessGroup(
                pid: pid,
                setProcessGroup: { Darwin.setpgid($0, 0) },
                processGroup: Darwin.getpgid
            )
        } catch {
            // A helper-launched child's group cannot always be certified from a
            // non-root parent; leave the row owner-anchored without it. For a
            // same-user launch an uncertifiable group is still fail-closed.
            guard foreignUserLaunch else {
                ProcessTerminator.terminateTreeImmediately(process)
                throw error
            }
            processGroup = nil
        }
        let tag = SpawnedProcessTag(
            pgid: pid,
            spawnedAt: now,
            ownerPID: ownerPID,
            ownerStartIdentity: ownerStartIdentity,
            provider: provider,
            managedKind: managedKind,
            executablePath: executablePath ?? "",
            startIdentity: startIdentity,
            isolatedProcessGroup: processGroup
        )
        do {
            try ProviderProcessOwnership.shared.record(tag)
        } catch {
            // A provider without a durable ownership row cannot be certified for
            // cleanup after a host crash. Fail the spawn and synchronously reap
            // the process instead of creating unowned background work.
            ProcessTerminator.terminateTreeImmediately(process)
            throw error
        }
        return tag
    }

    static func certifyIsolatedProcessGroup(
        pid: pid_t,
        setProcessGroup: (pid_t) -> Int32,
        processGroup: (pid_t) -> pid_t
    ) throws -> pid_t {
        _ = setProcessGroup(pid)
        let group = processGroup(pid)
        guard group == pid else {
            throw ProviderProcessOwnershipError.isolatedProcessGroupUnavailable(pid)
        }
        return group
    }

    /// Pure eligibility decision: a tagged process is reapable when
    ///   - it is still alive (process exists)
    ///   - it has lived longer than minAge (not just freshly spawned)
    /// The caller supplies isAlive and now so this stays fully testable.
    public static func isEligibleForReap(
        pgid: pid_t,
        spawnedAt: Date,
        minAge: TimeInterval = defaultMinAge,
        isAlive: (pid_t) -> Bool,
        now: Date = Date()
    ) -> Bool {
        guard isAlive(pgid) else { return false }
        return now.timeIntervalSince(spawnedAt) >= minAge
    }

    /// Choose the path stored in the ownership ledger for a just-spawned process.
    /// Prefer a non-env live `proc_pidpath` result; fall back to the Process launch
    /// URL when the kernel still reports the shebang trampoline (`env`) so Codex
    /// and other `#!/usr/bin/env node` CLIs do not permanently poison accounting.
    public static func preferredOwnershipExecutablePath(
        livePath: String?,
        launchedPath: String?
    ) -> String? {
        if let livePath, !livePath.isEmpty, !isEnvStyleLauncher(livePath) {
            return livePath
        }
        if let launchedPath, !launchedPath.isEmpty {
            return launchedPath
        }
        if let livePath, !livePath.isEmpty {
            return livePath
        }
        return nil
    }

    static func isEnvStyleLauncher(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == "env"
    }
}

public enum AgentRunEvent: Sendable {
    case event(AssistantEvent)
    case status(AgentRunStatus)
    case finished(AgentRunStatus, finalMessage: String?, providerThreadId: String?)
    case error(String)
}

public protocol AgentProviderRunner: AnyObject {
    var provider: AgentProvider { get }
    func listModels() async -> [AgentModelDescriptor]
    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle
}

public struct AgentProviderSessionSummary: Sendable, Equatable {
    public let threadId: AgentThreadID
    public let provider: AgentProvider
    public let status: AgentRunStatus
    public let providerThreadId: String?
    /// A turn was ended by the host while a tool call was still open, so the
    /// tool may still be running in this session's process tree.
    public let toolsMayStillRun: Bool

    public init(
        threadId: AgentThreadID,
        provider: AgentProvider,
        status: AgentRunStatus,
        providerThreadId: String?,
        toolsMayStillRun: Bool = false
    ) {
        self.threadId = threadId
        self.provider = provider
        self.status = status
        self.providerThreadId = providerThreadId
        self.toolsMayStillRun = toolsMayStillRun
    }
}

public enum AgentProviderRequestResponse: Sendable, Equatable {
    case approve
    case approveForSession
    case decline(String?)
    case cancel
}

public enum AgentProviderAdapterError: Error, CustomStringConvertible {
    case unsupported(String)
    case sessionNotFound(AgentThreadID)
    /// The provider refused the fork outright (bad method, bad params, no
    /// source session) and created no child, so the fork intent can be
    /// retired instead of blocking every later fork of the same thread.
    case forkRejected(String)

    public var description: String {
        switch self {
        case .unsupported(let operation): return "Provider adapter operation unsupported: \(operation)"
        case .sessionNotFound(let threadId): return "Provider session not found: \(threadId.value.uuidString)"
        case .forkRejected(let reason): return "The provider could not fork this thread: \(reason)"
        }
    }
}

/// Provider-side fork is only safe to expose when repeating the same request
/// key is guaranteed to return the same provider child. Without that contract,
/// a crash after the provider response but before the local SQLite commit can
/// orphan one child and create another on retry.
public enum AgentProviderForkSafety: Sendable, Equatable {
    case unsupported
    case keyedIdempotent(compensationSupported: Bool)

    public var supportsDurableFork: Bool {
        if case .keyedIdempotent(let compensationSupported) = self {
            return compensationSupported
        }
        return false
    }

    public var supportsCompensation: Bool {
        if case .keyedIdempotent(let compensationSupported) = self {
            return compensationSupported
        }
        return false
    }
}

public struct AgentProviderForkRequest: Sendable, Equatable {
    public let sourceThreadId: AgentThreadID
    public let childThreadId: AgentThreadID
    public let idempotencyKey: String
    public let workingDirectory: String?
    public let sourceProviderThreadId: String?
    /// The cwd the source's provider session was last opened with; a provider
    /// that stores sessions per directory needs it to fork a saved session.
    public let sourceWorkingDirectory: String?
    /// The child is an ephemeral side chat (`/side`) rather than a kept fork (`/fork`).
    public let isSide: Bool

    public init(
        sourceThreadId: AgentThreadID,
        childThreadId: AgentThreadID,
        idempotencyKey: String,
        workingDirectory: String? = nil,
        sourceProviderThreadId: String? = nil,
        sourceWorkingDirectory: String? = nil,
        isSide: Bool = false
    ) {
        self.sourceThreadId = sourceThreadId
        self.childThreadId = childThreadId
        self.idempotencyKey = idempotencyKey
        self.workingDirectory = workingDirectory
        self.sourceProviderThreadId = sourceProviderThreadId
        self.sourceWorkingDirectory = sourceWorkingDirectory
        self.isSide = isSide
    }
}

public protocol AgentProviderAdapter: AnyObject {
    var provider: AgentProvider { get }
    var forkSafety: AgentProviderForkSafety { get }
    func forkSafety(threadId: AgentThreadID) -> AgentProviderForkSafety
    func listModels() async -> [AgentModelDescriptor]
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle
    func interruptTurn(threadId: AgentThreadID) throws
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws
    func respondToUserInput(threadId: AgentThreadID, requestId: String, verbatimText: String, outboundText: String) throws
    func cancelUserInput(threadId: AgentThreadID, requestId: String) throws
    func stopSession(threadId: AgentThreadID) throws
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws
    func listSessions() -> [AgentProviderSessionSummary]
    func hasSession(threadId: AgentThreadID) -> Bool
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent]
    func forkThread(threadId: AgentThreadID) async throws -> String
    func forkThread(_ request: AgentProviderForkRequest) async throws -> String
    func compensateFork(_ request: AgentProviderForkRequest, providerChildThreadId: String) async throws
    func btw(threadId: AgentThreadID, question: String) async throws -> String
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws
    func stopAll()
    func stopAllForAppTermination()
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws
}

public extension AgentProviderAdapter {
    var forkSafety: AgentProviderForkSafety { .unsupported }

    func forkSafety(threadId: AgentThreadID) -> AgentProviderForkSafety {
        forkSafety
    }

    func respondToUserInput(threadId: AgentThreadID, requestId: String, verbatimText: String, outboundText: String) throws {
        try respondToUserInput(threadId: threadId, requestId: requestId, text: verbatimText)
    }

    func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {
        throw AgentProviderAdapterError.unsupported("User input cancellation is not available for this provider session.")
    }

    func forkThread(threadId: AgentThreadID) async throws -> String {
        throw AgentProviderAdapterError.unsupported("provider-native fork")
    }

    func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
        throw AgentProviderAdapterError.unsupported("crash-safe keyed provider fork")
    }

    func compensateFork(_ request: AgentProviderForkRequest, providerChildThreadId: String) async throws {
        throw AgentProviderAdapterError.unsupported("idempotent provider fork compensation")
    }

    func btw(threadId: AgentThreadID, question: String) async throws -> String {
        throw AgentProviderAdapterError.unsupported("provider side question")
    }

    func stopAllForAppTermination() {
        stopAll()
    }
}

public final class OneShotProviderAdapter: AgentProviderAdapter, @unchecked Sendable {
    public let runner: AgentProviderRunner
    private let lock = NSLock()
    private var sessions: [AgentThreadID: AgentProviderSessionSummary] = [:]
    private var handles: [AgentThreadID: AgentRunHandle] = [:]

    public var provider: AgentProvider { runner.provider }

    public init(runner: AgentProviderRunner) {
        self.runner = runner
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await runner.listModels()
    }

    public func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    public func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.withLock {
            sessions[request.threadId] = AgentProviderSessionSummary(threadId: request.threadId, provider: provider, status: .running, providerThreadId: request.providerThreadId)
        }
        let handle: AgentRunHandle
        do {
            handle = try await runner.startRun(request) { [weak self] event in
                self?.record(event: event, threadId: request.threadId)
                onEvent(event)
            }
        } catch {
            lock.withLock {
                sessions.removeValue(forKey: request.threadId)
                handles.removeValue(forKey: request.threadId)
            }
            throw error
        }
        lock.withLock {
            handles[request.threadId] = handle
        }
        return handle
    }

    public func interruptTurn(threadId: AgentThreadID) throws {
        lock.lock()
        let handle = handles[threadId]
        lock.unlock()
        guard let handle else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        handle.cancel()
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        throw AgentProviderAdapterError.unsupported("Approvals are not available in one-shot CLI mode. Use supervised or streaming mode to approve tool requests.")
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        throw AgentProviderAdapterError.unsupported("User input responses are not available in one-shot CLI mode. Use supervised or streaming mode.")
    }

    public func stopSession(threadId: AgentThreadID) throws {
        // A resident session whose turn already finished has no handle; stopping
        // it retires the session, like the streaming adapters do. A running
        // session without a handle is still starting and keeps throwing, so the
        // coordinator's pending stop cancels it once the handle registers.
        lock.lock()
        let finishedResident = handles[threadId] == nil
            && sessions[threadId].map { $0.status != .running && $0.status != .pending } == true
        if finishedResident {
            sessions.removeValue(forKey: threadId)
        }
        lock.unlock()
        if finishedResident { return }
        try interruptTurn(threadId: threadId)
        lock.lock()
        sessions.removeValue(forKey: threadId)
        handles.removeValue(forKey: threadId)
        lock.unlock()
    }

    public func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported("recoverSession requires providerThreadId")
        }
        lock.lock()
        sessions[request.threadId] = AgentProviderSessionSummary(threadId: request.threadId, provider: provider, status: .completed, providerThreadId: request.providerThreadId)
        lock.unlock()
    }

    public func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return Array(sessions.values)
    }

    public func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId] != nil
    }

    public func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        throw AgentProviderAdapterError.unsupported("readThread")
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        throw AgentProviderAdapterError.unsupported("rollbackThread")
    }

    public func stopAll() {
        lock.lock()
        let activeHandles = Array(handles.values)
        sessions.removeAll()
        handles.removeAll()
        lock.unlock()
        activeHandles.forEach { $0.cancel() }
    }

    public func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {
        throw AgentProviderAdapterError.unsupported("streamEvents")
    }

    private func record(event: AgentRunEvent, threadId: AgentThreadID) {
        guard case .finished(let status, _, let providerThreadId) = event else { return }
        lock.lock()
        sessions[threadId] = AgentProviderSessionSummary(threadId: threadId, provider: provider, status: status, providerThreadId: providerThreadId)
        handles.removeValue(forKey: threadId)
        lock.unlock()
    }

    /// Align the resident session after a coordinator-synthesized terminal.
    ///
    /// Stop claims cancellation through `AgentRunCoordinator.handle` without
    /// re-entering this adapter's event callback, so `record(.finished)` never
    /// runs. Without this, `status` stays `.running` and the next `startRun` is
    /// rejected as an in-flight turn even after durable terminal commit.
    func noteCoordinatorTerminal(
        threadId: AgentThreadID,
        status: AgentRunStatus,
        providerThreadId: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = sessions[threadId] else { return }
        guard existing.status == .running || existing.status == .pending else { return }
        sessions[threadId] = AgentProviderSessionSummary(
            threadId: existing.threadId,
            provider: existing.provider,
            status: status,
            providerThreadId: providerThreadId ?? existing.providerThreadId
        )
        // This is only the coordinator's durable terminal projection; it is
        // not proof that the provider process acknowledged cancellation. Keep
        // the handle so stopAndAwaitTermination (including a second Stop click)
        // can still cancel/tear down the exact provider work. A real provider
        // `.finished` event removes it in record(event:threadId:).
    }
}

public final class AgentRunHandle: @unchecked Sendable {
    public let runId: AgentRunID
    public let process: Process?
    private let cancelHandler: () -> Void

    public init(runId: AgentRunID, process: Process?, cancel: @escaping () -> Void) {
        self.runId = runId
        self.process = process
        self.cancelHandler = cancel
    }

    public func cancel() {
        cancelHandler()
    }
}

final class AgentCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct ProcessTerminationStep: Equatable {
    let pid: Int32
    let signal: Int32
}

enum ProcessTerminator {
    // Grace window between SIGTERM and SIGKILL escalation.
    static let graceInterval: TimeInterval = 2.0

    /// When `foreignUserUID` is set, `root` may be the helper-launched
    /// target-uid provider itself. This non-root app cannot `SIGKILL` a
    /// target-uid process directly (EPERM), so the escalation reaps every
    /// still-alive PID, including `root`, through the installed helper. NOTE:
    /// graceful SIGTERM for an exec-in-place root and PID-reuse-proof identity
    /// gating remain follow-ups.
    static func terminateTree(_ process: Process, grace: TimeInterval = graceInterval, foreignUserUID: uid_t? = nil) {
        let root = process.processIdentifier
        // Enumerate the tree once (children first so leaves die before parents),
        // including the root, then signal each node.
        let pids = processTreePIDs(root: root)

        for step in terminationPlan(pids: pids, isAlive: { _ in true }, graceElapsed: false) {
            kill(step.pid, step.signal)
        }

        // Cancel must always win: give SIGTERM a grace period, then escalate any
        // survivors to SIGKILL. The grace wait is scheduled on a background
        // queue — every cancel path (Stop button, queue drain, idle reap) runs
        // on the main thread, so sleeping here froze the UI for the whole
        // grace window (F15). Never block the calling thread.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) {
            let escalation = terminationPlan(pids: pids, isAlive: Self.isAlive(_:), graceElapsed: true)
            for step in escalation {
                kill(step.pid, step.signal)
            }
            if let foreignUserUID {
                let survivors = pids.filter { Self.isAlive($0) }
                killAsUserProvider(foreignUserUID, SIGKILL, survivors)
            }
        }
    }

    /// App termination cannot rely on the deferred escalation above: the app
    /// process may exit before its asyncAfter block runs, leaving a provider
    /// child alive for the next launch to rejoin. Preserve TERM-before-KILL,
    /// but deliver both phases synchronously without sleeping on the main actor.
    static func terminateTreeImmediately(_ process: Process, foreignUserUID: uid_t? = nil) {
        let root = process.processIdentifier
        let pids = processTreePIDs(root: root)
        for step in terminationPlan(pids: pids, isAlive: { _ in true }, graceElapsed: false) {
            kill(step.pid, step.signal)
        }
        // Reap the target-uid subtree via the installed helper BEFORE the direct
        // SIGKILL below. Include `root`: it may be the exec-in-place provider;
        // excluding it could orphan the provider to launchd. The helper is
        // non-interactive, so this stays synchronous on app quit.
        if let foreignUserUID {
            killAsUserProvider(foreignUserUID, SIGKILL, pids)
        }
        for pid in pids {
            kill(pid, SIGKILL)
        }
    }

    /// The real helper-routed reaper. Named so tests can restore it after swapping
    /// in a capture double (mirrors `LibprocChildPIDProvider` for childPIDProvider).
    static let defaultKillAsUserProvider: (uid_t, Int32, [pid_t]) -> Void = { uid, signal, pids in
        // Teardown must never install or authorize a helper while the app is
        // exiting. `runPrivilegedSignal` fails closed when it is unavailable.
        _ = RunAsUserProcessBootstrap.runPrivilegedSignal(uid: uid, signal: signal, pids: pids)
    }

    /// Delivers `signal` to `pids` as the target uid via the installed helper.
    /// Injectable so tests can assert routing without spawning the helper.
    static var killAsUserProvider: (uid_t, Int32, [pid_t]) -> Void = defaultKillAsUserProvider

    // Pure helper: builds the signal plan for a set of pids.
    // graceElapsed == false  -> phase 1: SIGTERM every pid.
    // graceElapsed == true   -> phase 2: SIGKILL only pids still alive (skip dead).
    static func terminationPlan(
        pids: [Int32],
        isAlive: (Int32) -> Bool,
        graceElapsed: Bool
    ) -> [ProcessTerminationStep] {
        if !graceElapsed {
            return pids.map { ProcessTerminationStep(pid: $0, signal: SIGTERM) }
        }
        return pids
            .filter { isAlive($0) }
            .map { ProcessTerminationStep(pid: $0, signal: SIGKILL) }
    }

    /// Claude interrupt fallback only: SIGINT ends the in-progress turn
    /// (SIGTERM leaves it unfinished so `--resume` continues it).
    /// graceElapsed == false -> SIGINT every pid; true -> SIGKILL survivors.
    static func interruptPlan(
        pids: [Int32],
        isAlive: (Int32) -> Bool,
        graceElapsed: Bool
    ) -> [ProcessTerminationStep] {
        if !graceElapsed {
            return pids.map { ProcessTerminationStep(pid: $0, signal: SIGINT) }
        }
        return pids
            .filter { isAlive($0) }
            .map { ProcessTerminationStep(pid: $0, signal: SIGKILL) }
    }

    /// Claude interrupt fallback. Does not change `terminateTree` (SIGTERM first)
    /// used by Codex, Grok, and Claude session teardown.
    static func interruptTree(_ process: Process, grace: TimeInterval = graceInterval, foreignUserUID: uid_t? = nil) {
        let root = process.processIdentifier
        let pids = processTreePIDs(root: root)

        for step in interruptPlan(pids: pids, isAlive: { _ in true }, graceElapsed: false) {
            kill(step.pid, step.signal)
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) {
            let escalation = interruptPlan(pids: pids, isAlive: Self.isAlive(_:), graceElapsed: true)
            for step in escalation {
                kill(step.pid, step.signal)
            }
            if let foreignUserUID {
                let survivors = pids.filter { Self.isAlive($0) }
                killAsUserProvider(foreignUserUID, SIGKILL, survivors)
            }
        }
    }

    // Liveness probe via signal 0 (no signal sent, only error checking).
    static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        // EPERM means the process exists but we lack permission; still alive.
        return errno == EPERM
    }

    // Returns the full process subtree rooted at `root` (children-first, root last).
    // Uses the injected `childPIDProvider` so tests can supply fake process trees
    // without spawning real processes.
    // `internal` (not `private`) so tests can call it directly to verify provider wiring.
    static func processTreePIDs(root: Int32) -> [Int32] {
        childPIDProvider.directChildren(of: root).flatMap(processTreePIDs(root:)) + [root]
    }

    /// After the root has been signalled, multiprocessing helpers (for example a
    /// Python resource_tracker) can remain. Recapture the tree and keep only
    /// still-alive non-root PIDs so a timeout cannot leak them.
    static func unreapedDescendants(
        root: Int32,
        tree: [Int32],
        isAlive: (Int32) -> Bool = { ProcessTerminator.isAlive($0) }
    ) -> [Int32] {
        tree.filter { pid in pid != root && pid > 0 && isAlive(pid) }
    }

    /// Tracks a provider tree across repeated teardown polls. `knownPIDs`
    /// retains children after reparenting; an isolated process group catches a
    /// child that forks during the root's TERM trap before the next tree scan.
    struct TreeTracker {
        let root: pid_t
        let isolatedProcessGroup: pid_t?
        private(set) var startIdentities: [pid_t: ProviderProcessStartIdentity] = [:]

        init(root: pid_t) {
            self.root = root
            let group = Darwin.getpgid(root)
            self.isolatedProcessGroup = group == root ? group : nil
            refresh()
        }

        init(
            root: pid_t,
            isolatedProcessGroup: pid_t?,
            initialPIDs: [pid_t],
            identity: (pid_t) -> ProviderProcessStartIdentity?
        ) {
            self.root = root
            self.isolatedProcessGroup = isolatedProcessGroup
            for pid in initialPIDs {
                if let value = identity(pid) { startIdentities[pid] = value }
            }
        }

        mutating func refresh() {
            refresh(
                descendants: { ProcessTerminator.processTreePIDs(root: $0) },
                processGroupMembers: ProcessTerminator.processGroupPIDs,
                identity: { ProviderProcessStartIdentity.read(pid: $0) }
            )
        }

        mutating func refresh(
            descendants: (pid_t) -> [pid_t],
            processGroupMembers: (pid_t) -> [pid_t],
            identity: (pid_t) -> ProviderProcessStartIdentity?
        ) {
            var candidates = descendants(root)
            if let isolatedProcessGroup {
                candidates.append(contentsOf: processGroupMembers(isolatedProcessGroup))
            }
            candidates.append(root)
            for pid in Set(candidates) where pid > 0 && pid != ProcessInfo.processInfo.processIdentifier {
                if startIdentities[pid] == nil, let value = identity(pid) {
                    startIdentities[pid] = value
                }
            }
        }

        func survivingPIDs(
            identity: (pid_t) -> ProviderProcessStartIdentity? = {
                ProviderProcessStartIdentity.read(pid: $0)
            }
        ) -> [pid_t] {
            startIdentities.compactMap { pid, expected in
                identity(pid) == expected ? pid : nil
            }.sorted()
        }

        func signalSurvivors(_ signal: Int32) {
            for pid in survivingPIDs().reversed() {
                _ = Darwin.kill(pid, signal)
            }
        }
    }

    static func processGroupPIDs(_ group: pid_t) -> [pid_t] {
        guard group > 0 else { return [] }
        let estimatedCount = max(1, Int(proc_listallpids(nil, 0)))
        var pids = [pid_t](repeating: 0, count: estimatedCount * 2)
        let count = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 && Darwin.getpgid($0) == group }
    }

    // MARK: - Child-PID provider seam

    /// Abstracts the kernel lookup of direct child PIDs so termination ordering
    /// and escalation logic can be exercised in unit tests with a fake tree,
    /// without spawning real processes (Rule 8). The default implementation
    /// calls `proc_listchildpids` directly (libproc, single enumeration).
    /// `internal` so `@testable import AgentRuntime` exposes it to tests.
    protocol ChildPIDProviding: Sendable {
        func directChildren(of pid: Int32) -> [Int32]
    }

    /// Real (production) provider backed by `proc_listchildpids`.
    struct LibprocChildPIDProvider: ChildPIDProviding {
        func directChildren(of pid: Int32) -> [Int32] {
            let size = proc_listchildpids(pid, nil, 0)
            guard size > 0 else { return [] }
            var buffer = [pid_t](repeating: 0, count: Int(size))
            let written = proc_listchildpids(pid, &buffer, size * Int32(MemoryLayout<pid_t>.size))
            guard written > 0 else { return [] }
            let count = min(Int(written), buffer.count)
            return buffer.prefix(count).filter { $0 > 0 }
        }
    }

    /// Injected provider; defaults to the real `proc_listchildpids` implementation.
    /// Tests replace this with a `FakeChildPIDProvider` that returns a pre-wired tree.
    /// Written only in tests (before concurrent access begins) and read on a
    /// single thread from `terminateTree`.  There is no concurrent mutation in production.
    static var childPIDProvider: any ChildPIDProviding = LibprocChildPIDProvider()
}
