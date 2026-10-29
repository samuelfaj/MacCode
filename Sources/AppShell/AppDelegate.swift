import Foundation
import CryptoKit
import AppKit
import Network
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import Surfaces
import AppLifecycleSupport
import UserNotifications
import os

private let appLifecycleLog = Logger(subsystem: "io.remotecode.app", category: "lifecycle")

public enum BonjourPublicationState: String, Sendable {
    case stopped
    case publishing
    case published
    case failed
}

private final class UnixBotPeerProgressBox: @unchecked Sendable {
    var date: Date?
}

@MainActor
func flushPersistedTerminalHistoryForRegisteredSurfaces(
    timeout: TimeInterval = 2
) async -> Bool {
    let barriers = SurfaceRegistry.shared.all().compactMap {
        ($0 as? TerminalRuntimeRoutingSurface)?.routedFlushPersistedHistoryBarrier()
    }
    let deadline = DispatchTime.now() + max(0, timeout)
    var completed = true
    for barrier in barriers {
        completed = await barrier.waitAsync(until: deadline) && completed
    }
    return completed
}

/// Starts every surface disposition before waiting, so many open terminals share
/// one app-exit deadline. Non-terminal surfaces use the default implementation,
/// which preserves their normal close behavior.
@MainActor
@discardableResult
func closeSurfacesForApplicationTermination(
    _ surfaces: [Surface],
    timeout: TimeInterval = 2
) -> Bool {
    var barriers = surfaces.compactMap { $0.closeForApplicationTermination() }
    if let pendingHistoryDelete = TerminalSurface.pendingHistoryDeleteBarrier() {
        barriers.append(pendingHistoryDelete)
    }
    if let unboundProcessDisposition = TerminalSurface.activeProcessDispositionBarrier() {
        barriers.append(unboundProcessDisposition)
    }
    let deadline = DispatchTime.now() + max(0, timeout)
    var completed = true
    for barrier in barriers {
        completed = barrier.waitForApplicationTermination(until: deadline) && completed
    }
    return completed
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    public var context: AppContext!
    public var router: AppCommandRouter!
    public var windowController: MainWindowController!
    public var socketServer: UnixSocketServer?
    public var httpServer: DirectHTTPServer?
    /// GAP-5: `DirectHTTPServer.auth` is a weak ref. Without an owner the
    /// LocalAuthAdapter deallocates the instant launch returns, which
    /// silently disables pairing AND bypasses the LAN auth gate. The
    /// app delegate must own it for the process lifetime.
    private var authProvider: DirectAuthProvider?
    private var localAuth: LocalAuthAdapter?

    /// GAP-5 retention seam. `DirectHTTPServer.auth` is a *weak* ref, so the
    /// app delegate is the sole strong owner; this method makes that ownership
    /// the single, named, testable assignment. A regression that turns
    /// `authProvider` into a weak/unowned ref (or drops this call) lets the
    /// provider deallocate and silently disables pairing AND the LAN auth gate.
    /// `authProviderIsRetained` lets a test observe the strong ref survives a
    /// dropped local reference without spinning up the full HTTP stack.
    func retainAuthProvider(_ provider: DirectAuthProvider) {
        authProvider = provider
    }

    /// True iff a strong reference to an auth provider is currently held.
    /// Used by the GAP-5 regression test to fail loud if the strong owner
    /// is ever removed.
    var authProviderIsRetained: Bool { authProvider != nil }
    private var bonjour: NetService?
    private var bonjourDelegate: BonjourDelegate?
    private var bonjourPublishRetryWorkItem: DispatchWorkItem?
    private var bonjourPublishRetryAttempt = 0
    private var bonjourPublicationGeneration = UUID()
    public private(set) var bonjourPublicationState: BonjourPublicationState = .stopped
    private var directAccessSupervisor: DirectAccessLifecycleSupervisor?
    private var relayHostClient: RelayHostClient?
    private var relayPathMonitor: NWPathMonitor?
    private let relayHostKeyStore: RelayHostKeyStoring =
        LocalAuthAdapter.isE2EPairingAutoApproveEnabled
        ? InMemoryRelayHostKeyStore()
        : KeychainRelayHostKeyStore()
    public var palette: CommandPalette?
    public var settings: SettingsWindowController?
    public private(set) var petController: PetController?
    private let activityDockBadge = ActivityDockBadge()
    public var updater: AppUpdateChecking?
    var keyWindowProviderForTests: (() -> NSWindow?)?
    public let channel: ReleaseChannel
    private let appSupportOverride: String?
    private let dbOverride: String?
    private let physicalMemoryBytesProvider: @Sendable () -> UInt64
    private var providerSessionReaperTimer: Timer?
    private var ccrRetentionTimer: Timer?
    private var diagnosticsHeartbeatTimer: Timer?
    private var accountUsageRefreshTimer: Timer?
    private var lifecycleRecorder: AppLifecycleRecorder?
    /// Forensic-only hang detector (plan-final W0). Never mutates run status.
    private var hangWatchdog: HangWatchdog?
    /// S-F4a: reclaims hidden terminals when the OS reports memory pressure.
    private var memoryPressureMonitor: MemoryPressureMonitor?
    /// Sleep-aware awake state for HangWatchdog (updated from NSWorkspace sleep/wake).
    private let hangWatchdogAwakeState = HangWatchdogAwakeBox(initial: .unknown)
    /// Distributed-notification observer: schedule store commits → rail reload.
    private var scheduledTaskStoreObserver: NSObjectProtocol?
    private var scheduledTaskScheduler: ScheduledTaskScheduler?
    private var botRoutineScheduler: BotRoutineScheduler?
    private var scheduledTaskTimer: Timer?
    private var scheduledTaskNotificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    /// Menu items whose keyEquivalent is controlled by keybindings.json.
    /// Populated by installMainMenu(); refreshed by reapplyKeybindingOverrides().
    private var keybindableMenuItems: [(item: NSMenuItem, command: String)] = []
    public static let accountUsageRefreshInterval: TimeInterval = 60

    /// Accumulates server startup failures so Settings can show a status
    /// row rather than relying on NSLog alone (UX-MAC_SOCKET_SERVER-P1).
    /// Populated at most once per server per launch; cleared on re-configure.
    public private(set) var serverStartupFailures: [(server: String, reason: String)] = []

    /// True once the first denied-post notice has been fired this session.
    /// Guards `handleDeniedPost` so the user sees the notice at most once
    /// per launch regardless of how many runs finish while notifications are off.
    private var notificationsDeniedNoticeFired = false

    /// Notification name posted (on the main thread) when a server startup
    /// failure is recorded. Observers receive the `serverStartupFailures` array
    /// via `AppDelegate.shared?.serverStartupFailures` after the post.
    public static let serverStartupFailureNotification = Notification.Name("io.remotecode.serverStartupFailure")

    public init(
        channel: ReleaseChannel = .debug,
        appSupportOverride: String? = nil,
        dbOverride: String? = nil,
        physicalMemoryBytesProvider: @escaping @Sendable () -> UInt64 = {
            ProcessInfo.processInfo.physicalMemory
        }
    ) {
        self.channel = channel
        self.appSupportOverride = appSupportOverride
        self.dbOverride = dbOverride
        self.physicalMemoryBytesProvider = physicalMemoryBytesProvider
        super.init()
    }

    var managedProcessMemoryProfile: ManagedProcessMemoryProfile {
        ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: physicalMemoryBytesProvider())
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window paints a Bot avatar.
        TitioBot.installAvatar()
        let appSupportDirectory = AppPaths.appSupportDirectory(
            for: channel,
            override: appSupportOverride
        )
        // First, before anything can start GhosttyKit: its init deletes the
        // previous run's crash files.
        let harvestedGhosttyCrashFiles = GhosttyCrashHarvester.harvest(
            from: GhosttyCrashHarvester.defaultSourceDirectories(),
            into: appSupportDirectory.appendingPathComponent("diagnostics/ghostty-crash", isDirectory: true)
        )
        ProviderProcessOwnership.shared.configure(
            fileURL: appSupportDirectory
                .appendingPathComponent("diagnostics", isDirectory: true)
                .appendingPathComponent("provider-process-ownership.json", isDirectory: false)
        )
        do {
            context = try AppContext(channel: channel, dbPathOverride: dbOverride, appSupportOverride: appSupportOverride)
        } catch {
            // UX-MAC_PERSISTENCE-P1: plain-language copy + recovery guidance.
            // The most common causes are a permissions error on first launch
            // or a half-written database after an abrupt kill. A fresh database
            // is stored alongside the corrupt one (Bootstrap quarantines it),
            // so the user can recover by deleting remotecode.sqlite and relaunching.
            let supportDir = AppPaths.appSupportDirectory(for: channel, override: appSupportOverride).path
            let alert = NSAlert()
            alert.messageText = "MacCode could not open its database"
            alert.informativeText = Self.dbOpenFailureInformativeText(
                supportDir: supportDir,
                errorDescription: error.localizedDescription
            )
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Show in Finder")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: supportDir, isDirectory: true)]
                )
            }
            NSApp.terminate(nil)
            return
        }
        configureManagedProviderAdmission()

        // UX-MAC_PERSISTENCE-P1: inform the user when a corrupt database was
        // silently quarantined so they know prior data was preserved as a backup.
        if context.bootstrapReport.recoveredFromCorruption {
            // A run-loop block, not a main-queue job: runModal inside a
            // main-queue job stalls every main-actor job (remote RPCs) until
            // the alert is dismissed.
            RunLoop.main.perform { MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Previous database was corrupt"
                alert.informativeText = """
                    MacCode found and quarantined a corrupt database, then started \
                    fresh. Your previous data is preserved as a backup file (suffix \
                    ".corrupt-<date>") in:

                    \(self.context.bootstrapReport.path.components(separatedBy: "/").dropLast().joined(separator: "/"))

                    Workspaces, settings, and history from this session will be saved normally.
                    """
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Show in Finder")
                if alert.runModal() == .alertSecondButtonReturn {
                    let dir = URL(fileURLWithPath: self.context.bootstrapReport.path)
                        .deletingLastPathComponent()
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            } }
        }

        installLifecycleRecorder(harvestedGhosttyCrashFiles: harvestedGhosttyCrashFiles)
        startMemoryPressureMonitor()
        // PERF (cold launch): the orphan provider sweep is a process scan and
        // the event-log decode + PTY restore are heavy. StartupPlan defers them
        // past the first frame; see runDeferredStartup().
        // `context.router` builds the bot peer authority, whose restore
        // reconcile commits thread chrome before the event log is wired below.
        context.holdsBotPeerThreadChromeUntilEventLogReady = true
        router = AppCommandRouter(context: context)
        context.router = router
        context.distillAccountsController.ensureDistillInstalled()
        DistillAutoGuideSheet.installFactory(context: context)

        // Wire EventBus to the persisted event log so events survive restart.
        // Encoding + SQLite run on AppContext's serial writer queue; publish
        // remains ordered without blocking the producer on durable storage.
        Self.wireEventPersistence(context: context)
        do {
            EventBus.shared.reloadFromPersistence(lastSeq: try context.eventLog.lastSeq(), recent: [])
            // C8: a clean previous quit lets its cursors resume from the log.
            DurableReplayResumeRecord.restore(
                eventBus: .shared,
                settings: context.settingsRepo,
                bootEpoch: context.liveActivityHostIdentity.bootEpoch
            )
        } catch {
            appLifecycleLog.error("event_log.sequence_init_failed error=\(error.localizedDescription, privacy: .public)")
        }
        // The bus is wired and past the durable head: restored chrome now gets
        // a persisted seq that counts toward agentThreads and C8 replay.
        context.botPeerHandoffAuthority.publishRestoredThreadChrome()
        // After the event log: the reconcile's events must be persisted and
        // sequenced after everything a client already saw.
        context.reconcileBotGroupsAfterLaunch()
        context.resumeDistillLoopsAfterLaunch()
        updater = SparkleAppUpdater.defaultIfConfigured()
        updater?.onWillInstallUpdate = { [weak self] in
            self?.persistRestorableStateBeforeUpdate()
        }
        windowController = MainWindowController(
            context: context,
            router: router,
            updater: updater
        )
        router.windowController = windowController
        settings = makeSettingsWindowController(context: context, updater: updater)
        // Schedules run in-process (paste+play Agent App). Unregister any legacy
        // LaunchAgent so it cannot dual-claim after upgrade.
        startInProcessScheduledTaskScheduler()
        installScheduledTaskStoreObserver()
        startPetController()
        // Titio lives in the Bot roster so paired devices can chat with it too.
        if let botStore = context?.botStore, let support = context?.appSupportDirectory {
            _ = try? TitioBot.ensure(store: botStore, appSupportDirectory: support)
            // Titio's notice hub: catch-up flush, banner re-post, retention and
            // its event subscriptions (hub spec §3 step 5).
            context?.titioNoticeCenter.start()
            // The roster may have loaded before Titio existed (first launch).
            router?.botsViewModel?.reload()
        }
        titioQuickChat.install { [weak self] text in self?.router?.sendTitioQuickMessage(text) }
        activityDockBadge.start()

        // start unix socket server
        let socketPath = AppPaths.socketPath(for: channel)
        let dispatcher = JSONRPCDispatcher(router: router)
        let server = UnixSocketServer(socketPath: socketPath, dispatcher: dispatcher)
        server.botPeerAskProgress = { [weak router] threadID, runID in
            let box = UnixBotPeerProgressBox()
            let gate = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                box.date = router?.botPeerAskProgress(threadID: threadID, runID: runID)
                gate.signal()
            }
            _ = gate.wait(timeout: .now() + 0.25)
            return box.date
        }
        server.botPeerActivityProgress = { [weak router] threadID, activityID in
            let box = UnixBotPeerProgressBox()
            let gate = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                box.date = router?.botPeerActivityProgress(threadID: threadID, activityID: activityID)
                gate.signal()
            }
            _ = gate.wait(timeout: .now() + 0.25)
            return box.date
        }
        do {
            try server.start()
            socketServer = server
            try? Self.resolvePetServerFailure(
                server: "rc2 socket",
                repository: NotificationRepository(db: context.db)
            )
            context.titioNoticeCenter.sourceResolved(key: Self.petServerFailureID(server: "rc2 socket"))
        } catch {
            NSLog("Failed to start socket server: \(error)")
            recordServerStartupFailure("rc2 socket", reason: error.localizedDescription)
        }

        let trustRepo = DeviceTrustRepository(db: context.db)
        let auth = LocalAuthAdapter(
            repo: trustRepo,
            privateAccountStore: PrivateAccountSessionStore(repo: context.settingsRepo)
        )
        retainAuthProvider(auth)   // GAP-5: retain for process lifetime
        localAuth = auth
        // A device-initiated pair request pops an approve/deny modal on
        // the Mac. The HTTP handler invokes this off the listener thread;
        // hop to main for AppKit. The device polls /v1/pair/status mean-
        // while, so the server never blocks on the user's decision.
        auth.onPairingRequest = { [weak self] prompt in
            NSLog("pairing.prompt.received request_id=%@", prompt.requestId)
            DispatchQueue.main.async { self?.presentPairingPrompt(prompt) }
        }
        // The device can cancel its own outstanding request (POST
        // /v1/pair/cancel). Fired off the listener thread; hop to main and
        // dismiss the approve/deny modal if it is showing that request.
        auth.onPairingCancelled = { [weak self] requestId in
            DispatchQueue.main.async { self?.dismissPairingSheetIfShowing(requestId: requestId) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(remoteAccessSettingChanged),
                                               name: .rc2RemoteAccessSettingChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(privateAccountChanged),
                                               name: .rc2PrivateAccountChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keybindingsReloaded),
                                               name: .rc2KeybindingsReloaded, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        configureDirectAccess()

        palette = CommandPalette(router: router)
        SystemNotifier.shared.bootstrap()
        SystemNotifier.shared.onNotificationResponse = { [weak self] response in
            self?.handleNotificationResponse(response)
        }
        // UX-MAC_APPSHELL-P2: when OS permission is denied, surface an in-app
        // notice so a finished run is not invisible. Fired at most once per
        // session (notificationsDeniedNoticeFired gate) to avoid spam.
        SystemNotifier.shared.onDeniedPost = { [weak self] content in
            self?.handleDeniedPost(content)
        }
        reapIdleProviderSessions()
        // Scan frequently enough to honor a 1–2 minute idleReleaseAge.
        providerSessionReaperTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let delegate = self else { return }
            Task { @MainActor in
                delegate.reapIdleProviderSessions()
            }
        }

        // PERF (launch): the first pass waits until the window is interactive and
        // the restore burst has settled, so its scan never competes with hydration.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchCCRRetentionDelaySeconds) { [weak self] in
            self?.runCCRRetention()
        }
        ccrRetentionTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            guard let delegate = self else { return }
            Task { @MainActor in
                delegate.runCCRRetention()
            }
        }

        installMainMenu()
        windowController.show()
        // Do not fire multi-provider account-usage probes (claude /usage, grok
        // models, …) on the first paint. Defer until the UI is interactive.
        startAccountUsageRefreshLoop()
        startDiagnosticsHeartbeat()
        logDiagnosticsHeartbeat(reason: "launch")
        checkForUpdatesAfterOpeningApp()
        // Only schedules: the first Distill update check runs off the main
        // actor, well after this frame.
        context?.startDistillAutoUpdates()
        context?.startManagedToolInstalls()

        // PERF (cold launch): the first frame has now painted (show() above), so
        // the "Restoring workspaces..." affordance can animate while the heavy,
        // frame-irrelevant restore work runs. StartupPlan.deferredSteps decide
        // what lands here. Hopping back through the main queue yields one runloop
        // turn for the frame before the PTY spawns / process scan begin.
        // A run-loop block, not a main-queue job: the onboarding alert is a
        // runModal, which inside a main-queue job would stall every main-actor
        // job (remote RPCs) until dismissed.
        RunLoop.main.perform { [weak self] in MainActor.assumeIsolated {
            // Explain folder TCC before restored surfaces/PTYs touch protected paths.
            self?.presentHostFileAccessOnboardingIfNeeded()
            self?.runDeferredStartup()
        } }
        // Account usage % rings: wait ~8s so boot probes do not pile on top of
        // workspace restore / first Agent surface open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.refreshAccountUsageOnLaunch()
        }
    }

    /// One-time Full Disk Access tip. Launch never probes Desktop/Documents/
    /// Downloads (that forced multi-folder TCC spam). Every button marks
    /// onboarding *handled* (not “permissions granted”) so launch never nags.
    func presentHostFileAccessOnboardingIfNeeded() {
        if LocalAuthAdapter.isE2EPairingAutoApproveEnabled {
            return
        }
        guard let context else { return }
        let repo = SettingsRepository(db: context.db)
        guard HostFileAccessOnboarding.shouldPresent(
            handled: HostFileAccessOnboarding.isHandled(repo: repo)
        ) else { return }

        let alert = NSAlert()
        alert.messageText = HostFileAccessCopy.onboardingTitle
        alert.informativeText = HostFileAccessCopy.onboardingMessage
        if let warning = HostCodeSignatureReader.current().adHocWarning {
            alert.informativeText += "\n\n" + warning
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: HostFileAccessCopy.openFullDiskAccessButton)
        alert.addButton(withTitle: HostFileAccessCopy.notNowButton)
        let response = alert.runModal()
        do {
            try HostFileAccessOnboarding.handleAlertResponse(
                response,
                markHandled: { try HostFileAccessOnboarding.markHandled(repo: repo) },
                openFullDiskAccess: {
                    NSWorkspace.shared.open(HostFileAccessSystemSettings.fullDiskAccessURL)
                }
            )
        } catch {
            appLifecycleLog.error(
                "host_file_access.onboarding_persist_failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// PERF (cold launch): the StartupPlan-deferred steps -- orphan provider
    /// sweep (process scan), persisted event-log read + JSON decode of up to 256
    /// payloads, and reinstantiating restored surfaces (a PTY spawn per restored
    /// terminal). Runs after the first frame so launch is not blocked.
    private func runDeferredStartup() {
        // Off MainActor: process scan + optional SIGTERM grace sleeps must not
        // hitch the first interactive frame after cold launch.
        scheduleOrphanRuntimeSweep(reason: "launch")

        if let log = context?.eventLog {
            do {
                let rows = try log.read(since: 0, limit: 256)
                let events = rows.compactMap { row -> EventBus.Event? in
                    guard let data = row.payloadJSON.data(using: .utf8),
                          let val = JSONValue.decode(from: data)
                    else { return nil }
                    return EventBus.Event(seq: row.seq, kind: row.kind, payload: val, ts: Date().timeIntervalSince1970)
                }
                EventBus.shared.reloadFromPersistence(lastSeq: try log.lastSeq(), recent: events)
            } catch {
                appLifecycleLog.error("event_log.deferred_reload_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }

        // Rebuild Surface objects from restored layout descriptors, then drop
        // the restoring affordance and render the real layout.
        router?.reinstantiateRestoredSurfaces()
        Task { @MainActor [weak self] in
            await self?.router?.reconcileQueuedAgentMessagesOnLaunch()
        }
        windowController?.markRestorationComplete()
    }

    func startPetController() {
        guard petController == nil, let context, let router else { return }
        do {
            let controller = try PetController(
                context: context,
                router: router,
                openSettings: { [weak self] route in
                    guard let self else { return false }
                    if let windowController = self.windowController {
                        windowController.presentSettingsInMainContent(route: route)
                        return true
                    }
                    guard let settings = self.settings else { return false }
                    if let window = self.windowController?.window {
                        return settings.show(route: route, attachedTo: window)
                    }
                    return settings.show(route: route)
                }
            )
            petController = controller
            controller.start()
            // Titio speaks new notices from the pet (hub spec §9).
            context.titioNoticeCenter.setOnSpeech { [weak controller] speech in
                Task { @MainActor in controller?.speak(speech) }
            }
        } catch {
            appLifecycleLog.error("pet.start_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func stopPetController() {
        context?.titioNoticeCenter.setOnSpeech(nil)
        petController?.stop()
        petController = nil
    }

    /// Schedule store commits (including Run Now) reload Agent App rails.
    func installScheduledTaskStoreObserver() {
        removeScheduledTaskStoreObserver()
        scheduledTaskStoreObserver = ScheduledTaskCrossProcess.observeStoreChanged { [weak self] reason in
            self?.reloadAgentSurfacesFromScheduledStoreChange()
            EventBus.shared.publish(kind: .botSchedulerUpdated, payload: .object([
                "source": .string("scheduled_tasks"),
                "reason": .string(reason ?? "changed"),
            ]))
        }
    }

    func removeScheduledTaskStoreObserver() {
        if let scheduledTaskStoreObserver {
            ScheduledTaskCrossProcess.removeObserver(scheduledTaskStoreObserver)
            self.scheduledTaskStoreObserver = nil
        }
    }

    private func startInProcessScheduledTaskScheduler() {
        // Best-effort: leftover LaunchAgent must not own provider turns anymore.
        // Off main: the SMAppService XPC must not delay the first window, and a
        // leftover agent that still launches unregisters itself in Main.swift.
        Task.detached(priority: .utility) { try? ScheduledTaskAgentServiceManager().unregister() }
        let scheduler = ScheduledTaskScheduler(context: context, router: router)
        scheduledTaskScheduler = scheduler
        router.scheduledTaskScheduler = scheduler
        // Bot scheduled tasks ride the same timer and observers.
        let botRoutines = BotRoutineScheduler(
            authority: { [weak router] in router?.botRoutineAuthority },
            botsViewModel: { [weak router] in router?.botsViewModel }
        )
        botRoutineScheduler = botRoutines
        scheduledTaskTimer?.invalidate()
        scheduledTaskTimer = Timer.scheduledTimer(
            withTimeInterval: BotRemoteControlAuthority.routineTickInterval,
            repeats: true
        ) { [weak scheduler, weak botRoutines] _ in
            Task { @MainActor in
                scheduler?.tick()
                botRoutines?.tick()
            }
        }
        let wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak scheduler, weak botRoutines] _ in
            Task { @MainActor in
                scheduler?.tick()
                botRoutines?.tick()
            }
        }
        scheduledTaskNotificationTokens.append((NSWorkspace.shared.notificationCenter, wakeToken))
        for name: Notification.Name in [.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak scheduler, weak botRoutines] _ in
                Task { @MainActor in
                    scheduler?.tick()
                    botRoutines?.tick()
                }
            }
            scheduledTaskNotificationTokens.append((NotificationCenter.default, token))
        }
        // First tick skips past-due occurrences (app was closed), then claims
        // only work that becomes due while the app stays open.
        scheduler.tick()
        botRoutines.tick()
    }

    private func stopInProcessScheduledTaskScheduler() {
        scheduledTaskTimer?.invalidate()
        scheduledTaskTimer = nil
        for (center, token) in scheduledTaskNotificationTokens {
            center.removeObserver(token)
        }
        scheduledTaskNotificationTokens.removeAll()
        router?.scheduledTaskScheduler = nil
        scheduledTaskScheduler = nil
        botRoutineScheduler = nil
    }

    private func reloadAgentSurfacesFromScheduledStoreChange() {
        var workspaceIDs = Set<WorkspaceID>()
        var selectedThreads: [(viewModel: AgentAppViewModel, threadID: AgentThreadID)] = []
        for surface in SurfaceRegistry.shared.all() {
            guard let agent = surface as? AgentAppSurface else { continue }
            workspaceIDs.insert(agent.viewModel.workspaceID)
            if let selected = agent.viewModel.selectedThreadId {
                selectedThreads.append((agent.viewModel, selected))
            }
        }
        // One request per workspace is enough: the coordinator owns the
        // shared off-main rail snapshot for every registered surface. The old
        // per-surface reloadThreads() loop repeatedly cancelled/replaced the
        // same workspace task during scheduled-run bursts.
        for workspaceID in workspaceIDs {
            AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(workspaceID: workspaceID)
        }
        // Keep the exact selected-thread chrome/read semantics. This soft
        // reselect does not wipe the painted transcript or fetch a provider
        // snapshot; it only reconciles the durable scheduled-run state.
        for selection in selectedThreads {
            selection.viewModel.selectThread(selection.threadID, markRead: false)
        }
        windowController?.refreshSurfaceRuntimeState()
    }

    public func checkForUpdatesAfterOpeningApp() {
        updater?.checkForUpdates()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        appLifecycleLog.info("app.will_terminate pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
        lifecycleRecorder?.endRunCleanly(reason: "applicationWillTerminate")
        logDiagnosticsHeartbeat(reason: "will_terminate")
        stopInProcessScheduledTaskScheduler()
        removeScheduledTaskStoreObserver()
        LanguageServerPool.terminateAllProcessesNow()
        context?.stopDistillAutoUpdates()
        context?.distillHostWatch?.cancel()
        disableInsomniaForAppClose()
        // Token Saver was removed, so quit only purges what older builds
        // installed (and reinstalls the always-on routing); it never installs
        // anything Token Saver owned.
        if ProcessInfo.processInfo.environment["RC2_DISABLE_MANAGED_DISTILL_RECONCILE"] == "1" {
            appLifecycleLog.info("app.will_terminate distill_integration=unchanged isolated_process=true")
        } else {
            appLifecycleLog.info("app.will_terminate distill_integration=legacy_purged")
            context?.reconcileManagedIntegration()
        }
        persistRestorableStateBeforeUpdate()
        stopPetController()
        stopLiveRuntimesForAppTermination()
        // After the provider sessions: also ends guest runs whose turn was
        // still ending, and deletes their sign-in copies before exit.
        context?.botGuestRunResolver?.endRunsForAppTermination()
        // Runtime shutdown publishes final lifecycle events after the snapshot
        // barrier above. Drain them before the process exits.
        context?.flushEventPersistence()
        socketServer?.stop()
        context?.botGuestMCPGateway.stop()
        directAccessSupervisor?.shutdown()
        directAccessSupervisor = nil
        relayHostClient?.stop()
        relayHostClient = nil
        relayPathMonitor?.cancel()
        relayPathMonitor = nil
        providerSessionReaperTimer?.invalidate()
        ccrRetentionTimer?.invalidate()
        diagnosticsHeartbeatTimer?.invalidate()
        accountUsageRefreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // C8: last, after the servers stopped: flush, then record what the
        // next boot needs to resume this boot's cursors from the event log.
        if let context {
            context.flushEventPersistence()
            DurableReplayResumeRecord.write(
                eventBus: .shared,
                settings: context.settingsRepo,
                bootEpoch: context.liveActivityHostIdentity.bootEpoch
            )
        }
    }

    private func disableInsomniaForAppClose() {
        windowController?.disableInsomniaForAppClose()
        if let context {
            SettingsStore(db: context.db).update { $0.insomniaEnabled = false }
        }
    }

    private func persistRestorableStateBeforeUpdate() {
        router?.flushPendingTerminalTitles()
        context?.saveSnapshot()
        // Sparkle may relaunch immediately after this hook returns. Make every
        // previously published event durable before handing control back.
        context?.flushEventPersistence()
    }

    static func wireEventPersistence(
        context: AppContext,
        eventBus: EventBus = .shared
    ) {
        eventBus.shouldRetainRecentEvent = { event in
            Self.shouldRetainRecentEvent(event)
        }
        eventBus.recentReplayStandIn = EventStreamFilter.terminalOutputReplayStandIn
        context.wireBackgroundPersister(eventBus: eventBus)
    }

    private func stopLiveRuntimesForAppTermination() {
        context?.coordinator.stopAllProviderSessionsForAppTermination()
        let completed = closeSurfacesForApplicationTermination(SurfaceRegistry.shared.all())
        if !completed {
            appLifecycleLog.error("app.will_terminate terminal_disposition=incomplete")
        }
    }

    private func configureManagedProviderAdmission() {
        let requiresResourceAdmission = ManagedProviderAdmissionPolicy.requiresProviderStartPreflight
        let profile = managedProcessMemoryProfile
        let gate = ManagedProviderAdmissionGate()
        // Resource accounting stays best-effort; pin authorization fails closed.
        context.coordinator.providerAdmissionCheck = { [weak self] provider, threadId in
            guard let self else { throw NSError(domain: "RemoteCode.BotContext", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bot context authority is unavailable."]) }
            let pin = try await MainActor.run { try self.context.botStore.conversationContextPin(linkedTo: threadId) }
            if pin != nil {
                let authorized = try await MainActor.run {
                    guard let conversation = try self.context.botStore.conversationLinked(to: threadId) else { return false }
                    return try self.context.botStore.authorizesConversation(conversation, hostID: self.context.liveActivityHostIdentity.serverId, action: .send)
                }
                guard authorized else { throw NSError(domain: "RemoteCode.BotContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bot conversation context is no longer authorized."]) }
            }
            guard requiresResourceAdmission else { return }
            guard let store = ProviderProcessOwnership.shared.store() else { return }
            let scan: ManagedProcessScan
            let appFootprintKB: Int?
            do {
                (scan, appFootprintKB) = try await Task.detached(priority: .userInitiated) {
                    let scan = try ProviderProcessSweeper.managedProcessScan(store: store)
                    let footprint = AppDiagnostics.currentProcessFootprintKB()
                    return (scan, footprint >= 0 ? footprint : nil)
                }.value
            } catch {
                return
            }
            _ = await gate.decide(
                profile: profile,
                scan: scan,
                appFootprintKB: appFootprintKB,
                key: ManagedProviderAdmissionKey(provider: provider, threadId: threadId)
            )
        }
    }

    private func startDiagnosticsHeartbeat() {
        diagnosticsHeartbeatTimer?.invalidate()
        diagnosticsHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.logDiagnosticsHeartbeat(reason: "periodic")
            }
        }
    }

    private func refreshAccountUsageOnLaunch() {
        context?.refreshAccountUsage(reason: "launch")
    }

    private func startAccountUsageRefreshLoop() {
        accountUsageRefreshTimer?.invalidate()
        accountUsageRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.accountUsageRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Grok stays independent from slow Claude/Codex probes, but the
                // combined operation issues only one Grok credits request.
                self.context?.refreshPeriodicAccountUsage()
            }
        }
    }

    /// Periodic telemetry can only observe processes backed by durable ownership.
    /// Termination is intentionally different: it samples the post-sweep table
    /// directly so shutdown diagnostics retain their established ordering.
    nonisolated static func providerProcessListForDiagnostics(
        reason: String,
        store: ProviderProcessOwnershipStore?,
        processList: @escaping ProviderProcessList
    ) -> ProviderProcessList {
        guard reason != "will_terminate" else { return processList }
        guard let store else { return { [] } }
        return {
            try ProviderProcessSweeper.persistedOwnershipRows(
                store: store,
                processList: processList
            )
        }
    }

    private func logDiagnosticsHeartbeat(reason: String) {
        // Periodic heartbeats must never block MainActor on process scans or
        // SIGTERM grace sleeps — that freezes the whole UI every 60s once orphans
        // accumulate. App termination is the only path that still reaps inline.
        let processList: ProviderProcessList
        if reason == "will_terminate" {
            // Termination telemetry runs after the blocking reaper and must read
            // the post-sweep table rather than reuse its pre-signal snapshot.
            processList = Self.providerProcessListForDiagnostics(
                reason: reason,
                store: ProviderProcessOwnership.shared.store(),
                processList: { try ProviderProcessSweeper.psRowsThrowing() }
            )
            reconcilePersistedProcessOwnership(reason: reason)
        } else {
            let persistedOwnershipProcessList = Self.providerProcessListForDiagnostics(
                reason: reason,
                store: ProviderProcessOwnership.shared.store(),
                processList: { try ProviderProcessSweeper.psRowsThrowing() }
            )
            let snapshot = ProviderProcessListSnapshot(loader: persistedOwnershipProcessList)
            let sweepDecision = scheduleOrphanRuntimeSweep(
                reason: reason,
                processSnapshot: snapshot
            )
            if sweepDecision == .start {
                // Only the reaper may materialize the snapshot. This prevents a
                // delayed sweep from acting on rows captured earlier by telemetry.
                processList = { try snapshot.rowsAfterSweepLoad() }
            } else {
                processList = persistedOwnershipProcessList
            }
        }
        AppDiagnostics.heartbeat(
            reason: reason,
            activeAgentThreads: context?.coordinator.activeThreadIdsSnapshot().count ?? 0,
            profile: managedProcessMemoryProfile,
            lifecycleRecorder: lifecycleRecorder,
            processList: processList
        )
    }

    private func installLifecycleRecorder(harvestedGhosttyCrashFiles: [URL]) {
        let directory = AppPaths.appSupportDirectory(for: channel, override: appSupportOverride)
            .appendingPathComponent("diagnostics", isDirectory: true)
        let recorder = AppLifecycleRecorder(directory: directory)
        let staleMarkers = recorder.consumeStaleRunMarkerRecords()
        for stale in staleMarkers.map(\.contents) {
            // The previous run never reached applicationWillTerminate: it was
            // killed (SIGTERM/SIGKILL) or died abruptly with no crash report.
            // This is the on-disk evidence for the "app silently vanished" report.
            appLifecycleLog.fault("app.previous_run_unclean \(stale, privacy: .public)")
            recorder.record("previous_run_ended_uncleanly \(stale)")
        }
        // The Ghostty folders are shared with Ghostty.app, so a harvested dump
        // is not necessarily RemoteCode's own crash.
        for file in harvestedGhosttyCrashFiles {
            appLifecycleLog.info("app.ghostty_crash_harvested source=shared-ghostty file=\(file.lastPathComponent, privacy: .public)")
            recorder.record("ghostty_crash_harvested source=shared-ghostty file=\(file.lastPathComponent)")
        }
        recorder.beginRun()
        recorder.installSignalHandlers()
        recorder.installExitHandler()
        lifecycleRecorder = recorder
        // How each unclean run ended comes from launchd's log, which takes a
        // second or more to query, so it is recorded off the launch path.
        let uncleanRuns = staleMarkers.compactMap { marker in marker.pid.map { ($0, marker.lastAlive) } }
        if !uncleanRuns.isEmpty {
            let bundleIdentifier = Bundle.main.bundleIdentifier
            DispatchQueue.global(qos: .utility).async {
                for (pid, lastAlive) in uncleanRuns {
                    recorder.record(PreviousRunExitStatus.lifecycleLine(
                        pid: pid,
                        lastAlive: lastAlive,
                        bundleIdentifier: bundleIdentifier
                    ))
                }
            }
        }
        startHangWatchdog(recorder: recorder, diagnosticsDirectory: directory)
    }

    private func startMemoryPressureMonitor() {
        let monitor = MemoryPressureMonitor(log: { [weak self] line in
            appLifecycleLog.info("app.\(line, privacy: .public)")
            self?.lifecycleRecorder?.record(line)
        })
        memoryPressureMonitor = monitor
        monitor.start()
    }

    private func startHangWatchdog(recorder: AppLifecycleRecorder, diagnosticsDirectory: URL) {
        hangWatchdog?.stop()
        hangWatchdogAwakeState.value = .awake
        let bootId = HostBootIdentity.currentBootId()
        let awakeBox = hangWatchdogAwakeState
        // S-F5: a hang that lasts 5 s gets one `sample` stack per episode.
        let stackCapture = HangStackCapture(
            directory: diagnosticsDirectory,
            log: { [weak recorder] line in recorder?.record(line) }
        )
        let watchdog = HangWatchdog(
            pingInterval: 1.0,
            hangThreshold: 2.0,
            awakeProvider: { awakeBox.value },
            sideContextProvider: { [weak self] in
                HangWatchdogSideContext(
                    activeAgentThreadCount: self?.context?.coordinator.activeThreadIdsSnapshot().count ?? 0,
                    recoveryInFlight: false,
                    bootId: bootId,
                    // The breach fires at 2 s; HangStackCapture logs its own
                    // hang_stack_* line once a sample is actually taken.
                    sampleCountRequested: 0
                )
            },
            onBreach: { [weak recorder] breach in
                // Forensic only — never flip run/thread status.
                recorder?.record(
                    "\(breach.sideContext.lifecycleLine) gapSec=\(Int(breach.gapSeconds)) kind=\(breach.kind.rawValue) awake=\(breach.awake.rawValue)"
                )
            },
            gapObserver: { gapSeconds, kind, episodeStart in
                stackCapture.observe(gapSeconds: gapSeconds, kind: kind, episodeStart: episodeStart)
            }
        )
        hangWatchdog = watchdog
        watchdog.start()
    }

    /// F9-adjacent: orphan reaping used Thread.sleep grace windows on MainActor
    /// (via the 60s diagnostics heartbeat). Latch + detached Task keep the UI
    /// responsive while still reaping provider + Distill orphans in the background.
    @MainActor private var orphanSweepInFlight = false

    /// Pure decision for the background-sweep latch (testable without timers).
    enum OrphanSweepDecision: Equatable {
        case start
        case skipInFlight
    }

    @MainActor
    static func beginOrphanSweepForTests(_ inFlight: inout Bool) -> OrphanSweepDecision {
        beginOrphanSweep(inFlight: &inFlight)
    }

    @MainActor
    private static func beginOrphanSweep(inFlight: inout Bool) -> OrphanSweepDecision {
        guard !inFlight else { return .skipInFlight }
        inFlight = true
        return .start
    }

    @MainActor
    @discardableResult
    private func scheduleOrphanRuntimeSweep(
        reason: String,
        processSnapshot: ProviderProcessListSnapshot = ProviderProcessListSnapshot()
    ) -> OrphanSweepDecision {
        if Self.beginOrphanSweep(inFlight: &orphanSweepInFlight) == .skipInFlight {
            appLifecycleLog.info("provider.orphan_sweep reason=\(reason, privacy: .public) result=skipped_in_flight")
            return .skipInFlight
        }
        let minAge: TimeInterval = reason == "launch" ? 0 : ProcessSpawnTagger.defaultMinAge
        Task.detached(priority: .utility) { [weak self] in
            defer {
                Task { @MainActor in
                    self?.orphanSweepInFlight = false
                }
            }
            // nonisolated static body — never hop back to MainActor for the
            // process scan / SIGTERM grace sleeps that freeze the UI. The
            // terminate path materializes the snapshot immediately before its
            // ownership evaluation, never earlier in telemetry.
            Self.performOrphanRuntimeSweep(
                reason: reason,
                minAge: minAge,
                processList: { try processSnapshot.rows() }
            )
            // An unconfigured store returns before asking for a process list.
            // Resolve any telemetry waiter after that no-op sweep exits.
            _ = try? processSnapshot.rows()
        }
        return .start
    }

    private func reconcilePersistedProcessOwnership(reason: String) {
        let minAge: TimeInterval = reason == "launch" ? 0 : ProcessSpawnTagger.defaultMinAge
        Self.performOrphanRuntimeSweep(reason: reason, minAge: minAge)
    }

    /// Blocking implementation. Call only from a background queue (periodic/launch)
    /// or during applicationWillTerminate where the UI is already shutting down.
    /// nonisolated so Task.detached can run the process-table reaper without
    /// MainActor isolation (process I/O + Thread.sleep must stay off the UI thread).
    nonisolated private static func performOrphanRuntimeSweep(
        reason: String,
        minAge: TimeInterval,
        processList: ProviderProcessList = { try ProviderProcessSweeper.psRowsThrowing() }
    ) {
        do {
            let result = try ProviderProcessSweeper.terminatePersistedOrphanedProviderRuntimes(
                minAge: minAge,
                processList: processList
            )
            if !result.orphanRootPIDs.isEmpty || !result.failedPIDs.isEmpty {
                appLifecycleLog.info("provider.orphan_sweep reason=\(reason, privacy: .public) roots=\(result.orphanRootPIDs.count, privacy: .public) terminated=\(result.terminatedPIDs.count, privacy: .public) failed=\(result.failedPIDs.count, privacy: .public)")
            }
        } catch {
            // The ledger remains intact. Surface the failed audit instead of
            // reporting the indistinguishable all-clear result used previously.
            appLifecycleLog.fault("provider.orphan_sweep_failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            windowController?.show()
        }
        router?.reconcileSurfaceVisibility()
        windowController?.repairSelectedTerminalFocus(reason: "app_reopen")
        return true
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        openDroppedWorkspaceFolders(urls)
    }

    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openDroppedWorkspaceFolders([URL(fileURLWithPath: filename, isDirectory: true)])
    }

    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let opened = openDroppedWorkspaceFolders(filenames.map { URL(fileURLWithPath: $0, isDirectory: true) })
        sender.reply(toOpenOrPrint: opened ? .success : .failure)
    }

    @discardableResult
    public func openDroppedWorkspaceFolders(_ urls: [URL]) -> Bool {
        guard let router else { return false }
        var opened = false
        for url in urls {
            if (try? router.createWorkspace(fromFolder: url)) != nil {
                // UX-MAC_SHELL_WINDOW-005: feed File ▸ Open Recent.
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                opened = true
            }
        }
        if opened {
            windowController?.show()
        }
        return opened
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        Task { _ = await SystemNotifier.shared.authorizationStatus() }
        // Timestamps the reveal (deminiaturize/refocus) AND samples memory at
        // that instant, so the lifecycle log shows the app was alive at the
        // moment focus returned — the gesture the silent-vanish report is tied
        // to — and whether memory spiked on reveal (out-of-memory kill).
        lifecycleRecorder?.recordHeartbeat(reason: "did_become_active")
        router?.reconcileSurfaceVisibility()
        windowController?.repairSelectedTerminalFocus(reason: "app_active")
    }

    /// S-F6: the scan, the DB writes and the process teardown run on the
    /// reaper queue; the main thread only logs the outcome.
    private func reapIdleProviderSessions() {
        context.reapIdleProviderSessionsOffMain(
            idleAge: managedProcessMemoryProfile.idleReleaseAge
        ) { outcome in
            switch outcome {
            case .success(let result):
                if !result.stoppedThreadIds.isEmpty || !result.cappedThreadIds.isEmpty {
                    NSLog("Stopped \(result.stoppedThreadIds.count) idle provider session runtime(s); released \(result.cappedThreadIds.count) over the resident cap of \(ProviderSessionReaper.providerRootCap).")
                }
            case .failure(let error):
                NSLog("Failed to reap idle provider sessions: \(error)")
            }
        }
    }

    static let launchCCRRetentionDelaySeconds: TimeInterval = 30

    /// Safe storage cleanup off the main thread (plan-final W3).
    /// Uses LocalStorageBudgetManager.cleanupExpired (marker-reachable handles),
    /// never prune-by-ref_count. Cadence: 30 s after launch + every 24h via ccrRetentionTimer.
    private func runCCRRetention() {
        guard let ctx = context else { return }
        let db = ctx.db
        let queue = ctx.backgroundWriterQueue
        queue.async {
            do {
                let manager = LocalStorageBudgetManager(db: db)
                // compact: false on periodic path — vacuum only when idle + headroom.
                let result = try manager.cleanupExpired(compact: false)
                let total = result.removedRows.values.reduce(0, +)
                if total > 0 {
                    NSLog("Local storage cleanup removed \(total) expired row(s) (handle-safe).")
                }
            } catch {
                NSLog("Local storage cleanup failed: \(error)")
            }
        }
    }

    /// Durable event-log rows. High-frequency stream chunks stay live-only:
    /// `surface.output` is large terminal base64; `agent.item.delta` /
    /// `agent.item.progress` fire at token rate (~30 Hz);
    /// `agent.provider_runtime.event` is provider diagnostics already stored
    /// in `agent_provider_event_logs`. The transcript, item start/complete,
    /// and run lifecycle still persist. Live EventBus plus the recent ring still
    /// carry deltas and provider-runtime for in-session iOS reconnect.
    static func shouldPersistEvent(_ event: EventBus.Event) -> Bool {
        !EventBus.liveOnlyStreamEventKinds.contains(event.kind)
    }

    static func shouldRetainRecentEvent(_ event: EventBus.Event) -> Bool {
        event.kind != "surface.output"
    }

    @objc private func remoteAccessSettingChanged() {
        configureDirectAccess()
    }

    @objc private func privateAccountChanged() {
        relayHostClient?.accountChanged()
    }

    /// Starts the relay host client with the HTTP server. It idles until the Private account has a session token.
    private func configureRelay() {
        guard let context else { return }
        relayHostClient?.stop()
        relayHostClient = nil
        httpServer?.relayAvailable = { false }
        // Lazy: the Keychain key is only created when pairing or the relay first needs it.
        let keyStore = relayHostKeyStore
        localAuth?.relayHostPublicKeyProvider = {
            (try? keyStore.loadOrCreate())?.publicKey.rawRepresentation
        }
        guard let http = httpServer else { return }
        let hostKey: Curve25519.KeyAgreement.PrivateKey
        do { hostKey = try keyStore.loadOrCreate() } catch {
            NSLog("Relay host key unavailable")
            return
        }
        let base = ProcessInfo.processInfo.environment["RC_RELAY_URL"].flatMap(URL.init(string:))
            ?? URL(string: "wss://relay.remotecode.io")!
        http.relayURLString = base.absoluteString
        let accountStore = PrivateAccountSessionStore(repo: context.settingsRepo)
        let trust = DeviceTrustRepository(db: context.db)
        let client = RelayHostClient(
            server: http,
            relayBase: base,
            serverId: context.liveActivityHostIdentity.serverId,
            hostStatic: hostKey,
            accessToken: { accountStore.load()?.accessToken },
            refreshAccessToken: { [bridge = context.privateNotificationBridge] in
                await bridge.refreshRejectedAccessToken($0)
            },
            trustedDeviceForRelayKey: { (try? trust.deviceIdForRelayKey($0)) ?? nil }
        )
        http.relayAvailable = { [weak client] in client?.isConnected ?? false }
        relayHostClient = client
        client.start()
        startRelayPathMonitor(client)
    }

    /// Reconnects the relay host when the set of active interfaces changes (Wi-Fi/Ethernet/VPN switch).
    private func startRelayPathMonitor(_ client: RelayHostClient) {
        relayPathMonitor?.cancel()
        let monitor = NWPathMonitor()
        var lastInterfaces: Set<NWInterface.InterfaceType>?
        monitor.pathUpdateHandler = { [weak client] path in
            guard path.status == .satisfied else { return }
            let interfaces = Set(path.availableInterfaces.map(\.type))
            defer { lastInterfaces = interfaces }
            guard let previous = lastInterfaces, previous != interfaces else { return }
            client?.reconnectNow()
        }
        monitor.start(queue: .global(qos: .utility))
        relayPathMonitor = monitor
    }

    @objc private func workspaceWillSleep() {
        hangWatchdogAwakeState.value = .displaySleep
        lifecycleRecorder?.record("hang_watchdog_awake state=displaySleep")
        directAccessSupervisor?.suspend()
    }

    @objc private func workspaceDidWake() {
        hangWatchdogAwakeState.value = .awake
        lifecycleRecorder?.record("hang_watchdog_awake state=awake")
        relayHostClient?.reconnectNow()
        guard let context else { return }
        let remoteEnabled = ((try? context.settingsRepo.get("remote_access_enabled")) ?? "0") == "1"
        do {
            try directAccessSupervisor?.resume(remoteEnabled: remoteEnabled)
        } catch {
            NSLog("Failed to restart HTTP server after wake: \(error)")
            recordServerStartupFailure("HTTP server", reason: error.localizedDescription)
        }
    }

    /// Invoked when KeybindingsSettingsPane posts `.rc2KeybindingsReloaded`
    /// (file-watcher change or manual Reload). The cache is already invalidated
    /// by the pane before the post; re-running applyKeybindingOverride here
    /// reads the updated file and sets the live keyEquivalent on every menu item
    /// that participates in keybindings.json without a relaunch.
    @objc private func keybindingsReloaded() {
        // Cache was already invalidated by the pane; calling invalidateCache()
        // again here is a no-op except it guarantees correctness if this observer
        // is ever triggered from a path other than the pane's reload().
        KeybindingConfig.invalidateCache()
        for entry in keybindableMenuItems {
            applyKeybindingOverride(to: entry.item, command: entry.command)
        }
    }

    /// Records a server startup failure, appends to `serverStartupFailures`,
    /// posts a notification, and logs via the lifecycle recorder.
    /// The method is `nonisolated` in name only — callers on the main actor
    /// call it synchronously; the notification is always posted on the main thread.
    private func recordServerStartupFailure(_ server: String, reason: String) {
        serverStartupFailures.append((server: server, reason: reason))
        lifecycleRecorder?.record("server_startup_failure server=\(server) reason=\(reason)")
        if let context {
            do {
                try Self.projectPetServerFailure(
                    server: server,
                    repository: NotificationRepository(db: context.db)
                )
            } catch {
                appLifecycleLog.error("pet.server_failure_projection_failed error=\(error.localizedDescription, privacy: .public)")
            }
            // A listener failure is an alert held 8 s (flap); a restart that
            // binds inside the window resolves it before it posts (§4).
            if context.titioNoticeCenter.isEnabled(SettingsStore(db: context.db).load()) {
                context.titioNoticeCenter.ingest(TitioNoticeFact(
                    // One row per failure: a listener that fails again after
                    // a recovery must alert again. `sourceResolved` with the
                    // base id resolves every open occurrence.
                    key: TitioNoticeIDs.occurrence(
                        of: Self.petServerFailureID(server: server),
                        String(Int64(Date().timeIntervalSince1970 * 1_000))
                    ),
                    kind: .serverListenerFailed,
                    facts: TitioNoticeFacts(
                        title: server,
                        port: server == "HTTP server" ? Int(DirectAccessConfiguration.port()) : nil
                    )
                ))
            }
        }
        NotificationCenter.default.post(name: Self.serverStartupFailureNotification, object: self)
    }

    static func petServerFailureID(server: String) -> String {
        var stableServer = ""
        stableServer.reserveCapacity(server.count)
        for scalar in server.lowercased() {
            stableServer.append(scalar.isLetter || scalar.isNumber ? scalar : "-")
        }
        return "pet.server-failure.\(stableServer)"
    }

    @discardableResult
    static func projectPetServerFailure(
        server: String,
        repository: NotificationRepository
    ) throws -> String {
        let id = petServerFailureID(server: server)
        let category = PetNotificationCategory.serverListenerFailed
        try repository.resurface(AppNotification(
            id: id,
            title: category.presentation.title,
            body: nil,
            category: category.rawValue
        ))
        EventBus.shared.publish(kind: .notificationCreated, payload: .object([
            "id": .string(id),
            "category": .string(category.rawValue)
        ]))
        return id
    }

    static func resolvePetServerFailure(
        server: String,
        repository: NotificationRepository
    ) throws {
        let id = petServerFailureID(server: server)
        try repository.markRead(id: id)
        EventBus.shared.publish(kind: .notificationRead, payload: .object(["id": .string(id)]))
    }

    private func configureDirectAccess() {
        // Clear previous HTTP failure state so re-configure starts fresh.
        serverStartupFailures.removeAll { $0.server == "HTTP server" }

        guard let context, router != nil, localAuth != nil else {
            directAccessSupervisor?.shutdown()
            directAccessSupervisor = nil
            return
        }
        let remoteEnabled = (try? context.settingsRepo.get("remote_access_enabled")) ?? "0"
        let serverId = context.liveActivityHostIdentity.serverId
        let port = DirectAccessConfiguration.port()
        if directAccessSupervisor == nil {
            directAccessSupervisor = DirectAccessLifecycleSupervisor(
                startServer: { [weak self] enabled in
                    try self?.startDirectHTTPServer(remoteEnabled: enabled, serverId: serverId, port: port)
                },
                stopServer: { [weak self] in
                    self?.relayHostClient?.stop()
                    self?.relayHostClient = nil
                    self?.httpServer?.stop()
                    self?.httpServer = nil
                },
                publishBonjour: { [weak self] in
                    self?.publishBonjour(serverId: serverId, port: port)
                },
                stopBonjour: { [weak self] in
                    self?.stopBonjourPublication()
                },
                retryDelays: [1, 2, 4, 8, 16, 30],
                continueRetryingAfterDelays: true,
                retryLogger: { attempt, delay, error in
                    let nsError = error as NSError
                    NSLog("Direct HTTP retry scheduled attempt=\(attempt) delay=\(delay)s reason=\(nsError.domain):\(nsError.code)")
                }
            )
        }
        do {
            try directAccessSupervisor?.configure(remoteEnabled: remoteEnabled == "1")
        } catch {
            NSLog("Failed to start HTTP server: \(error)")
            recordServerStartupFailure("HTTP server", reason: error.localizedDescription)
        }
    }

    private func startDirectHTTPServer(remoteEnabled: Bool, serverId: String, port: UInt16) throws {
        guard let context, let router, let auth = localAuth else { return }
        let loopbackOnly = !remoteEnabled
        let keepAliveSeconds = DirectHTTPServer.resolvedHttpKeepAliveIdleTimeoutSeconds(
            experimentEnabled: ConnectionFeatureFlags.transportKeepaliveExperimentEnabled
        )
        let attachmentStore = AgentAttachmentStore(
            root: context.appSupportDirectory
                .appendingPathComponent("agent-attachments", isDirectory: true)
        )
        let attachmentUploadV2Store = AttachmentUploadV2Store(
            root: context.appSupportDirectory
                .appendingPathComponent("agent-attachment-uploads-v2", isDirectory: true),
            attachmentStore: attachmentStore
        )
        let attachmentUploadV3Store = AttachmentUploadV3Store(
            plaintextStore: attachmentUploadV2Store
        )
        let dispatcher = JSONRPCDispatcher(
            router: router,
            agentAttachmentUploadCapability: .protectedV3
        )
        let http = DirectHTTPServer(
            port: port,
            loopbackOnly: loopbackOnly,
            dispatcher: dispatcher,
            auth: auth,
            serverId: serverId,
            bootEpoch: context.liveActivityHostIdentity.bootEpoch,
            clientReceiveTimeoutSeconds: keepAliveSeconds,
            attachmentUploadV2Store: attachmentUploadV2Store,
            attachmentUploadV3Store: attachmentUploadV3Store
        )
        try http.start()
        httpServer = http
        configureRelay()
        try? Self.resolvePetServerFailure(
            server: "HTTP server",
            repository: NotificationRepository(db: context.db)
        )
        context.titioNoticeCenter.sourceResolved(key: Self.petServerFailureID(server: "HTTP server"))
        NSLog(
            "Direct HTTP server listening on \(loopbackOnly ? "127.0.0.1" : "0.0.0.0"):\(port) (loopback=\(loopbackOnly) keepAliveIdle=\(keepAliveSeconds)s wakePhaseA=\(ConnectionFeatureFlags.wakePhaseAEnabled))"
        )
        if loopbackOnly {
            NSLog("Bonjour not published: remote access is disabled")
        }
    }

    /// Pure builder for the Bonjour TXT record (GAP-4/T021). Extracted so the
    /// exact keys/values the iOS client reads before connecting are pinned by
    /// a test; a dropped or renamed key silently makes this Mac undiscoverable
    /// or mis-identified. Values are UTF-8 Data exactly as `setTXTRecord` needs.
    nonisolated static func bonjourTXTRecord(serverId: String, version: String) -> [String: Data] {
        [
            "server_id": Data(serverId.utf8),
            "app": Data("remotecode".utf8),
            "version": Data(version.utf8),
            "api": Data("2".utf8)
        ]
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About MacCode", action: #selector(showAbout), keyEquivalent: ""))
        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let checkUpdatesItem = NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        checkUpdatesItem.target = self
        appMenu.addItem(checkUpdatesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide MacCode", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit MacCode", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let newWS = NSMenuItem(title: "New Workspace…", action: #selector(newWorkspace), keyEquivalent: "n")
        newWS.target = self
        fileMenu.addItem(newWS)
        // UX-MAC_SHELL_WINDOW-005: standard Open Recent submenu, populated
        // by AppKit from noteNewRecentDocumentURL; selections route through
        // application(_:open:) which opens the folder as a workspace.
        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        let clearRecent = NSMenuItem(title: "Clear Menu", action: Selector(("clearRecentDocuments:")), keyEquivalent: "")
        openRecentMenu.addItem(clearRecent)
        openRecent.submenu = openRecentMenu
        fileMenu.addItem(openRecent)
        fileMenu.addItem(.separator())
        // UX-MAC_SHELL_WINDOW-003: ⌘W closes the focused tab when one
        // exists; it only closes the window when the workspace has none.
        let closeTab = NSMenuItem(title: "Close Tab", action: #selector(closeActiveTabOrWindow), keyEquivalent: "w")
        closeTab.target = self
        fileMenu.addItem(closeTab)
        let reopenTab = NSMenuItem(title: "Reopen Closed Tab", action: #selector(reopenClosedTab), keyEquivalent: "t")
        reopenTab.keyEquivalentModifierMask = [.command, .shift]
        reopenTab.target = self
        fileMenu.addItem(reopenTab)
        let closeWin = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWin.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWin)
        fileMenuItem.submenu = fileMenu

        // Edit
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        // UX-MAC_SHELL_WINDOW-008: Undo/Redo route through the responder chain
        // to the first-responder's NSUndoManager (rename fields, description
        // editors, prompt composer). Without these items ⌘Z produces no result.
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        // View
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let paletteItem = NSMenuItem(title: "Show Command Palette", action: #selector(togglePalette), keyEquivalent: "k")
        paletteItem.keyEquivalentModifierMask = [.command]
        paletteItem.target = self
        // C5: ~/.remotecode/keybindings.json may rebind the palette.
        applyKeybindingOverride(to: paletteItem, command: "commandPalette.toggle")
        keybindableMenuItems = [(item: paletteItem, command: "commandPalette.toggle")]
        viewMenu.addItem(paletteItem)
        let petItem = NSMenuItem(
            title: "Open Titio",
            action: #selector(togglePetPopoverFromMenu),
            keyEquivalent: "p"
        )
        petItem.keyEquivalentModifierMask = [.command, .option]
        petItem.target = self
        viewMenu.addItem(petItem)
        viewMenu.addItem(.separator())
        let revealDiagnostics = NSMenuItem(title: "Reveal Diagnostics in Finder", action: #selector(revealDiagnosticsInFinder), keyEquivalent: "")
        revealDiagnostics.target = self
        viewMenu.addItem(revealDiagnostics)
        viewItem.submenu = viewMenu

        // Surface
        let surfaceItem = NSMenuItem()
        mainMenu.addItem(surfaceItem)
        let surfaceMenu = NSMenu(title: "Surface")
        let term = NSMenuItem(title: "New Terminal Surface", action: #selector(newTerminal), keyEquivalent: "t")
        term.target = self
        let browser = NSMenuItem(title: "New Browser Surface", action: #selector(newBrowser), keyEquivalent: "b")
        browser.target = self
        let agent = NSMenuItem(title: "New Agent App Surface", action: #selector(newAgentApp), keyEquivalent: "g")
        agent.target = self
        surfaceMenu.addItem(term)
        surfaceMenu.addItem(browser)
        surfaceMenu.addItem(agent)
        surfaceMenu.addItem(.separator())
        // UX-MAC_SHELL_WINDOW-004: keyboard splits, defaulting to Terminal.
        let splitRight = NSMenuItem(title: "Split Right", action: #selector(splitFocusedPaneRight), keyEquivalent: "d")
        splitRight.keyEquivalentModifierMask = [.command]
        splitRight.target = self
        let splitDown = NSMenuItem(title: "Split Down", action: #selector(splitFocusedPaneDown), keyEquivalent: "d")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        splitDown.target = self
        surfaceMenu.addItem(splitRight)
        surfaceMenu.addItem(splitDown)
        surfaceItem.submenu = surfaceMenu

        // Tab
        // UX-MAC_SHELL_WINDOW-002: keyboard navigation for the tab strip.
        let tabItem = NSMenuItem()
        mainMenu.addItem(tabItem)
        let tabMenu = NSMenu(title: "Tab")
        let nextTab = NSMenuItem(title: "Next Tab", action: #selector(selectNextTab), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        nextTab.target = self
        let prevTab = NSMenuItem(title: "Previous Tab", action: #selector(selectPreviousTab), keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        prevTab.target = self
        tabMenu.addItem(nextTab)
        tabMenu.addItem(prevTab)
        tabMenu.addItem(.separator())
        for n in 1...9 {
            let item = NSMenuItem(title: "Select Tab \(n)", action: #selector(selectTabByNumber(_:)), keyEquivalent: "\(n)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = n
            item.target = self
            tabMenu.addItem(item)
        }
        tabMenu.addItem(.separator())
        let nextPane = NSMenuItem(title: "Focus Next Pane", action: #selector(focusNextPane), keyEquivalent: "\t")
        nextPane.keyEquivalentModifierMask = [.control]
        nextPane.target = self
        tabMenu.addItem(nextPane)
        tabItem.submenu = tabMenu

        // Window
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - About panel

    /// Pure helper: builds the options dict for `orderFrontStandardAboutPanel`.
    ///
    /// Rules:
    ///   - `version` is always included as `.applicationVersion`.
    ///   - `build` is included as `.version` only when it is non-nil and
    ///     differs from `version` (avoids a redundant "1.2.3 (1.2.3)" line).
    ///   - For non-stable channels a credits line naming the channel is
    ///     included so the build provenance is visible in the About panel.
    nonisolated static func aboutPanelOptions(
        version: String,
        build: String?,
        channel: ReleaseChannel
    ) -> [NSApplication.AboutPanelOptionKey: Any] {
        var opts: [NSApplication.AboutPanelOptionKey: Any] = [:]
        opts[.applicationVersion] = version
        if let build, build != version {
            opts[.version] = build
        }
        if channel != .stable {
            opts[.credits] = NSAttributedString(string: channel.rawValue)
        }
        return opts
    }

    @objc private func showAbout() {
        let opts = Self.aboutPanelOptions(
            version: AppVersion.short,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            channel: channel
        )
        NSApp.orderFrontStandardAboutPanel(options: opts)
    }

    /// Opens the diagnostics folder in Finder so users can locate and attach
    /// lifecycle.log when filing a bug report about silent app disappearances.
    @objc private func revealDiagnosticsInFinder() {
        let dir = AppPaths.appSupportDirectory(for: channel, override: appSupportOverride)
            .appendingPathComponent("diagnostics", isDirectory: true)
        // Ensure directory exists even if no events have been recorded yet.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// Non-blocking pairing sheet with live countdown tied to the request TTL.
    /// Replaces the blocking runModal so the main run loop is never stalled.
    /// Auto-dismisses when the TTL expires; the user can Approve or Deny at
    /// any point before expiry. Once dismissed (any path) the timer is cancelled.
    var pairingSheet: NSPanel?
    private var pairingSheetTimer: Timer?
    private var pairingCountdownLabel: NSTextField?
    private var pairingAlwaysAllowCheckbox: NSButton?
    private var pairingPromptPending: PairingPrompt?

    static let pairingPanelStyleMask: NSWindow.StyleMask = [.titled]

    // PERF: DateFormatter is expensive; pairing sheet shows created-at per prompt.
    private static let pairingCreatedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    static func configurePairingPanel(_ panel: NSPanel) {
        panel.title = "Pairing Request"
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.collectionBehavior.insert(.moveToActiveSpace)
        panel.hidesOnDeactivate = false
    }

    static func pairingPanelFrame(panelSize: NSSize, visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.midY - panelSize.height / 2,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    func presentPairingPrompt(_ prompt: PairingPrompt) {
        if LocalAuthAdapter.isE2EPairingAutoApproveEnabled {
            localAuth?.approvePairingRequest(prompt.requestId)
            NSLog("pairing.prompt.e2e_auto_approve request_id=%@", prompt.requestId)
            return
        }
        // Only one pairing sheet at a time. If a new request arrives while one
        // is open, deny the pending one first to avoid leaking approval state.
        if let pending = pairingPromptPending {
            localAuth?.denyPairingRequest(pending.requestId)
            dismissPairingSheet()
        }
        pairingPromptPending = prompt

        let ttl = prompt.expiresAt.timeIntervalSince(prompt.createdAt)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 290),
            styleMask: Self.pairingPanelStyleMask,
            backing: .buffered,
            defer: false
        )
        Self.configurePairingPanel(panel)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 290))

        // Device name label
        let heading = NSTextField(labelWithString: "Allow \"\(prompt.deviceName)\" to connect?")
        heading.font = NSFont.boldSystemFont(ofSize: 14)
        heading.alignment = .center
        heading.frame = NSRect(x: 20, y: 240, width: 360, height: 20)
        content.addSubview(heading)

        // UX-P2: always show the confirmation instruction; append source IP when
        // available so the user can cross-check the device identity without losing
        // the "check the code" prompt that was previously replaced by the IP.
        let infoText: String
        if let ip = prompt.sourceIP {
            infoText = "Confirm this code matches the device (from \(ip)):"
        } else {
            infoText = "Confirm this code matches the device:"
        }
        let info = NSTextField(labelWithString: infoText)
        info.alignment = .center
        info.textColor = .secondaryLabelColor
        info.frame = NSRect(x: 20, y: 215, width: 360, height: 18)
        content.addSubview(info)

        // Code display — expose digits individually for VoiceOver so the user
        // can verify each digit of the security code without mental grouping.
        let codeField = NSTextField(labelWithString: prompt.code)
        codeField.font = NSFont.monospacedDigitSystemFont(ofSize: 36, weight: .bold)
        codeField.alignment = .center
        codeField.frame = NSRect(x: 20, y: 155, width: 360, height: 50)
        codeField.setAccessibilityLabel(Self.pairingCodeAccessibilityLabel(prompt.code))
        content.addSubview(codeField)

        // Created-at detail — DateFormatter is expensive; reuse one.
        let createdLabel = NSTextField(labelWithString: "Requested at \(Self.pairingCreatedAtFormatter.string(from: prompt.createdAt))")
        createdLabel.alignment = .center
        createdLabel.font = NSFont.systemFont(ofSize: 11)
        createdLabel.textColor = .secondaryLabelColor
        createdLabel.frame = NSRect(x: 20, y: 135, width: 360, height: 16)
        content.addSubview(createdLabel)

        // Countdown label
        let countdown = NSTextField(labelWithString: "")
        countdown.alignment = .center
        countdown.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countdown.textColor = .secondaryLabelColor
        countdown.frame = NSRect(x: 20, y: 105, width: 360, height: 20)
        content.addSubview(countdown)
        pairingCountdownLabel = countdown

        if prompt.clientDeviceID != nil {
            let alwaysAllow = NSButton(checkboxWithTitle: "Always allow this device", target: nil, action: nil)
            alwaysAllow.frame = NSRect(x: 20, y: 70, width: 360, height: 22)
            alwaysAllow.toolTip = "Future pairing requests from this same device will be approved automatically until you turn this off in Settings."
            alwaysAllow.setAccessibilityIdentifier("pairing.alwaysAllow")
            content.addSubview(alwaysAllow)
            pairingAlwaysAllowCheckbox = alwaysAllow
        }

        // Approve button
        let approveBtn = NSButton(title: "Approve", target: self, action: #selector(pairingApprove))
        approveBtn.keyEquivalent = "\r"
        approveBtn.frame = NSRect(x: 220, y: 16, width: 160, height: 44)
        content.addSubview(approveBtn)

        // Deny button
        let denyBtn = NSButton(title: "Deny", target: self, action: #selector(pairingDeny))
        denyBtn.frame = NSRect(x: 20, y: 16, width: 160, height: 44)
        content.addSubview(denyBtn)

        panel.contentView = content
        pairingSheet = panel

        // Update countdown immediately, then each second.
        updatePairingCountdown(prompt: prompt, ttl: ttl)
        pairingSheetTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let p = self.pairingPromptPending else { return }
            if PairingCountdown.expired(createdAt: p.createdAt, ttl: ttl, now: Date()) {
                self.localAuth?.denyPairingRequest(p.requestId)
                self.dismissPairingSheet()
            } else {
                self.updatePairingCountdown(prompt: p, ttl: ttl)
            }
        }

        let anchorWindow = keyWindowProviderForTests?() ?? NSApp.keyWindow ?? windowController?.window
        if let visibleFrame = (anchorWindow?.screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrame(
                Self.pairingPanelFrame(panelSize: panel.frame.size, visibleFrame: visibleFrame),
                display: false
            )
        } else {
            panel.center()
        }

        if !LocalAuthAdapter.isE2EPairingAutoApproveEnabled {
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
        }
        NSLog(
            "pairing.prompt.presented request_id=%@ visible=%d key=%d",
            prompt.requestId,
            panel.isVisible ? 1 : 0,
            panel.isKeyWindow ? 1 : 0
        )
    }

    private func updatePairingCountdown(prompt: PairingPrompt, ttl: TimeInterval) {
        let secs = PairingCountdown.remainingSecs(createdAt: prompt.createdAt, ttl: ttl, now: Date())
        let intSecs = Int(secs.rounded(.up))
        pairingCountdownLabel?.stringValue = "Expires in \(intSecs)s"
    }

    @objc private func pairingApprove() {
        guard let prompt = pairingPromptPending else { return }
        let alwaysAllowPairing = pairingAlwaysAllowCheckbox?.state == .on
        NSLog(
            "pairing.prompt.approved request_id=%@ always_allow=%d",
            prompt.requestId,
            alwaysAllowPairing ? 1 : 0
        )
        localAuth?.approvePairingRequest(
            prompt.requestId,
            alwaysAllowPairing: alwaysAllowPairing
        )
        dismissPairingSheet()
    }

    @objc private func pairingDeny() {
        guard let prompt = pairingPromptPending else { return }
        NSLog("pairing.prompt.denied request_id=%@", prompt.requestId)
        localAuth?.denyPairingRequest(prompt.requestId)
        dismissPairingSheet()
    }

    /// Dismiss the approve/deny modal only if it is currently showing the
    /// request the device just cancelled. A no-op when no sheet is open or a
    /// different request is shown, so it never disturbs an unrelated prompt.
    private func dismissPairingSheetIfShowing(requestId: String) {
        guard pairingPromptPending?.requestId == requestId else { return }
        dismissPairingSheet()
    }

    func dismissPairingSheet() {
        let requestId = pairingPromptPending?.requestId ?? "none"
        pairingSheetTimer?.invalidate()
        pairingSheetTimer = nil
        pairingSheet?.close()
        pairingSheet = nil
        pairingCountdownLabel = nil
        pairingAlwaysAllowCheckbox = nil
        pairingPromptPending = nil
        NSLog("pairing.prompt.dismissed request_id=%@", requestId)
    }

    private func applyKeybindingOverride(to item: NSMenuItem, command: String) {
        let cfg = KeybindingConfig.loadDefaultPath()
        guard let binding = cfg.bindings.last(where: { $0.command == command }) else { return }
        var mask: NSEvent.ModifierFlags = []
        var ch = ""
        for t in binding.key.split(separator: "+").map(String.init) {
            switch t {
            case "mod": mask.insert(.command)
            case "ctrl": mask.insert(.control)
            case "alt", "opt": mask.insert(.option)
            case "shift": mask.insert(.shift)
            default: ch = t
            }
        }
        if !ch.isEmpty { item.keyEquivalent = ch; item.keyEquivalentModifierMask = mask }
    }

    @objc private func togglePalette() {
        palette?.toggle()
    }

    @objc private func togglePetPopoverFromMenu() {
        if !togglePetPopover() {
            NSSound.beep()
        }
    }

    let titioQuickChat = TitioQuickChatController()

    func togglePetPopover() -> Bool {
        petController?.togglePopoverFromKeyboard() == true
    }

    @objc private func showSettings() {
        if let windowController {
            windowController.presentSettingsInMainContent()
            return
        }
        if let window = windowController?.window {
            settings?.show(attachedTo: window)
        } else {
            settings?.show()
        }
    }

    func makeSettingsWindowController(
        context: AppContext,
        updater: AppUpdateChecking?,
        loadImmediately: Bool = true
    ) -> SettingsWindowController {
        SettingsWindowController(
            context: context,
            updater: updater,
            loadImmediately: loadImmediately
        )
    }

    @objc func checkForUpdatesAction() {
        updater?.checkForUpdates()
    }

    // MARK: - NSMenuItemValidation

    /// Selectors that require at least one workspace to exist before they make
    /// any sense. Without a workspace the actions either beep (runtime guard) or
    /// crash; greying them out lets the responder chain give proper feedback and
    /// VoiceOver say "dimmed" instead of silently doing nothing.
    static let workspaceRequiredActions: Set<String> = [
        NSStringFromSelector(#selector(AppDelegate.newTerminal)),
        NSStringFromSelector(#selector(AppDelegate.newBrowser)),
        NSStringFromSelector(#selector(AppDelegate.newAgentApp)),
        NSStringFromSelector(#selector(AppDelegate.splitFocusedPaneRight)),
        NSStringFromSelector(#selector(AppDelegate.splitFocusedPaneDown)),
        NSStringFromSelector(#selector(AppDelegate.selectNextTab)),
        NSStringFromSelector(#selector(AppDelegate.selectPreviousTab)),
        NSStringFromSelector(#selector(AppDelegate.closeActiveTabOrWindow)),
        NSStringFromSelector(#selector(AppDelegate.reopenClosedTab)),
        NSStringFromSelector(#selector(AppDelegate.focusNextPane))
    ]

    /// Pure helper: given a menu item action selector and whether an updater is
    /// configured, returns whether the item should be enabled.
    /// Extracted for unit-testing without any AppKit or @MainActor dependency.
    public static func menuItemEnabled(action: Selector, updaterConfigured: Bool) -> Bool {
        if action == #selector(AppDelegate.checkForUpdatesAction) {
            return updaterConfigured
        }
        // All other items this delegate owns are unconditionally enabled.
        return true
    }

    /// Extended helper: also accounts for workspace presence for surface/tab
    /// actions. Kept separate so the existing `menuItemEnabled` signature is
    /// preserved and existing tests continue to compile unchanged.
    ///
    /// WHY: without `hasWorkspace` checks the Surface/Tab menu items are always
    /// active and produce a beep when no workspace is open — confusing for both
    /// sighted users and VoiceOver (UX-MAC_SHELL_WINDOW-013).
    public static func menuItemEnabled(
        action: Selector,
        updaterConfigured: Bool,
        hasWorkspace: Bool
    ) -> Bool {
        if workspaceRequiredActions.contains(NSStringFromSelector(action)) {
            return hasWorkspace
        }
        return menuItemEnabled(action: action, updaterConfigured: updaterConfigured)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        let hasWorkspace = context?.state.window.selectedWorkspaceID != nil
        return Self.menuItemEnabled(action: action,
                                    updaterConfigured: updater != nil,
                                    hasWorkspace: hasWorkspace)
    }

    @objc private func newWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            _ = try? router.createWorkspace(name: url.lastPathComponent, cwd: url.path)
            // UX-MAC_SHELL_WINDOW-005: feed File ▸ Open Recent.
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
    }

    @objc private func newTerminal() { newSurface(type: .terminal) }
    @objc private func newBrowser() { newSurface(type: .browser) }
    @objc private func newAgentApp() { newSurface(type: .agentApp) }

    private func newSurface(type: SurfaceType) {
        guard let wid = context.state.window.selectedWorkspaceID else { NSSound.beep(); return }
        _ = try? router.createSurface(workspace: wid, type: type, paneID: nil, title: nil)
    }

    // UX-MAC_SHELL_WINDOW-004: keyboard split entry points. The key window
    // decides which workspace the split lands in: a detached workspace window
    // owns its own panes.
    @objc private func splitFocusedPaneRight() {
        let keyWindow = keyWindowProviderForTests?() ?? NSApp.keyWindow
        if windowController?.splitFocusedPane(.right, in: keyWindow) != true { NSSound.beep() }
    }

    @objc private func splitFocusedPaneDown() {
        let keyWindow = keyWindowProviderForTests?() ?? NSApp.keyWindow
        if windowController?.splitFocusedPane(.down, in: keyWindow) != true { NSSound.beep() }
    }

    // MARK: - Tab keyboard navigation (UX-MAC_SHELL_WINDOW-002/003)

    /// The focused pane of the selected workspace, plus its ordered
    /// surfaces and the currently selected surface index.
    ///
    /// The window that owns the keyboard picks the workspace: with a workspace
    /// detached into its own window (or a bot window in front), stepping the
    /// main window's tabs would change a tab the user is not looking at.
    private func focusedPaneContext() -> (workspace: WorkspaceID, surfaces: [SurfaceDescriptor], selectedIndex: Int)? {
        let keyWindow = keyWindowProviderForTests?() ?? NSApp.keyWindow
        guard let wid = windowController?.tabNavigationWorkspace(in: keyWindow),
              let ws = context?.state.workspaces[wid] else { return nil }
        let paneID = ws.focusedPaneID ?? ws.layout.paneIDs().first
        guard let paneID, let pane = ws.layout.find(paneID: paneID),
              !pane.surfaces.isEmpty else { return nil }
        let selected = pane.selectedSurfaceID ?? pane.surfaces.first?.id
        let index = pane.surfaces.firstIndex { $0.id == selected } ?? 0
        return (wid, pane.surfaces, index)
    }

    @objc private func selectNextTab() { stepTab(by: 1) }
    @objc private func selectPreviousTab() { stepTab(by: -1) }

    private func stepTab(by delta: Int) {
        guard let ctx = focusedPaneContext(), ctx.surfaces.count > 1 else { NSSound.beep(); return }
        let count = ctx.surfaces.count
        let next = ((ctx.selectedIndex + delta) % count + count) % count
        try? router?.focusSurface(workspace: ctx.workspace, surface: ctx.surfaces[next].id)
    }

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        guard let ctx = focusedPaneContext(),
              sender.tag >= 1, sender.tag <= ctx.surfaces.count else { NSSound.beep(); return }
        try? router?.focusSurface(workspace: ctx.workspace, surface: ctx.surfaces[sender.tag - 1].id)
    }

    @objc private func closeActiveTabOrWindow() {
        let keyWindow = keyWindowProviderForTests?() ?? NSApp.keyWindow
        if keyWindow === settings?.window {
            settings?.close()
            return
        }
        // Route through the window controller so the focused pane's
        // unsaved-changes confirm runs; fall back to closing the key
        // window only when no surface is open. The key window picks the
        // target: with a workspace detached into its own window, ⌘W closes a
        // tab of THAT window, not of the main window behind it.
        if windowController?.closeFocusedSurface(in: keyWindow) == true { return }
        (keyWindow ?? window)?.performClose(nil)
    }

    @objc private func reopenClosedTab() {
        guard let wid = context?.state.window.selectedWorkspaceID,
              let router else { NSSound.beep(); return }
        do {
            // Returns nil when the closed-tab buffer is empty; beep in that case.
            if try router.reopenClosedSurface(workspace: wid) == nil {
                NSSound.beep()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func focusNextPane() {
        guard let wid = context?.state.window.selectedWorkspaceID,
              let ws = context?.state.workspaces[wid] else { NSSound.beep(); return }
        let paneIDs = ws.layout.paneIDs()
        guard paneIDs.count > 1 else { NSSound.beep(); return }
        let current = ws.focusedPaneID ?? paneIDs.first
        let idx = current.flatMap { paneIDs.firstIndex(of: $0) } ?? 0
        let nextPane = paneIDs[(idx + 1) % paneIDs.count]
        guard let pane = ws.layout.find(paneID: nextPane),
              let surface = pane.selectedSurfaceID ?? pane.surfaces.first?.id else { NSSound.beep(); return }
        try? router?.focusSurface(workspace: wid, surface: surface)
    }

    private var window: NSWindow? { windowController?.window }

    // MARK: - Denied-notification in-app fallback (UX-MAC_APPSHELL-P2)

    static let notificationsDeniedPetID = "pet.notifications.denied"

    @discardableResult
    static func projectPetNotificationsDenied(
        content: RemoteCodeNotificationContent,
        repository: NotificationRepository
    ) throws -> String {
        let workspaceID = content.userInfo["workspaceId"]
            .flatMap(UUID.init(uuidString:))
            .map(WorkspaceID.init)
        let category = PetNotificationCategory.notificationsDenied
        let id = notificationsDeniedPetID
        try repository.resurface(AppNotification(
            id: id,
            workspaceId: workspaceID,
            title: category.presentation.title,
            body: category.presentation.detail,
            category: category.rawValue
        ))
        var payload: [String: JSONValue] = [
            "id": .string(id),
            "category": .string(category.rawValue)
        ]
        if let workspaceID {
            payload["workspace_id"] = .string(workspaceID.value.uuidString)
        }
        EventBus.shared.publish(kind: .notificationCreated, payload: .object(payload))
        return id
    }

    /// Invoked by `SystemNotifier.shared.onDeniedPost`. Posts
    /// `SystemNotifier.rc2NotificationsDeniedPost` on the default
    /// `NotificationCenter` the first time it is called; subsequent calls
    /// are no-ops so the user is never spammed across multiple run completions.
    ///
    /// The once-only gate is a session-local `Bool` — intentionally not
    /// persisted, because the notice is only meaningful when the user is
    /// present and can act on it (open System Settings > Notifications).
    func handleDeniedPost(_ content: RemoteCodeNotificationContent) {
        guard Self.shouldFireDeniedNotice(alreadyFired: notificationsDeniedNoticeFired) else { return }
        notificationsDeniedNoticeFired = true
        if let context {
            // In-app only (no banner, no push): the denied banner is why we are here.
            if context.titioNoticeCenter.isEnabled(SettingsStore(db: context.db).load()) {
                context.titioNoticeCenter.ingest(TitioNoticeFact(
                    key: TitioNoticeIDs.notificationsDenied,
                    kind: .notificationsDenied
                ))
            }
            do {
                _ = try Self.projectPetNotificationsDenied(
                    content: content,
                    repository: NotificationRepository(db: context.db)
                )
            } catch {
                appLifecycleLog.error("pet.notifications_denied_projection_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
        NotificationCenter.default.post(
            name: SystemNotifier.rc2NotificationsDeniedPost,
            object: self,
            userInfo: [
                "id": Self.notificationsDeniedPetID,
                "threadId": content.userInfo["threadId"] ?? "",
                "workspaceId": content.userInfo["workspaceId"] ?? ""
            ]
        )
    }

    /// Pure gate: returns true iff the once-only denied notice has not yet
    /// fired this session. Extracted so the decision is testable without
    /// any AppKit or @MainActor dependency.
    nonisolated static func shouldFireDeniedNotice(alreadyFired: Bool) -> Bool {
        !alreadyFired
    }

    // MARK: - Notification deep-link routing

    private var notificationRouteGeneration = UUID()

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        let stringInfo = Dictionary(userInfo.compactMap { (k, v) -> (String, String)? in
            guard let ks = k as? String, let vs = v as? String else { return nil }
            return (ks, vs)
        }, uniquingKeysWith: { a, _ in a })
        openNotificationUserInfo(stringInfo)
    }

    /// Opens a notification-shaped route: a banner click, or a Titio notice
    /// card's navigation option (the same `[String: String]` map, hub spec §7).
    func openNotificationUserInfo(_ stringInfo: [String: String]) {
        notificationRouteGeneration = UUID()
        let generation = notificationRouteGeneration
        guard let intent = Self.routeFromNotification(userInfo: stringInfo) else { return }
        if let bot = intent.bot {
            openBotNotificationRoute(bot, generation: generation)
            return
        }
        if intent.opensActivity {
            windowController?.openActivityRoute(intent: intent)
            return
        }
        guard let threadId = intent.threadId else { return }
        do {
            switch try router?.agentThreadOpenDestination(threadId) ?? .unavailable {
            case .bot(let botID, let conversationID):
                openBotNotificationRoute(
                    NotificationRouteIntent.BotRoute(
                        botId: botID,
                        conversationId: conversationID,
                        messageId: intent.finalMessageId
                    ),
                    generation: generation
                )
                return
            case .unavailable:
                NSLog("RemoteCode notification route unavailable thread=%@", threadId.value.uuidString)
                return
            case .workspace:
                break
            }
            let surface = try openNotificationRoute(intent)
            guard let messageID = intent.finalMessageId else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.notificationRouteGeneration == generation,
                      let agent = SurfaceRegistry.shared.surface(surface.id) as? AgentAppSurface,
                      agent.viewModel.selectedThreadId == threadId else { return }
                do {
                    try await agent.viewModel.revealMessage(id: messageID, expectedThreadID: threadId)
                } catch {
                    NSLog("RemoteCode notification target missing thread=%@ message=%@ error=%@",
                          threadId.value.uuidString, messageID.description, error.localizedDescription)
                }
            }
        } catch {
            NSLog("RemoteCode notification route failed thread=%@ error=%@",
                  threadId.value.uuidString, error.localizedDescription)
        }
    }

    /// Opens the Bots desk at the notice's conversation, then reveals the
    /// message on the embedded desk once its Agent App view model is bound.
    private func openBotNotificationRoute(_ bot: NotificationRouteIntent.BotRoute, generation: UUID) {
        guard let router else { return }
        do {
            guard try router.openBotsDesk(botID: bot.botId, conversationID: bot.conversationId) else { return }
        } catch {
            NSLog("RemoteCode notification bot route failed bot=%@ conversation=%@ error=%@",
                  bot.botId.value.uuidString, bot.conversationId.value.uuidString, error.localizedDescription)
            return
        }
        guard let messageID = bot.messageId else { return }
        Task { @MainActor [weak self] in
            // The desk binds its Agent App view model on the next turns; give it a
            // short bounded wait, then reveal best-effort.
            for _ in 0..<20 {
                guard let self, self.notificationRouteGeneration == generation else { return }
                if let vm = router.botsViewModel?.deskAgentVM,
                   let selected = router.botsViewModel?.selectedConversation,
                   selected.botID == bot.botId,
                   selected.id == bot.conversationId,
                   let threadID = selected.linkedAgentThreadID,
                   vm.selectedThreadId == threadID {
                    try? await vm.revealMessage(id: messageID, expectedThreadID: threadID)
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Testable notification seam. The thread repository is authoritative for
    /// workspace selection; `workspaceId` remains payload metadata for backwards
    /// compatibility. The canonical router verifies exact surface binding before
    /// marking the notification's thread read.
    @discardableResult
    func openNotificationRoute(_ intent: NotificationRouteIntent) throws -> SurfaceDescriptor {
        guard let router else { throw LayoutError.workspaceNotFound }
        guard let threadId = intent.threadId else { throw LayoutError.workspaceNotFound }
        return try router.openAgentThread(thread: threadId, markRead: false)
    }

    /// Pure mapper: notification userInfo -> RouteIntent.
    /// Returns nil when `threadId` key is absent or not a valid UUID.
    /// `workspaceId` is optional; absent or invalid value yields nil workspace.
    public static func routeFromNotification(userInfo: [String: String]) -> NotificationRouteIntent? {
        // Bot branch first: a Titio notice opens its conversation. Payloads
        // without both ids (every legacy payload) fall through unchanged.
        if let botId = userInfo["botId"].flatMap(UUID.init(uuidString:)).map(BotID.init),
           let conversationId = userInfo["conversationId"].flatMap(UUID.init(uuidString:)).map(BotConversationID.init) {
            return NotificationRouteIntent(
                threadId: nil,
                workspaceId: nil,
                bot: NotificationRouteIntent.BotRoute(
                    botId: botId,
                    conversationId: conversationId,
                    messageId: userInfo["messageId"].flatMap(UUID.init(uuidString:)).map(AgentMessageID.init)
                )
            )
        }
        let activityItemId = userInfo["activityItemId"].flatMap { value -> String? in
            guard value.utf8.count <= 256,
                  ["run:", "notification:", "scheduled-occurrence:"].contains(where: value.hasPrefix) else { return nil }
            return value
        }
        let opensActivity = userInfo["activityDestination"] == "true" || activityItemId != nil
        let threadId = userInfo["threadId"].flatMap(UUID.init(uuidString:)).map(AgentThreadID.init)
        guard opensActivity || threadId != nil else { return nil }
        let workspaceId = userInfo["workspaceId"]
            .flatMap { UUID(uuidString: $0) }
            .map { WorkspaceID($0) }
        let finalMessageId = opensActivity
            ? nil
            : userInfo["finalMessageId"].flatMap(UUID.init(uuidString:)).map(AgentMessageID.init)
        return NotificationRouteIntent(
            threadId: threadId,
            workspaceId: workspaceId,
            finalMessageId: finalMessageId,
            opensActivity: opensActivity,
            activityItemId: activityItemId
        )
    }

    /// GAP-4: publish `_remotecode._tcp` so the iOS app can find this
    /// Mac on the LAN. TXT carries the stable identity + version so the
    /// client can show it before connecting.
    private func publishBonjour(serverId: String, port: UInt16) {
        let generation = UUID()
        bonjourPublicationGeneration = generation
        bonjourPublishRetryWorkItem?.cancel()
        bonjourPublishRetryWorkItem = nil
        bonjourPublishRetryAttempt = 0
        bonjour?.stop()
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let svc = NetService(domain: "", type: "_remotecode._tcp.", name: name, port: Int32(port))
        let txt = Self.bonjourTXTRecord(serverId: serverId, version: AppVersion.short)
        svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
        let delegate = BonjourDelegate(
            onPublished: { [weak self] in
                guard let self, self.bonjourPublicationGeneration == generation else { return }
                self.bonjourPublicationState = .published
                self.bonjourPublishRetryAttempt = 0
            },
            onFailure: { [weak self] error in
                guard let self, self.bonjourPublicationGeneration == generation else { return }
                self.bonjourPublicationState = .failed
                self.scheduleBonjourPublicationRetry(
                    serverId: serverId, port: port, generation: generation, error: error
                )
            }
        )
        bonjourDelegate = delegate
        svc.delegate = delegate
        bonjourPublicationState = .publishing
        svc.publish()
        bonjour = svc
        NSLog("Bonjour published: \(name) _remotecode._tcp:\(port)")
    }

    private func stopBonjourPublication() {
        bonjourPublishRetryWorkItem?.cancel()
        bonjourPublishRetryWorkItem = nil
        bonjour?.stop()
        bonjour = nil
        bonjourDelegate = nil
        bonjourPublicationGeneration = UUID()
        bonjourPublicationState = .stopped
    }

    private func scheduleBonjourPublicationRetry(
        serverId: String,
        port: UInt16,
        generation: UUID,
        error: Error
    ) {
        guard bonjourPublicationState == .failed else { return }
        let base = min(pow(2, Double(bonjourPublishRetryAttempt)), 30)
        bonjourPublishRetryAttempt += 1
        let delay = base + Double.random(in: 0...(base * 0.25))
        let nsError = error as NSError
        NSLog("Bonjour retry scheduled attempt=\(bonjourPublishRetryAttempt) delay=\(delay)s reason=\(nsError.domain):\(nsError.code)")
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.bonjourPublicationGeneration == generation,
                  self.bonjourPublicationState == .failed else { return }
            self.publishBonjour(serverId: serverId, port: port)
        }
        bonjourPublishRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Logs Bonjour publish outcome; a publish failure must be loud, not
/// silent, or the iOS app simply never sees this Mac (Rule 6).
final class BonjourDelegate: NSObject, NetServiceDelegate {
    private let onPublished: () -> Void
    private let onFailure: (Error) -> Void

    init(onPublished: @escaping () -> Void, onFailure: @escaping (Error) -> Void) {
        self.onPublished = onPublished
        self.onFailure = onFailure
    }

    func netServiceDidPublish(_ sender: NetService) {
        NSLog("Bonjour: did publish \(sender.name)")
        onPublished()
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("Bonjour: FAILED to publish \(sender.name): \(errorDict)")
        onFailure(NSError(domain: "Bonjour", code: errorDict[NetService.errorCode]?.intValue ?? -1, userInfo: errorDict))
    }
}

/// Decoded intent from a tapped notification. Carries the thread (and
/// optionally the workspace) to navigate to. Workspace is absent when
/// the notification payload does not carry `workspaceId` — the router
/// can still find the thread by ID alone.
public struct NotificationRouteIntent: Equatable {
    public let threadId: AgentThreadID?
    public let workspaceId: WorkspaceID?
    public let finalMessageId: AgentMessageID?
    public let opensActivity: Bool
    public let activityItemId: String?
    /// Bot conversation route (Titio notices, hub spec §9): opens the Bots
    /// desk at `conversationId` and reveals `messageId` best-effort.
    public let bot: BotRoute?

    public struct BotRoute: Equatable {
        public let botId: BotID
        public let conversationId: BotConversationID
        public let messageId: AgentMessageID?

        public init(botId: BotID, conversationId: BotConversationID, messageId: AgentMessageID? = nil) {
            self.botId = botId
            self.conversationId = conversationId
            self.messageId = messageId
        }
    }

    public init(
        threadId: AgentThreadID?,
        workspaceId: WorkspaceID?,
        finalMessageId: AgentMessageID? = nil,
        opensActivity: Bool = false,
        activityItemId: String? = nil,
        bot: BotRoute? = nil
    ) {
        self.threadId = threadId
        self.workspaceId = workspaceId
        self.finalMessageId = finalMessageId
        self.opensActivity = opensActivity
        self.activityItemId = activityItemId
        self.bot = bot
    }
}

extension AppDelegate {
    /// Pure helper: builds the informative text for the database-open failure
    /// alert. Extracted for testability without any AppKit side-effects.
    ///
    /// WHY: The copy must tell the user *where* the database is and *how* to
    /// recover — a raw Swift error string does neither. This helper pins the
    /// contract so regression tests catch copy drift.
    nonisolated public static func dbOpenFailureInformativeText(
        supportDir: String,
        errorDescription: String
    ) -> String {
        """
        Your workspaces and settings are stored in:
        \(supportDir)

        To recover: quit MacCode, delete "remotecode.sqlite" from that folder, \
        and relaunch. A backup of the previous database may be present with a \
        ".corrupt-<date>" suffix.

        Technical detail: \(errorDescription)
        """
    }

    /// Pure helper: formats a pairing code for VoiceOver announcement.
    ///
    /// Each character is separated by a single space so VoiceOver reads them
    /// individually ("3 4 2 7 8 1") rather than as a single number
    /// ("three hundred forty-two thousand ..."). The prefix "Pairing code: "
    /// identifies the field role before the digits are announced.
    ///
    /// WHY extracted: testable without any @MainActor or AppKit dependency.
    nonisolated public static func pairingCodeAccessibilityLabel(_ code: String) -> String {
        let spaced = code.map { String($0) }.joined(separator: " ")
        return "Pairing code: \(spaced)"
    }
}

/// Pure, nonisolated helper for pairing sheet countdown math.
/// Extracted from AppDelegate so it can be tested without AppKit or @MainActor.
///
/// WHY: The non-blocking pairing sheet must accurately reflect the server-side
/// 300-second TTL. Errors here cause "time left" / actual expiry drift, which
/// means the user could see an expired prompt or be dismissed before the real
/// deadline. The helper is pure (injected `now`) so tests are deterministic.
public enum PairingCountdown {
    /// Seconds remaining until the request expires, clamped to [0, ttl].
    /// - Parameters:
    ///   - createdAt: When the request was created.
    ///   - ttl: Total TTL in seconds (default 300 for device-initiated pair).
    ///   - now: Current time (injected for testability).
    public static func remainingSecs(createdAt: Date, ttl: TimeInterval, now: Date) -> Double {
        let elapsed = now.timeIntervalSince(createdAt)
        return max(0, ttl - elapsed)
    }

    /// Returns true when `now` is at or past the expiry instant.
    public static func expired(createdAt: Date, ttl: TimeInterval, now: Date) -> Bool {
        now.timeIntervalSince(createdAt) >= ttl
    }
}

extension SurfaceType {
    /// Human-facing label, mirrors cmux terminology.
    public var displayLabel: String {
        switch self {
        case .terminal: return "Terminal"
        case .ssh: return "SSH"
        case .browser: return "Browser"
        case .agentApp: return "Agent App"
        case .files: return "Files"
        case .markdown: return "Markdown"
        case .filePreview: return "File Preview"
        case .rightSidebarTool: return "Right Sidebar Tool"
        }
    }
}

#if DEBUG
extension AppDelegate {
    /// Test seam: synchronously drains the background writer queue after calling
    /// the production CCR retention path so tests can assert pruning without timers.
    ///
    /// WHY: `runCCRRetention` is private and dispatches asynchronously; a test
    /// that bypasses the delegate exercises only the API layer.  This seam drives
    /// the full production path — same store, same queue — then blocks until the
    /// async prune is complete, making the outcome synchronously verifiable.
    /// The 24-hour cadence timer is never installed in these tests, so disk growth
    /// due to an absent scheduling hook will fail this assertion.
    func runCCRRetentionForTesting() {
        runCCRRetention()
        context?.flushWriterQueue()
    }
}
#endif
