import Foundation
import Darwin
import CoreModel
import RemoteCodeCSystem

public enum TerminalInputStatus: String, Sendable, Equatable {
    case accepted
    case inputStalled = "input_stalled"
    case queueFull = "queue_full"
    case processExited = "process_exited"
    case surfaceNotFound = "surface_not_found"
    case writeFailed = "write_failed"
}

public struct TerminalRuntimeHealth: Sendable, Equatable {
    public var processAlive: Bool
    public var childPID: Int32?
    public var exitStatus: Int32?
    public var terminationSignal: Int32?
    public var ptyOpen: Bool
    public var inputAccepting: Bool
    public var terminalDeadReason: String?
    public var lastOutputAt: Date?
    public var outputPartial: Bool
    public var outputPartialReason: String? = nil
    public var outputPendingBytes: Int
    public var historyWriteFailures: Int
    public var droppedOutputBytes: Int = 0
    public var rows: Int
    public var cols: Int
    public var renderDiagnostics: TerminalRenderDiagnostics? = nil

    public var alive: Bool {
        processAlive && ptyOpen && terminalDeadReason == nil
    }
}

public struct TerminalTextSnapshot: Sendable, Equatable {
    public var text: String
    public var ansiText: String? = nil
    /// Resolved 16-entry ANSI palette (indices 0-15) as `#rrggbb` hex strings,
    /// populated ONLY when the active Ghostty theme differs from the built-in
    /// default palette. `nil` means "default palette" -- iOS renders with its
    /// own hardcoded default. Serialized as `ansi_palette: null` so clients can
    /// clear a previously cached custom palette for the same surface.
    public var ansiPalette: [String]? = nil
    public var complete: Bool
    public var source: String
    public var timestamp: Date
    public var partialReason: String?
    public var pendingBytes: Int
    public var rows: Int
    public var cols: Int
    public var renderDiagnostics: TerminalRenderDiagnostics? = nil
}

public struct TerminalRenderDiagnostics: Sendable, Equatable {
    public var logicalVisible: Bool
    public var registryVisible: Bool
    public var drainingHiddenBacklog: Bool
    public var windowAttached: Bool
    public var parked: Bool
    public var hasUsableBounds: Bool
    public var hiddenAncestor: Bool
    public var blockedReason: String?

    public var canRender: Bool {
        logicalVisible &&
        registryVisible &&
        !drainingHiddenBacklog &&
        windowAttached &&
        !parked &&
        hasUsableBounds &&
        !hiddenAncestor
    }

    public init(
        logicalVisible: Bool,
        registryVisible: Bool,
        drainingHiddenBacklog: Bool,
        windowAttached: Bool,
        parked: Bool,
        hasUsableBounds: Bool,
        hiddenAncestor: Bool
    ) {
        self.logicalVisible = logicalVisible
        self.registryVisible = registryVisible
        self.drainingHiddenBacklog = drainingHiddenBacklog
        self.windowAttached = windowAttached
        self.parked = parked
        self.hasUsableBounds = hasUsableBounds
        self.hiddenAncestor = hiddenAncestor
        self.blockedReason = Self.firstBlockedReason(
            logicalVisible: logicalVisible,
            registryVisible: registryVisible,
            drainingHiddenBacklog: drainingHiddenBacklog,
            windowAttached: windowAttached,
            parked: parked,
            hasUsableBounds: hasUsableBounds,
            hiddenAncestor: hiddenAncestor
        )
    }

    static func firstBlockedReason(
        logicalVisible: Bool,
        registryVisible: Bool,
        drainingHiddenBacklog: Bool,
        windowAttached: Bool,
        parked: Bool,
        hasUsableBounds: Bool,
        hiddenAncestor: Bool
    ) -> String? {
        if !logicalVisible { return "logical_hidden" }
        if !registryVisible { return "registry_hidden" }
        if drainingHiddenBacklog { return "hidden_backlog_draining" }
        if !windowAttached { return "window_detached" }
        if parked { return "parking_window" }
        if !hasUsableBounds { return "invalid_bounds" }
        if hiddenAncestor { return "hidden_ancestor" }
        return nil
    }
}

struct TerminalStartupEnvironment: Equatable {
    static let managedTerminalType = "xterm-256color"
    static let managedColorTerm = "truecolor"
    static let managedTerminalProgram = "ghostty"

