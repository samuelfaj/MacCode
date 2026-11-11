import Foundation
import Darwin
import AgentRuntime
import AppLifecycleSupport
import CoreModel
import Surfaces
import os

private let appDiagnosticsLog = Logger(subsystem: "io.remotecode.app", category: "diagnostics")

public struct ManagedProcessMemoryProfile: Sendable, Equatable {
    public let name: String
    public let physicalMemoryBytes: UInt64
    /// Reserved for telemetry only. Production admission never enforces a
    /// session count — the user decides how many concurrent agents to run.
    public let providerRootCap: Int?
    public let idleReleaseAge: TimeInterval
    public let warningFraction: Double
    public let criticalFraction: Double
    /// Reserved for telemetry only. Never used to refuse a user-started provider.
    public let hostProcessCeilingKB: Int?
    /// Reserved for telemetry only. Never used to refuse a user-started provider.
    public let managedTreeCeilingKB: Int?

    public init(
        name: String,
        physicalMemoryBytes: UInt64,
        providerRootCap: Int?,
        idleReleaseAge: TimeInterval,
        warningFraction: Double,
        criticalFraction: Double,
        hostProcessCeilingKB: Int?,
        managedTreeCeilingKB: Int?
    ) {
        self.name = name
        self.physicalMemoryBytes = physicalMemoryBytes
        self.providerRootCap = providerRootCap
        self.idleReleaseAge = idleReleaseAge
        self.warningFraction = warningFraction
        self.criticalFraction = criticalFraction
        self.hostProcessCeilingKB = hostProcessCeilingKB
        self.managedTreeCeilingKB = managedTreeCeilingKB
    }

    /// Scale idle release and pressure thresholds from installed RAM.
    /// Provider starts stay unlimited (user-controlled).
    public static func resolve(physicalMemoryBytes: UInt64) -> Self {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        if physicalMemoryBytes <= 8 * gib {
            return Self(
                name: "low-memory-8g",
                physicalMemoryBytes: physicalMemoryBytes,
                providerRootCap: nil,
                idleReleaseAge: 60,
                warningFraction: 0.60,
                criticalFraction: 0.75,
                hostProcessCeilingKB: nil,
                managedTreeCeilingKB: nil
            )
        }
        if physicalMemoryBytes <= 16 * gib {
            return Self(
                name: "mid-memory-16g",
                physicalMemoryBytes: physicalMemoryBytes,
                providerRootCap: nil,
                idleReleaseAge: 90,
                warningFraction: 0.65,
                criticalFraction: 0.80,
                hostProcessCeilingKB: nil,
                managedTreeCeilingKB: nil
            )
        }
        if physicalMemoryBytes <= 32 * gib {
            return Self(
                name: "standard-32g",
                physicalMemoryBytes: physicalMemoryBytes,
                providerRootCap: nil,
                idleReleaseAge: 2 * 60,
                warningFraction: 0.70,
                criticalFraction: 0.85,
                hostProcessCeilingKB: nil,
                managedTreeCeilingKB: nil
            )
        }
        if physicalMemoryBytes <= 64 * gib {
            return Self(
                name: "high-memory-64g",
                physicalMemoryBytes: physicalMemoryBytes,
                providerRootCap: nil,
                idleReleaseAge: 2 * 60,
                warningFraction: 0.72,
                criticalFraction: 0.88,
                hostProcessCeilingKB: nil,
                managedTreeCeilingKB: nil
            )
        }
        // 128 GiB+ workstation class.
        return Self(
            name: "high-memory-128g",
            physicalMemoryBytes: physicalMemoryBytes,
            providerRootCap: nil,
            idleReleaseAge: 2 * 60,
            warningFraction: 0.75,
            criticalFraction: 0.90,
            hostProcessCeilingKB: nil,
            managedTreeCeilingKB: nil
        )
    }
}

public enum ManagedProviderAdmissionDecision: Sendable, Equatable {
    case admit
    case blockedIncompleteScan
    case blockedUnknownMemory
    case blockedAtProviderCap(limit: Int)
    case blockedAtHostMemoryCeiling(limitKB: Int, measuredKB: Int)
    case blockedAtManagedTreeMemoryCeiling(limitKB: Int, measuredKB: Int)

