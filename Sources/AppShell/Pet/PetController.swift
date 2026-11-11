import AppKit
import AgentRuntime
import CoreModel
import Foundation
import Persistence
import RemoteCodeTreaty
import SocketServer
import Surfaces

@MainActor
public final class PetController {
    private let context: AppContext
    private let router: AppCommandRouter
    private let settingsStore: SettingsStore
    private let attentionStore: PetAttentionStore
    private let notificationRecorder: PetTerminalNotificationRecorder
    private let model: PetViewModel
    private let speechController: PetSpeechController
    private var animationController: PetAnimationController?
    private var windowController: PetWindowController?
    private let systemMonitor = PetSystemActivityMonitor()
    private let openSettings: (PetSettingsRoute) -> Bool
    private let idleTimeoutNanoseconds: UInt64
    private let extendedReactionDurationProvider: () -> Int64
    private let companionDelayProvider: (ClosedRange<Int>) -> Int

    static let projectionWatermarkKey = "pet.event-projection-watermark.v1"

    private var reducer = PetEventReducer()
    private var eventSubscription: UUID?
    private var notificationTokens: [NSObjectProtocol] = []
    private var transientTask: Task<Void, Never>?
    private var companionTask: Task<Void, Never>?
    private var pendingCompanionCue: PetCompanionCue?
    private var attentionRefreshTask: Task<Void, Never>?
    private var activityCountsObserver: UUID?
    private var activitySurfaceGeneration: UInt64 = 0
    private var activitySurfaceTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var projectionWatermark: Int64?
    private var projectionErrorMessage: String?
    private var projectionRecoveryBlocked = false
    private var lastHandledEventSequence: Int64?
    private var companionDirector = PetCompanionDirector()
    private var isScreenLocked = false
    private var previousActiveRunProjectionHandler:
        ((ActiveRunProjection, ActiveRunProjectionCause) -> Void)?
    private var installedActiveRunProjectionHandler = false
    /// Latest material progress text per active agent thread for Live Activity
    /// single-active preview (tools / assistant). Not used by the pet popover.
    private var lastUpdatePreviewByThread: [AgentThreadID: String] = [:]
    /// Host run start times for active threads. Progress republish must not
    /// wipe these — empty startedByThread maps used to drop elapsed detail.
    private var startedAtByThread: [AgentThreadID: Date] = [:]
    /// Chrome from the last durable projection. Live Activity progress only
    /// overlays `lastUpdatePreview` + retained `startedAt`; it must not repeat
    /// N full `threadRepo.get` + bot list/link queries on MainActor.
    private var activeThreadChromeByID: [AgentThreadID: CachedActiveThreadChrome] = [:]
    /// PL-03: which active threads belong to a bot. Resolved once per thread
    /// (a thread's bot link cannot change mid-run) from the BotStore in-memory
    /// cache or one off-main SQLite lookup; `applyActiveThreadIDs` used to call
    /// `botStore.conversationsLinked` + `bots(ids:)` synchronously on the main
    /// thread for every `agent.item.started/completed` of every run.
    private enum LinkedBotResolution {
        case unlinked
        case linked(botID: BotID, name: String?)
    }
    private var linkedBotByActiveThread: [AgentThreadID: LinkedBotResolution] = [:]
    private var linkedBotResolveGeneration = 0
    private var linkedBotResolveTask: Task<Void, Never>?
    var linkedBotDurableLookupCountForTesting = 0
    /// Durable `threadRepo.get` calls from `applyActiveThreadIDs`.
    private(set) var activeThreadDurableLookupCountForTesting = 0
    /// Latest-wins generation for off-main chrome fetches. A stale Task must
    /// not apply chrome over a newer active set.
    private var activeThreadChromeGeneration: UInt64 = 0
    private var activeThreadChromeFetchTask: Task<Void, Never>?
    /// True when the last progress republish reused cached chrome.
    private(set) var progressRepublishUsedCachedChromeForTesting = false
    private(set) var handledEventOutOfOrderForTests = false
    private(set) var handledEventCountForTests = 0
    private(set) var lastScheduledTransientMillisecondsForTests: Int64?

    var modelForTests: PetViewModel { model }
    var speechControllerForTests: PetSpeechController { speechController }
    /// Test seam for the speech bubble's click route.
    var openSpeechRouteForTests: (([String: String]) -> Void)?
    var windowControllerForTests: PetWindowController { windowController! }
    var animationTimerIsRunningForTests: Bool { animationController?.timerIsRunning == true }
    /// Test seam: inject host ActiveRunProjection the same path production uses
    /// after coordinator start/finish (reconciles pet work pose).
    func applyActiveRunProjectionForTests(_ projection: ActiveRunProjection) {
        applyActiveRunProjection(projection)
    }
    func applyActiveThreadIDsForTests(
        _ threadIDs: [AgentThreadID],
        startedByThread: [AgentThreadID: Date] = [:]
    ) {
        applyActiveThreadIDs(threadIDs, startedByThread: startedByThread)
    }
    func republishActiveThreadsForLiveActivityForTests() {
        republishActiveThreadsForLiveActivity()
    }
    var hasScheduledTasksForTests: Bool {
        transientTask != nil
            || companionTask != nil
            || attentionRefreshTask != nil
            || idleTask != nil
    }
    var visualRuntimeIsLoadedForTests: Bool {
        animationController != nil && windowController != nil
    }
    var afterStartupCursorCapturedForTests: (() -> Void)?
    var destinationWindowIsKeyForTests: ((NSWindow) -> Bool)?

    public init(
        context: AppContext,
        router: AppCommandRouter,
        openSettings: @escaping (PetSettingsRoute) -> Bool,
        idleTimeoutNanoseconds: UInt64 = 600_000_000_000,
        extendedReactionDurationProvider: @escaping () -> Int64 = {
            Int64.random(in: PetCompanionDirector.extendedReactionDurationRange)
        },
        companionDelayProvider: @escaping (ClosedRange<Int>) -> Int = {
            Int.random(in: $0)
        }
    ) throws {
        self.context = context
        self.router = router
        self.openSettings = openSettings
        self.idleTimeoutNanoseconds = idleTimeoutNanoseconds
        self.extendedReactionDurationProvider = extendedReactionDurationProvider
        self.companionDelayProvider = companionDelayProvider
        self.settingsStore = SettingsStore(db: context.db)
        let settings = settingsStore.load()
        self.model = PetViewModel(settings: settings)
        self.speechController = PetSpeechController(model: model)
        self.attentionStore = PetAttentionStore(
            threadRepository: context.threadRepo,
            callbackRepository: context.providerPendingCallbackRepo,
            notificationRepository: NotificationRepository(db: context.db),
            markAgentThreadRead: { try router.markAgentThreadRead(thread: $0) },
            markNotificationRead: { try router.notificationMarkRead(id: $0) },
            workspaceNameProvider: { [weak context] workspaceID in
                context?.state.workspaces[workspaceID]?.name
            },
            destLookup: { [weak context] in
                guard let store = context?.botStore, let db = context?.db else {
                    return PetDestAttentionSnapshot(bots: [], conversations: [], attention: [])
                }
                let inboxID = (try? TitioNoticeRepository(db: db).inboxState())?.conversationID
                    .flatMap(UUID.init(uuidString:)).map(BotConversationID.init)
                return PetDestAttentionSnapshot(
                    bots: try store.list(),
                    conversations: try store.listConversations(
                        attentionStates: [.unreadActivity, .needsAttention]
                    ),
                    attention: try store.listAttention(),
                    linkedThreadIDs: try store.listLinkedAgentThreadIDs(),
                    excludedConversationIDs: inboxID.map { [$0] } ?? []
                )
            },
            markBotConversationViewed: { [weak context] conversationID in
                guard let store = context?.botStore,
                      var conversation = try store.conversation(id: conversationID) else { return }
                conversation.unread = false
                if conversation.attentionState == .unreadActivity
                    || conversation.attentionState == .needsAttention {
                    conversation.attentionState = .none
                }
                conversation.updatedAt = Date()
                try store.upsertConversation(conversation)
            },
            acknowledgeBotAttention: { [weak context] itemID in
                try context?.botStore.acknowledgeAttention(id: itemID)
            }
        )
        self.notificationRecorder = PetTerminalNotificationRecorder(
            repository: NotificationRepository(db: context.db)
        )
        configureSpeech()
    }