    private static let blankedInheritedAgentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX"
    ]

    var assignments: [String: String]
    var removals: Set<String>

    init(
        parent: [String: String] = ProcessInfo.processInfo.environment,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID
    ) {
        var assignments: [String: String] = [
            "TERM": Self.managedTerminalType,
            "COLORTERM": Self.managedColorTerm,
            "CLICOLOR": "1",
            "TERM_PROGRAM": Self.managedTerminalProgram,
            "RC2_WORKSPACE_ID": workspaceID.value.uuidString,
            "RC2_SURFACE_ID": surfaceID.value.uuidString
        ]

        if parent["LANG"] == nil {
            assignments["LANG"] = "en_US.UTF-8"
        }

        let home = parent["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let installedBins = [(".local/share/maccode-node/bin", "node"), (".local/share/distill/bin", "distill")]
            .map { (home + "/" + $0.0, $0.1) }
            .filter { FileManager.default.isExecutableFile(atPath: $0.0 + "/" + $0.1) }.map { $0.0 }
        if !installedBins.isEmpty {
            var seen = Set<String>()
            assignments["PATH"] = (installedBins + (parent["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init))
                .filter { seen.insert($0).inserted }.joined(separator: ":")
        }

        for key in Self.blankedInheritedAgentKeys where parent[key] != nil {
            assignments[key] = ""
        }

        self.assignments = assignments
        self.removals = ["NO_COLOR"]
    }

    func mergedEnvironment(parent: [String: String]) -> [String: String] {
        var environment = parent
        for key in removals {
            environment.removeValue(forKey: key)
        }
        for (key, value) in assignments where !key.isEmpty {
            environment[key] = value
        }
        return environment
    }

    static func shellPath(from parent: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let value = parent["SHELL"] ?? "/bin/zsh"
        return value.isEmpty ? "/bin/zsh" : value
    }
}

enum TerminalPTYProcessRuntime {
    private static let childReapQueue = DispatchQueue(
        label: "rc2.terminal.child-reaper",
        qos: .utility
    )
    private static let applicationTerminationQueue = DispatchQueue(
        label: "rc2.terminal.application-termination",
        qos: .userInitiated,
        attributes: .concurrent
    )
    /// Accessed only on `childReapQueue`. Registration transfers final waitpid
    /// ownership away from the normal asynchronous reaper during disposition.
    private static var applicationTerminationPIDs = Set<pid_t>()
    private static var activeApplicationTerminationWorks: [pid_t: ApplicationTerminationWork] = [:]
    /// Joinable tab-close / EOF reapers. Unrelated to app-termination ownership;
    /// app quit aggregates these so work started before SurfaceRegistry unregister
    /// remains waitable without replacing the normal reaper path.
    private static var activeChildReapWorks: [pid_t: ApplicationTerminationWork] = [:]

    static func spawn(
        cwd: String,
        executable: String,
        arguments: [String],
        environment: [String: String],
        suspendedBeforeExec: Bool = false
    ) -> (pid: pid_t, masterFD: Int32) {
        var argv = arguments.map { strdup($0) }
        var envp = environment.sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") }
        argv.append(nil)
        envp.append(nil)
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }

        var masterFD: Int32 = -1
        let pid = cwd.withCString { cwdPointer in
            executable.withCString { executablePointer in
                argv.withUnsafeMutableBufferPointer { argvPointer in
                    envp.withUnsafeMutableBufferPointer { envpPointer in
                        if suspendedBeforeExec {
                            return rc2_spawnpty_exec_suspended(
                                &masterFD,
                                cwdPointer,
                                executablePointer,
                                argvPointer.baseAddress,
                                envpPointer.baseAddress
                            )
                        }
                        return rc2_spawnpty_exec(
                            &masterFD,
                            cwdPointer,
                            executablePointer,
                            argvPointer.baseAddress,
                            envpPointer.baseAddress
                        )
                    }
                }
            }
        }
        return (pid, masterFD)
    }

    struct CapturedForegroundProcessGroup: Sendable, Equatable, Hashable {
        let pgid: pid_t
        let sessionID: pid_t
    }

    enum CapturedGroupValidation: Sendable, Equatable {
        case active
        case gone
        case unverifiable
    }

    enum ReapPollDecision: Sendable, Equatable {
        case continuePolling
        case finish
        case beginTimeoutGrace
        case timeout
    }

    enum ChildSuspensionResult: Sendable, Equatable {
        case suspended
        case ownershipConsumed
        case failed
    }

    enum OwnedProcessStatusSnapshot: Equatable {
        case snapshot(parentPID: UInt32, status: UInt32)
        case unavailable
    }

    enum StoppedChildWaitObservation: Equatable {
        case stopped(signal: Int32)
        case exited
        case continued
        case ownedAliveNoEvent
        case unowned
        case unknown
    }

    struct ChildReapResult: Sendable, Equatable {
        let status: Int32?
        let timedOut: Bool
        let foregroundGroupRemaining: Bool
        let shellReaped: Bool
    }

    struct ApplicationTerminationWork: Sendable {
        let group: DispatchGroup
        let succeeded: @Sendable () -> Bool
    }

    private final class ApplicationTerminationResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func complete(_ succeeded: Bool) {
            lock.lock()
            value = succeeded
            lock.unlock()
        }

        func read() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private enum OwnedChildPoll: Equatable {
        case alive
        case exited
        case unowned
        case unknown
    }

    private struct ApplicationTerminationProgress {
        let child: OwnedChildPoll
        let sessionGroups: Set<CapturedForegroundProcessGroup>
        let sessionGroupsFinished: Bool
        let hasEnumeratedOwnedSession: Bool
        let ownershipEstablished: Bool

        var readyToReap: Bool {
            if ownershipEstablished {
                return (child == .exited || child == .unowned)
                    && sessionGroupsFinished
                    && hasEnumeratedOwnedSession
            }
            // ECHILD is safe to accept only as a no-signal completion. The normal
            // reaper now holds WNOWAIT until its whole captured session is gone.
            return child == .unowned && sessionGroupsFinished
        }
    }

    private struct ChildReapState: Sendable {
        var shellExitObserved = false
        var shellAlreadyReaped = false
        var sentHangup: Bool
        var sentTerminate = false
        var sentKill = false
        var deadlineKillSent = false
        var sessionGroups = Set<CapturedForegroundProcessGroup>()
        var hangupSignaledGroups = Set<CapturedForegroundProcessGroup>()
        var terminateSignaledGroups = Set<CapturedForegroundProcessGroup>()
        var killSignaledGroups = Set<CapturedForegroundProcessGroup>()
    }

    private static let maxReapDuration: TimeInterval = 5
    private static let postKillReapGrace: TimeInterval = 0.5

    static func reapPollDecision(
        shellExitObserved: Bool,
        groupValidation: CapturedGroupValidation,
        elapsed: TimeInterval,
        deadlineKillSent: Bool = false
    ) -> ReapPollDecision {
        if shellExitObserved, groupValidation == .gone { return .finish }
        if elapsed >= maxReapDuration + postKillReapGrace { return .timeout }
        if elapsed >= maxReapDuration, !deadlineKillSent { return .beginTimeoutGrace }
        return .continuePolling
    }

    /// Captures the foreground job's kernel session before teardown starts.
    /// Later escalation validates that at least one current member still belongs
    /// to this exact session before signalling the numeric process-group id.
    static func captureForegroundProcessGroup(
        pgid: pid_t?,
        shellPID: pid_t
    ) -> CapturedForegroundProcessGroup? {
        guard let pgid, pgid > 0, pgid != shellPID else { return nil }
        let foregroundSessionID = Darwin.getsid(pgid)
        // forkpty makes the child shell the controlling-session leader, so the
        // immutable expected SID is the reserved child PID itself. This remains
        // trustworthy while WNOWAIT holds the zombie even if getsid(shellPID)
        // stops answering on a particular macOS release.
        guard foregroundSessionID == shellPID else { return nil }
        let shellSessionID = Darwin.getsid(shellPID)
        // The shell may already be a zombie when PTY EOF is delivered. In that
        // case getsid(shellPID) can fail, but tcgetpgrp supplied this foreground
        // PGID directly from our controlling terminal and the live group leader
        // still exposes the session identity. While the shell is queryable, require
        // both identities to agree.
        if shellSessionID > 0, shellSessionID != shellPID { return nil }
        let target = CapturedForegroundProcessGroup(
            pgid: pgid,
            sessionID: shellPID
        )
        guard currentValidation(of: target) == .active else { return nil }
        return target
    }

    /// Pure validation seam. A numeric PGID that now belongs only to another
    /// session is the forced-reuse case and must be treated as gone, never
    /// signalled. Empty membership is also gone.
    static func validation(
        of target: CapturedForegroundProcessGroup,
        memberPIDs: [pid_t],
        processGroup: (pid_t) -> pid_t,
        session: (pid_t) -> pid_t
    ) -> CapturedGroupValidation {
        for memberPID in memberPIDs where memberPID > 0 {
            if processGroup(memberPID) == target.pgid,
               session(memberPID) == target.sessionID {
                return .active
            }
        }
        return .gone
    }

    private static func allProcessPIDs() -> [pid_t]? {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) * 2)
        let count = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard count >= 0 else { return nil }
        return Array(pids.prefix(Int(count)))
    }

    static func currentValidation(
        of target: CapturedForegroundProcessGroup
    ) -> CapturedGroupValidation {
        // Fast path while the group leader is alive. This is the common case
        // and avoids a system-wide PID enumeration on every 20 ms reap poll.
        if Darwin.getpgid(target.pgid) == target.pgid,
           Darwin.getsid(target.pgid) == target.sessionID {
            return .active
        }
        if let pids = allProcessPIDs() {
            return validation(
                of: target,
                memberPIDs: pids,
                processGroup: Darwin.getpgid,
                session: Darwin.getsid
            )
        }

        // Enumeration failure cannot prove ownership or disappearance. Retry
        // without signalling; kill(-pgid, 0) distinguishes a definitely gone
        // group from a still-present but temporarily unverifiable one.
        errno = 0
        if Darwin.kill(-target.pgid, 0) == 0 || errno == EPERM {
            return .unverifiable
        }
        return errno == ESRCH ? .gone : .unverifiable
    }

    @discardableResult
    private static func signalCapturedForegroundGroup(
        _ target: CapturedForegroundProcessGroup?,
        signal: Int32
    ) -> Bool {
        guard let target, currentValidation(of: target) == .active else { return false }
        return Darwin.kill(-target.pgid, signal) == 0
    }

    private static func signalShell(pid: pid_t, signal: Int32) {
        _ = Darwin.kill(-pid, signal)
        _ = Darwin.kill(pid, signal)
    }

    static func signalProcessTree(
        pid: pid_t,
        foregroundGroup: CapturedForegroundProcessGroup?,
        signal: Int32
    ) {
        _ = signalCapturedForegroundGroup(foregroundGroup, signal: signal)
        signalShell(pid: pid, signal: signal)
    }

    static func reapWithEscalation(
        pid: pid_t,
        foregroundGroup: CapturedForegroundProcessGroup?,
        initialHangupAlreadySent: Bool,
        completion: @escaping @Sendable (ChildReapResult) -> Void
    ) {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let group = DispatchGroup()
        let resultBox = ApplicationTerminationResult()
        let work = ApplicationTerminationWork(
            group: group,
            succeeded: { resultBox.read() }
        )
        group.enter()
        childReapQueue.sync {
            // Surface in-flight ownership must keep one reaper per PID. A second
            // start overwrites the join handle; only the map owner is aggregated.
            activeChildReapWorks[pid] = work
        }
        childReapQueue.async {
            var state = ChildReapState(sentHangup: initialHangupAlreadySent)
            if let foregroundGroup {
                state.sessionGroups.insert(foregroundGroup)
                if initialHangupAlreadySent {
                    state.hangupSignaledGroups.insert(foregroundGroup)
                }
            }
            pollChildReap(
                pid: pid,
                foregroundGroup: foregroundGroup,
                startedAt: startedAt,
                state: state,
                completion: { result in
                    // pollChildReap always completes on childReapQueue.
                    if activeChildReapWorks[pid]?.group === work.group {
                        activeChildReapWorks.removeValue(forKey: pid)
                    }
                    resultBox.complete(result.shellReaped)
                    group.leave()
                    completion(result)
                }
            )
        }
    }

    static func setApplicationTerminationOwnershipForTesting(
        pid: pid_t,
        owned: Bool
    ) {
        childReapQueue.sync {
            if owned {
                applicationTerminationPIDs.insert(pid)
            } else {
                applicationTerminationPIDs.remove(pid)
            }
        }
    }

    static func activeApplicationTerminationWorksSnapshot() -> [ApplicationTerminationWork] {
        childReapQueue.sync {
            Array(activeApplicationTerminationWorks.values)
        }
    }

    /// App-termination disposition works plus in-flight tab-close/EOF reapers.
    /// Used by applicationWillTerminate after surfaces may already be unregistered.
    static func activeProcessDispositionWorksSnapshot() -> [ApplicationTerminationWork] {
        childReapQueue.sync {
            Array(activeApplicationTerminationWorks.values)
                + Array(activeChildReapWorks.values)
        }
    }

    static func ownsLiveChild(pid: pid_t) -> Bool {
        childReapQueue.sync {
            observeOwnedChildWithoutReaping(pid: pid) == .alive
        }
    }

    static func ownsStoppedChild(
        pid: pid_t,
        processStatusReader: ((pid_t) -> OwnedProcessStatusSnapshot)? = nil,
        waitObservationReader: ((pid_t) -> StoppedChildWaitObservation)? = nil
    ) -> Bool {
        childReapQueue.sync {
            ownsStoppedChildWhileReaperSerialized(
                pid: pid,
                processStatusReader: processStatusReader,
                waitObservationReader: waitObservationReader
            )
        }
    }

    private static func ownsStoppedChildWhileReaperSerialized(
        pid: pid_t,
        processStatusReader: ((pid_t) -> OwnedProcessStatusSnapshot)?,
        waitObservationReader: ((pid_t) -> StoppedChildWaitObservation)?
    ) -> Bool {
        let readProcessStatus = processStatusReader ?? ownedProcessStatusSnapshot
        switch readProcessStatus(pid) {
        case .snapshot(let parentPID, let status):
            return parentPID == UInt32(getpid()) && status == UInt32(SSTOP)
        case .unavailable:
            break
        }

        let readWaitObservation = waitObservationReader ?? stoppedChildWaitObservation
        switch readWaitObservation(pid) {
        case .stopped(let signal):
            return signal == SIGSTOP
        case .ownedAliveNoEvent:
            guard case .snapshot(let parentPID, let status) = readProcessStatus(pid) else {
                return false
            }
            return parentPID == UInt32(getpid()) && status == UInt32(SSTOP)
        case .exited, .continued, .unowned, .unknown:
            return false
        }
    }

    static func stoppedChildWaitObservation(pid: pid_t) -> StoppedChildWaitObservation {
        var info = siginfo_t()
        errno = 0
        let result = waitid(
            P_PID,
            id_t(pid),
            &info,
            WEXITED | WSTOPPED | WCONTINUED | WNOHANG | WNOWAIT
        )
        guard result == 0 else {
            return errno == ECHILD ? .unowned : .unknown
        }
        guard info.si_pid != 0 else { return .ownedAliveNoEvent }
        guard info.si_pid == pid else { return .unknown }
        switch info.si_code {
        case CLD_STOPPED:
            return .stopped(signal: info.si_status)
        case CLD_EXITED, CLD_KILLED, CLD_DUMPED:
            return .exited
        case CLD_CONTINUED:
            return .continued
        default:
            return .unknown
        }
    }

    static func suspendOwnedLiveChild(pid: pid_t) -> ChildSuspensionResult {
        childReapQueue.sync {
            switch observeOwnedChildWithoutReaping(pid: pid) {
            case .alive:
                break
            case .unowned:
                return .ownershipConsumed
            case .exited, .unknown:
                return .failed
            }
            // The unreaped child retains its numeric PID between this ownership
            // proof and kill, so SIGSTOP cannot target a reused process.
            guard Darwin.kill(pid, SIGSTOP) == 0 else { return .failed }

            // Darwin's waitid(... WSTOPPED | WNOWAIT) does not reliably surface
            // CLD_STOPPED when the host process suppresses stopped-child SIGCHLD.
            // The WNOWAIT ownership proof above pins the PID, so proc_pidinfo can
            // safely confirm Darwin's SSTOP state without consuming child status.
            // waitpid(WUNTRACED) remains a fallback; it consumes only a stop
            // notification, but can reap an exit that races the stop request.
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            var nextStopRetry = DispatchTime.now().uptimeNanoseconds + 10_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                var processInfo = proc_bsdinfo()
                let processInfoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
                let processInfoResult = proc_pidinfo(
                    pid,
                    PROC_PIDTBSDINFO,
                    0,
                    &processInfo,
                    processInfoSize
                )
                if processInfoResult == processInfoSize,
                   processInfo.pbi_status == UInt32(SSTOP) {
                    return .suspended
                }

                var stopInfo = siginfo_t()
                errno = 0
                let stopResult = waitid(
                    P_PID,
                    id_t(pid),
                    &stopInfo,
                    WSTOPPED | WNOHANG
                )
                if stopResult == 0,
                   stopInfo.si_pid == pid,
                   stopInfo.si_code == CLD_STOPPED,
                   stopInfo.si_status == SIGSTOP {
                    return .suspended
                }
                if stopResult < 0, errno == EINTR { continue }
                if stopResult < 0, errno == ECHILD { return .ownershipConsumed }
                if stopResult < 0 { return .failed }

                var status: Int32 = 0
                errno = 0
                let result = waitpid(pid, &status, WUNTRACED | WNOHANG)
                if result == pid {
                    let stopped = (status & 0x7F) == 0x7F
                    let stopSignal = (status >> 8) & 0xFF
                    if stopped, stopSignal == SIGSTOP { return .suspended }
                    return stopped ? .failed : .ownershipConsumed
                }
                if result < 0, errno == EINTR { continue }
                if result < 0, errno == ECHILD { return .ownershipConsumed }
                if result < 0 { return .failed }

                let now = DispatchTime.now().uptimeNanoseconds
                if now >= nextStopRetry {
                    // Signal generation can precede observable delivery. Reassert
                    // it at a low bounded cadence until the owned child is proven
                    // stopped; the WNOWAIT proof keeps this PID unreusable.
                    guard Darwin.kill(pid, SIGSTOP) == 0 else { return .failed }
                    nextStopRetry = now + 10_000_000
                }
                usleep(500)
            }
            return .failed
        }
    }

    static func resumeOwnedLiveChild(
        pid: pid_t,
        processStatusReader: ((pid_t) -> OwnedProcessStatusSnapshot)? = nil,
        waitObservationReader: ((pid_t) -> StoppedChildWaitObservation)? = nil
    ) -> Bool {
        childReapQueue.sync {
            guard ownsStoppedChildWhileReaperSerialized(
                pid: pid,
                processStatusReader: processStatusReader,
                waitObservationReader: waitObservationReader
            ) else {
                return false
            }
            // The stopped child is still a direct child, so its numeric PID cannot
            // be reused between this proc-table ownership proof and SIGCONT.
            guard Darwin.kill(pid, SIGCONT) == 0 else { return false }
            let readProcessStatus = processStatusReader ?? ownedProcessStatusSnapshot
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                switch readProcessStatus(pid) {
                case .snapshot(let parentPID, let status):
                    guard parentPID == UInt32(getpid()) else { return false }
                    if status == UInt32(SZOMB) { return false }
                    if status != UInt32(SSTOP) { return true }
                case .unavailable:
                    switch observeOwnedChildWithoutReaping(pid: pid) {
                    case .exited, .unowned:
                        return false
                    case .alive, .unknown:
                        break
                    }
                }
                usleep(500)
            }
            return false
        }
    }

    /// Starts an app/restart disposition. All terminal workers start concurrently
    /// and attempt the fast bounded window first; resistant children retain a
    /// low-cadence ownership continuation until waitpid/ECHILD proves disposition.
    /// PID ownership proof (`waitid(..., WNOWAIT)`) and signalling execute on the
    /// same serial queue as the normal reaper, closing the PID-reuse race between
    /// proving that a child is ours and delivering a signal.
    static func beginApplicationTerminationDisposition(
        pid: pid_t,
        foregroundGroup: CapturedForegroundProcessGroup?
    ) -> ApplicationTerminationWork {
        let group = DispatchGroup()
        let result = ApplicationTerminationResult()
        let work = ApplicationTerminationWork(
            group: group,
            succeeded: { result.read() }
        )
        group.enter()
        let registration = childReapQueue.sync { () -> (
            existing: ApplicationTerminationWork?,
            groups: Set<CapturedForegroundProcessGroup>,
            enumeratedOwnedSession: Bool,
            ownershipEstablished: Bool
        ) in
            if let existing = activeApplicationTerminationWorks[pid] {
                return (existing, [], false, false)
            }
            activeApplicationTerminationWorks[pid] = work
            applicationTerminationPIDs.insert(pid)
            var groups = Set<CapturedForegroundProcessGroup>()
            if let foregroundGroup { groups.insert(foregroundGroup) }
            let ownership = observeOwnedChildWithoutReaping(pid: pid)
            guard ownership == .alive || ownership == .exited else {
                return (nil, groups, false, false)
            }
            if let discovered = ownedSessionProcessGroups(sessionID: pid) {
                groups.formUnion(discovered)
                return (nil, groups, true, true)
            }
            return (nil, groups, false, true)
        }
        if let existing = registration.existing {
            group.leave()
            return existing
        }
        applicationTerminationQueue.async {
            let startedAt = DispatchTime.now().uptimeNanoseconds

            var progress = applicationTerminationStep(
                pid: pid,
                knownSessionGroups: registration.groups,
                hasEnumeratedOwnedSession: registration.enumeratedOwnedSession,
                ownershipEstablished: registration.ownershipEstablished,
                signal: SIGHUP
            )
            if finalizeApplicationTerminationIfReady(pid: pid, progress: progress) {
                completeApplicationTerminationDisposition(
                    pid: pid,
                    group: group,
                    result: result
                )
                return
            }

            progress = pollApplicationTermination(
                pid: pid,
                startedAt: startedAt,
                until: 0.05,
                initial: progress
            )
            if finalizeApplicationTerminationIfReady(pid: pid, progress: progress) {
                completeApplicationTerminationDisposition(
                    pid: pid,
                    group: group,
                    result: result
                )
                return
            }

            progress = applicationTerminationStep(
                pid: pid,
                knownSessionGroups: progress.sessionGroups,
                hasEnumeratedOwnedSession: progress.hasEnumeratedOwnedSession,
                ownershipEstablished: progress.ownershipEstablished,
                signal: SIGTERM
            )
            progress = pollApplicationTermination(
                pid: pid,
                startedAt: startedAt,
                until: 0.15,
                initial: progress
            )
            if finalizeApplicationTerminationIfReady(pid: pid, progress: progress) {
                completeApplicationTerminationDisposition(
                    pid: pid,
                    group: group,
                    result: result
                )
                return
            }

            progress = applicationTerminationStep(
                pid: pid,
                knownSessionGroups: progress.sessionGroups,
                hasEnumeratedOwnedSession: progress.hasEnumeratedOwnedSession,
                ownershipEstablished: progress.ownershipEstablished,
                signal: SIGKILL
            )
            progress = pollApplicationTermination(
                pid: pid,
                startedAt: startedAt,
                until: 1.0,
                initial: progress
            )
            if !progress.readyToReap {
                progress = applicationTerminationStep(
                    pid: pid,
                    knownSessionGroups: progress.sessionGroups,
                    hasEnumeratedOwnedSession: progress.hasEnumeratedOwnedSession,
                    ownershipEstablished: progress.ownershipEstablished,
                    signal: SIGKILL
                )
            }
            let succeeded = finalizeApplicationTerminationIfReady(pid: pid, progress: progress)
            if succeeded {
                completeApplicationTerminationDisposition(
                    pid: pid,
                    group: group,
                    result: result
                )
            } else {
                continueApplicationTerminationDisposition(
                    pid: pid,
                    progress: progress,
                    group: group,
                    result: result
                )
            }
        }
        return work
    }

    /// A stopped or resistant child remains our responsibility after the fast
    /// app/restart window expires. Keep its unreaped shell anchor (and therefore
    /// its PID/SID namespace) reserved until ownership is actually consumed.
    /// The low-cadence continuation is constant-memory and never signals a raw
    /// numeric session after losing the child anchor.
    private static func continueApplicationTerminationDisposition(
        pid: pid_t,
        progress: ApplicationTerminationProgress,
        group: DispatchGroup,
        result: ApplicationTerminationResult
    ) {
        applicationTerminationQueue.asyncAfter(deadline: .now() + .seconds(1)) {
            var next = applicationTerminationStep(
                pid: pid,
                knownSessionGroups: progress.sessionGroups,
                hasEnumeratedOwnedSession: progress.hasEnumeratedOwnedSession,
                ownershipEstablished: progress.ownershipEstablished,
                signal: SIGKILL
            )
            if !next.readyToReap {
                next = pollApplicationTermination(
                    pid: pid,
                    startedAt: DispatchTime.now().uptimeNanoseconds,
                    until: 0.1,
                    initial: next
                )
            }
            if finalizeApplicationTerminationIfReady(pid: pid, progress: next) {
                completeApplicationTerminationDisposition(
                    pid: pid,
                    group: group,
                    result: result
                )
            } else {
                continueApplicationTerminationDisposition(
                    pid: pid,
                    progress: next,
                    group: group,
                    result: result
                )
            }
        }
    }

    private static func completeApplicationTerminationDisposition(
        pid: pid_t,
        group: DispatchGroup,
        result: ApplicationTerminationResult
    ) {
        childReapQueue.sync {
            _ = applicationTerminationPIDs.remove(pid)
            activeApplicationTerminationWorks.removeValue(forKey: pid)
        }
        result.complete(true)
        group.leave()
    }

    private static func pollApplicationTermination(
        pid: pid_t,
        startedAt: UInt64,
        until deadline: TimeInterval,
        initial: ApplicationTerminationProgress
    ) -> ApplicationTerminationProgress {
        var progress = initial
        while !progress.readyToReap {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt)
                / 1_000_000_000
            guard elapsed < deadline else { break }
            usleep(10_000)
            progress = applicationTerminationStep(
                pid: pid,
                knownSessionGroups: progress.sessionGroups,
                hasEnumeratedOwnedSession: progress.hasEnumeratedOwnedSession,
                ownershipEstablished: progress.ownershipEstablished,
                signal: nil
            )
        }
        return progress
    }

    private static func applicationTerminationStep(
        pid: pid_t,
        knownSessionGroups: Set<CapturedForegroundProcessGroup>,
        hasEnumeratedOwnedSession: Bool,
        ownershipEstablished: Bool,
        signal: Int32?
    ) -> ApplicationTerminationProgress {
        childReapQueue.sync {
            let childPoll = observeOwnedChildWithoutReaping(pid: pid)
            var sessionGroups = knownSessionGroups
            var didEnumerate = hasEnumeratedOwnedSession
            if ownershipEstablished,
               (childPoll == .alive || childPoll == .exited),
               let discovered = ownedSessionProcessGroups(sessionID: pid) {
                sessionGroups.formUnion(discovered)
                didEnumerate = true
            }
            if ownershipEstablished, childPoll == .alive, let signal {
                // Direct PID signalling remains safe because waitid just proved
                // ownership and this queue blocks the normal reaper from consuming
                // the zombie between proof and kill.
                if Darwin.getpgid(pid) == pid, Darwin.getsid(pid) == pid {
                    _ = Darwin.kill(-pid, signal)
                }
                _ = Darwin.kill(pid, signal)
            }
            if ownershipEstablished, let signal {
                for target in sessionGroups
                    where applicationTerminationValidation(of: target, shellPID: pid) == .active {
                    _ = Darwin.kill(-target.pgid, signal)
                }
            }
            let sessionGroupsFinished = sessionGroups.allSatisfy {
                applicationTerminationValidation(of: $0, shellPID: pid) == .gone
            }
            return ApplicationTerminationProgress(
                child: childPoll,
                sessionGroups: sessionGroups,
                sessionGroupsFinished: sessionGroupsFinished,
                hasEnumeratedOwnedSession: didEnumerate,
                ownershipEstablished: ownershipEstablished
            )
        }
    }

    private static func observeOwnedChildWithoutReaping(pid: pid_t) -> OwnedChildPoll {
        guard pid > 0 else { return .unowned }
        var info = siginfo_t()
        errno = 0
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result == 0, info.si_pid == pid { return .exited }
        if result == 0 { return .alive }
        if result < 0, errno == ECHILD {
            // Darwin may report ECHILD for a directly-owned stopped child when
            // WEXITED is the only requested state. The proc table preserves the
            // exact parent relationship while the stopped PID remains unreaped.
            if ownedProcessStatus(pid: pid) == UInt32(SSTOP) { return .alive }
            return .unowned
        }
        return .unknown
    }

    private static func ownedProcessStatusSnapshot(pid: pid_t) -> OwnedProcessStatusSnapshot {
        guard pid > 0 else { return .unavailable }
        var processInfo = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &processInfo, size) == size else {
            return .unavailable
        }
        return .snapshot(
            parentPID: processInfo.pbi_ppid,
            status: processInfo.pbi_status
        )
    }

    private static func ownedProcessStatus(pid: pid_t) -> UInt32? {
        guard case .snapshot(let parentPID, let status) = ownedProcessStatusSnapshot(pid: pid),
              parentPID == UInt32(getpid()) else {
            return nil
        }
        return status
    }

    private static func finalizeApplicationTerminationIfReady(
        pid: pid_t,
        progress: ApplicationTerminationProgress
    ) -> Bool {
        guard progress.readyToReap else { return false }
        return childReapQueue.sync {
            consumeOwnedChildIfExited(pid: pid)
        }
    }

    private static func consumeOwnedChildIfExited(pid: pid_t) -> Bool {
        var status: Int32 = 0
        errno = 0
        let waitResult = waitpid(pid, &status, WNOHANG)
        return waitResult == pid || (waitResult < 0 && errno == ECHILD)
    }

    private static func ownedSessionProcessGroups(
        sessionID: pid_t
    ) -> Set<CapturedForegroundProcessGroup>? {
        guard sessionID > 0, let pids = allProcessPIDs() else { return nil }
        var groups = Set<CapturedForegroundProcessGroup>()
        for memberPID in pids where memberPID > 0 && Darwin.getsid(memberPID) == sessionID {
            let pgid = Darwin.getpgid(memberPID)
            if pgid > 0 {
                groups.insert(CapturedForegroundProcessGroup(pgid: pgid, sessionID: sessionID))
            }
        }
        return groups
    }

    /// App termination holds the shell zombie with WNOWAIT, so its PID/SID cannot
    /// be reused. For the shell's own process group, ignore that zombie while
    /// checking whether any resistant peer is still alive.
    private static func applicationTerminationValidation(
        of target: CapturedForegroundProcessGroup,
        shellPID: pid_t
    ) -> CapturedGroupValidation {
        guard let pids = allProcessPIDs() else {
            errno = 0
            if Darwin.kill(-target.pgid, 0) == 0 || errno == EPERM { return .unverifiable }
            return errno == ESRCH ? .gone : .unverifiable
        }
        return validation(
            of: target,
            memberPIDs: pids.filter { $0 != shellPID },
            processGroup: Darwin.getpgid,
            session: Darwin.getsid
        )
    }

    private static func applicationTerminationSessionValidation(
        _ groups: Set<CapturedForegroundProcessGroup>,
        shellPID: pid_t
    ) -> CapturedGroupValidation {
        var sawUnverifiable = false
        for target in groups {
            switch applicationTerminationValidation(of: target, shellPID: shellPID) {
            case .active:
                return .active
            case .unverifiable:
                sawUnverifiable = true
            case .gone:
                continue
            }
        }
        return sawUnverifiable ? .unverifiable : .gone
    }

    private static func signalNewSessionGroups(
        _ groups: Set<CapturedForegroundProcessGroup>,
        shellPID: pid_t,
        signal: Int32,
        signaled: inout Set<CapturedForegroundProcessGroup>
    ) {
        for target in groups where !signaled.contains(target) {
            switch applicationTerminationValidation(of: target, shellPID: shellPID) {
            case .active:
                errno = 0
                if Darwin.kill(-target.pgid, signal) == 0 || errno == ESRCH {
                    signaled.insert(target)
                }
            case .gone:
                signaled.insert(target)
            case .unverifiable:
                continue
            }
        }
    }

    private static func signalActiveSessionGroups(
        _ groups: Set<CapturedForegroundProcessGroup>,
        shellPID: pid_t,
        signal: Int32
    ) {
        for target in groups
            where applicationTerminationValidation(of: target, shellPID: shellPID) == .active {
            _ = Darwin.kill(-target.pgid, signal)
        }
    }

    private static func pollChildReap(
        pid: pid_t,
        foregroundGroup: CapturedForegroundProcessGroup?,
        startedAt: UInt64,
        state: ChildReapState,
        completion: @escaping @Sendable (ChildReapResult) -> Void
    ) {
        if applicationTerminationPIDs.contains(pid) {
            childReapQueue.asyncAfter(deadline: .now() + .milliseconds(20)) {
                pollChildReap(
                    pid: pid,
                    foregroundGroup: foregroundGroup,
                    startedAt: startedAt,
                    state: state,
                    completion: completion
                )
            }
            return
        }
        var state = state
        let polledAt = DispatchTime.now().uptimeNanoseconds
        if !state.shellExitObserved {
            var info = siginfo_t()
            errno = 0
            let result = waitid(
                P_PID,
                id_t(pid),
                &info,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result == 0, info.si_pid == pid {
                state.shellExitObserved = true
            } else if result < 0, errno == ECHILD {
                // Another authorized disposition consumed the child anchor.
                // From this point the numeric PID/SID may be reused immediately;
                // finish without enumerating, validating, or signalling any raw
                // process/session identifiers retained by this older reaper.
                completion(ChildReapResult(
                    status: nil,
                    timedOut: false,
                    foregroundGroupRemaining: false,
                    shellReaped: true
                ))
                return
            }
        }

        if !state.shellAlreadyReaped,
           let discovered = ownedSessionProcessGroups(sessionID: pid) {
            state.sessionGroups.formUnion(discovered)
        }
        if let foregroundGroup {
            state.sessionGroups.insert(foregroundGroup)
        }

        let elapsed = Double(polledAt - startedAt)
            / 1_000_000_000

        if !state.sentHangup, elapsed >= 0.25 {
            if !state.shellExitObserved { signalShell(pid: pid, signal: SIGHUP) }
            state.sentHangup = true
        }
        if !state.sentTerminate, elapsed >= 0.75 {
            if !state.shellExitObserved { signalShell(pid: pid, signal: SIGTERM) }
            state.sentTerminate = true
        }
        if !state.sentKill, elapsed >= 1.5 {
            if !state.shellExitObserved { signalShell(pid: pid, signal: SIGKILL) }
            state.sentKill = true
        }

        if state.sentHangup {
            signalNewSessionGroups(
                state.sessionGroups,
                shellPID: pid,
                signal: SIGHUP,
                signaled: &state.hangupSignaledGroups
            )
        }
        if state.sentTerminate {
            signalNewSessionGroups(
                state.sessionGroups,
                shellPID: pid,
                signal: SIGTERM,
                signaled: &state.terminateSignaledGroups
            )
        }
        if state.sentKill {
            signalNewSessionGroups(
                state.sessionGroups,
                shellPID: pid,
                signal: SIGKILL,
                signaled: &state.killSignaledGroups
            )
        }

        let groupValidation = applicationTerminationSessionValidation(
            state.sessionGroups,
            shellPID: pid
        )
        switch reapPollDecision(
            shellExitObserved: state.shellExitObserved,
            groupValidation: groupValidation,
            elapsed: elapsed,
            deadlineKillSent: state.deadlineKillSent
        ) {
        case .finish:
            finalizeChildReap(
                pid: pid,
                state: state,
                timedOut: false,
                foregroundGroupRemaining: false,
                completion: completion
            )
            return
        case .beginTimeoutGrace:
            if !state.shellExitObserved { signalShell(pid: pid, signal: SIGKILL) }
            signalActiveSessionGroups(state.sessionGroups, shellPID: pid, signal: SIGKILL)
            state.deadlineKillSent = true
        case .timeout:
            if !state.shellExitObserved { signalShell(pid: pid, signal: SIGKILL) }
            signalActiveSessionGroups(state.sessionGroups, shellPID: pid, signal: SIGKILL)
            let finalGroupValidation = applicationTerminationSessionValidation(
                state.sessionGroups,
                shellPID: pid
            )
            finalizeChildReap(
                pid: pid,
                state: state,
                timedOut: true,
                foregroundGroupRemaining: finalGroupValidation != .gone,
                completion: completion
            )
            return
        case .continuePolling:
            break
        }

        // SIGKILL is repeated only while a member of the captured session still
        // proves ownership. A reused numeric PGID in another session is never hit.
        if elapsed >= 3 {
            if !state.shellExitObserved { signalShell(pid: pid, signal: SIGKILL) }
            signalActiveSessionGroups(state.sessionGroups, shellPID: pid, signal: SIGKILL)
        }
        let delay: DispatchTimeInterval = state.deadlineKillSent || elapsed < 3
            ? .milliseconds(20)
            : .seconds(1)
        childReapQueue.asyncAfter(deadline: .now() + delay) {
            pollChildReap(
                pid: pid,
                foregroundGroup: foregroundGroup,
                startedAt: startedAt,
                state: state,
                completion: completion
            )
        }
    }

    private static func finalizeChildReap(
        pid: pid_t,
        state: ChildReapState,
        timedOut: Bool,
        foregroundGroupRemaining: Bool,
        completion: @escaping @Sendable (ChildReapResult) -> Void
    ) {
        guard !state.shellAlreadyReaped else {
            completion(ChildReapResult(
                status: nil,
                timedOut: timedOut,
                foregroundGroupRemaining: foregroundGroupRemaining,
                shellReaped: true
            ))
            return
        }

        waitUntilChildReaped(pid: pid) { status in
            completion(ChildReapResult(
                status: status,
                timedOut: timedOut,
                foregroundGroupRemaining: foregroundGroupRemaining,
                shellReaped: true
            ))
        }
    }

    /// Keeps exactly one low-cadence callback responsible for the child until
    /// `waitpid` proves that this process consumed it (or another owner already
    /// did via ECHILD). In particular, a SIGKILL sent at the hard deadline is not
    /// assumed to have taken effect synchronously.
    static func waitUntilChildReaped(
        pid: pid_t,
        pollDelay: DispatchTimeInterval = .seconds(1),
        completion: @escaping @Sendable (Int32?) -> Void
    ) {
        childReapQueue.async {
            pollFinalChildWait(pid: pid, pollDelay: pollDelay, completion: completion)
        }
    }

    private static func pollFinalChildWait(
        pid: pid_t,
        pollDelay: DispatchTimeInterval,
        completion: @escaping @Sendable (Int32?) -> Void
    ) {
        if applicationTerminationPIDs.contains(pid) {
            childReapQueue.asyncAfter(deadline: .now() + .milliseconds(20)) {
                pollFinalChildWait(
                    pid: pid,
                    pollDelay: pollDelay,
                    completion: completion
                )
            }
            return
        }
        var status: Int32 = 0
        errno = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            completion(status)
            return
        }
        if result < 0, errno == ECHILD {
            completion(nil)
            return
        }
        childReapQueue.asyncAfter(deadline: .now() + pollDelay) {
            pollFinalChildWait(pid: pid, pollDelay: pollDelay, completion: completion)
        }
    }
}