    var telemetryReason: String {
        switch self {
        case .admit: "admit"
        case .blockedIncompleteScan: "blocked_incomplete_scan"
        case .blockedUnknownMemory: "blocked_unknown_memory"
        case .blockedAtProviderCap: "blocked_provider_cap"
        case .blockedAtHostMemoryCeiling: "blocked_host_memory_ceiling"
        case .blockedAtManagedTreeMemoryCeiling: "blocked_managed_tree_memory_ceiling"
        }
    }
}

public enum ManagedProviderAdmissionError: Error, LocalizedError, Sendable, Equatable {
    case processAccountingUnavailable
    case providerLimitReached(Int)
    case hostMemoryLimitReached(Int)
    case managedTreeMemoryLimitReached(Int)

    public var errorDescription: String? {
        switch self {
        case .processAccountingUnavailable:
            return L("A new provider could not start because managed-process accounting is incomplete. Try again after the next diagnostics scan.")
        case .providerLimitReached(let limit):
            return L("This Mac is already running the safe limit of %1$@ managed provider sessions. Finish or release an idle session, then try again.", limit)
        case .hostMemoryLimitReached(let limitKB):
            return L("A new provider could not start because MacCode reached its low-memory host limit of %1$@ MiB. Finish or release an idle session, then try again.", limitKB / 1_024)
        case .managedTreeMemoryLimitReached(let limitKB):
            return L("A new provider could not start because managed runtimes reached their low-memory limit of %1$@ MiB. Finish or release an idle session, then try again.", limitKB / 1_024)
        }
    }
}

public enum ManagedProviderAdmissionPolicy {
    /// Starts are unconditionally user-controlled, so sampling the complete
    /// process table before every provider launch cannot affect the decision.
    /// Periodic diagnostics continue to collect the same telemetry off-path.
    public static let requiresProviderStartPreflight = false

    /// Provider starts are user-controlled. Resource ceilings, session counts,
    /// incomplete process scans, and unknown memory samples must never refuse a
    /// start — they remain available only as telemetry enums for diagnostics.
    public static func decide(
        profile: ManagedProcessMemoryProfile,
        scanComplete: Bool,
        appFootprintKB: Int?,
        managedTreeRSSKB: Int?,
        liveProviderRoots: Int,
        requiresNewProviderRoot: Bool
    ) -> ManagedProviderAdmissionDecision {
        _ = profile
        _ = scanComplete
        _ = appFootprintKB
        _ = managedTreeRSSKB
        _ = liveProviderRoots
        _ = requiresNewProviderRoot
        return .admit
    }
}

public struct ManagedProviderAdmissionKey: Hashable, Sendable {
    public let provider: AgentProvider
    public let threadId: AgentThreadID

    public init(provider: AgentProvider, threadId: AgentThreadID) {
        self.provider = provider
        self.threadId = threadId
    }
}