    /// Titio's notice hub speaks through here (`TitioNoticeCenter.setOnSpeech`).
    func speak(_ notice: TitioNoticeSpeech) {
        speechController.speak(PetSpeech(notice))
    }

    /// The desk or popover changed: hide the bubble if a rule now says so.
    func reevaluateSpeech() {
        speechController.reevaluate()
    }

    private func configureSpeech() {
        speechController.inputs = { [weak self] conversationID in
            guard let self else {
                return PetSpeechSuppression.Inputs(
                    speechEnabled: false, petEnabled: false, petVisible: false,
                    popoverOpen: false, inboxIsKeyDesk: false
                )
            }
            return PetSpeechSuppression.Inputs(
                speechEnabled: self.model.settings.petSpeechEnabled,
                petEnabled: self.model.settings.petEnabled,
                petVisible: self.windowController?.isVisible == true,
                popoverOpen: self.windowController?.isPopoverVisible == true,
                inboxIsKeyDesk: self.router.isTitioInboxViewed(conversationID)
            )
        }
        speechController.present = { [weak self] speech, onClick in
            guard let self, let windowController = self.windowController else { return false }
            return windowController.showSpeech(
                speech,
                reduceMotion: self.model.settings.petReduceMotion
                    || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                onClick: onClick,
                onHover: { [weak self] hovering in self?.speechController.setHovering(hovering) }
            )
        }
        speechController.dismiss = { [weak self] animated in
            self?.windowController?.hideSpeech(animated: animated)
        }
        speechController.openRoute = { [weak self] route in
            if let openRoute = self?.openSpeechRouteForTests {
                openRoute(route)
            } else {
                (NSApp?.delegate as? AppDelegate)?.openNotificationUserInfo(route)
            }
        }
        speechController.onSpoke = { [weak self] _ in
            guard let self,
                  let cue = PetCompanionDirector.speechCue(baseState: self.reducer.companionBaseState) else { return }
            // playCompanionCue skips the pounce under reduced motion or paused
            // animations; the bubble then only fades in.
            self.playCompanionCue(cue)
        }
    }

    public func start() {
        guard eventSubscription == nil else { return }
        let petModel = model
        activityCountsObserver = PetActivityCountsProjection.shared.observe { global, _ in
            petModel.apply(activityCounts: global)
        }
        let subscription = EventBus.shared.subscribeFromCurrent(filter: .full) { [weak self] event in
            guard !Self.isPrefilteredNoiseKind(event.kind) else { return }
            DispatchQueue.main.async { self?.handle(event) }
        }
        eventSubscription = subscription.id
        let cursor = subscription.cursor
        projectionErrorMessage = prepareProjectionRecovery(capturedCursor: cursor)
        projectionRecoveryBlocked = projectionErrorMessage != nil
        afterStartupCursorCapturedForTests?()
        installActiveRunProjectionObserver()
        refreshActiveThreadsFromCoordinator()
        refreshAttentionNow()
        applySettings(settingsStore.load())
        if let projectionErrorMessage { model.routeError = projectionErrorMessage }

        observeSettings()
        configureSystemMonitor()
        systemMonitor.start()
        scheduleIdleTimeout()
    }

    nonisolated static func isPrefilteredNoiseKind(_ kind: String) -> Bool {
        if alwaysPrefilteredNoiseKinds.contains(kind) { return true }
        return !PetEventDecoder.acceptedKinds.contains(kind)
            && !attentionProjectionKinds.contains(kind)
            && !liveActivityProgressKinds.contains(kind)
    }