public final class SurfaceRuntimeBus: @unchecked Sendable {
    public static let shared = SurfaceRuntimeBus()

    // Lock-guarded storage instead of a serial dispatch queue (F12): the previous
    // `queue.async` emit delivered health transitions LATE (the new state sat in a
    // background FIFO before the sink ran), and the `queue.sync` getter could block
    // — or deadlock if ever read from the bus queue. The sink is set once at startup
    // and itself hops to @MainActor where it needs to, so reading it under a lock
    // and invoking it synchronously on the emitting thread is both safe and makes
    // health publication deterministic (no transition is dropped or reordered).
    private let lock = NSLock()
    private var sinkStorage: (@Sendable (_ surfaceId: SurfaceID, _ health: TerminalRuntimeHealth) -> Void)?

    public var sink: (@Sendable (_ surfaceId: SurfaceID, _ health: TerminalRuntimeHealth) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return sinkStorage }
        set { lock.lock(); sinkStorage = newValue; lock.unlock() }
    }

    public func emit(_ surfaceId: SurfaceID, _ health: TerminalRuntimeHealth) {
        lock.lock()
        let sink = sinkStorage
        lock.unlock()
        sink?(surfaceId, health)
    }
}

enum TerminalWriteResult: Equatable {
    case wrote(Int)
    case wouldBlock
    case interrupted
    case failed(Int32)
}