public actor ManagedProviderAdmissionGate {
    private var pendingAdmissionDates: [ManagedProviderAdmissionKey: Date] = [:]
    private var residentRootByKey: [ManagedProviderAdmissionKey: pid_t] = [:]
    private var lastProviderRootPIDs: Set<pid_t> = []
    private let reservationLifetime: TimeInterval

    public init(reservationLifetime: TimeInterval = 60) {
        self.reservationLifetime = max(1, reservationLifetime)
    }

    public func decide(
        profile: ManagedProcessMemoryProfile,
        scan: ManagedProcessScan,
        appFootprintKB: Int?,
        key: ManagedProviderAdmissionKey,
        now: Date = Date()
    ) -> ManagedProviderAdmissionDecision {
        pendingAdmissionDates = pendingAdmissionDates.filter {
            now.timeIntervalSince($0.value) < reservationLifetime
        }
        var currentRootPIDs = Set<pid_t>()
        currentRootPIDs.reserveCapacity(scan.providerProcesses.count)
        for process in scan.providerProcesses {
            if let pgid = process.pgid, pgid > 0 {
                currentRootPIDs.insert(pgid)
            }
        }
        residentRootByKey = residentRootByKey.filter { currentRootPIDs.contains($0.value) }
        let appearedRootPIDs = currentRootPIDs.subtracting(lastProviderRootPIDs).sorted()
        let pendingKeys = pendingAdmissionDates.sorted {
            if $0.value == $1.value {
                return $0.key.threadId.value.uuidString < $1.key.threadId.value.uuidString
            }
            return $0.value < $1.value
        }.map(\.key)
        for (pendingKey, rootPID) in zip(pendingKeys, appearedRootPIDs) {
            residentRootByKey[pendingKey] = rootPID
            pendingAdmissionDates.removeValue(forKey: pendingKey)
        }
        lastProviderRootPIDs = currentRootPIDs

        let alreadyOwnsRootOrReservation = residentRootByKey[key] != nil
            || pendingAdmissionDates[key] != nil
        let effectiveRoots = scan.providerRootCount + pendingAdmissionDates.count
        let decision = ManagedProviderAdmissionPolicy.decide(
            profile: profile,
            scanComplete: scan.isComplete,
            appFootprintKB: appFootprintKB,
            managedTreeRSSKB: Self.totalManagedRSSKB(appFootprintKB: appFootprintKB, scan: scan),
            liveProviderRoots: effectiveRoots,
            requiresNewProviderRoot: !alreadyOwnsRootOrReservation
        )
        if decision == .admit, !alreadyOwnsRootOrReservation {
            pendingAdmissionDates[key] = now
        }
        return decision
    }

    private static func totalManagedRSSKB(
        appFootprintKB: Int?,
        scan: ManagedProcessScan
    ) -> Int? {
        guard scan.isComplete, let appFootprintKB, appFootprintKB >= 0 else { return nil }
        let values = [appFootprintKB]
            + scan.providerProcesses.map(\.rssKB)
            + scan.sidecarProcesses.map(\.rssKB)
        var total = 0
        for value in values {
            guard value >= 0 else { return nil }
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }
}

public enum ManagedMemoryPressureDecision: String, Sendable, Equatable {
    case unknown
    case normal
    case warning
    case critical
}

enum AppDiagnostics {
    struct SurfaceSnapshot: Sendable {
        let surfaceCount: Int
        let terminalCount: Int
        let runningTerminals: Int
        let pendingBytes: Int
        let droppedBytes: Int
        let historyFailures: Int
    }

    struct ProviderStats: Sendable, Equatable {
        let processCount: Int
        let totalRSSKB: Int
        let orphanCount: Int
    }

    struct ManagedAggregateSample: Sendable, Equatable {
        let appFootprintKB: Int?
        let providerProcessCount: Int?
        let providerRootCount: Int?
        let providerRSSKB: Int?
        let sidecarProcessCount: Int?
        let sidecarRootCount: Int?
        let sidecarRSSKB: Int?
        let totalManagedRSSKB: Int?
        let previousTotalManagedRSSKB: Int?
        let sampleIntervalSeconds: TimeInterval?
        let deltaManagedRSSKB: Int?
        let slopeKBPerMinute: Double?
        let highWaterManagedRSSKB: Int?
        let isComplete: Bool
        let pressureDecision: ManagedMemoryPressureDecision
        let admissionDecision: ManagedProviderAdmissionDecision
        let profile: ManagedProcessMemoryProfile
    }

    struct ManagedTrendState: Sendable, Equatable {
        private(set) var previousTotalManagedRSSKB: Int?
        private(set) var previousDate: Date?
        private(set) var highWaterManagedRSSKB: Int?

        mutating func record(
            appFootprintKB: Int?,
            scan: ManagedProcessScan?,
            profile: ManagedProcessMemoryProfile,
            now: Date
        ) -> ManagedAggregateSample {
            let interval = previousDate.map { now.timeIntervalSince($0) }
            let sample = aggregateManagedSample(
                appFootprintKB: appFootprintKB,
                scan: scan,
                profile: profile,
                previousTotalManagedRSSKB: previousTotalManagedRSSKB,
                sampleIntervalSeconds: interval,
                previousHighWaterManagedRSSKB: highWaterManagedRSSKB
            )
            if let total = sample.totalManagedRSSKB {
                previousTotalManagedRSSKB = total
                previousDate = now
                highWaterManagedRSSKB = sample.highWaterManagedRSSKB
            }
            return sample
        }
    }

    @MainActor
    static func aggregateSurfaceSnapshot(_ surfaces: [any Surface]) -> SurfaceSnapshot {
        let terminalHealth = surfaces.compactMap {
            ($0 as? TerminalRuntimeRoutingSurface)?.routedRuntimeHealth()
        }
        return SurfaceSnapshot(
            surfaceCount: surfaces.count,
            terminalCount: terminalHealth.count,
            runningTerminals: terminalHealth.filter(\.processAlive).count,
            pendingBytes: terminalHealth.reduce(0) { $0 + $1.outputPendingBytes },
            droppedBytes: terminalHealth.reduce(0) { $0 + $1.droppedOutputBytes },
            historyFailures: terminalHealth.reduce(0) { $0 + $1.historyWriteFailures }
        )
    }

    nonisolated static func aggregateProviderStats(
        processes: [ProviderRuntimeProcess]
    ) -> ProviderStats {
        // Single pass: RSS total + orphan (ppid == 1) count together, no
        // filter intermediate on the heartbeat path.
        var totalRSSKB = 0
        var orphanCount = 0
        for process in processes {
            totalRSSKB += process.rssKB
            if process.ppid == 1 { orphanCount += 1 }
        }
        return ProviderStats(
            processCount: processes.count,
            totalRSSKB: totalRSSKB,
            orphanCount: orphanCount
        )
    }

    nonisolated static func providerAdmissionDecision(
        profile: ManagedProcessMemoryProfile,
        scanComplete: Bool,
        appFootprintKB: Int?,
        managedTreeRSSKB: Int?,
        liveProviderRoots: Int,
        requiresNewProviderRoot: Bool = true
    ) -> ManagedProviderAdmissionDecision {
        ManagedProviderAdmissionPolicy.decide(
            profile: profile,
            scanComplete: scanComplete,
            appFootprintKB: appFootprintKB,
            managedTreeRSSKB: managedTreeRSSKB,
            liveProviderRoots: liveProviderRoots,
            requiresNewProviderRoot: requiresNewProviderRoot
        )
    }

    nonisolated static func aggregateManagedSample(
        appFootprintKB: Int?,
        scan: ManagedProcessScan?,
        profile: ManagedProcessMemoryProfile,
        previousTotalManagedRSSKB: Int? = nil,
        sampleIntervalSeconds: TimeInterval? = nil,
        previousHighWaterManagedRSSKB: Int? = nil
    ) -> ManagedAggregateSample {
        let validApp = appFootprintKB.flatMap { $0 >= 0 ? $0 : nil }
        let complete = validApp != nil && scan?.isComplete == true
        guard complete, let validApp, let scan else {
            return ManagedAggregateSample(
                appFootprintKB: validApp,
                providerProcessCount: nil,
                providerRootCount: nil,
                providerRSSKB: nil,
                sidecarProcessCount: nil,
                sidecarRootCount: nil,
                sidecarRSSKB: nil,
                totalManagedRSSKB: nil,
                previousTotalManagedRSSKB: previousTotalManagedRSSKB,
                sampleIntervalSeconds: sampleIntervalSeconds,
                deltaManagedRSSKB: nil,
                slopeKBPerMinute: nil,
                highWaterManagedRSSKB: previousHighWaterManagedRSSKB,
                isComplete: false,
                pressureDecision: .unknown,
                admissionDecision: ManagedProviderAdmissionPolicy.decide(
                    profile: profile,
                    scanComplete: scan?.isComplete == true,
                    appFootprintKB: validApp,
                    managedTreeRSSKB: nil,
                    liveProviderRoots: scan?.providerRootCount ?? 0,
                    requiresNewProviderRoot: true
                ),
                profile: profile
            )
        }

        let providerStats = aggregateProviderStats(processes: scan.providerProcesses)
        let sidecarStats = aggregateProviderStats(processes: scan.sidecarProcesses)
        let total = validApp + providerStats.totalRSSKB + sidecarStats.totalRSSKB
        let delta = previousTotalManagedRSSKB.map { total - $0 }
        let slope = delta.flatMap { delta -> Double? in
            guard let sampleIntervalSeconds, sampleIntervalSeconds > 0 else { return nil }
            return Double(delta) * 60 / sampleIntervalSeconds
        }
        let highWater = max(previousHighWaterManagedRSSKB ?? total, total)
        let physicalKB = Double(profile.physicalMemoryBytes) / 1_024
        let fraction = physicalKB > 0 ? Double(total) / physicalKB : 0
        let pressure: ManagedMemoryPressureDecision
        if fraction >= profile.criticalFraction {
            pressure = .critical
        } else if fraction >= profile.warningFraction {
            pressure = .warning
        } else {
            pressure = .normal
        }
        return ManagedAggregateSample(
            appFootprintKB: validApp,
            providerProcessCount: providerStats.processCount,
            providerRootCount: scan.providerRootCount,
            providerRSSKB: providerStats.totalRSSKB,
            sidecarProcessCount: sidecarStats.processCount,
            sidecarRootCount: scan.sidecarRootCount,
            sidecarRSSKB: sidecarStats.totalRSSKB,
            totalManagedRSSKB: total,
            previousTotalManagedRSSKB: previousTotalManagedRSSKB,
            sampleIntervalSeconds: sampleIntervalSeconds,
            deltaManagedRSSKB: delta,
            slopeKBPerMinute: slope,
            highWaterManagedRSSKB: highWater,
            isComplete: true,
            pressureDecision: pressure,
            admissionDecision: ManagedProviderAdmissionPolicy.decide(
                profile: profile,
                scanComplete: true,
                appFootprintKB: validApp,
                managedTreeRSSKB: total,
                liveProviderRoots: scan.providerRootCount,
                requiresNewProviderRoot: true
            ),
            profile: profile
        )
    }

    @MainActor private static var providerScanInFlight = false
    @MainActor private static var managedTrendState = ManagedTrendState()
    /// S7: single process-wide pressure coordinator driven by live heartbeat samples.
    static let pressureGovernor = PressureGovernorCoordinator()
#if DEBUG
    @MainActor static var lastPressureIngestEmittedForTesting: [PressureActionKind] = []
    @MainActor static var lastPressureExecuteOutcomeForTesting: PressureMutationOutcome?
#endif

    enum ProviderScanDecision: Equatable {
        case start
        case skipInFlight
    }

    @MainActor static func beginProviderScanForTests() -> ProviderScanDecision { beginProviderScan() }
    @MainActor static func finishProviderScanForTests() { finishProviderScan() }

    /// Test seam: drive the same ingest→execute path as heartbeat without OS scans.
    @MainActor
    static func ingestPressureFromHeartbeatSampleForTesting(
        sample: ManagedAggregateSample,
        activeAgentThreads: Int,
        surface: SurfaceSnapshot
    ) {
        drivePressureGovernor(
            sample: sample,
            activeAgentThreads: activeAgentThreads,
            surface: surface
        )
    }

    @MainActor
    private static func beginProviderScan() -> ProviderScanDecision {
        guard !providerScanInFlight else { return .skipInFlight }
        providerScanInFlight = true
        return .start
    }

    @MainActor private static func finishProviderScan() { providerScanInFlight = false }

    @MainActor
    static func heartbeat(
        reason: String,
        activeAgentThreads: Int,
        profile: ManagedProcessMemoryProfile,
        lifecycleRecorder: AppLifecycleRecorder? = nil,
        processList: @escaping ProviderProcessList = { try ProviderProcessSweeper.psRowsThrowing() }
    ) {
        let snapshot = aggregateSurfaceSnapshot(SurfaceRegistry.shared.all())
        let footprint = currentProcessFootprintKB()
        let appFootprint = footprint >= 0 ? footprint : nil
        let pid = ProcessInfo.processInfo.processIdentifier

        guard beginProviderScan() == .start else {
            let sample = managedTrendState.record(
                appFootprintKB: appFootprint,
                scan: nil,
                profile: profile,
                now: Date()
            )
            logHeartbeat(
                reason: reason,
                pid: pid,
                activeAgentThreads: activeAgentThreads,
                surface: snapshot,
                sample: sample,
                scanState: "skipped_in_flight"
            )
            return
        }

        Task.detached(priority: .utility) {
            let scan: ManagedProcessScan?
            let scanState: String
            do {
                guard let store = ProviderProcessOwnership.shared.store() else {
                    throw ProviderProcessOwnershipError.storeNotConfigured
                }
                scan = try ProviderProcessSweeper.managedProcessScan(
                    store: store,
                    processList: processList
                )
                scanState = scan?.isComplete == true ? "complete" : "incomplete_ownership"
            } catch {
                scan = nil
                scanState = "failed"
            }
            await MainActor.run {
                finishProviderScan()
                let sample = managedTrendState.record(
                    appFootprintKB: appFootprint,
                    scan: scan,
                    profile: profile,
                    now: Date()
                )
                logHeartbeat(
                    reason: reason,
                    pid: pid,
                    activeAgentThreads: activeAgentThreads,
                    surface: snapshot,
                    sample: sample,
                    scanState: scanState
                )
                if sample.isComplete,
                   let providerProcesses = sample.providerProcessCount,
                   let providerRSSKB = sample.providerRSSKB,
                   let sidecarProcesses = sample.sidecarProcessCount,
                   let sidecarRSSKB = sample.sidecarRSSKB {
                    lifecycleRecorder?.recordHeartbeat(
                        reason: reason,
                        providerProcesses: providerProcesses,
                        providerRSSKB: providerRSSKB,
                        orphanProviders: scan.map { aggregateProviderStats(processes: $0.providerProcesses).orphanCount } ?? 0,
                        sidecarProcesses: sidecarProcesses,
                        sidecarRSSKB: sidecarRSSKB,
                        orphanSidecars: scan.map { aggregateProviderStats(processes: $0.sidecarProcesses).orphanCount } ?? 0
                    )
                }
            }
        }
    }

    @MainActor
    private static func logHeartbeat(
        reason: String,
        pid: Int32,
        activeAgentThreads: Int,
        surface: SurfaceSnapshot,
        sample: ManagedAggregateSample,
        scanState: String
    ) {
        let value: (Int?) -> String = { $0.map(String.init) ?? "unavailable" }
        let doubleValue: (Double?) -> String = { $0.map { String(format: "%.2f", $0) } ?? "unavailable" }
        appDiagnosticsLog.info(
            "app.heartbeat reason=\(reason, privacy: .public) pid=\(pid, privacy: .public) managedScan=\(scanState, privacy: .public) complete=\(sample.isComplete, privacy: .public) appRSSKB=\(value(sample.appFootprintKB), privacy: .public) providerProcesses=\(value(sample.providerProcessCount), privacy: .public) providerRoots=\(value(sample.providerRootCount), privacy: .public) providerRSSKB=\(value(sample.providerRSSKB), privacy: .public) sidecarProcesses=\(value(sample.sidecarProcessCount), privacy: .public) sidecarRoots=\(value(sample.sidecarRootCount), privacy: .public) sidecarRSSKB=\(value(sample.sidecarRSSKB), privacy: .public) totalManagedRSSKB=\(value(sample.totalManagedRSSKB), privacy: .public) previousManagedRSSKB=\(value(sample.previousTotalManagedRSSKB), privacy: .public) sampleIntervalSeconds=\(doubleValue(sample.sampleIntervalSeconds), privacy: .public) deltaManagedRSSKB=\(value(sample.deltaManagedRSSKB), privacy: .public) slopeKBPerMinute=\(doubleValue(sample.slopeKBPerMinute), privacy: .public) highWaterManagedRSSKB=\(value(sample.highWaterManagedRSSKB), privacy: .public) memoryProfile=\(sample.profile.name, privacy: .public) physicalMemoryBytes=\(sample.profile.physicalMemoryBytes, privacy: .public) providerRootCap=\(value(sample.profile.providerRootCap), privacy: .public) hostProcessCeilingKB=\(value(sample.profile.hostProcessCeilingKB), privacy: .public) managedTreeCeilingKB=\(value(sample.profile.managedTreeCeilingKB), privacy: .public) admission=\(sample.admissionDecision.telemetryReason, privacy: .public) ownershipLedgerCap=\(ProviderProcessOwnershipStore.defaultMaxRecords, privacy: .public) pressure=\(sample.pressureDecision.rawValue, privacy: .public) surfaces=\(surface.surfaceCount, privacy: .public) terminals=\(surface.terminalCount, privacy: .public) runningTerminals=\(surface.runningTerminals, privacy: .public) activeAgentThreads=\(activeAgentThreads, privacy: .public) terminalPendingBytes=\(surface.pendingBytes, privacy: .public) terminalDroppedBytes=\(surface.droppedBytes, privacy: .public) terminalHistoryFailures=\(surface.historyFailures, privacy: .public)"
        )
        // S7 + S12: drive pressure coordinator (ingest/execute) and publish Capacity UX.
        drivePressureGovernor(
            sample: sample,
            activeAgentThreads: activeAgentThreads,
            surface: surface
        )
    }

    /// Shared production path: heartbeat samples → PressureGovernorCoordinator
    /// ingest → non-destructive execute with live target revalidation.
    @MainActor
    private static func drivePressureGovernor(
        sample: ManagedAggregateSample,
        activeAgentThreads: Int,
        surface: SurfaceSnapshot
    ) {
        let hostLevel: PressureLevel = {
            switch sample.pressureDecision {
            case .critical: return .critical
            case .warning: return .warning
            case .normal, .unknown: return .normal
            }
        }()
        // Provider-tree pressure vs an authoritative capacity denominator (managed tree
        // ceiling when known), not app/provider composition share.
        let providerLevel: PressureLevel = {
            guard sample.isComplete, let providerKB = sample.providerRSSKB else {
                return .normal
            }
            let denominatorKB: Double = {
                if let ceiling = sample.profile.managedTreeCeilingKB, ceiling > 0 {
                    return Double(ceiling)
                }
                let physical = sample.profile.physicalMemoryBytes
                if physical > 0 {
                    return Double(physical) / 1024.0
                }
                return 0
            }()
            guard denominatorKB > 0 else { return .normal }
            let fraction = Double(providerKB) / denominatorKB
            if fraction >= 0.85 { return .critical }
            if fraction >= 0.70 { return .warning }
            return .normal
        }()

        let physicalKB = Double(sample.profile.physicalMemoryBytes) / 1_024
        let managedFraction: Double? = {
            guard sample.isComplete, let total = sample.totalManagedRSSKB, physicalKB > 0 else {
                return nil
            }
            return Double(total) / physicalKB
        }()
        // S7: managed-RSS samples must NOT be promoted to OS critical/warning.
        // RSS hysteresis is two complete samples; OS signals are immediate only
        // when a real dispatch/OS source says so (not yet wired → always normal).
        let pressureSample = PressureSample(
            date: Date(),
            osSignal: .normal,
            managedRSSFraction: managedFraction,
            isComplete: sample.isComplete,
            isStale: !sample.isComplete
        )
        // Align governor thresholds with the host memory profile (S7).
        let profileThresholds = PressureThresholds(
            warningFraction: sample.profile.warningFraction,
            criticalFraction: sample.profile.criticalFraction
        )
        let transition = pressureGovernor.ingest(
            sample: pressureSample,
            thresholds: profileThresholds
        )
#if DEBUG
        lastPressureIngestEmittedForTesting = transition.emittedActions
#endif
        if !transition.emittedActions.isEmpty {
            let planEpoch = transition.state.epoch
            let planTarget = PressureMutationTarget(
                epoch: planEpoch,
                surfaceVisible: surface.surfaceCount > 0,
                providerSessionActive: activeAgentThreads > 0
                    || (sample.providerRootCount ?? 0) > 0
            )
            let plan = PressureMutationPlan(
                actions: transition.emittedActions,
                target: planTarget
            )
            let outcome = pressureGovernor.execute(plan: plan, liveTargetProvider: {
                PressureMutationTarget(
                    epoch: planEpoch,
                    surfaceVisible: SurfaceRegistry.shared.all().isEmpty == false,
                    providerSessionActive: activeAgentThreads > 0
                        || (sample.providerRootCount ?? 0) > 0
                )
            })
#if DEBUG
            lastPressureExecuteOutcomeForTesting = outcome
#endif
            let acknowledged = applyPressureActions(outcome.applied)
            // Sticky UX: union newly acknowledged with still-active effects.
            lastAppliedPressureActionsForUX = Array(
                Set(acknowledged.map(\.rawValue)).union(activePressureEffects.map(\.rawValue))
            ).sorted()
        } else if !activePressureEffects.isEmpty {
            lastAppliedPressureActionsForUX = activePressureEffects.map(\.rawValue).sorted()
        }

        // S7: paced recovery only fires once level is already normal (resume
        // optional work after step-down). Calling it while elevated is a no-op.
        if transition.state.level == .normal {
            if !activePressureEffects.isEmpty || maintenancePruneDeferred {
                _ = applyPressureActions([.resumeOptionalWorkUnit])
            }
            // Healthy normal operation must not show degradation actions.
            lastAppliedPressureActionsForUX = []
            // pacedRecovery still advances recovery accounting without UX noise.
            _ = pressureGovernor.pacedRecovery(at: Date())
        }

        // S1: production gauge recording from live heartbeat RSS samples.
        CapacityGaugeRecorder.shared.noteRSS(
            appKB: sample.appFootprintKB.map(Int64.init),
            providerKB: sample.providerRSSKB.map(Int64.init),
            sidecarKB: sample.sidecarRSSKB.map(Int64.init)
        )

        // Capacity UX: prefer coordinator level when ingest advanced state; else
        // host-level from sample (ingest already published via CapacityUXStatusStore).
        let coordLevel = pressureGovernor.currentState().level
        CapacityUXStatusStore.shared.publish(
            CapacityUXStatus.from(
                hardwareTierName: sample.profile.name,
                hostPressure: max(hostLevel, coordLevel),
                providerTreePressure: providerLevel,
                envelopeMeasured: false, // physical canary not claimed from heartbeat alone
                beyondEnvelope: sample.pressureDecision == .critical || coordLevel == .critical,
                accountingAvailable: sample.isComplete,
                degradationActions: {
                    if !lastAppliedPressureActionsForUX.isEmpty {
                        return lastAppliedPressureActionsForUX
                    }
                    if sample.pressureDecision != .normal,
                       sample.pressureDecision != .unknown {
                        return [sample.pressureDecision.rawValue]
                    }
                    return []
                }()
            )
        )
    }

    /// Live flags for optional-work actions so UX only reports real mutations.
    @MainActor private static var maintenancePruneDeferred = false
    /// Sticky active effects until recovery (not cleared on every heartbeat).
    @MainActor private static var activePressureEffects: Set<PressureActionKind> = []
    @MainActor private static var lastAppliedPressureActionsForUX: [String] = []
    /// Hooks installed by AppShell (idle session shortener, UI reclaim).
    static var pressureActionHandlers: [PressureActionKind: @Sendable () -> Void] = [:]

    /// Returns only mutations that actually executed (not notional notifications).
    @MainActor
    @discardableResult
    private static func applyPressureActions(_ actions: [PressureActionKind]) -> [PressureActionKind] {
        var acknowledged: [PressureActionKind] = []
        for action in actions {
            switch action {
            case .resumeOptionalWorkUnit:
                maintenancePruneDeferred = false
                activePressureEffects.removeAll()
                acknowledged.append(action)
            case .deferMaintenancePrune:
                // No production consumer yet — do not acknowledge as applied.
                maintenancePruneDeferred = true
            case .reclaimHiddenRecomputableUI,
                 .shortenCompletedIdleProviderSessions:
                // Only count as applied when a real handler is registered.
                if let handler = pressureActionHandlers[action] {
                    handler()
                    activePressureEffects.insert(action)
                    acknowledged.append(action)
                }
            case .neverKillActiveTurn, .neverDeferScheduledOccurrence:
                break
            }
        }
        return acknowledged
    }

    @MainActor
    static var isMaintenancePruneDeferred: Bool { maintenancePruneDeferred }

    @MainActor
    static var activePressureEffectsForTesting: Set<PressureActionKind> { activePressureEffects }

    static func currentProcessFootprintKB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1_024)
    }
}

extension Notification.Name {
    /// S7: non-destructive pressure optional-work (UI reclaim, idle session, Distill GPU).
    static let rcPressureOptionalWork = Notification.Name("io.remotecode.pressure.optionalWork")
}
