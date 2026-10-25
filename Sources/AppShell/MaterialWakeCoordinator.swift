import Foundation
import os
import SocketServer

/// S-005a: expand silent catch-up emission for Phase A material kinds.
/// Subscribes to EventBus; never pushes stream_only kinds. Gated by `wake_phase_a`
/// (default **on**; kill via UserDefaults false). Published attention kinds also
/// require `wake_published_kinds` (default on).
///
/// Delivery is a bounded serial queue: classify on the EventBus delivery thread,
/// then enqueue one ordered drain task so concurrent material events cannot spawn
/// unbounded unstructured Tasks. Pending depth is bounded by coalesce class: at
/// most one item per `MaterialWakeCoalesceClass` (newest payload/seq wins).
/// Force / `.boot` is its own class so a Mac-relaunch wake cannot be collapsed
/// away by run-progress traffic.
public final class MaterialWakeCoordinator: @unchecked Sendable {
    public static let shared = MaterialWakeCoordinator()
    private static let log = Logger(subsystem: "io.remotecode.app", category: "material-wake")

    /// Hard upper bound on `pending` depth (= number of coalesce classes).
    public static var maxPendingDepth: Int { MaterialWakeCoalesceClass.allCases.count }

    private let lock = NSLock()
    private var subscriptionToken: UUID?
    private weak var bridge: PrivateNotificationBridge?
    private var bootEpochProvider: (() -> String?)?
    private var watermarkProvider: (() -> String?)?

    /// Serial wake work items (FIFO by first-seen class). Filled on EventBus
    /// delivery; drained off it. At most one entry per coalesce class.
    private var pending: [PendingWake] = []
    private var drainTask: Task<Void, Never>?
    /// Runs whose terminal event wakes no phone (`muteTerminalWake`).
    private var mutedRunIds: Set<String> = []

    #if DEBUG
    /// DEBUG-only delivery observer/replacement for unit tests. Compiled out of
    /// release/shipped builds so production drain can only call the real bridge.
    private var testDeliverer: (@Sendable (String, Bool, SilentCatchUpV1, MaterialWakeCoalesceClass) async -> Void)?
    /// Counts DEBUG-only diversions off the real bridge (tests / local debug).
    private var testDelivererDivertCount: Int = 0
    #endif

    private struct PendingWake {
        let hostHint: String
        let force: Bool
        let payload: SilentCatchUpV1
        let coalesceClass: MaterialWakeCoalesceClass
        var delta: [String: String] = [:]
    }

    private init() {}

    /// - Parameters:
    ///   - bootEpochProvider: host boot epoch for silent_catchup.v1 (S-006).
    ///   - watermarkProvider: monotonic event bus seq string for `rc2_wm`.
    public func start(
        bridge: PrivateNotificationBridge,
        bootEpochProvider: @escaping () -> String? = { nil },
        watermarkProvider: @escaping () -> String? = { String(EventBus.shared.currentSeq) }
    ) {
        // Never call EventBus.subscribe while holding `lock`: subscribe may
        // synchronously replay backlog into `handle`, which also takes `lock`
        // (self-deadlock once any material event is already in the recent ring).
        lock.lock()
        self.bridge = bridge
        self.bootEpochProvider = bootEpochProvider
        self.watermarkProvider = watermarkProvider
        let needsSubscribe = subscriptionToken == nil
        lock.unlock()
        if needsSubscribe {
            installSubscription()
        }
        Self.log.info("MaterialWakeCoordinator started")
    }

    #if DEBUG
    /// Test-only start: EventBus subscribe + classify/enqueue without a real
    /// `PrivateNotificationBridge`. Requires `setTestDelivererForTests` so
    /// `handle` admits wakes and drain diverts off HTTPS. Avoids full app
    /// Bootstrap (not needed when the DEBUG deliverer is installed).
    ///
    /// Subscribes from `currentSeq` (not `nil`) so prior tests' EventBus ring
    /// does not flood this test's deliverer — coverage is still the live
    /// subscribe → handle → enqueue path for events published after start.
    func startForTests(
        bootEpochProvider: @escaping () -> String? = { nil },
        watermarkProvider: @escaping () -> String? = { String(EventBus.shared.currentSeq) }
    ) {
        lock.lock()
        self.bridge = nil
        self.bootEpochProvider = bootEpochProvider
        self.watermarkProvider = watermarkProvider
        let needsSubscribe = subscriptionToken == nil
        lock.unlock()
        if needsSubscribe {
            installSubscription(since: EventBus.shared.currentSeq)
        }
        Self.log.info("MaterialWakeCoordinator started (tests, no bridge)")
    }
    #endif