enum TerminalWriteReadinessResult: Equatable {
    case writable
    case timedOut
    case unavailable
}

final class TerminalFileDescriptorLease: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else {
            errno = EBADF
            return -1
        }
        return Darwin.read(fd, buffer.baseAddress, buffer.count)
    }

    func write(_ data: Data, offset: Int) -> TerminalWriteResult {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return .failed(EBADF) }
        return data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return .wrote(0) }
            let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
            if count > 0 { return .wrote(count) }
            if count < 0, errno == EINTR { return .interrupted }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
            return .failed(errno)
        }
    }

    func waitForWritable(
        timeoutMicros: UInt64,
        onPoll: (@Sendable () -> Void)? = nil
    ) -> TerminalWriteReadinessResult {
        guard timeoutMicros > 0 else { return .timedOut }
        lock.lock()
        let descriptor = fd
        lock.unlock()
        // A concurrent close is surfaced by poll as POLLNVAL/HUP, then the
        // lease-guarded write below resolves the authoritative EBADF state.
        guard descriptor >= 0 else { return .writable }

        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMicros * 1_000
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timedOut }
            let remainingMicros = (deadline - now + 999) / 1_000
            // Darwin does not guarantee that close() on another thread wakes a
            // descriptor already inside poll. Slice the kernel wait so teardown
            // observes lease closure within 100 ms while still replacing up to
            // 2,500 user-space sleep/write wakeups with at most 50 timeouts.
            let pollMicros = min(remainingMicros, 100_000)
            let timeoutMillis = Int32(min(
                UInt64(Int32.max),
                max(1, (pollMicros + 999) / 1_000)
            ))
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            onPoll?()
            let result = Darwin.poll(&pollDescriptor, 1, timeoutMillis)
            if result > 0 { return .writable }
            if result == 0 {
                lock.lock()
                let stillOwned = fd == descriptor
                lock.unlock()
                if !stillOwned { return .writable }
                continue
            }
            if errno == EINTR { continue }
            return .unavailable
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}