    public func stop() {
        speechController.clear(animated: false)
        activitySurfaceGeneration &+= 1
        activitySurfaceTask?.cancel()
        activitySurfaceTask = nil
        windowController?.cancelActiveDrag()
        if let eventSubscription {
            EventBus.shared.unsubscribe(eventSubscription)
        }
        eventSubscription = nil
        if let activityCountsObserver {
            PetActivityCountsProjection.shared.removeObserver(activityCountsObserver)
            self.activityCountsObserver = nil
        }
        uninstallActiveRunProjectionObserver()
        transientTask?.cancel()
        transientTask = nil
        companionTask?.cancel()
        companionTask = nil
        pendingCompanionCue = nil
        attentionRefreshTask?.cancel()
        attentionRefreshTask = nil
        idleTask?.cancel()
        idleTask = nil
        activeThreadChromeFetchTask?.cancel()
        activeThreadChromeFetchTask = nil
        activeThreadChromeGeneration += 1
        animationController?.stop()
        windowController?.stop()
        animationController = nil
        windowController = nil
        systemMonitor.stop()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func prepareProjectionRecovery(capturedCursor: Int64) -> String? {
        do {
            let raw = try context.settingsRepo.get(Self.projectionWatermarkKey)
            guard let raw, let stored = Int64(raw) else {
                try persistProjectionWatermark(capturedCursor)
                return nil
            }

            if stored > capturedCursor {
                projectionWatermark = stored
                let durableLastSequence = try context.eventLog.lastSeq()
                guard durableLastSequence <= capturedCursor else {
                    return L("Ready-item recovery is waiting for the event log.")
                }
                try persistProjectionWatermark(capturedCursor)
                return nil
            }
            projectionWatermark = stored
            var scanCursor = stored
            let decoder = Self.recoveryDecoder
            let timestampFormatter = Self.recoveryTimestampFormatter
            while scanCursor < capturedCursor {
                let rows = try context.eventLog.read(since: scanCursor, limit: 500)
                    .filter { $0.seq <= capturedCursor }
                guard !rows.isEmpty else { break }

                for row in rows {
                    if Self.isPotentialProjectionKind(row.kind) {
                        do {
                            guard let data = row.payloadJSON.data(using: .utf8) else {
                                throw CocoaError(.fileReadCorruptFile)
                            }
                            let payload = try decoder.decode(JSONValue.self, from: data)
                            let event = EventBus.Event(
                                seq: row.seq,
                                kind: row.kind,
                                payload: payload,
                                ts: timestampFormatter.date(from: row.createdAt)?.timeIntervalSince1970
                                    ?? Date().timeIntervalSince1970
                            )
                            if Self.isProjectionCandidate(event) {
                                _ = try notificationRecorder.record(event: event, replaying: true)
                            }
                        } catch {
                            NSLog("Remote Code pet attention recovery failed at seq %lld: %@", row.seq, String(describing: error))
                            return L("A ready item could not be restored.")
                        }
                    }
                    scanCursor = row.seq
                }
                try persistProjectionWatermark(scanCursor)
                if rows.count < 500 { break }
            }
            // All persisted candidates through this launch cursor were projected.
            // Sequence gaps are non-persisted stream noise (`surface.output`,
            // `agent.item.delta`, `agent.item.progress`) by contract.
            try persistProjectionWatermark(capturedCursor)
            return nil
        } catch {
            NSLog("Remote Code pet projection watermark failed: %@", String(describing: error))
            return L("Ready-item recovery could not be initialized.")
        }
    }

    // PERF: ISO8601DateFormatter is expensive; recovery can parse hundreds of rows.
    // PetController is @MainActor, so one MainActor-isolated formatter avoids per-recovery alloc.
    private static let recoveryTimestampFormatter = ISO8601DateFormatter()
    private static let recoveryDecoder = JSONDecoder()

    // PERF: event-log recovery and live EventBus handling classify every
    // published kind. Array literals reallocated membership tables per event;
    // share process-wide Sets (membership contract unchanged).
    /// Internal: the Titio notice hub subscribes to the same kinds.
    static let potentialProjectionKinds: Set<String> = [
        "git.push", "git.deliver", "project.script.finished",
        "ssh.transfer.completed", "ssh.transfer.failed", "ssh.session.updated",
        "agent.provider.updated", "files.edit.conflict", "files.edit.saved",
        "files.edit.discarded", "files.edit.closed",
    ]
    private static let fileEditResolvedKinds: Set<String> = [
        "files.edit.saved", "files.edit.discarded", "files.edit.closed",
    ]
    private static let attentionProjectionKinds: Set<String> = [
        "notification.created", "notification.read", "notification.dismissed",
        "agent.thread.read", "agent.thread.updated", "agent.thread.renamed",
        "agent.thread.deleted",
        "agent.thread.deleted_many",
        "bots.attention.changed",
    ]
    private static let liveActivityProgressKinds: Set<String> = [
        "agent.item.started", "agent.item.delta", "agent.item.completed",
        "agent.turn.completed",
        "agent.run.started", "agent.run.finished", "agent.run.completed",
        "agent.run.failed", "agent.run.cancelled",
    ]
    /// Always dropped before MainActor, even if later listed in acceptedKinds.
    /// `agent.item.delta` stays here so Live Activity still does not observe
    /// the high-rate delta stream (existing prefilter contract).
    private static let alwaysPrefilteredNoiseKinds: Set<String> = [
        "agent.provider_runtime.event",
        "token_saver.digest",
        "agent.item.delta",
    ]

    private static func isPotentialProjectionKind(_ kind: String) -> Bool {
        potentialProjectionKinds.contains(kind)
    }

    private static func isProjectionCandidate(_ event: EventBus.Event) -> Bool {
        if PetTerminalNotificationRecorder.classify(event) != nil { return true }
        if event.kind == "ssh.session.updated",
           case .object(let payload) = event.payload,
           (payload["status"]?.stringValue == "connected"
                || payload["reason"]?.stringValue == "user_requested"),
           payload["surface_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil {
            return true
        }
        guard Self.fileEditResolvedKinds.contains(event.kind),
              case .object(let payload) = event.payload,
              payload["session_id"]?.stringValue?.isEmpty == false else { return false }
        return true
    }

    private func advanceProjectionWatermark(to sequence: Int64) {
        guard !projectionRecoveryBlocked else { return }
        guard sequence > (projectionWatermark ?? -1) else { return }
        do {
            try persistProjectionWatermark(sequence)
            projectionErrorMessage = nil
        } catch {
            projectionRecoveryBlocked = true
            projectionErrorMessage = L("Ready-item recovery could not be updated.")
            model.routeError = projectionErrorMessage
            NSLog("Remote Code pet projection watermark write failed at seq %lld: %@", sequence, String(describing: error))
        }
    }

    private func persistProjectionWatermark(_ sequence: Int64) throws {
        try context.settingsRepo.set(Self.projectionWatermarkKey, String(sequence))
        projectionWatermark = sequence
    }

    private func ensureVisualRuntime() throws {
        guard animationController == nil, windowController == nil else { return }
        let animationController = try PetAnimationController(atlas: .bundled())
        let windowController = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: context.settingsRepo)
        )
        self.animationController = animationController
        self.windowController = windowController
        wireCallbacks(animationController: animationController, windowController: windowController)
        if let frame = animationController.currentFrame {
            model.setFrame(frame)
        }
    }

    private func wireCallbacks(
        animationController: PetAnimationController,
        windowController: PetWindowController
    ) {
        animationController.onFrame = { [weak model, weak windowController] frame in
            model?.setFrame(frame)
            windowController?.animationFrameDidChange()
        }
        animationController.onError = { [weak model] _ in
            model?.routeError = L("Pet artwork could not be loaded.")
        }
        windowController.onOpenItem = { [weak self] item in self?.open(item) }
        windowController.onOpenActiveThread = { [weak self] item in self?.openActive(item) }
        windowController.onOpenRemoteCode = { [weak self] in self?.showActivity() }
        windowController.onOpenTitio = { [weak self] in self?.openTitio() }
        windowController.onSendToTitio = { [weak self] in self?.sendToTitio($0) }
        windowController.onOpenSettings = { [weak self] in
            _ = self?.openSettings(.general)
        }
        windowController.onHidePet = { [weak self] in self?.setPetEnabled(false) }
        windowController.onToggleAnimations = { [weak self] in self?.toggleAnimations() }
        windowController.onAdoptFreePosition = { [weak self] in self?.adoptFreePosition() }
        windowController.onInteraction = { [weak self] in self?.handleInteraction() }
        windowController.onDragStateChanged = { [weak self] isDragging in
            self?.handlePetDragStateChanged(isDragging)
        }
        windowController.onPopoverWillOpen = { [weak self] in
            self?.speechController.clear(animated: false)
        }
        windowController.onCareAction = { [weak self] action in
            guard let self else { return }
            self.playCompanionCue(PetCompanionDirector.careCue(
                action: action,
                returnState: self.reducer.state,
                durationMilliseconds: self.randomExtendedReactionDuration()
            ), allowsStaticReaction: true)
        }
    }

    @discardableResult
    public func togglePopoverFromKeyboard() -> Bool {
        guard model.settings.petEnabled, let windowController else { return false }
        windowController.show()
        handleInteraction()
        windowController.togglePopover()
        return true
    }

    private func configureSystemMonitor() {
        systemMonitor.onScreenLockChanged = { [weak self] locked in
            self?.handleSystemScreenLockChanged(locked)
        }
        systemMonitor.onWake = { [weak self] in
            self?.handleSystemWake()
        }
        systemMonitor.onScreenParametersChanged = { [weak self] in
            self?.windowController?.screensDidChange()
        }
        systemMonitor.onDockContentsMayHaveChanged = { [weak self] in
            self?.windowController?.screensDidChange()
        }
        systemMonitor.onAccessibilityDisplayOptionsChanged = { [weak self] in
            self?.applySettings(self?.settingsStore.load() ?? AppSettings())
        }
    }

    func handleSystemScreenLockChanged(_ locked: Bool) {
        if locked { windowController?.cancelActiveDrag() }
        isScreenLocked = locked
        animationController?.setScreenLocked(locked)
        apply(reducer.reduce(
            .screenLockChanged(isLocked: locked),
            atMilliseconds: monotonicMilliseconds()
        ))
        if !locked { scheduleIdleTimeout() }
    }

    func handleSystemWake() {
        apply(reducer.reduce(.wake, atMilliseconds: monotonicMilliseconds()))
        scheduleIdleTimeout()
    }

    private func observeSettings() {
        let settingsToken = NotificationCenter.default.addObserver(
            forName: .petSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applySettings(self.settingsStore.reload())
                self.refreshAttentionNow()
            }
        }
        let resetToken = NotificationCenter.default.addObserver(
            forName: .petResetPositionRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windowController?.resetPosition() }
        }
        notificationTokens = [settingsToken, resetToken]
    }

    private func handle(_ event: EventBus.Event) {
        handledEventCountForTests += 1
        if let lastHandledEventSequence, event.seq <= lastHandledEventSequence {
            handledEventOutOfOrderForTests = true
        }
        lastHandledEventSequence = event.seq
        if event.kind == "agent.thread.updated" || event.kind == "agent.thread.renamed" {
            invalidateCachedActiveThreadChrome(from: event)
        }
        let attentionProjectionChanged = Self.attentionProjectionKinds.contains(event.kind)
        let focusedSurfaceByWorkspace = context.state.workspaces.reduce(
            into: [WorkspaceID: SurfaceID]()
        ) { result, entry in
            let workspace = entry.value
            guard let paneID = workspace.focusedPaneID,
                  let surfaceID = workspace.layout.find(paneID: paneID)?.selectedSurfaceID else { return }
            result[entry.key] = surfaceID
        }
        let detachedWorkspaceIDs = Set(context.state.workspaces.keys.filter {
            router.windowController?.workspaceWindow(for: $0) != nil
        })
        let focusDestination = PetAttentionFocusPolicy.resolveDestination(
            event: event,
            mainSelectedWorkspaceID: context.state.window.selectedWorkspaceID,
            focusedSurfaceByWorkspace: focusedSurfaceByWorkspace,
            detachedWorkspaceIDs: detachedWorkspaceIDs
        )
        let destinationWindow = focusDestination.detachedWorkspaceID
            .flatMap { router.windowController?.workspaceWindow(for: $0) }
            ?? router.windowController?.window
        let shouldPersist = PetAttentionFocusPolicy.shouldPersist(
            event: event,
            isAppActive: NSApplication.shared.isActive,
            isDestinationWindowFocused: destinationWindow?.isVisible == true
                && destinationWindow?.isMiniaturized == false
                && destinationWindow?.isKeyWindow == true,
            selectedWorkspaceID: focusDestination.selectedWorkspaceID,
            focusedSurfaceID: focusDestination.focusedSurfaceID
        )
        let projectionCandidate = Self.isProjectionCandidate(event)
        var projectionChanged = false
        var projectionFailed = false
        if projectionCandidate {
            if shouldPersist {
                do {
                    _ = try notificationRecorder.record(event: event)
                    projectionChanged = true
                    advanceProjectionWatermark(to: event.seq)
                } catch {
                    projectionFailed = true
                    projectionRecoveryBlocked = true
                    projectionErrorMessage = L("A ready item could not be saved.")
                    NSLog("Remote Code pet attention projection failed at seq %lld: %@", event.seq, String(describing: error))
                }
            } else {
                advanceProjectionWatermark(to: event.seq)
            }
        }
        // Material agent progress → Live Activity single-active description.
        // Deltas/progress are prefiltered noise and never reach here.
        let liveActivityProgressChanged = noteLiveActivityProgress(from: event)
        guard let domainEvent = PetEventDecoder.decode(event) else {
            if projectionFailed { model.routeError = projectionErrorMessage }
            if projectionChanged || attentionProjectionChanged { scheduleAttentionRefresh() }
            if liveActivityProgressChanged { republishActiveThreadsForLiveActivity() }
            return
        }
        let reduction = reducer.reduce(domainEvent, atMilliseconds: monotonicMilliseconds())
        if case .ignored = reduction.disposition {
            // Noise, duplicate compatibility events, and explicit user disconnects
            // do not count as activity for the idle-sleep policy.
        } else {
            scheduleIdleTimeout()
        }
        apply(reduction)
        // Invariant: work/plan (laptop, hard-hat, thinking, coding…) only while the
        // Active list (model.activeThreads) is non-empty. EventBus can insert ghost run ids when
        // finish is missed; host coordinator Active is the sole authority.
        if Self.shouldResyncActiveRuns(after: domainEvent) {
            // A lifecycle event can arrive before the coordinator publishes its
            // matching projection. An empty snapshot at that instant is not
            // authoritative and must not erase the event's active work pose or
            // a projected row that is still being republished for Live Activity.
            refreshActiveThreadsFromCoordinator()
        }
        if case .ignored = reduction.disposition {
            // Duplicate terminal compatibility events do not increment celebrations.
        } else if case .agentRunFinished(_, .completed) = domainEvent,
                  let cue = companionDirector.successCue(returnState: reducer.companionBaseState) {
            playCompanionCue(cue)
        }
        if projectionFailed { model.routeError = projectionErrorMessage }
        if projectionChanged || reduction.shouldRefreshAttention {
            scheduleAttentionRefresh()
        } else if liveActivityProgressChanged {
            republishActiveThreadsForLiveActivity()
        }
    }

    /// Capture latest human-readable progress for the Live Activity description.
    /// Returns true when the cache changed so the surface can be republished.
    @discardableResult
    private func noteLiveActivityProgress(from event: EventBus.Event) -> Bool {
        guard case .object(let payload) = event.payload,
              let threadUUID = payload["thread_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        else { return false }
        let threadID = AgentThreadID(threadUUID)
        let preview: String?
        switch event.kind {
        case "agent.item.started":
            preview = Self.itemStartedPreview(payload: payload)
        case "agent.item.delta":
            // Live assistant/tool body growth — keep single-active LA description
            // fresh without waiting for item.completed.
            preview = Self.itemDeltaPreview(payload: payload)
        case "agent.item.completed":
            preview = Self.itemCompletedPreview(payload: payload)
        case "agent.turn.completed":
            preview = Self.turnCompletedPreview(payload: payload)
        case "agent.run.started":
            preview = L("Working…")
        case "agent.run.finished", "agent.run.completed", "agent.run.failed", "agent.run.cancelled":
            lastUpdatePreviewByThread.removeValue(forKey: threadID)
            return true
        default:
            return false
        }
        guard let preview,
              let redacted = PetAttentionRedactor.safeContextLabel(preview),
              !redacted.isEmpty else {
            return false
        }
        if lastUpdatePreviewByThread[threadID] == redacted { return false }
        lastUpdatePreviewByThread[threadID] = redacted
        return true
    }

    private func republishActiveThreadsForLiveActivity() {
        // Rebuild active rows so lastUpdatePreview is embedded, then push LA.
        // Prefer currently projected active thread IDs (with cached startedAt)
        // so material item/turn updates never drop elapsed or empty the list
        // when coordinator snapshot lags the projection callback.
        let projectedIDs = model.activeThreads.map(\.threadID)
        if projectedIDs.isEmpty {
            progressRepublishUsedCachedChromeForTesting = false
            refreshActiveThreadsFromCoordinator()
            return
        }
        if let reused = reuseProjectedActiveThreadsForProgress(threadIDs: projectedIDs) {
            progressRepublishUsedCachedChromeForTesting = true
            model.apply(activeThreads: reused)
            publishLiveActivitySurface()
            return
        }
        progressRepublishUsedCachedChromeForTesting = false
        applyActiveThreadIDs(projectedIDs, startedByThread: startedAtByThread)
    }

    /// Live Activity progress does not change workspace/provider/title/route.
    /// Reuse the last durable projection's chrome so item.started does not
    /// hitch behind FULLMUTEX SQLite on MainActor.
    private func reuseProjectedActiveThreadsForProgress(
        threadIDs: [AgentThreadID]
    ) -> [PetActiveThreadItem]? {
        let unique = Array(Set(threadIDs)).sorted {
            $0.value.uuidString < $1.value.uuidString
        }
        var items: [PetActiveThreadItem] = []
        items.reserveCapacity(unique.count)
        for threadID in unique {
            guard let chrome = activeThreadChromeByID[threadID] else { return nil }
            items.append(
                PetActiveThreadItem(
                    threadID: threadID,
                    workspaceID: chrome.workspaceID,
                    workspaceName: chrome.workspaceName,
                    providerName: chrome.providerName,
                    threadTitle: chrome.threadTitle,
                    startedAt: startedAtByThread[threadID],
                    lastUpdatePreview: lastUpdatePreviewByThread[threadID],
                    route: chrome.route
                )
            )
        }
        return items
    }

    /// Merge host-provided startedAt values with the retained cache for threads
    /// that remain active. Pure so unit tests can prove progress republish does
    /// not erase elapsed anchors.
    nonisolated static func mergingStartedAtByThread(
        activeThreadIDs: [AgentThreadID],
        incoming: [AgentThreadID: Date],
        retained: [AgentThreadID: Date]
    ) -> [AgentThreadID: Date] {
        let activeSet = Set(activeThreadIDs)
        var next = retained.filter { activeSet.contains($0.key) }
        for (id, date) in incoming where activeSet.contains(id) {
            next[id] = date
        }
        return next
    }

    /// Agent App-style Live Activity line from an item.started payload.
    /// Thinking / assistant text / tool runs — never provider-runtime method ids.
    nonisolated static func itemStartedPreview(payload: [String: JSONValue]) -> String? {
        guard let item = payload["item"]?.objectValue else { return nil }
        let type = item["type"]?.stringValue ?? "tool"
        if type == "reasoning" {
            if let body = friendlyPreview(nonempty(item["body"])) { return body }
            return L("Thinking…")
        }
        if type == "assistantMessage" {
            if let body = friendlyPreview(nonempty(item["body"])) { return body }
            return L("Writing…")
        }
        if type == "plan" {
            return friendlyPreview(nonempty(item["summary"]) ?? nonempty(item["body"]))
        }
        // Prefer human summary; reject dotted runtime method names.
        if let summary = nonempty(item["summary"]) {
            if isProviderRuntimeNoise(summary) {
                // No user-facing summary — do not invent a generic "Running: tool"
                // line for provider telemetry methods.
                return nil
            }
            if let friendly = friendlyPreview(summary) {
                return L("Running: %1$@", friendly)
            }
        }
        let label = activityLabel(type: type, summary: nil, body: nonempty(item["body"]))
        guard let friendly = friendlyPreview(label), !isProviderRuntimeNoise(friendly) else {
            return nil
        }
        // Skip bare type fallbacks when body/summary had no human content.
        if friendly == type || friendly == "tool" || friendly == "command" {
            if nonempty(item["body"]) == nil { return nil }
        }
        return L("Running: %1$@", friendly)
    }

    nonisolated static func itemCompletedPreview(payload: [String: JSONValue]) -> String? {
        if let summary = friendlyPreview(nonempty(payload["summary"])) {
            return L("Ran: %1$@", summary)
        }
        // completed often carries only item_id; keep prior cache if no text.
        if let state = payload["state"]?.stringValue, state == "failed" {
            return L("Failed: tool")
        }
        return nil
    }

    /// Mid-stream body growth for the LA description (single-active, no red badge).
    /// Prefer assistant prose; ignore empty / pure runtime noise.
    nonisolated static func itemDeltaPreview(payload: [String: JSONValue]) -> String? {
        // Common shapes: { item: { type, body } } or top-level body_append.
        let item = payload["item"]?.objectValue
        let type = item?["type"]?.stringValue
            ?? payload["type"]?.stringValue
            ?? ""
        let body = nonempty(item?["body"])
            ?? nonempty(payload["body_append"])
            ?? nonempty(payload["bodyAppend"])
            ?? nonempty(payload["body"])
        guard let body, let friendly = friendlyPreview(body) else { return nil }
        if type == "assistantMessage" || type.isEmpty {
            return friendly
        }
        if type == "reasoning" {
            return friendly
        }
        // Tools: only surface when body looks human (not dotted method ids).
        if isProviderRuntimeNoise(friendly) { return nil }
        return L("Running: %1$@", friendly)
    }

    nonisolated static func turnCompletedPreview(payload: [String: JSONValue]) -> String? {
        if let final = friendlyPreview(nonempty(payload["final"])) { return final }
        if let final = friendlyPreview(nonempty(payload["final_message"])) { return final }
        return nil
    }

    /// Drop provider-runtime telemetry ("claude runtime: …", dotted method ids).
    // PERF: dotted-id scan used CharacterSet.alphanumerics.union(…) inside
    // allSatisfy — allocating a new set for every scalar. Share one set for
    // live-activity stream previews.
    private static let providerRuntimeTokenScalars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._-"))

    nonisolated static func isProviderRuntimeNoise(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()
        if lower.contains(" runtime: ") { return true }
        if lower.hasPrefix("runtime:") { return true }
        if trimmed.contains("."), !trimmed.contains(" "),
           trimmed.unicodeScalars.allSatisfy({ providerRuntimeTokenScalars.contains($0) }) {
            return true
        }
        return false
    }

    nonisolated private static func friendlyPreview(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProviderRuntimeNoise(trimmed) else { return nil }
        return String(trimmed.prefix(140))
    }

    nonisolated private static func activityLabel(type: String, summary: String?, body: String?) -> String {
        if let summary, !summary.isEmpty { return summary }
        if let body {
            let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        switch type {
        case "commandExecution": return "command"
        case "fileChange": return L("file edit")
        case "webSearch": return L("search")
        case "mcpToolCall", "dynamicToolCall", "collabToolCall", "tool": return "tool"
        default: return type
        }
    }

    nonisolated private static func nonempty(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    private func apply(_ reduction: PetEventReduction) {
        applyTransientTimerDirective(reduction.transientTimerDirective)
        var nextState = reduction.state
        // Hard rule: no work/plan pose without an Active list row. Projection
        // and EventBus can diverge; the visible Active list is authoritative.
        if model.activeThreads.isEmpty,
           reducer.activeRunCount > 0 || PetEventReducer.isWorkPose(nextState) {
            let cleared = reducer.reconcileActiveRunIDs(
                [],
                atMilliseconds: monotonicMilliseconds()
            )
            applyTransientTimerDirective(cleared.transientTimerDirective)
            nextState = cleared.state
        }
        if nextState != model.animationState {
            model.setAnimationState(nextState)
            let derived: PetAnimationState = model.count > 0 ? .waiting : .idle
            do {
                try animationController?.setState(nextState, derivedTerminalState: derived)
                model.routeError = projectionErrorMessage
            } catch {
                model.routeError = L("Pet animation is unavailable.")
            }
        }
        scheduleCompanionBehavior()
    }

    /// Agent lifecycle / item / companion events can arm work poses — re-check host.
    nonisolated static func shouldResyncActiveRuns(after event: PetDomainEvent) -> Bool {
        switch event {
        case .agentRunStarted, .agentRunFinished, .agentRunError,
             .agentTurnStarted, .agentItemStarted, .agentItemCompleted,
             .contextCompaction, .companionCue, .transientExpired:
            return true
        default:
            return false
        }
    }

    private func applyTransientTimerDirective(_ directive: PetTransientTimerDirective?) {
        guard let directive else { return }
        transientTask?.cancel()
        transientTask = nil
        lastScheduledTransientMillisecondsForTests = nil
        guard case .schedule(let milliseconds) = directive else { return }
        lastScheduledTransientMillisecondsForTests = milliseconds
        let nanoseconds = UInt64(max(0, milliseconds)) * 1_000_000
        transientTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.apply(self.reducer.reduce(
                    .transientExpired,
                    atMilliseconds: self.monotonicMilliseconds()
                ))
            }
        }
    }

    private func scheduleAttentionRefresh() {
        attentionRefreshTask?.cancel()
        attentionRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.refreshAttentionNow() }
        }
    }

    private func refreshAttentionNow() {
        PetActivityCountsProjection.shared.refresh(
            router: router,
            workspaceIDs: context.state.workspaces.keys.map { $0 }
        )
        do {
            let previousCount = model.count
            let snapshot = try attentionStore.refresh(filter: attentionFilter(model.settings.petAttentionFilter))
            model.apply(snapshot: snapshot)
            model.routeError = projectionErrorMessage
            let reduction = reducer.reduce(
                .attentionHydrated(attentionHydration(from: snapshot)),
                atMilliseconds: monotonicMilliseconds()
            )
            apply(reduction)
            if let cue = companionDirector.notificationCue(
                previousCount: previousCount,
                newCount: snapshot.count,
                baseState: reduction.state
            ) {
                playCompanionCue(cue)
            }
            if snapshot.count == 0 { scheduleIdleTimeout() }
            publishLiveActivitySurface()
        } catch {
            model.routeError = L("Ready items could not be loaded.")
        }
    }

    nonisolated static func decodeActivityPage(_ value: JSONValue) throws -> AgentActivityPage {
        try AgentActivityPage.makeJSONDecoder().decode(AgentActivityPage.self, from: JSONEncoder().encode(value))
    }

    /// Push authoritative Activity copy. Offline reads must not retire an existing surface.
    private func publishLiveActivitySurface() {
        activitySurfaceGeneration &+= 1
        let owner = activitySurfaceGeneration
        activitySurfaceTask?.cancel()
        activitySurfaceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.activitySurfaceGeneration == owner { self.activitySurfaceTask = nil } }
            do {
                let value = try await self.router.activityListOffMain(params: [
                    "section": .string("all"), "limit": .number(50)
                ])
                guard !Task.isCancelled, self.activitySurfaceGeneration == owner else { return }
                let page = try Self.decodeActivityPage(value)
                self.context.liveActivitySyncCoordinator.submitSurface(PetLiveActivityCopy.makeActivity(page: page))
            } catch {
                guard !Task.isCancelled, self.activitySurfaceGeneration == owner else { return }
                NSLog("Pet Live Activity projection unavailable; preserving current surface.")
            }
        }
    }

    private func attentionHydration(from snapshot: PetAttentionSnapshot) -> PetAttentionHydration {
        var approvalIDs: Set<String> = []
        var questionIDs: Set<String> = []
        var fileConflictIDs: Set<String> = []
        var isReconnecting = false

        for item in snapshot.items {
            switch item.kind {
            case .callback(let kind, _):
                let reducerID: String
                if case .callback(let threadID, let requestID, _) = item.source {
                    reducerID = "\(threadID.value.uuidString):\(requestID)"
                } else {
                    reducerID = item.id
                }
                if kind == .approval {
                    approvalIDs.insert(reducerID)
                } else {
                    questionIDs.insert(reducerID)
                }
            case .notification(let category):
                if category == .fileConflict {
                    let persistedID: String
                    if case .notification(let id) = item.source {
                        persistedID = id
                    } else {
                        persistedID = item.id
                    }
                    let prefix = "pet.file-conflict."
                    fileConflictIDs.insert(
                        persistedID.hasPrefix(prefix)
                            ? String(persistedID.dropFirst(prefix.count))
                            : persistedID
                    )
                }
                if category == .serverListenerFailed || category == .sshUnexpectedDisconnect {
                    isReconnecting = true
                }
            case .agentOutcome:
                break
            }
        }

        return PetAttentionHydration(
            approvalIDs: approvalIDs,
            questionIDs: questionIDs,
            fileConflictIDs: fileConflictIDs,
            count: snapshot.count,
            isReconnecting: isReconnecting
        )
    }

    private func open(_ item: PetAttentionItem) {
        do {
            let result = try attentionStore.openAndMarkRead(itemID: item.id) { [weak self] currentItem in
                guard let self else { return false }
                let conversationID: BotConversationID?
                if case .bot(_, let id, _) = currentItem.source { conversationID = id }
                else { conversationID = nil }
                return try self.verifyAndOpen(currentItem.route, conversationID: conversationID)
            }
            switch result {
            case .marked, .retainedBlocker:
                model.routeError = nil
                windowController?.closePopover(restoringPreviousKeyWindow: false)
                refreshAttentionNow()
            case .routeRejected:
                model.routeError = L("The exact destination could not be opened. The item was kept.")
            case .notFound:
                model.routeError = L("Item no longer exists.")
            }
        } catch {
            model.routeError = L("The exact destination could not be opened. The item was kept.")
        }
    }

    private func openActive(_ item: PetActiveThreadItem) {
        do {
            let route: PetAttentionRoute
            if case .botsDesk = item.route,
               try AppCommandRouter.contextPinnedThreadDestination(item.threadID, context: context) != nil {
                route = .agentThread(threadID: item.threadID, workspaceID: nil)
            } else {
                route = item.route
            }
            let opened = try verifyAndOpen(route)
            if opened {
                model.routeError = nil
                windowController?.closePopover(restoringPreviousKeyWindow: false)
            } else {
                model.routeError = L("The exact destination could not be opened. The item was kept.")
            }
        } catch {
            model.routeError = L("The exact destination could not be opened. The item was kept.")
        }
    }

    private func installActiveRunProjectionObserver() {
        guard !installedActiveRunProjectionHandler else { return }
        previousActiveRunProjectionHandler = context.coordinator.onActiveRunProjectionChanged
        context.coordinator.onActiveRunProjectionChanged = { [weak self] projection, cause in
            self?.previousActiveRunProjectionHandler?(projection, cause)
            DispatchQueue.main.async {
                self?.applyActiveRunProjection(projection)
            }
        }
        installedActiveRunProjectionHandler = true
    }

    private func uninstallActiveRunProjectionObserver() {
        guard installedActiveRunProjectionHandler else { return }
        context.coordinator.onActiveRunProjectionChanged = previousActiveRunProjectionHandler
        previousActiveRunProjectionHandler = nil
        installedActiveRunProjectionHandler = false
    }

    private func refreshActiveThreadsFromCoordinator() {
        // Primary threads only — delegated bot-peer runs show under Subagents.
        let threadIDs = Array(context.coordinator.primaryActiveThreadIdsSnapshot())
        if !threadIDs.isEmpty {
            let missing = threadIDs.filter { activeThreadChromeByID[$0] == nil }
            if missing.isEmpty {
                applyActiveThreadIDs(threadIDs)
            } else {
                fetchActiveThreadChromeOffMain(threadIDs: threadIDs, missing: missing)
            }
        }
        // Reconcile animation active-run set to coordinator truth when it has
        // positive evidence. An empty snapshot during event delivery can be a
        // projection race; explicit ActiveRunProjection callbacks remain the
        // authoritative path for clearing work.
        let hostRunIDs = Set(threadIDs.compactMap {
            context.coordinator.activeRunId(threadId: $0)?.value.uuidString
        })
        if !threadIDs.isEmpty {
            reconcilePetActiveRuns(hostRunIDs)
        }
    }

    private func fetchActiveThreadChromeOffMain(
        threadIDs: [AgentThreadID],
        missing: [AgentThreadID]
    ) {
        activeThreadChromeGeneration += 1
        let generation = activeThreadChromeGeneration
        activeThreadChromeFetchTask?.cancel()
        let threadRepo = context.threadRepo
        activeThreadChromeFetchTask = Task.detached { [weak self] in
            let chromeByID = (try? threadRepo.listChrome(ids: missing)) ?? [:]
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard generation == self.activeThreadChromeGeneration else { return }
                self.mergeActiveThreadChrome(chromeByID, missingIDs: missing)
                self.applyActiveThreadIDs(threadIDs)
            }
        }
    }

    private func applyActiveRunProjection(_ projection: ActiveRunProjection) {
        let runsMissingStamp = projection.runs.filter { startedAtByThread[$0.threadId] == nil }
        let stamps: [AgentRunID: Date]
        if runsMissingStamp.isEmpty {
            stamps = [:]
        } else {
            stamps = (try? context.runRepo.startedAt(ids: runsMissingStamp.map(\.runId))) ?? [:]
        }
        var startedByThread: [AgentThreadID: Date] = [:]
        for run in projection.runs {
            if let retained = startedAtByThread[run.threadId] {
                startedByThread[run.threadId] = retained
                continue
            }
            guard let startedAt = stamps[run.runId] else { continue }
            if let existing = startedByThread[run.threadId] {
                startedByThread[run.threadId] = min(existing, startedAt)
            } else {
                startedByThread[run.threadId] = startedAt
            }
        }
        applyActiveThreadIDs(projection.runs.map(\.threadId), startedByThread: startedByThread)
        // Host ActiveRunProjection is authoritative for pet work pose. Empty
        // projection clears EventBus ghost run ids that never received finished.
        let hostRunIDs = Set(projection.runs.map { $0.runId.value.uuidString })
        reconcilePetActiveRuns(hostRunIDs)
    }

    /// Push host-authoritative active run ids into the pet reducer and refresh
    /// animation. Shared by projection callbacks and coordinator snapshot refresh.
    private func reconcilePetActiveRuns(_ hostRunIDs: Set<String>) {
        let reduction = reducer.reconcileActiveRunIDs(
            hostRunIDs,
            atMilliseconds: monotonicMilliseconds()
        )
        if case .ignored = reduction.disposition {
            // reconcile never ignores
        } else {
            scheduleIdleTimeout()
        }
        apply(reduction)
    }

    private func applyActiveThreadIDs(
        _ threadIDs: [AgentThreadID],
        startedByThread: [AgentThreadID: Date] = [:]
    ) {
        activeThreadChromeGeneration += 1
        activeThreadChromeFetchTask?.cancel()
        activeThreadChromeFetchTask = nil
        // Drop progress cache for threads that are no longer active.
        let activeSet = Set(threadIDs)
        lastUpdatePreviewByThread = lastUpdatePreviewByThread.filter { activeSet.contains($0.key) }
        // Preserve startedAt across progress-only republishes (empty incoming
        // map must not clear elapsed embedded in pet detail / LA statusLine).
        startedAtByThread = Self.mergingStartedAtByThread(
            activeThreadIDs: threadIDs,
            incoming: startedByThread,
            retained: startedAtByThread
        )
        activeThreadChromeByID = activeThreadChromeByID.filter { activeSet.contains($0.key) }
        cacheMissingActiveThreadChrome(ids: threadIDs)

        let items = PetActiveThreadProjector.items(threadIDs: threadIDs) { [weak self] threadID in
            guard let self, let chrome = self.activeThreadChromeByID[threadID] else {
                return nil
            }
            return (
                workspaceID: chrome.workspaceID,
                workspaceName: chrome.workspaceName,
                providerName: chrome.providerName,
                threadTitle: chrome.threadTitle,
                startedAt: self.startedAtByThread[threadID],
                lastUpdatePreview: self.lastUpdatePreviewByThread[threadID]
            )
        }
        let linkedBots = resolveLinkedBots(for: threadIDs)
        let remapped = items.map { item -> PetActiveThreadItem in
            guard let link = linkedBots[item.threadID] else {
                return item
            }
            let chrome = CachedActiveThreadChrome(
                workspaceID: nil,
                workspaceName: L("Bots"),
                providerName: nil,
                threadTitle: link.name,
                route: .botsDesk(botID: link.botID)
            )
            self.activeThreadChromeByID[item.threadID] = chrome
            return PetActiveThreadItem(
                threadID: item.threadID,
                workspaceID: nil,
                workspaceName: L("Bots"),
                threadTitle: link.name,
                startedAt: startedAtByThread[item.threadID],
                lastUpdatePreview: item.lastUpdatePreview,
                route: chrome.route
            )
        }
        model.apply(activeThreads: remapped)
        // User-visible Active is empty → pet must leave work/plan even if EventBus
        // still holds a ghost run id (missed finished / stale projection lag).
        if threadIDs.isEmpty, reducer.activeRunCount > 0 || PetEventReducer.isWorkPose(model.animationState) {
            reconcilePetActiveRuns([])
        }
        publishLiveActivitySurface()
    }

    /// Cache-only resolution of active thread → bot. Unknown threads are
    /// resolved off-main once; the result re-applies the active list.
    private func resolveLinkedBots(
        for threadIDs: [AgentThreadID]
    ) -> [AgentThreadID: (botID: BotID, name: String?)] {
        let activeSet = Set(threadIDs)
        linkedBotByActiveThread = linkedBotByActiveThread.filter { activeSet.contains($0.key) }
        var resolved: [AgentThreadID: (botID: BotID, name: String?)] = [:]
        var unresolved: [AgentThreadID] = []
        for threadID in threadIDs {
            switch linkedBotByActiveThread[threadID] {
            case .linked(let botID, let name)?:
                resolved[threadID] = (botID, name)
            case .unlinked?:
                continue
            case nil:
                // Lock-free BotStore cache: paints the Bots route immediately;
                // the name still comes from the off-main lookup.
                if let botID = context.botStore.cachedBotID(linkedTo: threadID) {
                    resolved[threadID] = (botID, nil)
                }
                unresolved.append(threadID)
            }
        }
        if !unresolved.isEmpty {
            fetchLinkedBotsOffMain(threadIDs: threadIDs, unresolved: unresolved)
        }
        return resolved
    }

    private func fetchLinkedBotsOffMain(threadIDs: [AgentThreadID], unresolved: [AgentThreadID]) {
        guard linkedBotResolveTask == nil else { return }
        linkedBotResolveGeneration += 1
        let generation = linkedBotResolveGeneration
        let botStore = context.botStore
        linkedBotResolveTask = Task.detached(priority: .utility) { [weak self] in
            let linked = (try? botStore.conversationsLinked(to: Set(unresolved))) ?? [:]
            let botIDs = Set(linked.values.map(\.botID))
            let names: [BotID: String] = botIDs.isEmpty
                ? [:]
                : ((try? botStore.bots(ids: botIDs)) ?? [:]).mapValues(\.name)
            await MainActor.run {
                guard let self else { return }
                self.linkedBotResolveTask = nil
                guard generation == self.linkedBotResolveGeneration else { return }
                self.linkedBotDurableLookupCountForTesting += 1
                for threadID in unresolved {
                    if let conversation = linked[threadID] {
                        self.linkedBotByActiveThread[threadID] = .linked(
                            botID: conversation.botID,
                            name: names[conversation.botID]
                        )
                    } else {
                        self.linkedBotByActiveThread[threadID] = .unlinked
                    }
                }
                guard !linked.isEmpty else { return }
                let current = Set(self.model.activeThreads.map(\.threadID))
                guard current == Set(threadIDs) else { return }
                self.applyActiveThreadIDs(threadIDs)
            }
        }
    }

    private func cacheMissingActiveThreadChrome(ids: [AgentThreadID]) {
        let missing = ids.filter { activeThreadChromeByID[$0] == nil }
        guard !missing.isEmpty else { return }
        let chromeByID = (try? context.threadRepo.listChrome(ids: missing)) ?? [:]
        mergeActiveThreadChrome(chromeByID, missingIDs: missing)
    }

    private func mergeActiveThreadChrome(
        _ chromeByID: [AgentThreadID: AgentThreadRepository.ListChrome],
        missingIDs: [AgentThreadID]
    ) {
        activeThreadDurableLookupCountForTesting += chromeByID.count
        for threadID in missingIDs {
            guard activeThreadChromeByID[threadID] == nil else { continue }
            if let meta = chromeByID[threadID] {
                let workspaceName = meta.workspaceId.flatMap { context.state.workspaces[$0]?.name }
                let providerName = PetActiveThreadProjector.providerLabel(meta.provider)
                activeThreadChromeByID[threadID] = CachedActiveThreadChrome(
                    workspaceID: meta.workspaceId,
                    workspaceName: workspaceName,
                    providerName: providerName,
                    threadTitle: meta.title,
                    route: .agentThread(threadID: threadID, workspaceID: meta.workspaceId)
                )
            } else {
                activeThreadChromeByID[threadID] = .empty(threadID: threadID)
            }
        }
    }

    private func invalidateCachedActiveThreadChrome(from event: EventBus.Event) {
        guard case .object(let payload) = event.payload else { return }
        let raw = payload["thread_id"]?.stringValue ?? payload["id"]?.stringValue
        guard let raw, let uuid = UUID(uuidString: raw) else { return }
        activeThreadChromeByID.removeValue(forKey: AgentThreadID(uuid))
    }

    private func verifyAndOpen(_ route: PetAttentionRoute, conversationID: BotConversationID? = nil) throws -> Bool {
        switch route {
        case .agentThread(let threadID, _):
            switch try router.agentThreadOpenDestination(threadID) {
            case .bot(let botID, let conversationID):
                guard try router.openBotsDesk(botID: botID, conversationID: conversationID) else { return false }
                guard let destination = router.windowController?.window,
                      destination.isVisible,
                      !destination.isMiniaturized else { return false }
                return destinationWindowIsKey(destination)
            case .unavailable:
                return false
            case .workspace:
                let descriptor = try router.openAgentThread(thread: threadID, markRead: false)
                guard let window = SurfaceRegistry.shared.surface(descriptor.id)?.view.window else { return false }
                return window.isVisible && !window.isMiniaturized && destinationWindowIsKey(window)
            }
        case .surface(let surfaceID, let requestedWorkspaceID):
            let requestedStillOwnsSurface = requestedWorkspaceID.flatMap { workspaceID in
                context.state.workspaces[workspaceID]?.layout.contains(surfaceID: surfaceID) == true
                    ? workspaceID
                    : nil
            }
            guard let workspaceID = requestedStillOwnsSurface ?? context.state.workspaces.first(where: {
                $0.value.layout.contains(surfaceID: surfaceID)
            })?.key else { return false }
            guard let destinationWindow = activateDestinationWindow(for: workspaceID) else { return false }
            if router.windowController?.workspaceWindow(for: workspaceID) == nil {
                try router.selectWorkspace(workspaceID)
            }
            try router.focusSurface(workspace: workspaceID, surface: surfaceID)
            router.windowController?.flushPendingRefresh()
            router.windowController?.focusSurface(surfaceID)
            guard let workspace = context.state.workspaces[workspaceID],
                  let paneID = workspace.focusedPaneID else { return false }
            return workspace.layout.find(paneID: paneID)?.selectedSurfaceID == surfaceID
                && destinationWindow.isVisible
                && !destinationWindow.isMiniaturized
                && destinationWindowIsKey(destinationWindow)
                && SurfaceRegistry.shared.surface(surfaceID)?.view.window === destinationWindow
        case .workspace(let workspaceID):
            guard let destinationWindow = activateDestinationWindow(for: workspaceID) else { return false }
            if router.windowController?.workspaceWindow(for: workspaceID) == nil {
                try router.selectWorkspace(workspaceID)
                guard context.state.window.selectedWorkspaceID == workspaceID else { return false }
            }
            return destinationWindow.isVisible
                && !destinationWindow.isMiniaturized
                && destinationWindowIsKey(destinationWindow)
        case .settings(let settingsRoute):
            return openSettings(settingsRoute)
        case .botsDesk(let botID):
            guard try router.openBotsDesk(botID: botID, conversationID: conversationID) else { return false }
            guard let destination = router.windowController?.window,
                  destination.isVisible,
                  !destination.isMiniaturized else { return false }
            return destinationWindowIsKey(destination)
        }
    }

    private func activateDestinationWindow(for workspaceID: WorkspaceID) -> NSWindow? {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let detachedWindow = router.windowController?.workspaceWindow(for: workspaceID) {
            detachedWindow.makeKeyAndOrderFront(nil)
            return detachedWindow
        }
        router.windowController?.show()
        return router.windowController?.window
    }

    private func destinationWindowIsKey(_ window: NSWindow) -> Bool {
        destinationWindowIsKeyForTests?(window) ?? window.isKeyWindow
    }

    func openTitio() {
        windowController?.closePopover(restoringPreviousKeyWindow: false)
        do {
            try router.openTitio()
        } catch {
            model.routeError = L("Titio could not be opened.")
        }
    }

    /// Popover field: same path as Option+Space, a new Titio conversation, opened.
    func sendToTitio(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        windowController?.closePopover(restoringPreviousKeyWindow: false)
        if router.sendTitioQuickMessage(trimmed) == nil {
            model.routeError = L("Titio could not be reached.")
        }
    }

    private func showActivity() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        router.windowController?.show()
        router.windowController?.presentActiveThreadsInMainContent()
        windowController?.closePopover(restoringPreviousKeyWindow: false)
    }

    private func toggleAnimations() {
        settingsStore.update { $0.petAnimationsEnabled.toggle() }
        applySettings(settingsStore.load())
        NotificationCenter.default.post(name: .petSettingsDidChange, object: self)
    }

    private func setPetEnabled(_ enabled: Bool) {
        settingsStore.update { $0.petEnabled = enabled }
        applySettings(settingsStore.load())
        NotificationCenter.default.post(name: .petSettingsDidChange, object: self)
    }

    private func adoptFreePosition() {
        settingsStore.update { $0.petPosition = "free" }
        model.apply(settings: settingsStore.load())
        NotificationCenter.default.post(name: .petSettingsDidChange, object: self)
    }

    private func applySettings(_ settings: AppSettings) {
        model.apply(settings: settings)
        // Titio's avatars move like the pet and pause with it.
        TitioAvatarAnimator.shared.setMotionAllowed(
            settings.petAnimationsEnabled
                && !settings.petReduceMotion
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        if settings.petEnabled {
            do {
                let visualRuntimeWasLoaded = animationController != nil
                try ensureVisualRuntime()
                animationController?.setVisible(true)
                animationController?.setAnimationsEnabled(settings.petAnimationsEnabled)
                animationController?.setReducedMotion(
                    settings.petReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                )
                windowController?.applySettings(settings)
                if !visualRuntimeWasLoaded {
                    let derived: PetAnimationState = model.count > 0 ? .waiting : .idle
                    try animationController?.setState(model.animationState, derivedTerminalState: derived)
                }
                if let cue = pendingCompanionCue {
                    pendingCompanionCue = nil
                    playCompanionCue(cue)
                }
            } catch {
                model.routeError = L("Pet animation is unavailable.")
            }
            scheduleIdleTimeout()
            scheduleCompanionBehavior()
        } else {
            animationController?.setVisible(false)
            windowController?.applySettings(settings)
            idleTask?.cancel()
            idleTask = nil
            companionTask?.cancel()
            companionTask = nil
            pendingCompanionCue = nil
        }
        speechController.reevaluate()
    }

    private func handleInteraction() {
        apply(reducer.reduce(.interactionBegan, atMilliseconds: monotonicMilliseconds()))
        scheduleIdleTimeout()
    }

    private func handlePetDragStateChanged(_ isDragging: Bool) {
        // The bubble would be left behind mid-air; it is in the inbox anyway.
        if isDragging { speechController.clear(animated: false) }
        apply(reducer.reduce(
            isDragging ? .petDragBegan : .petDragEnded,
            atMilliseconds: monotonicMilliseconds()
        ))
        scheduleIdleTimeout()
    }

    private func companionEligibility() -> PetCompanionEligibility {
        let settings = model.settings
        // Use companionBaseState (no decorative transient), not reducer.state.
        // WHY: while workingMouse/Bug/Engineer is showing, display state is not in
        // the work-base set — using reducer.state cancelled the next work countdown
        // and re-froze the laptop pose for a full 35–55s after every variant.
        //
        // activeRunCount = Active list (model.activeThreads), not EventBus
        // ghost run ids. Work variants (laptop/hard-hat) must not play with zero
        // Active rows — that was the "working with no badge" stick.
        return PetCompanionEligibility(
            baseState: reducer.companionBaseState,
            attentionCount: model.count,
            activeRunCount: model.activeThreads.count,
            isVisible: windowController?.isVisible == true,
            animationsEnabled: settings.petAnimationsEnabled,
            reducedMotion: settings.petReduceMotion
                || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            screenLocked: isScreenLocked
        )
    }

    private func scheduleCompanionBehavior() {
        let eligibility = companionEligibility()
        let delayRange: ClosedRange<Int>
        if eligibility.allowsWorkCue {
            delayRange = PetCompanionDirector.workDelayRange
        } else if eligibility.allowsAmbientCue {
            delayRange = PetCompanionDirector.ambientDelayRange
        } else {
            companionTask?.cancel()
            companionTask = nil
            return
        }
        guard companionTask == nil else { return }
        let delay = companionDelayProvider(delayRange)
        companionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.companionTask = nil
                let eligibility = self.companionEligibility()
                let cue: PetCompanionCue?
                if eligibility.allowsWorkCue {
                    cue = self.companionDirector.nextWorkCue(
                        eligibility: eligibility,
                        preferredIndex: Int.random(in: 0..<3),
                        durationMilliseconds: self.randomExtendedReactionDuration()
                    )
                } else if eligibility.allowsAmbientCue {
                    cue = self.companionDirector.nextAmbientCue(
                        eligibility: eligibility,
                        preferredIndex: Int.random(in: 0..<8),
                        durationMilliseconds: self.randomExtendedReactionDuration()
                    )
                } else {
                    cue = nil
                }
                if let cue {
                    self.playCompanionCue(cue)
                } else {
                    self.scheduleCompanionBehavior()
                }
            }
        }
    }

    private func playCompanionCue(
        _ cue: PetCompanionCue,
        allowsStaticReaction: Bool = false
    ) {
        // Always re-arm the companion loop after this attempt. Early returns used
        // to leave companionTask == nil with no pending schedule during long runs.
        defer { scheduleCompanionBehavior() }

        guard model.settings.petEnabled, !isScreenLocked else { return }
        let motionAllowed = model.settings.petAnimationsEnabled
            && !model.settings.petReduceMotion
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard allowsStaticReaction || motionAllowed else { return }
        guard let animationController else {
            pendingCompanionCue = cue
            return
        }
        // Drain any cue stashed while the visual runtime was missing.
        if pendingCompanionCue != nil {
            pendingCompanionCue = nil
        }
        let alignedDuration = animationController.loopSafeDurationMilliseconds(
            for: cue.state,
            requested: cue.durationMilliseconds
        )
        // Hardening: rebind return to the live semantic base at fire time
        // (defense-in-depth; production mints return from eligibility after the delay).
        let effectiveCue = PetCompanionCue(
            state: cue.state,
            returnState: reducer.companionBaseState,
            durationMilliseconds: alignedDuration
        )
        // Avoid recursive defer double-schedule: apply → scheduleCompanionBehavior
        // already; defer also runs. scheduleCompanionBehavior is idempotent when
        // companionTask != nil, and apply may start a task first — OK.
        apply(reducer.reduce(
            .companionCue(effectiveCue),
            atMilliseconds: monotonicMilliseconds()
        ))
    }

    private func randomExtendedReactionDuration() -> Int64 {
        extendedReactionDurationProvider()
    }

    private func scheduleIdleTimeout() {
        idleTask?.cancel()
        guard model.settings.petEnabled else {
            idleTask = nil
            return
        }
        idleTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.idleTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.model.count == 0, self.reducer.activeRunCount == 0 else { return }
                self.apply(self.reducer.reduce(
                    .idleTimeout,
                    atMilliseconds: self.monotonicMilliseconds()
                ))
            }
        }
    }

    private func attentionFilter(_ raw: String) -> PetAttentionFilter {
        switch raw {
        case "completed": return .completed
        case "needsYou": return .needsYou
        default: return .all
        }
    }

    private func monotonicMilliseconds() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}

/// Painted pet-row chrome from the last durable projection. Progress ticks
/// rebuild `PetActiveThreadItem` from this instead of SQLite.
private struct CachedActiveThreadChrome {
    let workspaceID: WorkspaceID?
    let workspaceName: String?
    let providerName: String?
    let threadTitle: String?
    let route: PetAttentionRoute

    static func empty(threadID: AgentThreadID) -> CachedActiveThreadChrome {
        CachedActiveThreadChrome(
            workspaceID: nil,
            workspaceName: nil,
            providerName: nil,
            threadTitle: nil,
            route: .agentThread(threadID: threadID, workspaceID: nil)
        )
    }
}