    /// Install EventBus subscription without holding `lock` (see `start`).
    private func installSubscription(since: Int64? = nil) {
        let token = EventBus.shared.subscribe(since: since) { [weak self] event in
            self?.handle(event: event)
        }
        lock.lock()
        if subscriptionToken == nil {
            subscriptionToken = token
            lock.unlock()
        } else {
            // Lost a race with another start — drop the extra subscription.
            lock.unlock()
            EventBus.shared.unsubscribe(token)
        }
    }

    public func stop() {
        // Unsubscribe off `lock`: delivery may be mid-`handle` waiting on it.
        lock.lock()
        let token = subscriptionToken
        subscriptionToken = nil
        bridge = nil
        bootEpochProvider = nil
        watermarkProvider = nil
        #if DEBUG
        testDeliverer = nil
        testDelivererDivertCount = 0
        #endif
        pending.removeAll()
        mutedRunIds.removeAll()
        drainTask?.cancel()
        drainTask = nil
        lock.unlock()
        if let token {
            EventBus.shared.unsubscribe(token)
        }
    }

    /// The terminal event of this run (`agent.run.completed` / `agent.run.failed`)
    /// queues no wake. For a side chat: the phone does not list side threads, so
    /// their finish must not take a slot of the hourly silent-wake budget. The
    /// publisher calls this before it publishes; `runId` is the payload's `run_id`.
    public func muteTerminalWake(runId: String) {
        lock.lock()
        // Not subscribed: no event would ever take the entry out again.
        if subscriptionToken != nil { mutedRunIds.insert(runId) }
        lock.unlock()
    }

    /// Pure seam: build v1 payload for a material event (tests assert fields).
    public static func makeSilentPayload(
        eventSeq: Int64,
        reason: String,
        bootEpoch: String?,
        watermark: String?
    ) -> SilentCatchUpV1 {
        SilentCatchUpV1(
            catchUp: true,
            watermark: watermark ?? String(eventSeq),
            sinceSeq: String(eventSeq),
            bootEpoch: bootEpoch,
            reason: reason
        )
    }

    /// Pure seam for tests: should this event produce a silent wake under current flags?
    public static func shouldSilentWake(
        kind: String,
        wakePhaseA: Bool,
        wakePhaseBGit: Bool,
        wakePublishedKinds: Bool = true
    ) -> (allowed: Bool, force: Bool, reason: String) {
        let classification = MaterialWakeTaxonomy.classification(forEventKind: kind)
        switch classification {
        case .streamOnly:
            return (false, false, "stream_only")
        case .criticalAlert:
            // Alert path remains the primary UX; silent optional only via Phase A list.
            return (false, false, "critical_alert_only")
        case .silentOrAlert:
            guard wakePhaseBGit else { return (false, false, "phase_b_off") }
            return (true, false, MaterialWakeTaxonomy.silentReason(forEventKind: kind))
        case .criticalAlertAndSilent, .silent, .silentForce:
            guard wakePhaseA else { return (false, false, "phase_a_off") }
            if MaterialWakeTaxonomy.publishedAttentionKinds.contains(kind) {
                // Widened allowlist kill switch: core lifecycle still works when false.
                guard wakePublishedKinds else { return (false, false, "published_kinds_off") }
            }
            guard MaterialWakeTaxonomy.phaseAAllowsSilent(classification) else {
                return (false, false, "not_phase_a_silent")
            }
            let force = MaterialWakeTaxonomy.shouldForceSilent(classification)
            return (true, force, MaterialWakeTaxonomy.silentReason(forEventKind: kind))
        }
    }

    /// Test / observability seam: pending serial queue depth (0 when idle).
    public func pendingWakeCountForTests() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    #if DEBUG
    /// DEBUG-only: install a deliverer that replaces the real bridge path so
    /// queue bound / newest-wins / force-survival can be proven without HTTPS.
    /// Not present in release builds — shipped drain always uses `bridge`.
    func setTestDelivererForTests(
        _ deliverer: (@Sendable (String, Bool, SilentCatchUpV1, MaterialWakeCoalesceClass) async -> Void)?
    ) {
        lock.lock()
        testDeliverer = deliverer
        lock.unlock()
        if deliverer != nil {
            Self.log.warning("material_wake test_deliverer_installed (DEBUG only; not in release builds)")
        }
    }