/// Owns a fully spawned and descriptor-configured PTY until a terminal restart
/// crosses its irreversible teardown boundary. If the restart is abandoned,
/// deinit closes the master and starts ownership-safe child disposition.
public final class TerminalPreparedPTYRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t
    private var masterFD: Int32
    private var lease: TerminalFileDescriptorLease?
    private var suspended = false

    init(
        pid: pid_t,
        masterFD: Int32,
        lease: TerminalFileDescriptorLease,
        suspended: Bool = false
    ) {
        self.pid = pid
        self.masterFD = masterFD
        self.lease = lease
        self.suspended = suspended
    }

    public func isOwnedAndAlive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let ownedPID = pid
        guard ownedPID > 0 else { return false }
        if suspended {
            return TerminalPTYProcessRuntime.ownsStoppedChild(pid: ownedPID)
        }
        return TerminalPTYProcessRuntime.ownsLiveChild(pid: ownedPID)
    }

    public var ownedPIDForTesting: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return pid > 0 ? pid : nil
    }

    public func suspendIfOwnedAndAlive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pid > 0, lease != nil else { return false }
        if suspended {
            return TerminalPTYProcessRuntime.ownsStoppedChild(pid: pid)
        }
        switch TerminalPTYProcessRuntime.suspendOwnedLiveChild(pid: pid) {
        case .suspended:
            suspended = true
            return true
        case .ownershipConsumed:
            // waitpid may have reaped an exit while confirming SIGSTOP. Remove
            // all authority to signal the raw PID before deinit closes the FD.
            pid = -1
            return false
        case .failed:
            return false
        }
    }

    func takeOwnership() -> (
        pid: pid_t,
        masterFD: Int32,
        lease: TerminalFileDescriptorLease,
        wasSuspended: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard pid > 0, masterFD >= 0, let lease else {
            preconditionFailure("prepared terminal runtime ownership already consumed")
        }
        let ownership = (
            pid: pid,
            masterFD: masterFD,
            lease: lease,
            wasSuspended: suspended
        )
        self.pid = -1
        self.masterFD = -1
        self.lease = nil
        suspended = false
        return ownership
    }

    @discardableResult
    public func discard() -> SurfaceTerminationBarrier? {
        lock.lock()
        let ownedPID = pid
        let ownedLease = lease
        pid = -1
        masterFD = -1
        lease = nil
        suspended = false
        lock.unlock()

        ownedLease?.close()
        guard ownedPID > 0 else { return nil }
        let work = TerminalPTYProcessRuntime.beginApplicationTerminationDisposition(
            pid: ownedPID,
            foregroundGroup: nil
        )
        return SurfaceTerminationBarrier(
            groups: [work.group],
            completionChecks: [work.succeeded]
        )
    }

    deinit {
        _ = discard()
    }
}

final class TerminalReaderHandoffState: @unchecked Sendable {
    struct Batch: Sendable {
        let id: UInt64
        let data: Data
        let shouldClose: Bool
        let readCalls: Int
    }

    struct ClosingSnapshot: Sendable {
        let batches: [Batch]
        let awaitsPublication: Bool
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var activeReadEvents = 0
    private var closing = false
    private var pending: [UInt64: Batch] = [:]
    private var publicationReady: (@Sendable () -> Void)?

    func beginReadEvent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closing else { return false }
        activeReadEvents += 1
        return true
    }

    func publish(data: Data, shouldClose: Bool, readCalls: Int) -> UInt64? {
        lock.lock()
        precondition(activeReadEvents > 0)
        activeReadEvents -= 1
        var id: UInt64?
        if !data.isEmpty || shouldClose {
            nextID &+= 1
            let batch = Batch(
                id: nextID,
                data: data,
                shouldClose: shouldClose,
                readCalls: readCalls
            )
            pending[batch.id] = batch
            id = batch.id
        }
        let ready = closing && activeReadEvents == 0 ? publicationReady : nil
        if ready != nil {
            publicationReady = nil
        }
        lock.unlock()
        ready?()
        return id
    }

    func claim(_ id: UInt64) -> Batch? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    func beginClosing(
        publicationReady: @escaping @Sendable () -> Void
    ) -> ClosingSnapshot {
        lock.lock()
        closing = true
        let batches = Array(pending.values).sorted { $0.id < $1.id }
        pending.removeAll(keepingCapacity: false)
        let awaitsPublication = activeReadEvents > 0
        if awaitsPublication {
            self.publicationReady = publicationReady
        }
        lock.unlock()
        return ClosingSnapshot(
            batches: batches,
            awaitsPublication: awaitsPublication
        )
    }