    /// DEBUG-only: how many times drain diverted to the test deliverer.
    func testDelivererDivertCountForTests() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return testDelivererDivertCount
    }
    #endif

    /// Test seam: enqueue a pending wake without EventBus (classification already decided).
    public func enqueueForTests(
        hostHint: String,
        force: Bool,
        payload: SilentCatchUpV1,
        coalesceClass: MaterialWakeCoalesceClass
    ) {
        enqueue(PendingWake(
            hostHint: hostHint,
            force: force,
            payload: payload,
            coalesceClass: coalesceClass
        ))
    }

    /// Pure seam: insert or replace by coalesce class. Newest same-class item
    /// wins; depth is at most the number of distinct classes present.
    /// Force / `.boot` is a separate class so progress never collapses it.
    public static func insertCoalesced(
        into pending: inout [(coalesceClass: MaterialWakeCoalesceClass, hostHint: String, force: Bool, sinceSeq: String)],
        item: (coalesceClass: MaterialWakeCoalesceClass, hostHint: String, force: Bool, sinceSeq: String)
    ) {
        if let idx = pending.firstIndex(where: { $0.coalesceClass == item.coalesceClass }) {
            pending[idx] = item
        } else {
            pending.append(item)
        }
    }

    private func handle(event: EventBus.Event) {
        // Runs on EventBus serial delivery queue — classify here, deliver off-queue.
        let kind = event.kind
        if kind == "agent.run.completed" || kind == "agent.run.failed",
           let runId = event.payload.objectValue?["run_id"]?.stringValue {
            lock.lock()
            let muted = mutedRunIds.remove(runId) != nil
            lock.unlock()
            if muted { return }
        }
        let decision = Self.shouldSilentWake(
            kind: kind,
            wakePhaseA: ConnectionFeatureFlags.wakePhaseAEnabled,
            wakePhaseBGit: ConnectionFeatureFlags.wakePhaseBGitEnabled,
            wakePublishedKinds: ConnectionFeatureFlags.wakePublishedKindsEnabled
        )
        guard decision.allowed else { return }
        lock.lock()
        let bridge = self.bridge
        #if DEBUG
        let hasTestDeliverer = testDeliverer != nil
        #endif
        let bootEpoch = bootEpochProvider?()
        let watermark = watermarkProvider?()
        lock.unlock()
        // Production: only the real bridge admits a wake. DEBUG tests may observe
        // via a compile-gated deliverer when no bridge is retained.
        #if DEBUG
        guard bridge != nil || hasTestDeliverer else { return }
        #else
        guard bridge != nil else { return }
        #endif
        let payload = Self.makeSilentPayload(
            eventSeq: event.seq,
            reason: decision.reason,
            bootEpoch: bootEpoch,
            watermark: watermark
        )
        let object = event.payload.objectValue
        let item = PendingWake(
            hostHint: kind,
            force: decision.force,
            payload: payload,
            coalesceClass: MaterialWakeTaxonomy.coalesceClass(forEventKind: kind),
            delta: PushConnectionHints.delta(
                threadId: object?["thread_id"]?.stringValue,
                workspaceId: object?["workspace_id"]?.stringValue,
                state: object?["status"]?.stringValue ?? kind,
                kind: kind,
                preview: object?["preview"]?.stringValue,
                seq: String(event.seq)
            )
        )
        enqueue(item)
    }

    private func enqueue(_ item: PendingWake) {
        lock.lock()
        // Bound: at most one pending item per coalesce class. Newest wins so a
        // hung HTTPS POST cannot grow `pending` without limit under a storm of
        // redundant same-class material events. Force is `.boot` and never
        // shares a slot with run-progress / attention.
        if let idx = pending.firstIndex(where: { $0.coalesceClass == item.coalesceClass }) {
            pending[idx] = item
        } else {
            pending.append(item)
        }
        if drainTask == nil {
            drainTask = Task { [weak self] in
                await self?.drainPending()
            }
        }
        lock.unlock()
    }

    private func drainPending() async {
        while true {
            let next: PendingWake?
            let bridge: PrivateNotificationBridge?
            #if DEBUG
            let testDeliverer: (@Sendable (String, Bool, SilentCatchUpV1, MaterialWakeCoalesceClass) async -> Void)?
            #endif
            lock.lock()
            if pending.isEmpty {
                drainTask = nil
                lock.unlock()
                return
            }
            next = pending.removeFirst()
            bridge = self.bridge
            #if DEBUG
            testDeliverer = self.testDeliverer
            #endif
            lock.unlock()
            guard let next else { continue }
            #if DEBUG
            if let testDeliverer {
                // DEBUG-only diversion: never present in release. Log + count so
                // local debug builds cannot silently swap the push path unnoticed.
                lock.lock()
                testDelivererDivertCount += 1
                let divertN = testDelivererDivertCount
                lock.unlock()
                Self.log.warning(
                    "material_wake test_deliverer_divert n=\(divertN, privacy: .public) hostHint=\(next.hostHint, privacy: .public) class=\(next.coalesceClass.rawValue, privacy: .public)"
                )
                await testDeliverer(next.hostHint, next.force, next.payload, next.coalesceClass)
                continue
            }
            #endif
            // Shipped path: only the real PrivateNotificationBridge.
            if let bridge {
                await bridge.deliverSilentCatchUp(
                    hostHint: next.hostHint,
                    force: next.force,
                    payload: next.payload,
                    coalesceClass: next.coalesceClass,
                    delta: next.delta
                )
            }
        }
    }
}