    func drainPublished() -> [Batch] {
        lock.lock()
        defer { lock.unlock() }
        let batches = Array(pending.values).sorted { $0.id < $1.id }
        pending.removeAll(keepingCapacity: false)
        return batches
    }
}

final class TerminalDeferredTerminationState: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var completed = false
    private var successful = false

    init() {
        group.enter()
    }

    func complete(success: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        successful = success
        lock.unlock()
        group.leave()
    }

    func barrier() -> SurfaceTerminationBarrier {
        SurfaceTerminationBarrier(
            groups: [group],
            completionChecks: [{ [self] in
                lock.lock()
                defer { lock.unlock() }
                return completed && successful
            }]
        )
    }

    func applicationTerminationBarrier(
        continuation: @escaping @MainActor @Sendable (DispatchTime) -> Bool
    ) -> SurfaceTerminationBarrier {
        SurfaceTerminationBarrier(
            groups: [group],
            completionChecks: [{ [self] in
                lock.lock()
                defer { lock.unlock() }
                return completed && successful
            }],
            applicationTerminationContinuations: [continuation]
        )
    }
}

final class TerminalTickCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false

    func trySchedule() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func complete() {
        lock.lock()
        scheduled = false
        lock.unlock()
    }
}

enum TerminalFileDescriptorFlags {
    @discardableResult
    static func enableCloseOnExec(_ fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0 else { return false }
        guard flags & FD_CLOEXEC == 0 else { return true }
        return fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    @discardableResult
    static func enableNonBlocking(_ fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        guard flags & O_NONBLOCK == 0 else { return true }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }
}

final class TerminalInputPump: @unchecked Sendable {
    typealias Writer = @Sendable (_ data: Data, _ offset: Int) -> TerminalWriteResult
    typealias WriteReadinessWaiter = @Sendable (_ timeoutMicros: UInt64) -> TerminalWriteReadinessResult
    private struct WaitingDrain: Sendable {
        let data: Data
        let chunkID: UInt64
        let offset: Int
        let countedBytes: Int
        let reportStall: Bool
        let stalledRetryAttempt: Int
    }

    private enum DrainPermission {
        case write
        case wait
        case stopped
    }

    private let queue: DispatchQueue
    private let maxQueuedBytes: Int
    private let maxQueuedItems: Int
    private let retryDelay: useconds_t
    private let maxWouldBlockWaitMicros: UInt64
    private let waitForWriteReadiness: WriteReadinessWaiter?
    private let writer: Writer
    private let lock = NSLock()
    private var queuedBytes = 0
    private var accepting = true
    private var lastFailure: TerminalInputStatus?
    private var drainingAcceptedBacklog = false
    private var nextChunkID: UInt64 = 0
    private var pendingChunkIDs: [UInt64] = []
    private var pendingChunkHeadIndex = 0
    private var finishedChunkIDs: Set<UInt64> = []
    private var waitingDrains: [UInt64: WaitingDrain] = [:]
    private var activeChunkCount = 0
    private var scheduledRetryCount = 0
    var onTerminalFailure: (@Sendable (TerminalInputStatus) -> Void)?
    var onInputResumed: (@Sendable () -> Void)?
    /// Fired (off the pump's queue) when a single write blocks past the retry
    /// budget because the child stopped draining its stdin. The unwritten bytes
    /// stay queued and are retried later; new input is rejected until this accepted
    /// chunk is either delivered or the terminal stops.
    var onInputStalled: (@Sendable (_ unwrittenBytes: Int) -> Void)?

    init(
        label: String = "rc2.terminal.input-pump",
        maxQueuedBytes: Int = 1024 * 1024,
        maxQueuedItems: Int = 1024,
        retryDelay: useconds_t = 2_000,
        maxWouldBlockWaitMicros: UInt64 = 5_000_000,
        waitForWriteReadiness: WriteReadinessWaiter? = nil,
        writer: @escaping Writer
    ) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.maxQueuedBytes = max(1, maxQueuedBytes)
        self.maxQueuedItems = max(1, maxQueuedItems)
        self.retryDelay = retryDelay
        self.maxWouldBlockWaitMicros = maxWouldBlockWaitMicros
        self.waitForWriteReadiness = waitForWriteReadiness
        self.writer = writer
    }

    /// Pure decision seam for the `.wouldBlock` retry budget. Returns true once the
    /// cumulative time spent waiting on a non-draining PTY reaches the budget, so the
    /// drain loop stops spinning instead of head-of-line-blocking the serial queue
    /// (and every later keystroke) forever. `nonisolated static` so the budget logic
    /// is unit-testable without a live pump, queue, or PTY.
    static func shouldAbortWouldBlock(waitedMicros: UInt64, budgetMicros: UInt64) -> Bool {
        budgetMicros > 0 && waitedMicros >= budgetMicros
    }

    var queuedByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return queuedBytes
    }

    var inputAccepting: Bool {
        lock.lock(); defer { lock.unlock() }
        return accepting
            && queuedBytes < maxQueuedBytes
            && activeChunkCount < maxQueuedItems
    }

    var pendingChunkMetadataForTesting: (active: Int, storage: Int, limit: Int) {
        lock.lock(); defer { lock.unlock() }
        return (activeChunkCount, pendingChunkIDs.count, maxQueuedItems)
    }

    var scheduledRetryCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return scheduledRetryCount
    }

    func enqueue(_ data: Data) -> TerminalInputStatus {
        guard !data.isEmpty else { return .accepted }
        let chunkID: UInt64
        lock.lock()
        if !accepting {
            let failure = lastFailure ?? .processExited
            lock.unlock()
            return failure
        }
        guard queuedBytes + data.count <= maxQueuedBytes else {
            lock.unlock()
            return .queueFull
        }
        guard activeChunkCount < maxQueuedItems else {
            lock.unlock()
            return .queueFull
        }
        queuedBytes += data.count
        activeChunkCount += 1
        nextChunkID &+= 1
        chunkID = nextChunkID
        pendingChunkIDs.append(chunkID)
        lock.unlock()

        queue.async { [weak self] in
            self?.drain(
                data,
                chunkID: chunkID,
                offset: 0,
                countedBytes: data.count,
                reportStall: true,
                stalledRetryAttempt: 0
            )
        }
        return .accepted
    }

    func stop(reason: TerminalInputStatus = .processExited) {
        lock.lock()
        accepting = false
        lastFailure = reason
        // Drop retained stdin payload immediately. In-flight drain completions
        // remain idempotent via finishedChunkIDs; waiting drains would otherwise
        // pin up to maxQueuedBytes after tab close until a later retry fires.
        let waiting = Array(waitingDrains.values)
        waitingDrains.removeAll(keepingCapacity: false)
        for drain in waiting {
            guard finishedChunkIDs.insert(drain.chunkID).inserted else { continue }
            queuedBytes = max(0, queuedBytes - drain.countedBytes)
            activeChunkCount = max(0, activeChunkCount - 1)
        }
        lock.unlock()
    }

    func drain() {
        queue.sync {}
    }

    private func drain(
        _ data: Data,
        chunkID: UInt64,
        offset initialOffset: Int,
        countedBytes: Int,
        reportStall: Bool,
        stalledRetryAttempt: Int
    ) {
        switch drainPermission(chunkID: chunkID, stalledRetry: stalledRetryAttempt > 0) {
        case .write:
            break
        case .wait:
            storeWaitingDrain(WaitingDrain(
                data: data,
                chunkID: chunkID,
                offset: initialOffset,
                countedBytes: countedBytes,
                reportStall: reportStall,
                stalledRetryAttempt: max(1, stalledRetryAttempt + 1)
            ))
            return
        case .stopped:
            finishQueuedBytes(countedBytes, chunkID: chunkID)
            return
        }

        var offset = initialOffset
        var wouldBlockWaitMicros: UInt64 = 0
        while offset < data.count {
            switch writer(data, offset) {
            case .wrote(let count) where count > 0:
                offset += count
                wouldBlockWaitMicros = 0   // forward progress resets the stall budget
            case .wrote:
                finishQueuedBytes(countedBytes, chunkID: chunkID)
                fail(.writeFailed)
                return
            case .interrupted:
                continue
            case .wouldBlock:
                // The child stopped reading its stdin (slave tty input buffer full).
                // Bound the retry: an open-ended `usleep`+continue spins a CPU core
                // forever AND head-of-line-blocks every later keystroke queued behind
                // this chunk on the serial queue — the "terminal alive but typing
                // dead" freeze. This is RECOVERABLE backpressure, not process death:
                // do not drop the already-accepted bytes. Pause later input, publish
                // the stalled state, then retry the unwritten suffix asynchronously.
                if stalledRetryAttempt > 0 || Self.shouldAbortWouldBlock(waitedMicros: wouldBlockWaitMicros,
                                              budgetMicros: maxWouldBlockWaitMicros) {
                    pauseForStalledInput()
                    if reportStall {
                        onInputStalled?(data.count - offset)
                    }
                    let nextAttempt = offset > initialOffset ? 1 : max(1, stalledRetryAttempt + 1)
                    scheduleRetry(
                        data,
                        chunkID: chunkID,
                        offset: offset,
                        countedBytes: countedBytes,
                        reportStall: false,
                        stalledRetryAttempt: nextAttempt
                    )
                    return
                }
                if let waitForWriteReadiness {
                    let remainingMicros = maxWouldBlockWaitMicros > wouldBlockWaitMicros
                        ? maxWouldBlockWaitMicros - wouldBlockWaitMicros
                        : UInt64(max(1, retryDelay))
                    let waitStarted = DispatchTime.now().uptimeNanoseconds
                    switch waitForWriteReadiness(remainingMicros) {
                    case .writable:
                        let elapsed = (DispatchTime.now().uptimeNanoseconds - waitStarted + 999) / 1_000
                        wouldBlockWaitMicros &+= max(1, elapsed)
                    case .timedOut:
                        wouldBlockWaitMicros &+= remainingMicros
                    case .unavailable:
                        usleep(retryDelay)
                        wouldBlockWaitMicros &+= UInt64(retryDelay)
                    }
                } else {
                    usleep(retryDelay)
                    wouldBlockWaitMicros &+= UInt64(retryDelay)
                }
                continue
            case .failed:
                finishQueuedBytes(countedBytes, chunkID: chunkID)
                fail(.writeFailed)
                return
            }
        }
        finishQueuedBytes(countedBytes, chunkID: chunkID)
        resumeAfterStallIfNeeded()
    }

    private func fail(_ status: TerminalInputStatus) {
        lock.lock()
        accepting = false
        lastFailure = status
        drainingAcceptedBacklog = false
        lock.unlock()
        onTerminalFailure?(status)
    }

    private func pauseForStalledInput() {
        lock.lock()
        accepting = false
        lastFailure = .inputStalled
        drainingAcceptedBacklog = false
        lock.unlock()
    }

    private func resumeAfterStallIfNeeded() {
        var didResume = false
        lock.lock()
        if lastFailure == .inputStalled {
            if queuedBytes == 0 {
                accepting = true
                lastFailure = nil
                drainingAcceptedBacklog = false
                didResume = true
            } else {
                drainingAcceptedBacklog = true
            }
        }
        lock.unlock()
        if didResume {
            onInputResumed?()
        }
    }

    private func drainPermission(chunkID: UInt64, stalledRetry: Bool) -> DrainPermission {
        lock.lock()
        defer { lock.unlock() }
        if !accepting, lastFailure != .inputStalled { return .stopped }
        guard pendingChunkHeadIndex < pendingChunkIDs.count,
              pendingChunkIDs[pendingChunkHeadIndex] == chunkID else { return .wait }
        if accepting { return .write }
        return (stalledRetry || drainingAcceptedBacklog) ? .write : .wait
    }

    private func finishQueuedBytes(_ count: Int, chunkID: UInt64) {
        var nextDrain: WaitingDrain?
        lock.lock()
        guard finishedChunkIDs.insert(chunkID).inserted else {
            lock.unlock()
            return
        }
        queuedBytes = max(0, queuedBytes - count)
        activeChunkCount = max(0, activeChunkCount - 1)
        waitingDrains.removeValue(forKey: chunkID)
        while pendingChunkHeadIndex < pendingChunkIDs.count,
              finishedChunkIDs.remove(pendingChunkIDs[pendingChunkHeadIndex]) != nil {
            pendingChunkHeadIndex += 1
        }
        // Array.removeFirst on every chunk made one-byte backpressure O(n^2).
        // Compact only after a sizeable consumed prefix; live storage remains
        // bounded to roughly maxQueuedItems + this threshold.
        if pendingChunkHeadIndex >= 256,
           pendingChunkHeadIndex * 2 >= pendingChunkIDs.count {
            pendingChunkIDs.removeFirst(pendingChunkHeadIndex)
            pendingChunkHeadIndex = 0
        }
        if pendingChunkHeadIndex < pendingChunkIDs.count {
            nextDrain = waitingDrains.removeValue(forKey: pendingChunkIDs[pendingChunkHeadIndex])
        }
        lock.unlock()
        if let nextDrain {
            queue.async { [weak self] in
                self?.drain(
                    nextDrain.data,
                    chunkID: nextDrain.chunkID,
                    offset: nextDrain.offset,
                    countedBytes: nextDrain.countedBytes,
                    reportStall: nextDrain.reportStall,
                    stalledRetryAttempt: nextDrain.stalledRetryAttempt
                )
            }
        }
    }

    private func storeWaitingDrain(_ drain: WaitingDrain) {
        lock.lock()
        if !finishedChunkIDs.contains(drain.chunkID) {
            waitingDrains[drain.chunkID] = drain
        }
        lock.unlock()
    }

    private func scheduleRetry(
        _ data: Data,
        chunkID: UInt64,
        offset: Int,
        countedBytes: Int,
        reportStall: Bool,
        stalledRetryAttempt: Int
    ) {
        lock.lock()
        scheduledRetryCount += 1
        lock.unlock()
        let exponent = min(max(0, stalledRetryAttempt - 1), 10)
        let scaled = min(100_000, max(1, Int(retryDelay)) << exponent)
        let delay = DispatchTimeInterval.microseconds(scaled)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.drain(
                data,
                chunkID: chunkID,
                offset: offset,
                countedBytes: countedBytes,
                reportStall: reportStall,
                stalledRetryAttempt: stalledRetryAttempt
            )
        }
    }
}
