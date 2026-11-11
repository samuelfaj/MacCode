import AppKit
import SwiftUI
import CoreModel
import AgentRuntime
import DesignSystemKit
import Persistence
import SocketServer
import Surfaces
import os

// Structured logging for SSH connect/transfer/listing so flaky sessions can be
// diagnosed from logs instead of the short in-memory log (QA-MAC_SSH-006).
private let sshLog = Logger(subsystem: "io.remotecode.appshell", category: "ssh")

/// Internal bridge for registered surfaces backed by a terminal runtime. The
/// router and app-termination barrier use this instead of assuming that every
/// terminal is itself the registered Surface object.
@MainActor
protocol TerminalRuntimeRoutingSurface: AnyObject {
    func routedSendTextStatus(_ text: String) -> TerminalInputStatus
    func routedTextSnapshot() -> TerminalTextSnapshot?
    func routedRuntimeHealth() -> TerminalRuntimeHealth?
    func routedFlushPersistedHistory()
    func routedFlushPersistedHistoryBarrier() -> SurfaceTerminationBarrier?
    func routedClearPersistedHistory()
    func routedReadPersistedHistory(
        beforeChunkID: Int64?,
        maxBytes: Int,
        timeout: TimeInterval
    ) async throws -> TerminalOutputWindow
    func routedRepairTerminalFocus(reason: String)
}

extension TerminalSurface: TerminalRuntimeRoutingSurface {
    func routedSendTextStatus(_ text: String) -> TerminalInputStatus {
        sendTextStatus(text)
    }

    func routedTextSnapshot() -> TerminalTextSnapshot? {
        readTextSnapshot()
    }

    func routedRuntimeHealth() -> TerminalRuntimeHealth? {
        runtimeHealth()
    }

    func routedFlushPersistedHistory() {
        flushPersistedHistory()
    }

    func routedFlushPersistedHistoryBarrier() -> SurfaceTerminationBarrier? {
        flushPersistedHistoryBarrier()
    }

    func routedClearPersistedHistory() {
        clearPersistedHistory()
    }

    func routedReadPersistedHistory(
        beforeChunkID: Int64?,
        maxBytes: Int,
        timeout: TimeInterval
    ) async throws -> TerminalOutputWindow {
        try await readPersistedHistory(
            beforeChunkID: beforeChunkID,
            maxBytes: maxBytes,
            timeout: timeout
        )
    }

    func routedRepairTerminalFocus(reason: String) {
        repairTerminalFocus(reason: reason)
    }
}

@MainActor
protocol SSHTransferSurface: Surface {
    var sshTransferProfile: SSHHostProfile? { get }
    func appendSystemText(_ raw: String)
    /// Terminal that owns this surface's system-output stream, if any.
    var transferTerminal: TerminalSurface? { get }
}

extension SSHTransferSurface {
    var transferTerminal: TerminalSurface? { nil }
}

@MainActor
final class SSHSurface: NSObject, SSHTransferSurface, TerminalRuntimeRoutingSurface {
    private let workspaceID: WorkspaceID
    private let cwd: String
    private weak var router: AppCommandRouter?
    private let settingsRepo: (any SettingsWriteRepository)?
    private let historyRepo: TerminalOutputRepository?
    private let outputBus: SurfaceOutputBus
    private let terminalFontSize: Double
    private let terminalContainer = NSView()
    private let hostResizeHandle = DSResizeHandleView(axis: .vertical)
    private let transferDivider = DSResizeHandleView(axis: .vertical)
    private let viewModel: SSHSurfaceViewModel
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var transferWidthConstraint: NSLayoutConstraint?
    private var transferDividerWidthConstraint: NSLayoutConstraint?
    private var dragStartSidebarWidth: CGFloat?
    private var dragStartTransferWidth: CGFloat?
    private var terminal: TerminalSurface? {
        didSet {
            guard terminal !== oldValue else { return }
            oldValue?.onBusyStateChanged = nil
            terminal?.onBusyStateChanged = { [weak self, weak terminal] busy in
                // Only the current inner terminal may report busy for this tab.
                guard let self, let terminal, self.terminal === terminal else { return }
                self.onBusyStateChanged?(busy)
            }
            // Replacement or disconnect: publish the wrapper's state so a busy
            // row clears when its session goes away.
            if (oldValue?.isBusy ?? false) != isBusy { onBusyStateChanged?(isBusy) }
        }
    }
    var isBusy: Bool { terminal?.isBusy ?? false }
    var onBusyStateChanged: ((Bool) -> Void)?
    private var isVisible = true
    private var shouldReplayHistoryOnNextConnect: Bool
    private struct ConnectionRequest {
        let host: SSHHostProfile
        let generation: UInt64
    }
    private struct RetirementOutcome {
        let groupsCompleted: Bool
        let dispositionCompleted: Bool

        static let complete = RetirementOutcome(
            groupsCompleted: true,
            dispositionCompleted: true
        )
    }
    private var connectionGeneration: UInt64 = 0
    private var pendingConnection: ConnectionRequest?
    private var connectionWorker: Task<Void, Never>?
    private var retirementBarriers: [UUID: SurfaceTerminationBarrier] = [:]
    private var retiringTerminals: [UUID: TerminalSurface] = [:]
    var retiredHistoryDeleteAttemptForTesting: (@Sendable () -> Void)?
    private var inFlightPreparedRuntime: TerminalPreparedPTYRuntime?
#if DEBUG
    private var lastPreparationFailurePIDForTesting: pid_t?
#endif
#if DEBUG
    private(set) var terminalFocusRepairForwardCountForTesting = 0
#endif
    private var sessionAliveTimer: DispatchSourceTimer?
    private var activeTransferCount = 0
    // Path-pairs the user cancelled while in flight. The router runs scp
    // opaquely, so cancel is cooperative: the surface honors the request when the
    // async transfer resumes and records the row as .cancelled (P1).
    private var cancelledTransferKeys: Set<String> = []
    // Injectable file pickers so tests can supply a path without a blocking
    // NSOpenPanel modal (QA-MAC_SSH-003). Default nil → real panel.
    var localPathPickerForTesting: (() -> (path: String, isDirectory: Bool)?)?
    var identityFilePickerForTesting: (() -> String?)? {
        didSet { viewModel.identityFilePicker = identityFilePickerForTesting }
    }
    var terminalReplacementRuntimePreparerForTesting: ((
        WorkspaceID,
        String,
        TerminalSurface.Launch,
        SurfaceID
    ) -> TerminalPreparedPTYRuntime?)?
    var terminalReplacementCloseOnExecEnablerForTesting: ((Int32) -> Bool)?
    var terminalReplacementNonBlockingEnablerForTesting: ((Int32) -> Bool)?
    static let hostSidebarWidthDefaultsKey = "ssh.hosts.sidebar.width.v1"
    static let transferSidebarWidthDefaultsKey = "ssh.files.sidebar.width.v1"
    static let transferSidebarExpandedDefaultsKey = "ssh.files.sidebar.expanded.v1"
    private static let transferSidebarExpandedWidth: CGFloat = 680

    private(set) var descriptor: SurfaceDescriptor
    let view: NSView

    var sshTransferProfile: SSHHostProfile? { viewModel.selectedHost }

    init(
        workspaceID: WorkspaceID,
        cwd: String,
        title: String,
        router: AppCommandRouter?,
        restoredSurfaceID: SurfaceID? = nil,
        historyRepo: TerminalOutputRepository? = nil,
        settingsRepo: (any SettingsWriteRepository)? = nil,
        terminalFontSize: Double = TerminalFontSizeSetting.defaultSize,
        outputBus: SurfaceOutputBus = .shared
    ) throws {
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.router = router
        self.historyRepo = historyRepo
        self.settingsRepo = settingsRepo
        self.outputBus = outputBus
        self.terminalFontSize = terminalFontSize
        self.shouldReplayHistoryOnNextConnect = restoredSurfaceID != nil
        self.descriptor = SurfaceDescriptor(
            id: restoredSurfaceID ?? SurfaceID(),
            type: .ssh,
            title: title,
            iconName: "network",
            metadata: [
                "workspace": workspaceID.value.uuidString,
                "cwd": cwd,
                "ssh_status": "disconnected"
            ]
        )
        self.viewModel = SSHSurfaceViewModel()

        let root = AdaptiveSSHRootView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.backgroundColor = DS.NS.bg.cgColor

        let sidebar = NSHostingView(rootView: SSHSidebarView(vm: viewModel))
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = DS.NS.terminalBG.cgColor

        hostResizeHandle.translatesAutoresizingMaskIntoConstraints = false

        let transferSidebar = NSHostingView(rootView: SSHTransferSidebarView(vm: viewModel))
        transferSidebar.translatesAutoresizingMaskIntoConstraints = false

        transferDivider.translatesAutoresizingMaskIntoConstraints = false
        transferDivider.wantsLayer = true

        root.addSubview(sidebar)
        root.addSubview(hostResizeHandle)
        root.addSubview(terminalContainer)
        root.addSubview(transferDivider)
        root.addSubview(transferSidebar)
        let width = sidebar.widthAnchor.constraint(equalToConstant: Self.persistedHostSidebarWidth())
        let transferWidth = transferSidebar.widthAnchor.constraint(equalToConstant: 0)
        let transferDividerWidth = transferDivider.widthAnchor.constraint(equalToConstant: 0)
        self.sidebarWidthConstraint = width
        self.transferWidthConstraint = transferWidth
        self.transferDividerWidthConstraint = transferDividerWidth
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            width,

            hostResizeHandle.topAnchor.constraint(equalTo: root.topAnchor),
            hostResizeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            hostResizeHandle.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            hostResizeHandle.widthAnchor.constraint(equalToConstant: DS.ResizeDivider.thickness),

            terminalContainer.topAnchor.constraint(equalTo: root.topAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: hostResizeHandle.trailingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: transferDivider.leadingAnchor),

            transferDivider.topAnchor.constraint(equalTo: root.topAnchor),
            transferDivider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            transferDivider.trailingAnchor.constraint(equalTo: transferSidebar.leadingAnchor),
            transferDividerWidth,

            transferSidebar.topAnchor.constraint(equalTo: root.topAnchor),
            transferSidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            transferSidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transferWidth
        ])
        self.view = root

        super.init()

        root.onSizeChanged = { [weak self] size in
            self?.applyAdaptiveHostSidebar(width: size.width, event: .resize)
        }
        hostResizeHandle.onDrag = { [weak self] delta, ended in
            self?.resizeHostSidebar(delta: delta, ended: ended)
        }
        transferDivider.onDrag = { [weak self] delta, ended in
            self?.resizeTransferSidebar(delta: delta, ended: ended)
        }
        viewModel.onRefresh = { [weak self] in self?.reloadHosts() }
        viewModel.onSave = { [weak self] draft in self?.save(draft) }
        viewModel.onConnect = { [weak self] host in self?.connect(host) }
        viewModel.onOpenNewConnection = { [weak self] host in self?.openNewConnection(host) }
        viewModel.onDelete = { [weak self] host in self?.delete(host) }
        viewModel.onImportFromConfig = { [weak self] in self?.importFromConfig() }
        viewModel.onDisconnect = { [weak self] in self?.disconnect() }
        viewModel.onSidebarCollapsedChange = { [weak self] collapsed in
            self?.setSidebarCollapsed(collapsed)
        }
        viewModel.onTransferSidebarCollapsedChange = { [weak self] collapsed in
            UserDefaults.standard.set(!collapsed, forKey: Self.transferSidebarExpandedDefaultsKey)
            self?.syncTransferSidebarWidth(animated: true)
        }
        viewModel.onTransfer = { [weak self] upload, localPath, remotePath in
            self?.runTransfer(upload: upload, localPath: localPath, remotePath: remotePath)
        }
        viewModel.onCancelTransfer = { [weak self] localPath, remotePath in
            self?.requestCancel(localPath: localPath, remotePath: remotePath)
        }
        viewModel.onRefreshLocalFiles = { [weak self] in self?.refreshLocalFiles() }
        viewModel.onRefreshRemoteFiles = { [weak self] in self?.refreshRemoteFiles() }
        viewModel.onChooseLocalPath = { [weak self] in self?.chooseLocalTransferPath() }
        viewModel.onRemoteMkdir = { [weak self] path in self?.runRemoteMkdir(path: path) }
        viewModel.onRemoteRename = { [weak self] from, to in self?.runRemoteRename(from: from, to: to) }
        viewModel.onRemoteDelete = { [weak self] path, isDirectory in self?.runRemoteDelete(path: path, isDirectory: isDirectory) }
        viewModel.onDropOnRemotePane = { [weak self] urls in self?.handleFinderDropOnRemotePane(urls: urls) }
        showPlaceholder()
        reloadHosts()
        syncTransferSidebarWidth(animated: false)
        applyAdaptiveHostSidebar(width: root.bounds.width, event: .structural)
    }

    private func setSidebarCollapsed(_ collapsed: Bool) {
        sidebarWidthConstraint?.constant = collapsed ? 44 : Self.persistedHostSidebarWidth()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layoutSubtreeIfNeeded()
        }
    }

    private func applyAdaptiveHostSidebar(width: CGFloat, event: AdaptiveSidebarLayoutEvent) {
        guard view.window != nil else { return }
        applyAdaptiveHostSidebar(width: width, event: event, now: Date().timeIntervalSinceReferenceDate)
    }

    // Window-independent, clock-injectable core so the policy can be driven
    // deterministically in tests without attaching a real window or relying on
    // wall-clock debounce (QA-MAC_SSH-010).
    private func applyAdaptiveHostSidebar(width: CGFloat, event: AdaptiveSidebarLayoutEvent, now: TimeInterval) {
        guard width > 0 else { return }
        let transferWidth = transferWidthConstraint?.constant ?? 0
        let decision = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: width - transferWidth,
            contentMinimumExtent: 520,
            sidebarExtent: Self.persistedHostSidebarWidth() + DS.ResizeDivider.thickness,
            currentVisible: !viewModel.sidebarCollapsed,
            intent: viewModel.hostSidebarIntent,
            event: event,
            now: now,
            lastAutomaticChange: viewModel.lastAutomaticHostSidebarChange
        )
        guard decision.isVisible == viewModel.sidebarCollapsed else { return }
        viewModel.sidebarCollapsed = !decision.isVisible
        if decision.didChangeAutomatically {
            viewModel.lastAutomaticHostSidebarChange = now
        }
    }

    func applyAdaptiveHostSidebarForTesting(width: CGFloat, event: AdaptiveSidebarLayoutEvent, now: TimeInterval) {
        applyAdaptiveHostSidebar(width: width, event: event, now: now)
    }

    private static func persistedHostSidebarWidth() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: hostSidebarWidthDefaultsKey)
        guard stored > 0 else { return 292 }
        return min(520, max(220, stored))
    }

    private static func persistedTransferSidebarWidth() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: transferSidebarWidthDefaultsKey)
        guard stored > 0 else { return transferSidebarExpandedWidth }
        return min(1120, max(480, stored))
    }

    private static func persistedTransferSidebarCollapsed() -> Bool {
        guard UserDefaults.standard.object(forKey: transferSidebarExpandedDefaultsKey) != nil else { return false }
        return !UserDefaults.standard.bool(forKey: transferSidebarExpandedDefaultsKey)
    }

    private func resizeHostSidebar(delta: CGFloat, ended: Bool) {
        guard !viewModel.sidebarCollapsed else { return }
        if dragStartSidebarWidth == nil {
            dragStartSidebarWidth = sidebarWidthConstraint?.constant ?? Self.persistedHostSidebarWidth()
        }
        let start = dragStartSidebarWidth ?? Self.persistedHostSidebarWidth()
        let next = min(520, max(220, start + delta))
        sidebarWidthConstraint?.constant = next
        // Persist only when the drag ends, not on every delta, to avoid hundreds
        // of synchronous UserDefaults writes per drag (PERF-MAC_SSH-012).
        if ended {
            UserDefaults.standard.set(Double(next), forKey: Self.hostSidebarWidthDefaultsKey)
            dragStartSidebarWidth = nil
        }
    }

    private func syncTransferSidebarWidth(animated: Bool) {
        let visible = viewModel.transferSidebarVisible
        transferDividerWidthConstraint?.constant = visible ? DS.ResizeDivider.thickness : 0
        transferWidthConstraint?.constant = visible ? (viewModel.transferSidebarCollapsed ? 44 : Self.persistedTransferSidebarWidth()) : 0
        let changes = { self.view.layoutSubtreeIfNeeded() }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                changes()
            }
        } else {
            changes()
        }
    }

    private func resizeTransferSidebar(delta: CGFloat, ended: Bool) {
        guard viewModel.transferSidebarVisible, !viewModel.transferSidebarCollapsed else { return }
        if dragStartTransferWidth == nil {
            dragStartTransferWidth = transferWidthConstraint?.constant ?? Self.persistedTransferSidebarWidth()
        }
        let start = dragStartTransferWidth ?? Self.persistedTransferSidebarWidth()
        let next = min(1120, max(480, start - delta))
        transferWidthConstraint?.constant = next
        // Persist only on drag end (PERF-MAC_SSH-012).
        if ended {
            UserDefaults.standard.set(Double(next), forKey: Self.transferSidebarWidthDefaultsKey)
            dragStartTransferWidth = nil
        }
    }

    private func reloadHosts() {
        do {
            viewModel.hosts = try router?.sshHostList(workspace: workspaceID) ?? []
            viewModel.error = nil
        } catch {
            viewModel.error = error.localizedDescription
        }
    }

    private func save(_ draft: SSHHostDraft) {
        let shouldConnectAfterSave = draft.id == nil
        let host = SSHHostProfile(
            id: draft.id ?? SSHHostID(),
            label: draft.resolvedLabel,
            destination: draft.destination,
            port: draft.parsedPort,
            identityFile: draft.parsedIdentityFile,
            password: draft.parsedPassword,
            hasSavedPassword: draft.hasSavedPassword && draft.parsedPassword == nil,
            options: draft.options
        )
        do {
            let saved = try router?.sshHostUpsert(host, workspace: workspaceID) ?? host
            reloadHosts()
            viewModel.showForm = false
            viewModel.editingHostID = nil
            if shouldConnectAfterSave {
                connect(saved)
            }
        } catch {
            viewModel.error = error.localizedDescription
        }
    }

    private func delete(_ host: SSHHostProfile) {
        do {
            try router?.sshHostDelete(host.id, workspace: workspaceID)
            if viewModel.selectedHost?.id == host.id {
                invalidateConnectionRequests()
                cancelInFlightPreparedRuntimeAndTrack()
                stopSessionAliveTimer()
                retireCurrentTerminalWithoutWaiting()
                descriptor.metadata["ssh_status"] = "disconnected"
                viewModel.selectedHost = nil
                viewModel.status = L("Disconnected")
                viewModel.sessionDead = false
                viewModel.transferSidebarVisible = false
                showPlaceholder()
                syncTransferSidebarWidth(animated: true)
            }
            reloadHosts()
        } catch {
            viewModel.error = error.localizedDescription
        }
    }

    private static func waitForCommittedFrame() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func connect(_ host: SSHHostProfile) {
        // Phase 1 (.painting): update the label now so SwiftUI can commit the
        // frame. Phase 2 (.connecting) runs after waitForCommittedFrame hands
        // control back after the CATransaction, guaranteeing the "Connecting…"
        // text paints before the keychain read + forkpty stall (PERF-SSH-001 /
        // UX-MAC_SSH-002). Task.yield() is only an executor hop, not proof
        // that the frame painted — use committed-frame barrier (AGENTS.md).
        enqueueConnection(host)
    }

    @discardableResult
    private func enqueueConnection(_ host: SSHHostProfile) -> UInt64 {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        pendingConnection = ConnectionRequest(host: host, generation: generation)
        viewModel.status = L("Connecting\u{2026}")  // U+2026 HORIZONTAL ELLIPSIS
        viewModel.error = nil
        guard connectionWorker == nil else { return generation }
        connectionWorker = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            await self?.drainConnectionRequests()
        }
        return generation
    }

    private func drainConnectionRequests() async {
        while let request = pendingConnection {
            pendingConnection = nil
            await performConnect(request.host, generation: request.generation)
        }
        connectionWorker = nil
    }

    private func invalidateConnectionRequests() {
        connectionGeneration &+= 1
        pendingConnection = nil
    }

    @discardableResult
    private func discardInFlightPreparedRuntime() -> SurfaceTerminationBarrier? {
        guard let prepared = inFlightPreparedRuntime else { return nil }
        inFlightPreparedRuntime = nil
        return prepared.discard()
    }

    private func cancelInFlightPreparedRuntimeAndTrack() {
        if let cleanup = discardInFlightPreparedRuntime() {
            trackRetirementCleanup(cleanup)
        }
    }

    private func connectionIsCurrent(_ generation: UInt64) -> Bool {
        generation == connectionGeneration
    }

    private func performConnect(_ host: SSHHostProfile, generation: UInt64) async {
        guard connectionIsCurrent(generation) else { return }
        sshLog.info("ssh connect start: \(host.destination, privacy: .private)")
        var crossedReplacementBoundary = false
        do {
            let saved = try router?.sshHostForConnection(host, workspace: workspaceID) ?? host
            guard connectionIsCurrent(generation) else { return }
            let outstandingRetirements = await waitForOutstandingRetirements()
            guard outstandingRetirements.groupsCompleted else {
                throw NSError(
                    domain: "RemoteCode.SSHSurface",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            L("The previous SSH terminal is still shutting down. Retry shortly.")
                    ]
                )
            }
            var dispositionCompleted = outstandingRetirements.dispositionCompleted
            guard connectionIsCurrent(generation) else { return }
            let launch = TerminalSurface.Launch.ssh(profile: saved, cwd: cwd)
            let preparedRuntime: TerminalPreparedPTYRuntime?
            if let terminalReplacementRuntimePreparerForTesting {
                preparedRuntime = terminalReplacementRuntimePreparerForTesting(
                    workspaceID,
                    cwd,
                    launch,
                    descriptor.id
                )
            } else {
                preparedRuntime = TerminalSurface.prepareRuntimeForReplacement(
                    workspaceID: workspaceID,
                    cwd: cwd,
                    launch: launch,
                    surfaceID: descriptor.id,
                    closeOnExecEnabler: terminalReplacementCloseOnExecEnablerForTesting,
                    nonBlockingEnabler: terminalReplacementNonBlockingEnablerForTesting,
                    onFailureCleanup: { [weak self] pid, barrier in
#if DEBUG
                        self?.lastPreparationFailurePIDForTesting = pid
#endif
                        self?.trackRetirementCleanup(barrier)
                    }
                )
            }
            guard let preparedRuntime else {
                guard connectionIsCurrent(generation) else { return }
                if terminal?.runtimeHealth().processAlive == true {
                    descriptor.metadata["ssh_status"] = "connected"
                    viewModel.status = L("Connected")
                    startSessionAliveTimer()
                } else {
                    descriptor.metadata["ssh_status"] = "disconnected"
                    viewModel.status = L("Failed")
                }
                viewModel.error = L("The replacement SSH terminal could not be started.")
                sshLog.error("ssh connect blocked: replacement PTY preparation failed")
                return
            }
            inFlightPreparedRuntime = preparedRuntime
            defer {
                if inFlightPreparedRuntime === preparedRuntime {
                    inFlightPreparedRuntime = nil
                }
                if let cleanup = preparedRuntime.discard() {
                    trackRetirementCleanup(cleanup)
                }
            }
            guard preparedRuntime.suspendIfOwnedAndAlive() else {
                guard connectionIsCurrent(generation) else { return }
                if terminal?.runtimeHealth().processAlive == true {
                    descriptor.metadata["ssh_status"] = "connected"
                    viewModel.status = L("Connected")
                    startSessionAliveTimer()
                } else {
                    descriptor.metadata["ssh_status"] = "disconnected"
                    viewModel.status = L("Failed")
                }
                viewModel.error = L("The replacement SSH terminal exited before it was ready.")
                sshLog.error("ssh connect blocked: prepared PTY child was not alive")
                return
            }
            guard connectionIsCurrent(generation) else {
                // `TerminalPreparedPTYRuntime.deinit` closes the PTY and starts
                // bounded child disposition when ownership was not consumed.
                return
            }
            stopSessionAliveTimer()
            crossedReplacementBoundary = terminal != nil
            let currentRetirement = await retireCurrentTerminalAndWait()
            dispositionCompleted = dispositionCompleted
                && currentRetirement.dispositionCompleted
            guard currentRetirement.groupsCompleted else {
                throw NSError(
                    domain: "RemoteCode.SSHSurface",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            L("The current SSH terminal did not finish shutting down. Retry shortly.")
                    ]
                )
            }
            guard connectionIsCurrent(generation), terminal == nil else {
                return
            }
            viewModel.sessionDead = false
            let shouldReplayHistory = shouldReplayHistoryOnNextConnect
            let next = try TerminalSurface(
                workspaceID: workspaceID,
                title: saved.label,
                launch: .ssh(profile: saved, cwd: cwd),
                restoredSurfaceID: shouldReplayHistory ? descriptor.id : nil,
                assignedSurfaceID: shouldReplayHistory ? nil : descriptor.id,
                historyRepo: historyRepo,
                settingsRepo: settingsRepo,
                terminalFontSize: terminalFontSize,
                outputBus: outputBus,
                preparedRuntime: preparedRuntime
            )
            if inFlightPreparedRuntime === preparedRuntime {
                inFlightPreparedRuntime = nil
            }
            guard next.runtimeHealth().processAlive,
                  next.runtimeHealth().inputAccepting else {
                _ = await disposeUncommittedTerminal(next)
                throw NSError(
                    domain: "RemoteCode.SSHSurface",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            L("The replacement SSH terminal did not become interactive.")
                    ]
                )
            }
            guard connectionIsCurrent(generation), terminal == nil else {
                _ = await disposeUncommittedTerminal(next)
                return
            }
            if !dispositionCompleted {
                next.markRuntimeRestartDispositionIncomplete()
            }
            terminal = next
            shouldReplayHistoryOnNextConnect = true
            if isVisible {
                next.didBecomeVisible()
            } else {
                next.didBecomeHidden()
            }
            descriptor.metadata = next.descriptor.metadata
            descriptor.metadata["ssh_status"] = "connected"
            viewModel.selectedHost = saved
            viewModel.status = L("Connected")
            viewModel.transferSidebarCollapsed = Self.persistedTransferSidebarCollapsed()
            viewModel.transferSidebarVisible = true
            viewModel.prepareTransferPanel(localPath: cwd, remotePath: "/")
            viewModel.error = nil
            installTerminal(next.view)
            syncTransferSidebarWidth(animated: true)
            refreshLocalFiles()
            refreshRemoteFiles()
            startSessionAliveTimer()
            next.focus()
            EventBus.shared.publish(kind: .sshSessionUpdated, payload: .object([
                "workspace_id": .string(workspaceID.value.uuidString),
                "surface_id": .string(descriptor.id.value.uuidString),
                "profile_id": .string(saved.id.value.uuidString),
                "destination": .string(saved.destination),
                "status": .string("connected")
            ]))
            reloadHosts()
            sshLog.info("ssh connect ok: \(saved.destination, privacy: .private)")
        } catch {
            guard connectionIsCurrent(generation) else { return }
            if !crossedReplacementBoundary,
               terminal?.runtimeHealth().processAlive == true {
                descriptor.metadata["ssh_status"] = "connected"
                viewModel.status = L("Connected")
                startSessionAliveTimer()
            } else {
                descriptor.metadata["ssh_status"] = "disconnected"
                viewModel.status = L("Failed")
                publishDisconnected(reason: "connection_failed")
            }
            viewModel.error = error.localizedDescription
            sshLog.error("ssh connect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func retireCurrentTerminalWithoutWaiting() {
        guard let current = terminal else { return }
        let barrier = current.closeForRuntimeRestart()
        terminal = nil
        current.relinquishRuntimeHealthOwnershipForReplacement()
        guard let barrier else { return }
        let token = registerRetirementBarrier(barrier, terminal: current)
        monitorTerminalRetirement(
            token: token,
            barrier: barrier,
            terminal: current,
            timeoutMessage: "ssh terminal cleanup exceeded the fast asynchronous retirement window"
        )
    }

    @discardableResult
    private func registerRetirementBarrier(
        _ barrier: SurfaceTerminationBarrier,
        terminal: TerminalSurface? = nil
    ) -> UUID {
        let token = UUID()
        retirementBarriers[token] = barrier
        if let terminal {
            retiringTerminals[token] = terminal
        }
        return token
    }

    private func removeRetirementBarrier(_ token: UUID) {
        retirementBarriers.removeValue(forKey: token)
        retiringTerminals.removeValue(forKey: token)
    }

    private func terminalHistoryOwners() -> [TerminalSurface] {
        var seen = Set<ObjectIdentifier>()
        var owners: [TerminalSurface] = []
        for candidate in [terminal].compactMap({ $0 }) + Array(retiringTerminals.values) {
            let identity = ObjectIdentifier(candidate)
            guard seen.insert(identity).inserted else { continue }
            owners.append(candidate)
        }
        return owners
    }

    private func trackRetirementCleanup(
        _ barrier: SurfaceTerminationBarrier,
        terminal: TerminalSurface? = nil
    ) {
        let token = registerRetirementBarrier(barrier, terminal: terminal)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let completedInFastWindow = await barrier.waitForGroupsAsync(until: .now() + 2)
            if !completedInFastWindow {
                sshLog.error("ssh terminal cleanup exceeded the fast fallback window; ownership retained")
                _ = await barrier.waitForGroupsAsync(until: .distantFuture)
            }
            if !barrier.completionChecksSucceeded() {
                // Production process barriers retain their PID anchor until they
                // can complete successfully. A false check here is therefore an
                // injected/foreign contract failure; keep it visible in logs.
                sshLog.error("ssh terminal fallback cleanup completed without disposition proof")
            }
            self.removeRetirementBarrier(token)
        }
    }

    private func monitorTerminalRetirement(
        token: UUID,
        barrier: SurfaceTerminationBarrier,
        terminal: TerminalSurface,
        alreadyTimedOut: Bool = false,
        timeoutMessage: String
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var completedInFastWindow = !alreadyTimedOut
            if !alreadyTimedOut {
                completedInFastWindow = await barrier.waitForGroupsAsync(until: .now() + 2)
            }
            if !completedInFastWindow {
                sshLog.error("\(timeoutMessage, privacy: .public); ownership retained")
                _ = await barrier.waitForGroupsAsync(until: .distantFuture)
            }
            let dispositionCompleted = barrier.completionChecksSucceeded()
            if !dispositionCompleted,
               let cleanup = terminal.continueCleanupAfterFailedRuntimeRestart() {
                // Publish fallback ownership before removing the original token;
                // app termination must never observe an empty handoff window.
                self.trackRetirementCleanup(cleanup, terminal: terminal)
                sshLog.error("ssh terminal disposition check failed; fallback cleanup retained")
            }
            self.removeRetirementBarrier(token)
        }
    }

    private func waitForOutstandingRetirements() async -> RetirementOutcome {
        guard !retirementBarriers.isEmpty else { return .complete }
        let deadline = DispatchTime.now() + 2
        var dispositionCompleted = true
        var observed = Set<ObjectIdentifier>()
        while true {
            let barriers = retirementBarriers.values.filter {
                !observed.contains(ObjectIdentifier($0))
            }
            if barriers.isEmpty {
                return RetirementOutcome(
                    groupsCompleted: true,
                    dispositionCompleted: dispositionCompleted
                )
            }
            for barrier in barriers {
                observed.insert(ObjectIdentifier(barrier))
                guard await barrier.waitForGroupsAsync(until: deadline) else {
                    return RetirementOutcome(
                        groupsCompleted: false,
                        dispositionCompleted: false
                    )
                }
                dispositionCompleted = barrier.completionChecksSucceeded()
                    && dispositionCompleted
            }
            // Tracking tasks may publish a fallback barrier after evaluating a
            // completed original disposition. Observe that handoff before reuse.
            await Task.yield()
        }
    }

    @discardableResult
    private func retireCurrentTerminalAndWait() async -> RetirementOutcome {
        guard let current = terminal else { return .complete }
        let barrier = current.closeForRuntimeRestart()
        terminal = nil
        guard let barrier else {
            current.relinquishRuntimeHealthOwnershipForReplacement()
            return .complete
        }
        let token = registerRetirementBarrier(barrier, terminal: current)
        let deadline = DispatchTime.now() + 2
        if let requiredHistory = current.requiredHistoryBarrierForRuntimeRestart() {
            let historyGroupsCompleted = await requiredHistory.waitForGroupsAsync(
                until: deadline
            )
            guard historyGroupsCompleted,
                  requiredHistory.completionChecksSucceeded() else {
                monitorTerminalRetirement(
                    token: token,
                    barrier: barrier,
                    terminal: current,
                    alreadyTimedOut: !historyGroupsCompleted,
                    timeoutMessage: "ssh terminal history retirement timed out"
                )
                current.relinquishRuntimeHealthOwnershipForReplacement()
                return RetirementOutcome(
                    groupsCompleted: false,
                    dispositionCompleted: false
                )
            }
        }
        let groupsCompleted = await barrier.waitForGroupsAsync(until: deadline)
        guard groupsCompleted else {
            if let cleanup = current.continueCleanupAfterFailedRuntimeRestart() {
                trackRetirementCleanup(cleanup, terminal: current)
            }
            monitorTerminalRetirement(
                token: token,
                barrier: barrier,
                terminal: current,
                alreadyTimedOut: true,
                timeoutMessage: "ssh terminal process retirement timed out"
            )
            sshLog.error("ssh terminal process cleanup incomplete; replacement may continue with partial health")
            current.relinquishRuntimeHealthOwnershipForReplacement()
            return RetirementOutcome(
                groupsCompleted: true,
                dispositionCompleted: false
            )
        }
        let dispositionCompleted = barrier.completionChecksSucceeded()
        if !dispositionCompleted {
            if let cleanup = current.continueCleanupAfterFailedRuntimeRestart() {
                trackRetirementCleanup(cleanup, terminal: current)
            }
            sshLog.error("ssh terminal cleanup incomplete; replacement may continue with partial health")
        }
        removeRetirementBarrier(token)
        current.relinquishRuntimeHealthOwnershipForReplacement()
        return RetirementOutcome(
            groupsCompleted: true,
            dispositionCompleted: dispositionCompleted
        )
    }

    @discardableResult
    private func disposeUncommittedTerminal(_ uncommitted: TerminalSurface) async -> RetirementOutcome {
        guard let barrier = uncommitted.closeForRuntimeRestart() else {
            uncommitted.relinquishRuntimeHealthOwnershipForReplacement()
            return .complete
        }
        let token = registerRetirementBarrier(barrier, terminal: uncommitted)
        let groupsCompleted = await barrier.waitForGroupsAsync(until: .now() + 2)
        guard groupsCompleted else {
            monitorTerminalRetirement(
                token: token,
                barrier: barrier,
                terminal: uncommitted,
                alreadyTimedOut: true,
                timeoutMessage: "uncommitted SSH replacement cleanup timed out"
            )
            uncommitted.relinquishRuntimeHealthOwnershipForReplacement()
            return RetirementOutcome(
                groupsCompleted: false,
                dispositionCompleted: false
            )
        }
        let dispositionCompleted = barrier.completionChecksSucceeded()
        if !dispositionCompleted,
           let cleanup = uncommitted.continueCleanupAfterFailedRuntimeRestart() {
            trackRetirementCleanup(cleanup, terminal: uncommitted)
            sshLog.error("uncommitted SSH replacement required fallback cleanup")
        }
        removeRetirementBarrier(token)
        uncommitted.relinquishRuntimeHealthOwnershipForReplacement()
        return RetirementOutcome(
            groupsCompleted: true,
            dispositionCompleted: dispositionCompleted
        )
    }

    // Explicit user-initiated disconnect: close the terminal, reset status/UI.
    private func disconnect() {
        invalidateConnectionRequests()
        cancelInFlightPreparedRuntimeAndTrack()
        stopSessionAliveTimer()
        retireCurrentTerminalWithoutWaiting()
        descriptor.metadata["ssh_status"] = "disconnected"
        viewModel.selectedHost = nil
        viewModel.status = L("Disconnected")
        viewModel.sessionDead = false
        viewModel.transferSidebarVisible = false
        showPlaceholder()
        syncTransferSidebarWidth(animated: true)
        publishDisconnected(reason: "user_requested")
        sshLog.info("ssh disconnect: user requested")
    }

    // Import hosts from ~/.ssh/config. Each non-wildcard Host block whose
    // HostName resolves becomes a saved SSHHostProfile. Duplicate destinations
    // (same destination+port) are not deduplicated here; the router upsert is
    // by ID so each import always creates a fresh profile.
    private func importFromConfig() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
        let profiles = SSHConfigParser.parse(fileURL: url)
        guard !profiles.isEmpty else {
            viewModel.error = L("No importable hosts found in ~/.ssh/config.")
            return
        }
        var importedCount = 0
        for profile in profiles {
            do {
                try router?.sshHostUpsert(profile, workspace: workspaceID)
                importedCount += 1
            } catch {
                sshLog.error("ssh config import upsert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        reloadHosts()
        viewModel.error = importedCount == 0 ? L("Import failed - could not save any hosts.") : nil
        sshLog.info("ssh config import: imported \(importedCount, privacy: .public) hosts")
    }

    // Starts a repeating timer that checks whether the SSH child process is
    // still alive. Flips viewModel.status to "Disconnected" when the child
    // exits without an explicit user-disconnect. The timer fires off the main
    // queue and dispatches UI updates back to main.
    private func startSessionAliveTimer() {
        stopSessionAliveTimer()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.descriptor.metadata["ssh_status"] == "connected" else { return }
                let alive = self.terminal?.runtimeHealth().processAlive ?? false
                if !alive {
                    self.handleUnexpectedDisconnect()
                }
            }
        }
        timer.resume()
        sessionAliveTimer = timer
    }

    private func stopSessionAliveTimer() {
        sessionAliveTimer?.cancel()
        sessionAliveTimer = nil
    }

    // Testing accessor so tests can trigger the disconnect path without a timer.
    func disconnectForTesting() {
        disconnect()
    }

    func disconnectForRouter() {
        disconnect()
    }

    func unexpectedDisconnectForTesting() {
        handleUnexpectedDisconnect()
    }

    func connectionFailedForTesting() {
        descriptor.metadata["ssh_status"] = "disconnected"
        publishDisconnected(reason: "connection_failed")
    }

    private func handleUnexpectedDisconnect() {
        invalidateConnectionRequests()
        cancelInFlightPreparedRuntimeAndTrack()
        stopSessionAliveTimer()
        retireCurrentTerminalWithoutWaiting()
        descriptor.metadata["ssh_status"] = "disconnected"
        viewModel.status = L("Disconnected")
        viewModel.sessionDead = true
        publishDisconnected(reason: "unexpected_child_exit")
        sshLog.info("ssh session: child exited, status flipped to Disconnected")
    }

    private func publishDisconnected(reason: String) {
        EventBus.shared.publish(kind: .sshSessionUpdated, payload: .object([
            "workspace_id": .string(workspaceID.value.uuidString),
            "surface_id": .string(descriptor.id.value.uuidString),
            "status": .string("disconnected"),
            "reason": .string(reason)
        ]))
    }

    // Testing accessor for import - allows injecting a custom file URL.
    func importFromConfigURLForTesting(_ url: URL) {
        let profiles = SSHConfigParser.parse(fileURL: url)
        guard !profiles.isEmpty else {
            viewModel.error = L("No importable hosts found.")
            return
        }
        var importedCount = 0
        for profile in profiles {
            do {
                try router?.sshHostUpsert(profile, workspace: workspaceID)
                importedCount += 1
            } catch {}
        }
        reloadHosts()
        viewModel.error = importedCount == 0 ? L("Import failed.") : nil
    }

    private func runTransfer(upload: Bool, localPath: String, remotePath: String) {
        let kind = upload ? L("Upload") : L("Download")
        let direction: SSHTransferDirection = upload ? .upload : .download
        viewModel.recordTransfer(direction: direction, localPath: localPath, remotePath: remotePath, status: .queued)
        viewModel.transferStatus = L("%1$@ running", kind)
        activeTransferCount += 1
        sshLog.info("ssh transfer start: \(kind, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            // Process execution runs off the main run loop inside the router's
            // async transfer; UI updates resume here on the main actor.
            var ok = false
            do {
                let result = upload
                    ? try await self.router?.sshTransferUploadAsync(surface: self.descriptor.id, localPath: localPath, remotePath: remotePath)
                    : try await self.router?.sshTransferDownloadAsync(surface: self.descriptor.id, remotePath: remotePath, localPath: localPath)
                ok = result?.objectValue?["ok"]?.boolValue == true
                // Honor a cancel requested while the opaque scp was running:
                // record .cancelled instead of success/failure (P1).
                if self.consumeCancel(localPath: localPath, remotePath: remotePath) {
                    self.viewModel.transferStatus = L("%1$@ cancelled", kind)
                    self.viewModel.markCancelled(localPath: localPath, remotePath: remotePath)
                } else {
                    self.viewModel.transferStatus = ok ? L("%1$@ completed", kind) : L("%1$@ failed", kind)
                    self.viewModel.recordTransfer(direction: direction, localPath: localPath, remotePath: remotePath, status: ok ? .successful : .failed)
                }
                sshLog.info("ssh transfer end: \(kind, privacy: .public) ok=\(ok, privacy: .public)")
            } catch {
                if self.consumeCancel(localPath: localPath, remotePath: remotePath) {
                    self.viewModel.transferStatus = L("%1$@ cancelled", kind)
                    self.viewModel.markCancelled(localPath: localPath, remotePath: remotePath)
                } else {
                    self.viewModel.transferStatus = L("%1$@ failed", kind)
                    self.viewModel.recordTransfer(direction: direction, localPath: localPath, remotePath: remotePath, status: .failed)
                    self.viewModel.error = error.localizedDescription
                }
                sshLog.error("ssh transfer error: \(kind, privacy: .public) \(error.localizedDescription, privacy: .public)")
            }
            self.activeTransferCount -= 1
            // Coalesce listing refreshes: only refresh once the whole batch
            // (e.g. a multi-file uploadLocalSelection loop) has drained.
            if self.activeTransferCount == 0 {
                self.refreshLocalFiles()
                await self.refreshRemoteFilesAsync()
            }
        }
    }

    private static func cancelKey(localPath: String, remotePath: String) -> String {
        "\(localPath)\u{1F}\(remotePath)"
    }

    // Records a cancel request for an in-flight transfer and marks the row
    // immediately so the UI reflects intent even before the opaque scp returns.
    private func requestCancel(localPath: String, remotePath: String) {
        cancelledTransferKeys.insert(Self.cancelKey(localPath: localPath, remotePath: remotePath))
        viewModel.markCancelled(localPath: localPath, remotePath: remotePath)
    }

    // Returns (and clears) whether this transfer was cancelled, so the async
    // completion path records the row correctly exactly once.
    private func consumeCancel(localPath: String, remotePath: String) -> Bool {
        cancelledTransferKeys.remove(Self.cancelKey(localPath: localPath, remotePath: remotePath)) != nil
    }

    func requestCancelForTesting(localPath: String, remotePath: String) {
        requestCancel(localPath: localPath, remotePath: remotePath)
    }

    // MARK: - Remote file management

    private func runRemoteMkdir(path: String) {
        guard let profile = viewModel.selectedHost else { return }
        let argv = SSHRemoteManagementCommand.mkdirArguments(profile: profile, path: path)
        let password = profile.password
        viewModel.addTransferLog(L("Remote mkdir: %1$@", path))
        Task { [weak self] in
            guard let self else { return }
            do {
                let ok = try await self.router?.sshRemoteManageAsync(argv: argv, password: password) ?? false
                if ok {
                    self.viewModel.addTransferLog(L("Mkdir ok: %1$@", path))
                    await self.refreshRemoteFilesAsync()
                } else {
                    self.viewModel.addTransferLog(L("Mkdir failed: %1$@", path))
                }
            } catch {
                self.viewModel.addTransferLog(L("Mkdir failed: %1$@", error.localizedDescription))
                sshLog.error("ssh mkdir failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func runRemoteRename(from: String, to: String) {
        guard let profile = viewModel.selectedHost else { return }
        let argv = SSHRemoteManagementCommand.renameArguments(profile: profile, from: from, to: to)
        let password = profile.password
        viewModel.addTransferLog(L("Remote rename: %1$@ -> %2$@", from, to))
        Task { [weak self] in
            guard let self else { return }
            do {
                let ok = try await self.router?.sshRemoteManageAsync(argv: argv, password: password) ?? false
                if ok {
                    self.viewModel.addTransferLog(L("Rename ok: %1$@", to))
                    await self.refreshRemoteFilesAsync()
                } else {
                    self.viewModel.addTransferLog(L("Rename failed: %1$@ -> %2$@", from, to))
                }
            } catch {
                self.viewModel.addTransferLog(L("Rename failed: %1$@", error.localizedDescription))
                sshLog.error("ssh rename failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func runRemoteDelete(path: String, isDirectory: Bool) {
        guard let profile = viewModel.selectedHost else { return }
        let argv = SSHRemoteManagementCommand.deleteArguments(profile: profile, path: path, isDirectory: isDirectory)
        let password = profile.password
        viewModel.addTransferLog(L("Remote delete: %1$@", path))
        Task { [weak self] in
            guard let self else { return }
            do {
                let ok = try await self.router?.sshRemoteManageAsync(argv: argv, password: password) ?? false
                if ok {
                    self.viewModel.addTransferLog(L("Delete ok: %1$@", path))
                    await self.refreshRemoteFilesAsync()
                } else {
                    self.viewModel.addTransferLog(L("Delete failed: %1$@", path))
                }
            } catch {
                self.viewModel.addTransferLog(L("Delete failed: %1$@", error.localizedDescription))
                sshLog.error("ssh delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Testing accessor: trigger remote mkdir synchronously via the same path
    /// the UI uses. The router call is async, so callers must await the returned
    /// task or observe viewModel.transferLogs for the result.
    func runRemoteMkdirForTesting(path: String) {
        runRemoteMkdir(path: path)
    }

    func runRemoteRenameForTesting(from: String, to: String) {
        runRemoteRename(from: from, to: to)
    }

    func runRemoteDeleteForTesting(path: String, isDirectory: Bool) {
        runRemoteDelete(path: path, isDirectory: isDirectory)
    }

    private func refreshLocalFiles() {
        do {
            let listing = try router?.sshFilesLocalList(path: viewModel.localSitePath)
            viewModel.applyLocalListing(listing?.objectValue ?? [:])
        } catch {
            viewModel.transferStatus = L("Local list failed")
            viewModel.localListError = error.localizedDescription
            viewModel.addTransferLog(L("Local: %1$@", error.localizedDescription))
            sshLog.error("ssh local list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshRemoteFiles() {
        guard descriptor.metadata["ssh_status"] == "connected" else { return }
        Task { [weak self] in
            await self?.refreshRemoteFilesAsync()
        }
    }

    /// Async remote listing so post-transfer refreshes never block the main
    /// run loop (PERF-MAC_SSH-002). Spawns the remote shell off-thread via the
    /// router; UI updates resume on the main actor.
    private func refreshRemoteFilesAsync() async {
        guard descriptor.metadata["ssh_status"] == "connected" else { return }
        do {
            let listing = try await router?.sshFilesRemoteListAsync(surface: descriptor.id, path: viewModel.remoteSitePath)
            viewModel.applyRemoteListing(listing?.objectValue ?? [:])
        } catch {
            viewModel.transferStatus = L("Remote list failed")
            viewModel.remoteListError = error.localizedDescription
            viewModel.addTransferLog(L("Remote: %1$@", error.localizedDescription))
            sshLog.error("ssh remote list (async) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func chooseLocalTransferPath() {
        let picked: (path: String, isDirectory: Bool)?
        if let localPathPickerForTesting {
            picked = localPathPickerForTesting()
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = L("Choose")
            picked = panel.runModal() == .OK ? panel.url.map { ($0.path, $0.hasDirectoryPath) } : nil
        }
        if let picked {
            viewModel.selectLocalPath(picked.path, isDirectory: picked.isDirectory)
            if picked.isDirectory { refreshLocalFiles() }
        }
    }

    private func openNewConnection(_ host: SSHHostProfile) {
        if terminal == nil {
            connect(host)
            return
        }
        do {
            let saved = try router?.sshHostUpsert(host, workspace: workspaceID) ?? host
            let desc = try router?.sshConnect(workspace: workspaceID, profileID: saved.id, profile: nil, title: saved.label, paneID: nil)
            if let desc {
                try router?.focusSurface(workspace: workspaceID, surface: desc.id)
            }
            viewModel.error = nil
        } catch {
            viewModel.status = L("Failed")
            viewModel.error = error.localizedDescription
        }
    }

    func openNewConnectionForTesting(_ host: SSHHostProfile) {
        openNewConnection(host)
    }

    func connectForRouter(_ host: SSHHostProfile) {
        connect(host)
    }

    private func installTerminal(_ terminalView: NSView) {
        terminalContainer.subviews.forEach { $0.removeFromSuperview() }
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor)
        ])
    }

    private func showPlaceholder() {
        terminalContainer.subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: L("Select a saved SSH host or press + to add one."))
        label.textColor = DS.NS.textTertiary
        label.font = NSFont.systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: terminalContainer.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: terminalContainer.centerYAnchor)
        ])
    }

    func appendSystemText(_ raw: String) {
        terminal?.appendSystemText(raw)
    }

    var transferTerminal: TerminalSurface? { terminal }

    func focus() {
        terminal?.focus()
    }

    func unfocus() {
        terminal?.unfocus()
    }

    func didBecomeVisible() {
        isVisible = true
        // Parking reparents the unregistered embedded TerminalSurface into a
        // hidden NSWindow. PaneTabs only rehosts this outer SSHSurface.view, so
        // reinstall the terminal when it is parked/orphaned or the Connected
        // pane stays blank until reconnect.
        if let terminal, terminal.view.superview !== terminalContainer {
            installTerminal(terminal.view)
        }
        terminal?.didBecomeVisible()
    }

    func didBecomeHidden() {
        isVisible = false
        terminal?.didBecomeHidden()
    }

    func close() {
        invalidateConnectionRequests()
        cancelInFlightPreparedRuntimeAndTrack()
        stopSessionAliveTimer()
        terminal?.close()
        publishDisconnected(reason: "user_requested")
    }

    func closeForApplicationTermination() -> SurfaceTerminationBarrier? {
        invalidateConnectionRequests()
        stopSessionAliveTimer()
        if let preparedCleanup = discardInFlightPreparedRuntime() {
            trackRetirementCleanup(preparedCleanup)
        }
        if let current = terminal {
            let barrier = current.closeForApplicationTermination()
            terminal = nil
            current.relinquishRuntimeHealthOwnershipForReplacement()
            if let barrier {
                let token = registerRetirementBarrier(barrier, terminal: current)
                monitorTerminalRetirement(
                    token: token,
                    barrier: barrier,
                    terminal: current,
                    timeoutMessage: "SSH app-termination disposition exceeded the fast window"
                )
            }
        }
        let barriers = Array(retirementBarriers.values)
        publishDisconnected(reason: "application_termination")
        return barriers.isEmpty ? nil : SurfaceTerminationBarrier(combining: barriers)
    }

    func closeAndDeletePersistedHistory() {
        invalidateConnectionRequests()
        cancelInFlightPreparedRuntimeAndTrack()
        stopSessionAliveTimer()
        let historyOwners = terminalHistoryOwners()
        for owner in historyOwners {
            owner.closeAndDeletePersistedHistory()
        }
        if historyOwners.isEmpty {
            if let historyRepo {
                TerminalSurface.scheduleOwnerlessHistoryDelete(
                    repository: historyRepo,
                    surfaceID: descriptor.id.value.uuidString
                )
            }
            outputBus.remove(surfaceId: descriptor.id)
        }
        self.terminal = nil
        publishDisconnected(reason: "user_requested")
    }

    func flushPersistedHistory() {
        terminal?.flushPersistedHistory()
    }

    func flushPersistedHistoryForTesting() async -> Bool {
        guard let terminal else { return false }
        return await terminal.flushPersistedHistoryAsync()
    }

    func routedSendTextStatus(_ text: String) -> TerminalInputStatus {
        terminal?.sendTextStatus(text) ?? .processExited
    }

    func routedTextSnapshot() -> TerminalTextSnapshot? {
        terminal?.readTextSnapshot()
    }

    func routedRuntimeHealth() -> TerminalRuntimeHealth? {
        terminal?.runtimeHealth()
    }

    func routedFlushPersistedHistory() {
        terminal?.flushPersistedHistory()
    }

    func routedFlushPersistedHistoryBarrier() -> SurfaceTerminationBarrier? {
        terminal?.flushPersistedHistoryBarrier()
    }

    func routedClearPersistedHistory() {
        if let terminal {
            // The live coordinator owns generation rotation. Retirees only
            // finish the drain already started by runtime replacement.
            terminal.clearPersistedHistory()
            return
        }

        let retired = Array(retiringTerminals.values)
        retired.forEach {
            retiredHistoryDeleteAttemptForTesting?()
            $0.closeAndDeletePersistedHistory()
        }
        if retired.isEmpty, let historyRepo {
            TerminalSurface.scheduleOwnerlessHistoryClearForReuse(
                repository: historyRepo,
                surfaceID: descriptor.id.value.uuidString
            )
        }
    }

    func routedReadPersistedHistory(
        beforeChunkID: Int64?,
        maxBytes: Int,
        timeout: TimeInterval
    ) async throws -> TerminalOutputWindow {
        guard let terminal else { throw TerminalHistoryReadError.unavailable }
        return try await terminal.readPersistedHistory(
            beforeChunkID: beforeChunkID,
            maxBytes: maxBytes,
            timeout: timeout
        )
    }

    func routedRepairTerminalFocus(reason: String) {
#if DEBUG
        terminalFocusRepairForwardCountForTesting += 1
#endif
        terminal?.repairTerminalFocus(reason: reason)
    }

    func sendText(_ text: String) {
        terminal?.sendText(text)
    }

    func readText() -> String {
        terminal?.readText() ?? ""
    }

    func snapshot() -> [String: String] {
        [
            "cwd": cwd,
            "ssh_status": descriptor.metadata["ssh_status"] ?? "disconnected",
            "ssh_destination": descriptor.metadata["ssh_destination"] ?? ""
        ]
    }

    var embeddedTerminalIDForTesting: SurfaceID? { terminal?.descriptor.id }
    var embeddedTerminalForTesting: TerminalSurface? { terminal }
    var embeddedTerminalLogicalVisibleForTesting: Bool? {
        terminal?.runtimeHealth().renderDiagnostics?.logicalVisible
    }
    var embeddedOutputPendingBytesForTesting: Int? { terminal?.runtimeHealth().outputPendingBytes }

    func connectImmediatelyForTesting(_ host: SSHHostProfile) async {
        connectionGeneration &+= 1
        pendingConnection = nil
        await performConnect(host, generation: connectionGeneration)
    }

    func installEmbeddedPlaceholderForTesting() async throws {
        let retirement = await retireCurrentTerminalAndWait()
        guard retirement.groupsCompleted else {
            throw NSError(domain: "RemoteCode.SSHSurface.Tests", code: 1)
        }
        let next = try TerminalSurface(
            workspaceID: workspaceID,
            title: descriptor.title,
            launch: .sshPlaceholder(cwd: cwd),
            assignedSurfaceID: descriptor.id,
            historyRepo: historyRepo,
            settingsRepo: settingsRepo,
            terminalFontSize: terminalFontSize,
            outputBus: outputBus
        )
        if !retirement.dispositionCompleted {
            next.markRuntimeRestartDispositionIncomplete()
        }
        terminal = next
        shouldReplayHistoryOnNextConnect = true
        if isVisible {
            next.didBecomeVisible()
        } else {
            next.didBecomeHidden()
        }
        installTerminal(next.view)
    }

    func installHistoryClearOwnersForTesting(
        current: TerminalSurface,
        retiree: TerminalSurface,
        retirementBarrier: SurfaceTerminationBarrier
    ) {
        terminal = current
        let token = UUID()
        retiringTerminals[token] = retiree
        retirementBarriers[token] = retirementBarrier
    }

    func installEmbeddedShellForApplicationTerminationTesting() async throws -> TerminalSurface {
        let retirement = await retireCurrentTerminalAndWait()
        guard retirement.groupsCompleted else {
            throw NSError(domain: "RemoteCode.SSHSurface.Tests", code: 2)
        }
        let next = try TerminalSurface(
            workspaceID: workspaceID,
            title: descriptor.title,
            launch: .shell(cwd: cwd),
            assignedSurfaceID: descriptor.id,
            historyRepo: historyRepo,
            settingsRepo: settingsRepo,
            terminalFontSize: terminalFontSize,
            outputBus: outputBus
        )
        if !retirement.dispositionCompleted {
            next.markRuntimeRestartDispositionIncomplete()
        }
        terminal = next
        if isVisible {
            next.didBecomeVisible()
        } else {
            next.didBecomeHidden()
        }
        installTerminal(next.view)
        return next
    }

    var connectionWorkerActiveForTesting: Bool { connectionWorker != nil }
    var inFlightPreparedPIDForTesting: pid_t? {
        inFlightPreparedRuntime?.ownedPIDForTesting
    }
#if DEBUG
    var preparationFailurePIDForTesting: pid_t? { lastPreparationFailurePIDForTesting }
#endif

    func waitForRetirementsForTesting() async {
        let deadline = DispatchTime.now() + 3
        while !retirementBarriers.isEmpty,
              DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds {
            let barriers = Array(retirementBarriers.values)
            for barrier in barriers {
                _ = await barrier.waitAsync(until: deadline)
            }
            await Task.yield()
        }
    }

    var retirementBarrierCountForTesting: Int { retirementBarriers.count }

    var hostSidebarWidthForTesting: CGFloat {
        sidebarWidthConstraint?.constant ?? 0
    }

    var transferSidebarWidthForTesting: CGFloat {
        transferWidthConstraint?.constant ?? 0
    }

    func setHostSidebarWidthForTesting(_ width: CGFloat) {
        sidebarWidthConstraint?.constant = min(520, max(220, width))
        UserDefaults.standard.set(Double(sidebarWidthConstraint?.constant ?? width), forKey: Self.hostSidebarWidthDefaultsKey)
    }

    // Testing accessors over the fileprivate view model so tests can assert
    // transfer/queue/selection state without reaching into private types
    // (QA-MAC_SSH-008). Plain value types keep the VM itself encapsulated.
    var transferStatusForTesting: String { viewModel.transferStatus }
    var queueCountForTesting: Int { viewModel.queueItems.count }
    var queuedCountForTesting: Int { viewModel.queueItems.filter { $0.status == .queued }.count }
    var selectedLocalCountForTesting: Int { viewModel.selectedLocalIDs.count }
    var selectedRemoteCountForTesting: Int { viewModel.selectedRemoteIDs.count }
    var selectedLocalIDsForTesting: Set<String> { viewModel.selectedLocalIDs }
    var selectedRemoteIDsForTesting: Set<String> { viewModel.selectedRemoteIDs }
    var transferLogForTesting: [String] { viewModel.transferLogs }

    // Seeds localEntries in the VM so selection tests can exercise range logic
    // without a router round-trip. Each name becomes one file entry whose id
    // equals its name (predictable for assertions).
    func seedLocalEntriesForTesting(_ names: [String]) {
        let entries = names.map { name in
            SSHFileEntry(id: name, name: name, path: "/\(name)", kind: "file",
                         size: "0", fileType: "file", modified: "")
        }
        viewModel.localEntries = entries
        viewModel.localDerived = SSHPaneDerived(entries: entries)
    }

    // Drives a plain-click on the entry at `index` (sets anchor + single selection).
    func plainSelectLocalAtForTesting(_ index: Int) {
        guard index < viewModel.localEntries.count else { return }
        viewModel.selectLocal(viewModel.localEntries[index], flags: [])
    }

    // Drives a shift-click on the entry at `index` (range from anchor to index).
    func shiftSelectLocalAtForTesting(_ index: Int) {
        guard index < viewModel.localEntries.count else { return }
        viewModel.selectLocal(viewModel.localEntries[index], flags: .shift)
    }

    // Drives a cmd-click on the entry at `index` (toggle).
    func cmdSelectLocalAtForTesting(_ index: Int) {
        guard index < viewModel.localEntries.count else { return }
        viewModel.selectLocal(viewModel.localEntries[index], flags: .command)
    }

    var cancelledCountForTesting: Int { viewModel.queueItems.filter { $0.status == .cancelled }.count }
    var transferringCountForTesting: Int { viewModel.queueItems.filter { $0.status == .transferring }.count }
    func queueProgressForTesting(localPath: String, remotePath: String) -> Int? {
        viewModel.queueItems.first { $0.localPath == localPath && $0.remotePath == remotePath }?.progress
    }

    /// Seed a queued row so cancel/progress logic can be exercised without a
    /// router round-trip.
    func enqueueForTesting(upload: Bool, localPath: String, remotePath: String) {
        viewModel.recordTransfer(direction: upload ? .upload : .download, localPath: localPath, remotePath: remotePath, status: .queued)
    }

    /// Marks the active row for this path-pair cancelled, mirroring the UI cancel
    /// control + the surface's cooperative cancel registration.
    @discardableResult
    func markCancelledForTesting(localPath: String, remotePath: String) -> Bool {
        requestCancel(localPath: localPath, remotePath: remotePath)
        return viewModel.queueItems.contains { $0.localPath == localPath && $0.remotePath == remotePath && $0.status == .cancelled }
    }

    func updateProgressForTesting(localPath: String, remotePath: String, percent: Int) {
        viewModel.updateProgress(localPath: localPath, remotePath: remotePath, percent: percent)
    }

    /// Drives a single transfer end-to-end through the same path the UI uses so
    /// tests can exercise queue/status updates with a fake router.
    func runTransferForTesting(upload: Bool, localPath: String, remotePath: String) {
        runTransfer(upload: upload, localPath: localPath, remotePath: remotePath)
    }

    // MARK: - Drag-and-drop (Finder -> remote pane)

    /// Accepts file URLs dropped onto the remote pane and queues one upload per
    /// valid URL. Returns the number of requests enqueued so tests can verify the
    /// count without inspecting the full queue. The surface uses
    /// viewModel.remoteSitePath as the destination directory, matching the
    /// currently-browsed remote path visible in the UI.
    @discardableResult
    func handleFinderDropOnRemotePane(urls: [URL]) -> Int {
        let requests = SSHDropPayloadResolver.resolve(
            fileURLs: urls,
            remotePath: viewModel.remoteSitePath
        )
        for req in requests {
            runTransfer(upload: true, localPath: req.localPath, remotePath: req.remotePath)
        }
        return requests.count
    }

    /// Testing accessor — same as handleFinderDropOnRemotePane but callable from
    /// test targets without spinning up a real Finder drag session.
    @discardableResult
    func handleFinderDropOnRemotePaneForTesting(urls: [URL]) -> Int {
        handleFinderDropOnRemotePane(urls: urls)
    }
}

private struct SSHFileEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let kind: String
    let size: String
    let fileType: String
    let modified: String

    var isDirectory: Bool { kind == "directory" }
}

private enum SSHTransferDirection: String {
    case upload = "Upload"
    case download = "Download"
}

// Pure parser for scp progress lines (P1: per-row transfer progress). scp emits
// progress to stderr as a single rewritten line per file, e.g.
//   "bigfile.iso   23%  118MB   5.8MB/s   01:23 ETA"
// The whole token set is whitespace-separated; the percent token always ends
// with '%'. We pull percent (0...100) and, when present, the cumulative byte
// count. Non-progress lines (banners, errors, prompts) return nil so the caller
// leaves the row's progress untouched. Kept non-MainActor + pure for testing.
enum SSHTransferProgressParser {
    struct Sample: Equatable {
        let percent: Int
        let bytes: Int64?
    }

    static func parse(_ rawLine: String) -> Sample? {
        // scp rewrites the same line with carriage returns; take the last
        // segment so a buffered chunk yields the freshest sample.
        let line = rawLine
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .last
            .map(String.init) ?? rawLine
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let percentToken = tokens.first(where: { $0.hasSuffix("%") }) else { return nil }
        let digits = percentToken.dropLast()
        guard !digits.isEmpty, let percent = Int(digits), (0...100).contains(percent) else {
            return nil
        }
        // The transferred-size token follows the percent token (e.g. "118MB").
        var bytes: Int64?
        if let percentIndex = tokens.firstIndex(of: percentToken), percentIndex + 1 < tokens.count {
            bytes = parseByteCount(tokens[percentIndex + 1])
        }
        return Sample(percent: percent, bytes: bytes)
    }

    // Parses scp's human-readable size tokens ("118MB", "1024KB", "512", "1.5GB")
    // into a byte count. Returns nil when the token isn't a size.
    static func parseByteCount(_ token: String) -> Int64? {
        let suffixes: [(String, Double)] = [
            ("GB", 1_073_741_824), ("MB", 1_048_576), ("KB", 1_024),
            ("G", 1_073_741_824), ("M", 1_048_576), ("K", 1_024), ("B", 1)
        ]
        for (suffix, multiplier) in suffixes where token.hasSuffix(suffix) {
            let number = token.dropLast(suffix.count)
            guard !number.isEmpty, let value = Double(number) else { return nil }
            return Int64(value * multiplier)
        }
        // Bare integer (no unit) is a raw byte count.
        return Int64(token)
    }
}

// Pure builder for recursive (folder) scp transfers (P1: recursive folder
// transfer). The shared SSHCommandBuilder.scp*Arguments helpers omit "-r", so a
// folder transfer silently no-ops; this mirrors their base flags and inserts
// "-r" so directory trees copy. Kept here (owned file) + non-MainActor + pure so
// the argv is unit-testable without touching the router or CoreModel.
enum SSHRecursiveTransferCommand {
    static func scpRecursiveArguments(
        profile: SSHHostProfile,
        upload: Bool,
        localPath: String,
        remotePath: String
    ) -> [String] {
        var args = baseArguments(profile: profile)
        args.append("-r")
        let remote = "\(profile.destination):\(remotePath)"
        if upload {
            args += [localPath, remote]
        } else {
            args += [remote, localPath]
        }
        return args
    }

    private static func baseArguments(profile: SSHHostProfile) -> [String] {
        var args = [
            "-o", "ConnectTimeout=6",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if let port = profile.port { args += ["-P", String(port)] }
        if let identity = profile.identityFile, !identity.isEmpty { args += ["-i", identity] }
        for option in profile.options where !option.isEmpty {
            args += ["-o", option]
        }
        return args
    }
}

// Pure builders for remote file-management commands (mkdir/rename/delete) sent
// to the remote host via the existing SSH exec channel. Kept non-MainActor +
// pure so the exact argv shape can be tested without any network or router.
// All paths are single-quoted with the standard POSIX escape so spaces, dollar
// signs, backticks, and other shell metacharacters reach the remote shell
// verbatim.
enum SSHRemoteManagementCommand {

    // POSIX single-quote escaping: wrap the value in single-quotes and replace
    // every embedded single-quote with the sequence '\'' (end-quote, literal
    // apostrophe, re-open-quote). This is the safest shell-quoting approach
    // because single-quoting suppresses ALL expansion: variables, globs,
    // history, command substitution -- regardless of the remote shell variant.
    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    // Returns the full ssh argv to create a remote directory and all parents.
    // The remote script is: mkdir -p 'QUOTED_PATH'
    static func mkdirArguments(profile: SSHHostProfile, path: String) -> [String] {
        sshBaseArguments(profile: profile) + ["sh", "-c", "mkdir -p \(shellQuote(path))"]
    }

    // Returns the full ssh argv to rename (move) a remote path.
    // The remote script is: mv -- 'SRC' 'DST'
    // The -- sentinel prevents paths starting with '-' from being parsed as flags.
    static func renameArguments(profile: SSHHostProfile, from: String, to: String) -> [String] {
        sshBaseArguments(profile: profile) + ["sh", "-c", "mv -- \(shellQuote(from)) \(shellQuote(to))"]
    }

    // Returns the full ssh argv to delete a remote path.
    // Files: rm -f -- 'PATH'; Directories: rm -rf -- 'PATH'
    // The -f flag suppresses errors on already-absent targets; -- guards against
    // flag-like path names (e.g. a file named "-rf").
    static func deleteArguments(profile: SSHHostProfile, path: String, isDirectory: Bool) -> [String] {
        let rmCmd = isDirectory ? "rm -rf -- \(shellQuote(path))" : "rm -f -- \(shellQuote(path))"
        return sshBaseArguments(profile: profile) + ["sh", "-c", rmCmd]
    }

    // Mirrors SSHCommandBuilder.sshArguments(for:) base flags without the
    // terminal-interaction options (ServerAlive, BatchMode) that are unnecessary
    // for short management exec commands.
    private static func sshBaseArguments(profile: SSHHostProfile) -> [String] {
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if let port = profile.port { args += ["-p", String(port)] }
        if let identity = profile.identityFile, !identity.isEmpty { args += ["-i", identity] }
        for option in profile.options where !option.isEmpty {
            args += ["-o", option]
        }
        args.append(profile.destination)
        return args
    }
}

// Extension on AppCommandRouter (same module) that adds the remote management
// async exec channel. Resolves the SSHHostProfile from the surface registry so
// this code lives entirely in the owned file and avoids touching AppCommandRouter.swift.
extension AppCommandRouter {
    /// Run a one-shot remote shell command on the SSH host attached to `surface`.
    /// Returns true when the remote exit code is 0. Runs off the main run loop
    /// via Task.detached so the caller's actor is never blocked.
    func sshRemoteManageAsync(argv: [String], password: String?) async throws -> Bool {
        let result = try await ProviderCLIProbe.runOffCooperativePool {
            Result { try Self.runCommandBlocking(executable: "/usr/bin/ssh", arguments: argv, password: password) }
        }.get()
        return result.exitCode == 0
    }
}

// Pure keyboard-navigation helper for the SSH host list.
// Non-MainActor + pure so the movement math is testable without any UI.
//
// moveHostSelection(current:direction:count:)
//   direction: +1 = down, -1 = up.
//   Returns nil when count == 0 (empty list -- no movement, no crash).
//   Clamps result to 0..<count so callers never receive an out-of-range index.
//   nil current with count > 0 returns 0 (first row) regardless of direction.
enum SSHHostKeyboardNav {
    static func moveHostSelection(current: Int?, direction: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let idx = current else { return 0 }
        return max(0, min(count - 1, idx + direction))
    }
}

// Pure policy for the "large tree" confirm before a recursive transfer (P1:
// explicit confirm for large trees). Avoids surprising the user with a huge
// silent copy. Non-MainActor + pure so the threshold logic is testable.
enum SSHLargeTreeConfirm {
    static let fileCountThreshold = 50
    static let byteThreshold: Int = 100 * 1_048_576 // 100 MB

    static func needsConfirm(fileCount: Int, totalBytes: Int) -> Bool {
        fileCount > fileCountThreshold || totalBytes > byteThreshold
    }
}

// Pure model for a single drag-and-drop upload request produced by the resolver
// (P3: SSH drag-and-drop). Carries the three fields the surface's runTransfer
// needs so no view or router dependency is required.
struct SSHDropTransferRequest: Equatable, Sendable {
    let localPath: String
    let remotePath: String
    let isDirectory: Bool
}

// Pure resolver that converts a raw drop payload (file URLs + current remote
// path) into a list of upload requests. Non-MainActor so it is fully testable
// without a window, surface, or router. Mirrors the FileZilla mental model:
// every dropped item becomes an upload to remotePath/filename.
enum SSHDropPayloadResolver {
    // Resolves each URL to one SSHDropTransferRequest.
    // Rules:
    //  - URLs with an empty lastPathComponent (e.g. "/") are skipped.
    //  - isDirectory is determined from the URL's hasDirectoryPath flag so
    //    tests can control it by constructing URL(fileURLWithPath:isDirectory:).
    //  - Trailing slashes on remotePath are stripped before joining.
    static func resolve(fileURLs: [URL], remotePath: String) -> [SSHDropTransferRequest] {
        let cleanRemote = remotePath.hasSuffix("/") && remotePath.count > 1
            ? String(remotePath.dropLast())
            : remotePath
        return fileURLs.compactMap { url in
            let name = url.lastPathComponent
            guard !name.isEmpty, name != "/" else { return nil }
            let destRemote = cleanRemote + "/" + name
            return SSHDropTransferRequest(
                localPath: url.path,
                remotePath: destRemote,
                isDirectory: url.hasDirectoryPath
            )
        }
    }
}

// Pure helpers for per-host path persistence (P3: SSH per-host recent paths).
// Non-MainActor + pure so storage-key logic and the bounded-list algorithm can
// be driven in tests without any UI or UserDefaults side-effects.
//
// storageKey:       UserDefaults key for the last local+remote path pair.
// recentRemotePathsKey: UserDefaults key for the bounded most-recent-remote-paths list.
// updatedRecentPaths:   Pure list update - moves the path to front, deduplicates,
//                       and trims to `limit`. Isolated from UserDefaults so the
//                       exact ordering contract is testable.
enum SSHHostRecentPaths {
    // The key that stores the last {"local": ..., "remote": ...} pair for a
    // given profile.  Mirrors the legacy key format so existing persisted data
    // is read back correctly.
    static func storageKey(profileID: SSHHostID) -> String {
        "ssh.transfer.lastpaths.\(profileID.value.uuidString)"
    }

    // The key that stores the ordered list of recent remote paths for a given
    // profile (most-recent first, bounded to `recentPathsLimit` entries).
    static func recentRemotePathsKey(profileID: SSHHostID) -> String {
        "ssh.transfer.recentremote.\(profileID.value.uuidString)"
    }

    // Maximum number of entries kept in the recent-remote-paths list.
    static let recentPathsLimit = 10

    // Pure: returns the list after moving `path` to the front, deduplicating,
    // and capping at `limit`. Callers pass their current stored list so this
    // function is side-effect free and fully testable.
    static func updatedRecentPaths(
        _ current: [String],
        adding path: String,
        limit: Int = recentPathsLimit
    ) -> [String] {
        guard !path.isEmpty else { return current }
        var result = current.filter { $0 != path }
        result.insert(path, at: 0)
        return limit > 0 ? Array(result.prefix(limit)) : result
    }
}

// Pure parser for ~/.ssh/config files. Reads Host blocks and extracts
// HostName (destination), User, Port, and IdentityFile per stanza.
// Wildcard patterns ("*", "?", "!") and pattern-only hosts are skipped
// because they cannot map to a single connectable address.
// Comments (#) and blank lines are ignored. Non-MainActor + pure for testing.
enum SSHConfigParser {
    // Parsed representation of a single Host block.
    struct HostEntry: Equatable {
        let hostAlias: String   // The literal token after "Host"
        let hostName: String    // HostName value (falls back to hostAlias)
        let user: String?
        let port: Int?
        let identityFile: String?
    }

    // Parse the text content of an ssh_config file into host entries,
    // skipping wildcard-only aliases. Returns entries in declaration order.
    static func parseText(_ text: String) -> [HostEntry] {
        var results: [HostEntry] = []
        var currentAlias: String?
        var currentHostName: String?
        var currentUser: String?
        var currentPort: Int?
        var currentIdentityFile: String?

        func flush() {
            guard let alias = currentAlias, !Self.isWildcard(alias) else { return }
            let destination: String
            if let u = currentUser, !u.isEmpty {
                destination = "\(u)@\(currentHostName ?? alias)"
            } else {
                destination = currentHostName ?? alias
            }
            results.append(HostEntry(
                hostAlias: alias,
                hostName: destination,
                user: currentUser,
                port: currentPort,
                identityFile: currentIdentityFile
            ))
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            let keyword = parts[0].lowercased()
            let value = parts[1...].joined(separator: " ")
            switch keyword {
            case "host":
                flush()
                currentAlias = value
                currentHostName = nil
                currentUser = nil
                currentPort = nil
                currentIdentityFile = nil
            case "hostname":
                currentHostName = value
            case "user":
                currentUser = value
            case "port":
                currentPort = Int(value)
            case "identityfile":
                currentIdentityFile = Self.expandTilde(value)
            default:
                break
            }
        }
        flush()
        return results
    }

    // Convert entries to SSHHostProfile values ready for upsert.
    // The profile label is the hostAlias; destination is user@hostname or hostname.
    static func parse(text: String) -> [SSHHostProfile] {
        parseText(text).map { entry in
            SSHHostProfile(
                label: entry.hostAlias,
                destination: entry.hostName,
                port: entry.port,
                identityFile: entry.identityFile
            )
        }
    }

    // Read and parse the file at the given URL. Returns [] when the file is
    // unreadable (missing, permission denied).
    static func parse(fileURL: URL) -> [SSHHostProfile] {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe), let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text: text)
    }

    // Returns true when the host pattern is a glob/wildcard that cannot map to
    // a single connectable address (*, ?, ! prefix, or multi-token patterns).
    static func isWildcard(_ token: String) -> Bool {
        token.contains("*") || token.contains("?") || token.hasPrefix("!")
    }

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return NSHomeDirectory() + path.dropFirst()
    }
}

private struct SSHPaneDerived {
    var directories: [SSHFileEntry] = []
    var fileCount = 0
    var totalBytes = 0

    init() {}

    init(entries: [SSHFileEntry]) {
        var dirs: [SSHFileEntry] = []
        dirs.reserveCapacity(entries.count)
        var count = 0
        var bytes = 0
        for entry in entries {
            if entry.isDirectory {
                dirs.append(entry)
            } else {
                count += 1
                if let size = Int(entry.size) { bytes += size }
            }
        }
        directories = dirs
        fileCount = count
        totalBytes = bytes
    }
}

private enum SSHTransferState: String, CaseIterable {
    case queued = "Queued"
    case transferring = "Transferring"
    case failed = "Failed"
    case cancelled = "Cancelled"
    case successful = "Successful"
}

private struct SSHTransferQueueItem: Identifiable, Hashable {
    let id = UUID()
    let direction: SSHTransferDirection
    let localPath: String
    let remotePath: String
    let size: String
    let status: SSHTransferState
    // 0...100 while .transferring; nil otherwise. Drives the per-row progress
    // bar + percent label (P1).
    var progress: Int? = nil
}

private struct SSHFileColumnWidths {
    var name: CGFloat = 220
    var size: CGFloat = 82
    var type: CGFloat = 104
    var modified: CGFloat = 132

    var total: CGFloat { name + size + type + modified }
}

// Pure connect-phase state machine — no UI, no actor isolation.
// Extracted so phase-transition invariants can be tested without touching
// SSHSurface directly. Rule: .painting always precedes .connecting, and
// .connecting must precede .connected/.failed.
enum SSHConnectPhase: Equatable {
    case painting     // status label set, waiting for next runloop pass
    case connecting   // keychain read + TerminalSurface init in progress
    case connected    // session live
    case failed       // setup threw; error stored separately

    // Returns valid next phases from the current one.
    // Used by tests to assert the one-way ordering invariant.
    nonisolated static func validTransitions(from phase: SSHConnectPhase) -> Set<SSHConnectPhase> {
        switch phase {
        case .painting:   return [.connecting]
        case .connecting: return [.connected, .failed]
        case .connected:  return []
        case .failed:     return []
        }
    }
}

private struct SSHQueueColumnWidths {
    var local: CGFloat = 210
    var direction: CGFloat = 86
    var remote: CGFloat = 180
    var size: CGFloat = 70
    var status: CGFloat = 86

    var total: CGFloat { local + direction + remote + size + status }
}

// Pure helper for shift-click range selection in SSH file tables.
// Returns the closed range lo...hi (inclusive, order-independent) for a
// contiguous row selection from `anchor` to `clicked` within a list of `count`
// rows. Returns nil when either index is out of bounds.
//
// Convention implemented:
//   - shift-click selects anchor...clicked, REPLACING the current selection.
//   - The anchor is set on plain click and held fixed for successive shift-clicks.
//   - cmd+shift is not handled here (cmd takes priority at the call site).
//
// WHY internal (not fileprivate): the pure index math must be testable without
// constructing SSHFileEntry (private) values.
func sshRangeIndices(anchor: Int, clicked: Int, count: Int) -> ClosedRange<Int>? {
    let lo = min(anchor, clicked)
    let hi = max(anchor, clicked)
    guard lo >= 0, hi < count else { return nil }
    return lo...hi
}

@MainActor
fileprivate final class SSHSurfaceViewModel: ObservableObject {
    @Published var hosts: [SSHHostProfile] = []
    @Published var hostFilter = ""
    @Published var selectedHost: SSHHostProfile?
    @Published var showForm = false
    @Published var sidebarCollapsed = false {
        didSet { onSidebarCollapsedChange?(sidebarCollapsed) }
    }
    var hostSidebarIntent: AdaptiveSidebarIntent = .auto
    var lastAutomaticHostSidebarChange: TimeInterval?
    @Published var status = L("Disconnected")
    @Published var error: String?
    @Published var draft = SSHHostDraft()
    @Published var editingHostID: SSHHostID?
    @Published var transferSidebarVisible = false
    @Published var transferSidebarCollapsed = false {
        didSet { onTransferSidebarCollapsedChange?(transferSidebarCollapsed) }
    }
    @Published var localSitePath = ""
    @Published var remoteSitePath = "/"
    @Published var localEntries: [SSHFileEntry] = []
    @Published var remoteEntries: [SSHFileEntry] = []
    // Per-pane listing error so the empty state can distinguish "empty
    // directory" from "listing failed / permission denied" (UX-MAC_SSH-011).
    @Published var localListError: String?
    @Published var remoteListError: String?
    // Derived once per listing so the views don't filter/map/reduce on every
    // render (PERF-MAC_SSH-008 / PERF-MAC_SSH-009).
    @Published var localDerived = SSHPaneDerived()
    @Published var remoteDerived = SSHPaneDerived()
    @Published var selectedLocalEntry: SSHFileEntry?
    @Published var selectedRemoteEntry: SSHFileEntry?
    @Published var selectedLocalIDs: Set<String> = []
    @Published var selectedRemoteIDs: Set<String> = []
    // Anchor row index for shift-click range selection (Mac convention).
    // Set on plain click; not updated on cmd-click or shift-click so the range
    // always extends from the original anchor row.
    var lastClickedLocalIndex: Int?
    var lastClickedRemoteIndex: Int?
    @Published var transferLocalPath = ""
    @Published var transferRemotePath = ""
    @Published var transferStatus = L("Ready")
    @Published var transferLogs: [String] = ["Ready"]
    @Published var queueItems: [SSHTransferQueueItem] = []
    @Published var selectedQueueState: SSHTransferState = .queued

    // True while the SSH child process is known to have exited without an explicit
    // user disconnect - drives the "Disconnected" pill in SSHHostRow.
    @Published var sessionDead = false

    var onRefresh: (() -> Void)?
    var onSave: ((SSHHostDraft) -> Void)?
    var onConnect: ((SSHHostProfile) -> Void)?
    var onOpenNewConnection: ((SSHHostProfile) -> Void)?
    var onDelete: ((SSHHostProfile) -> Void)?
    var onImportFromConfig: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onSidebarCollapsedChange: ((Bool) -> Void)?
    var onTransferSidebarCollapsedChange: ((Bool) -> Void)?
    var onTransfer: ((Bool, String, String) -> Void)?
    // Drag-and-drop from Finder or local pane onto the remote pane (P3 DnD).
    // The overlay fires this with the dropped file URLs; the surface resolves
    // them and queues upload requests.
    var onDropOnRemotePane: (([URL]) -> Void)?
    // Routes a per-row cancel back to the surface so it can register the cancel
    // key the async completion path checks (P1).
    var onCancelTransfer: ((String, String) -> Void)?
    var onRefreshLocalFiles: (() -> Void)?
    var onRefreshRemoteFiles: (() -> Void)?
    var onChooseLocalPath: (() -> Void)?
    // Remote file-management callbacks wired to the surface's exec channel.
    var onRemoteMkdir: ((String) -> Void)?
    var onRemoteRename: ((String, String) -> Void)?
    var onRemoteDelete: ((String, Bool) -> Void)?
    // Injectable identity-file picker so the form sheet can be driven without a
    // blocking NSOpenPanel modal (QA-MAC_SSH-003). Default nil → real panel.
    var identityFilePicker: (() -> String?)?

    // Filter saved hosts by label or destination so the list scales past a
    // handful of entries (IMP-MAC_SSH-009).
    var filteredHosts: [SSHHostProfile] {
        let needle = hostFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return hosts }
        return hosts.filter {
            // PERF: avoid per-host lowercased() alloc on every keystroke — use case-insensitive range
            $0.label.range(of: needle, options: .caseInsensitive) != nil || $0.destination.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    func resetDraft() {
        draft = SSHHostDraft()
        editingHostID = nil
        showForm = true
        hostSidebarIntent = .forcedVisible
        sidebarCollapsed = false
    }

    func edit(_ host: SSHHostProfile) {
        draft = SSHHostDraft(host: host)
        editingHostID = host.id
        showForm = true
        hostSidebarIntent = .forcedVisible
        sidebarCollapsed = false
    }

    func duplicate(_ host: SSHHostProfile) {
        // Pre-fill the form from an existing host but clear the id/label so save
        // creates a new profile instead of editing the original (IMP-MAC_SSH-007).
        var prefilled = SSHHostDraft(host: host)
        prefilled.id = nil
        prefilled.label = host.label.isEmpty ? "" : L("%1$@ copy", host.label)
        draft = prefilled
        editingHostID = nil
        showForm = true
        hostSidebarIntent = .forcedVisible
        sidebarCollapsed = false
    }

    func cancelDraft() {
        showForm = false
        editingHostID = nil
        error = nil
    }

    func prepareTransferPanel(localPath: String, remotePath: String) {
        // Resume where the user left off on this host instead of always starting
        // at cwd / "/" (IMP-MAC_SSH-013). Persisted paths win over the defaults.
        let restored = Self.restorePaths(host: selectedHost)
        localSitePath = restored.local ?? (localSitePath.isEmpty ? localPath : localSitePath)
        remoteSitePath = restored.remote ?? (remoteSitePath.isEmpty ? remotePath : remoteSitePath)
        addTransferLog(L("Connected"))
    }

    private static func pathsDefaultsKey(host: SSHHostProfile?) -> String? {
        guard let host else { return nil }
        return SSHHostRecentPaths.storageKey(profileID: host.id)
    }

    private static func restorePaths(host: SSHHostProfile?) -> (local: String?, remote: String?) {
        guard let key = pathsDefaultsKey(host: host),
              let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else {
            return (nil, nil)
        }
        return (stored["local"], stored["remote"])
    }

    func persistLastPaths() {
        guard let key = Self.pathsDefaultsKey(host: selectedHost) else { return }
        UserDefaults.standard.set(["local": localSitePath, "remote": remoteSitePath], forKey: key)
    }

    func applyLocalListing(_ object: [String: JSONValue]) {
        localListError = nil
        localSitePath = object["path"]?.stringValue ?? localSitePath
        localEntries = decodeEntries(object["entries"]?.arrayValue)
        localDerived = SSHPaneDerived(entries: localEntries)
        selectedLocalIDs = selectedLocalIDs.intersection(Set(localEntries.map(\.id)))
        if let selectedLocalEntry, !selectedLocalIDs.contains(selectedLocalEntry.id) {
            self.selectedLocalEntry = nil
        }
        transferStatus = L("Local listed")
        addTransferLog(L("Local site: %1$@", localSitePath))
        persistLastPaths()
    }

    func applyRemoteListing(_ object: [String: JSONValue]) {
        remoteListError = nil
        remoteSitePath = object["path"]?.stringValue ?? remoteSitePath
        remoteEntries = decodeEntries(object["entries"]?.arrayValue)
        remoteDerived = SSHPaneDerived(entries: remoteEntries)
        selectedRemoteIDs = selectedRemoteIDs.intersection(Set(remoteEntries.map(\.id)))
        if let selectedRemoteEntry, !selectedRemoteIDs.contains(selectedRemoteEntry.id) {
            self.selectedRemoteEntry = nil
        }
        transferStatus = L("Remote listed")
        addTransferLog(L("Remote site: %1$@", remoteSitePath))
        persistLastPaths()
        // Record this remote path in the bounded most-recent list for the profile
        // so reconnects can restore it and the path picker can suggest history.
        if let profile = selectedHost {
            let key = SSHHostRecentPaths.recentRemotePathsKey(profileID: profile.id)
            let current = UserDefaults.standard.stringArray(forKey: key) ?? []
            let updated = SSHHostRecentPaths.updatedRecentPaths(current, adding: remoteSitePath)
            UserDefaults.standard.set(updated, forKey: key)
        }
    }

    func selectLocal(_ entry: SSHFileEntry, flags: NSEvent.ModifierFlags = []) {
        let isCmd = flags.contains(.command)
        let isShift = flags.contains(.shift) && !isCmd
        let clickedIndex = localEntries.firstIndex(where: { $0.id == entry.id })

        if isShift, let anchor = lastClickedLocalIndex, let clicked = clickedIndex,
           let range = sshRangeIndices(anchor: anchor, clicked: clicked, count: localEntries.count) {
            // Shift-click: replace selection with contiguous anchor...clicked range.
            selectedLocalIDs = Set(localEntries[range].map(\.id))
            selectedLocalEntry = entry
            // Do not update lastClickedLocalIndex -- anchor stays fixed for
            // successive shift-clicks (Mac Finder convention).
        } else if isCmd {
            // Cmd-click: toggle this row additively; anchor stays at last plain click.
            selectedLocalEntry = entry
            if selectedLocalIDs.contains(entry.id) {
                selectedLocalIDs.remove(entry.id)
            } else {
                selectedLocalIDs.insert(entry.id)
            }
        } else {
            // Plain click: single selection + set anchor.
            selectedLocalEntry = entry
            selectedLocalIDs = [entry.id]
            lastClickedLocalIndex = clickedIndex
        }
    }

    func selectRemote(_ entry: SSHFileEntry, flags: NSEvent.ModifierFlags = []) {
        let isCmd = flags.contains(.command)
        let isShift = flags.contains(.shift) && !isCmd
        let clickedIndex = remoteEntries.firstIndex(where: { $0.id == entry.id })

        if isShift, let anchor = lastClickedRemoteIndex, let clicked = clickedIndex,
           let range = sshRangeIndices(anchor: anchor, clicked: clicked, count: remoteEntries.count) {
            // Shift-click: replace selection with contiguous anchor...clicked range.
            selectedRemoteIDs = Set(remoteEntries[range].map(\.id))
            selectedRemoteEntry = entry
        } else if isCmd {
            // Cmd-click: toggle this row additively; anchor stays at last plain click.
            selectedRemoteEntry = entry
            if selectedRemoteIDs.contains(entry.id) {
                selectedRemoteIDs.remove(entry.id)
            } else {
                selectedRemoteIDs.insert(entry.id)
            }
        } else {
            // Plain click: single selection + set anchor.
            selectedRemoteEntry = entry
            selectedRemoteIDs = [entry.id]
            lastClickedRemoteIndex = clickedIndex
        }
    }

    func openLocal(_ entry: SSHFileEntry) {
        if entry.isDirectory {
            localSitePath = entry.path
            onRefreshLocalFiles?()
        }
    }

    func openRemote(_ entry: SSHFileEntry) {
        if entry.isDirectory {
            remoteSitePath = entry.path
            onRefreshRemoteFiles?()
        }
    }

    func goUpLocal() {
        let parent = parentPath(localSitePath)
        guard parent != localSitePath else { return }
        localSitePath = parent
        onRefreshLocalFiles?()
    }

    func goUpRemote() {
        let parent = parentPath(remoteSitePath)
        guard parent != remoteSitePath else { return }
        remoteSitePath = parent
        onRefreshRemoteFiles?()
    }

    private func parentPath(_ path: String) -> String {
        let trimmed = path.isEmpty ? "/" : path
        let parent = (trimmed as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    func localTransferEntries(anchor: SSHFileEntry) -> [SSHFileEntry] {
        let selected = localEntries.filter { selectedLocalIDs.contains($0.id) && !$0.isDirectory }
        if selectedLocalIDs.contains(anchor.id), !selected.isEmpty { return selected }
        return anchor.isDirectory ? [] : [anchor]
    }

    func remoteTransferEntries(anchor: SSHFileEntry) -> [SSHFileEntry] {
        let selected = remoteEntries.filter { selectedRemoteIDs.contains($0.id) && !$0.isDirectory }
        if selectedRemoteIDs.contains(anchor.id), !selected.isEmpty { return selected }
        return anchor.isDirectory ? [] : [anchor]
    }

    func uploadLocalSelection(anchor: SSHFileEntry) {
        let entries = localTransferEntries(anchor: anchor)
        // UX-P2: directories are silently skipped by scp; tell the user so it
        // does not look like the transfer was accepted (mac-aux-surfaces §SSH P2).
        if entries.isEmpty {
            transferStatus = anchor.isDirectory
                ? L("Folders cannot be transferred - select individual files")
                : L("No files selected")
            return
        }
        for entry in entries {
            let remotePath = (remoteSitePath as NSString).appendingPathComponent(entry.name)
            onTransfer?(true, entry.path, remotePath)
        }
    }

    func downloadRemoteSelection(anchor: SSHFileEntry) {
        let entries = remoteTransferEntries(anchor: anchor)
        // UX-P2: same directory guard for the download direction.
        if entries.isEmpty {
            transferStatus = anchor.isDirectory
                ? L("Folders cannot be transferred - select individual files")
                : L("No files selected")
            return
        }
        for entry in entries {
            let localPath = (localSitePath as NSString).appendingPathComponent(entry.name)
            onTransfer?(false, localPath, entry.path)
        }
    }

    func selectLocalPath(_ path: String, isDirectory: Bool) {
        if isDirectory {
            localSitePath = path
            transferLocalPath = path
        } else {
            transferLocalPath = path
            localSitePath = (path as NSString).deletingLastPathComponent
        }
        selectedLocalIDs.removeAll()
        selectedLocalEntry = nil
    }

    func recordTransfer(direction: SSHTransferDirection, localPath: String, remotePath: String, status: SSHTransferState) {
        // Populate the queue Size column from the matching listed file entry so
        // the column isn't permanently blank (UX-MAC_SSH-009). The source side
        // (local for uploads, remote for downloads) holds the authoritative size.
        let size = transferSize(direction: direction, localPath: localPath, remotePath: remotePath)
        let item = SSHTransferQueueItem(direction: direction, localPath: localPath, remotePath: remotePath, size: size, status: status)
        if status != .queued {
            queueItems.removeAll { $0.localPath == localPath && $0.remotePath == remotePath && $0.status == .queued }
        }
        queueItems.insert(item, at: 0)
        // Cap finished-history growth so a long session doesn't accumulate
        // unbounded rows (and SwiftUI diff cost). Keep queued items, trim the
        // oldest terminal entries beyond the cap. (PERF-MAC_SSH-004)
        if queueItems.count > Self.queueHistoryLimit {
            var trimmed: [SSHTransferQueueItem] = []
            var terminalKept = 0
            for queued in queueItems {
                if queued.status == .queued {
                    trimmed.append(queued)
                } else if terminalKept < Self.queueHistoryLimit {
                    trimmed.append(queued)
                    terminalKept += 1
                }
            }
            queueItems = trimmed
        }
        // Only auto-switch the queue tab when the user is watching an active-state
        // tab (.queued/.transferring). If they navigated to .failed/.cancelled/.successful
        // to review results, don't yank them away when an unrelated transfer updates
        // (P2 don't-yank-queue-tab).
        let userIsWatchingActiveTab = selectedQueueState == .queued || selectedQueueState == .transferring
        if userIsWatchingActiveTab {
            selectedQueueState = status
        }
        addTransferLog("\(direction.rawValue): \(status.rawValue)")
    }

    private static let queueHistoryLimit = 200

    // Flip the active (queued/transferring) row for this path-pair to .cancelled
    // so the queue reflects the user's cancel action (P1). Returns true when a
    // row was actually marked, so the surface can short-circuit the transfer.
    @discardableResult
    func markCancelled(localPath: String, remotePath: String) -> Bool {
        var marked = false
        queueItems = queueItems.map { item in
            guard !marked,
                  item.localPath == localPath,
                  item.remotePath == remotePath,
                  item.status == .queued || item.status == .transferring else { return item }
            marked = true
            return SSHTransferQueueItem(
                direction: item.direction,
                localPath: item.localPath,
                remotePath: item.remotePath,
                size: item.size,
                status: .cancelled,
                progress: nil
            )
        }
        if marked {
            let userIsWatchingActiveTab = selectedQueueState == .queued || selectedQueueState == .transferring
            if userIsWatchingActiveTab { selectedQueueState = .cancelled }
            addTransferLog(L("Cancelled: %1$@ -> %2$@", localPath, remotePath))
        }
        return marked
    }

    // Move the active row to .transferring and update its progress percent so the
    // per-row bar advances as scp reports bytes (P1).
    func updateProgress(localPath: String, remotePath: String, percent: Int) {
        queueItems = queueItems.map { item in
            guard item.localPath == localPath,
                  item.remotePath == remotePath,
                  item.status == .queued || item.status == .transferring else { return item }
            return SSHTransferQueueItem(
                direction: item.direction,
                localPath: item.localPath,
                remotePath: item.remotePath,
                size: item.size,
                status: .transferring,
                progress: max(0, min(100, percent))
            )
        }
    }

    private func transferSize(direction: SSHTransferDirection, localPath: String, remotePath: String) -> String {
        let entries = direction == .upload ? localEntries : remoteEntries
        let sourcePath = direction == .upload ? localPath : remotePath
        return entries.first { $0.path == sourcePath }?.size ?? ""
    }

    func clearFinishedTransfers() {
        queueItems.removeAll { $0.status != .queued }
    }

    // Re-run a failed transfer through the same path the original used so users
    // recover from a dropped connection in one click (IMP-MAC_SSH-010). Drops the
    // old failed row; runTransfer re-queues a fresh entry.
    func retryTransfer(_ item: SSHTransferQueueItem) {
        guard item.status == .failed else { return }
        queueItems.removeAll { $0.id == item.id }
        onTransfer?(item.direction == .upload, item.localPath, item.remotePath)
    }

    // Cancel an in-flight (queued/transferring) row from its context menu /
    // cancel control (P1). Delegates to the surface, which both marks the row and
    // registers the cooperative cancel for the async completion path.
    func cancelTransfer(_ item: SSHTransferQueueItem) {
        guard item.status == .queued || item.status == .transferring else { return }
        onCancelTransfer?(item.localPath, item.remotePath)
    }

    func addTransferLog(_ line: String) {
        transferLogs.append(line)
        // Keep a longer rolling history so transient errors don't scroll off
        // instantly; the log pane is scrollable (UX-MAC_SSH-010).
        // PERF: suffix cap only pays when over budget; steady-state appends
        // skip the Array copy. Same retained contents.
        if transferLogs.count > Self.transferLogLimit {
            transferLogs.removeFirst(transferLogs.count - Self.transferLogLimit)
        }
    }

    private static let transferLogLimit = 200

    private func decodeEntries(_ values: [JSONValue]?) -> [SSHFileEntry] {
        values?.compactMap { value in
            guard let object = value.objectValue,
                  let name = object["name"]?.stringValue,
                  let path = object["path"]?.stringValue else { return nil }
            return SSHFileEntry(id: path,
                                name: name,
                                path: path,
                                kind: object["kind"]?.stringValue ?? object["type"]?.stringValue ?? "file",
                                size: object["size"]?.stringValue ?? "",
                                fileType: object["file_type"]?.stringValue ?? "",
                                modified: object["modified"]?.stringValue ?? "")
        } ?? []
    }
}

private final class AdaptiveSSHRootView: NSView {
    var onSizeChanged: ((NSSize) -> Void)?
    private var lastReportedWidth: CGFloat = 0
    private var pendingSize: NSSize?

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        guard oldSize != newSize else { return }
        // The adaptive-sidebar policy only depends on width, and reading
        // UserDefaults + running policy math on every live-resize frame is
        // wasteful. Skip sub-threshold width deltas and coalesce the callback
        // to once per run loop with the final size. (PERF-MAC_SSH-010 / 006)
        guard abs(newSize.width - lastReportedWidth) >= 1 else { return }
        let alreadyPending = pendingSize != nil
        pendingSize = newSize
        guard !alreadyPending else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let size = self.pendingSize else { return }
            self.pendingSize = nil
            self.lastReportedWidth = size.width
            self.onSizeChanged?(size)
        }
    }
}

struct SSHHostDraft {
    var id: SSHHostID?
    var label = ""
    var destination = ""
    var portText = ""
    var identityFileText = ""
    var passwordText = ""
    var hasSavedPassword = false
    var optionLines = ""

    var resolvedLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? destination : trimmed
    }

    var parsedPort: Int? {
        Int(portText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var options: [String] {
        optionLines
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var parsedIdentityFile: String? {
        let trimmed = identityFileText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var parsedPassword: String? {
        passwordText.isEmpty ? nil : passwordText
    }

    init(host: SSHHostProfile? = nil) {
        guard let host else { return }
        id = host.id
        label = host.label
        destination = host.destination
        portText = host.port.map(String.init) ?? ""
        identityFileText = host.identityFile ?? ""
        passwordText = host.password ?? ""
        hasSavedPassword = host.hasSavedPassword || (host.password?.isEmpty == false)
        optionLines = host.options.joined(separator: "\n")
    }
}

private struct SSHSidebarView: View {
    @ObservedObject var vm: SSHSurfaceViewModel
    // Keyboard highlight index into vm.filteredHosts. nil means no keyboard
    // row is highlighted; mouse clicks clear this so the two selections stay
    // independent. Clamped by SSHHostKeyboardNav so it is always in-range.
    @State private var keyboardHighlightedHostIndex: Int?

    var body: some View {
        Group {
            if vm.sidebarCollapsed {
                collapsedRail
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    DSSectionHeaderG("SSH") {
                        HStack(spacing: DS.Space.xs) {
                            DSIconButton("sidebar.left", help: L("Hide hosts")) {
                                vm.hostSidebarIntent = .forcedHidden
                                vm.sidebarCollapsed = true
                            }
                            .accessibilityIdentifier("ssh.sidebar.host.toggle")
                            DSIconButton("square.and.arrow.down", help: L("Import hosts from ~/.ssh/config")) {
                                vm.onImportFromConfig?()
                            }
                            .accessibilityIdentifier("ssh.host.import")
                            DSIconButton("plus", help: L("Add SSH host")) {
                                vm.resetDraft()
                            }
                            .accessibilityIdentifier("ssh.host.add")
                        }
                    }
                    Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                            savedHosts
                        }
                        .padding(DS.Space.sm)
                    }
                    .focusable()
                    .onMoveCommand { direction in
                        let delta: Int
                        switch direction {
                        case .up:   delta = -1
                        case .down: delta = 1
                        default: return
                        }
                        let count = vm.filteredHosts.count
                        keyboardHighlightedHostIndex = SSHHostKeyboardNav.moveHostSelection(
                            current: keyboardHighlightedHostIndex,
                            direction: delta,
                            count: count
                        )
                    }
                    .onKeyPress(.return) {
                        guard let idx = keyboardHighlightedHostIndex,
                              idx < vm.filteredHosts.count else { return .ignored }
                        vm.onConnect?(vm.filteredHosts[idx])
                        keyboardHighlightedHostIndex = nil
                        return .handled
                    }
                }
                .background(DS.Palette.sidebar)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
                }
            }
        }
        .background(DS.Palette.sidebar)
        .sheet(isPresented: $vm.showForm) {
            SSHHostFormSheet(vm: vm)
        }
    }

    private var collapsedRail: some View {
        VStack(spacing: DS.Space.sm) {
            DSIconButton("sidebar.left", help: L("Show hosts")) {
                vm.hostSidebarIntent = .forcedVisible
                vm.sidebarCollapsed = false
            }
            .accessibilityIdentifier("ssh.sidebar.host.toggle")
            DSIconButton("plus", help: L("Add SSH host")) {
                vm.resetDraft()
            }
            .accessibilityIdentifier("ssh.host.add")
            Divider().overlay(DS.Palette.line)
            Image(systemName: "network")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(vm.selectedHost == nil ? DS.Palette.textTertiary : DS.Palette.accent)
                .frame(width: 28, height: 28)
                .help(vm.selectedHost?.label ?? L("SSH hosts"))
            Spacer()
        }
        .padding(.top, DS.Space.sm)
        .frame(width: 44)
        .background(DS.Palette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }

    private var savedHosts: some View {
        let filtered = vm.filteredHosts
        return VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(vm.hosts.isEmpty ? L("Saved") : L("Saved · %1$@", vm.hosts.count))
                .font(DS.Font.caption2.weight(.semibold))
                .foregroundColor(DS.Palette.textTertiary)
                .textCase(.uppercase)
                .padding(.horizontal, DS.Space.xs)
                .padding(.top, DS.Space.xs)
            if vm.hosts.isEmpty {
                DSEmptyState(
                    icon: "network",
                    title: L("No hosts"),
                    subtitle: L("Add a host to open an SSH terminal."),
                    background: DS.Palette.sidebar
                )
            } else {
                // Search field to filter saved hosts by label/destination
                // (IMP-MAC_SSH-009). Shown only once the list is non-empty.
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Palette.textTertiary)
                    TextField(L("Filter hosts"), text: $vm.hostFilter)
                        .textFieldStyle(.plain)
                        .font(DS.Font.caption)
                        .accessibilityIdentifier("ssh.host.filter")
                    if !vm.hostFilter.isEmpty {
                        Button { vm.hostFilter = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(DS.Palette.textTertiary)
                        .help(L("Clear filter"))
                        .accessibilityLabel(L("Clear host filter"))
                    }
                }
                .padding(.horizontal, DS.Space.xs)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.bg))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Palette.line))
                .padding(.horizontal, DS.Space.xs)
                if filtered.isEmpty {
                    Text(L("No hosts match “%1$@”.", vm.hostFilter))
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .padding(.horizontal, DS.Space.xs)
                        .padding(.top, DS.Space.xs)
                        .accessibilityIdentifier("ssh.host.filter.empty")
                } else {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, host in
                        SSHHostRow(
                            host: host,
                            connected: vm.selectedHost?.id == host.id && vm.status == L("Connected"),
                            sessionDead: vm.selectedHost?.id == host.id && vm.sessionDead,
                            isKeyboardHighlighted: keyboardHighlightedHostIndex == idx,
                            onConnect: {
                                keyboardHighlightedHostIndex = nil
                                vm.onConnect?(host)
                            },
                            onOpenNewConnection: { vm.onOpenNewConnection?(host) },
                            onEdit: { vm.edit(host) },
                            onDuplicate: { vm.duplicate(host) },
                            onDelete: { vm.onDelete?(host) },
                            onDisconnect: { vm.onDisconnect?() }
                        )
                    }
                }
            }
        }
    }

}

private struct SSHTransferSidebarView: View {
    @ObservedObject var vm: SSHSurfaceViewModel
    @State private var fileColumns = SSHFileColumnWidths()
    @State private var queueColumns = SSHQueueColumnWidths()
    @State private var localPaneWidth: CGFloat = 340
    @State private var treeHeight: CGFloat = 126
    @State private var queueHeight: CGFloat = 166
    @State private var showLog = false

    var body: some View {
        Group {
            if !vm.transferSidebarVisible {
                Color.clear
            } else if vm.transferSidebarCollapsed {
                collapsedRail
            } else {
                panel
            }
        }
        .background(DS.Palette.sidebar)
    }

    private var collapsedRail: some View {
        VStack(spacing: DS.Space.sm) {
            DSIconButton("sidebar.right", help: L("Show file transfer")) {
                vm.transferSidebarCollapsed = false
            }
            .accessibilityIdentifier("ssh.sidebar.transfer.toggle")
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Palette.accent)
                .frame(width: 28, height: 28)
                .help(L("SSH file transfer"))
            Spacer()
        }
        .padding(.top, DS.Space.sm)
        .frame(width: 44)
        .overlay(alignment: .leading) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }

    private var panel: some View {
        GeometryReader { proxy in
            let boundedQueueHeight = min(max(queueHeight, 112), max(112, proxy.size.height * 0.42))
            VStack(alignment: .leading, spacing: 0) {
                DSSectionHeaderG(L("Files")) {
                    HStack(spacing: DS.Space.xs) {
                        DSIconButton("arrow.clockwise", help: L("Refresh both panes")) {
                            vm.onRefreshLocalFiles?()
                            vm.onRefreshRemoteFiles?()
                        }
                        .accessibilityIdentifier("ssh.transfer.refresh.both")
                        DSIconButton("sidebar.right", help: L("Hide file transfer")) {
                            vm.transferSidebarCollapsed = true
                        }
                        .accessibilityIdentifier("ssh.sidebar.transfer.toggle")
                    }
                }
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                GeometryReader { contentProxy in
                    let panesHeight = max(220, contentProxy.size.height - boundedQueueHeight - 9)
                    VStack(spacing: 0) {
                        splitPanes
                            .frame(height: panesHeight)
                        DSResizeDivider(axis: .horizontal, help: L("Resize transfer queue")) { delta in
                            queueHeight = min(max(queueHeight - delta, 112), max(112, contentProxy.size.height * 0.56))
                        }
                        queuePanel
                            .frame(height: boundedQueueHeight)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(minWidth: 240)
        .overlay(alignment: .leading) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }

    private var splitPanes: some View {
        GeometryReader { proxy in
            let minPane: CGFloat = min(230, max(180, proxy.size.width * 0.38))
            let maxLeft = max(minPane, proxy.size.width - minPane - 8)
            let leftWidth = min(max(localPaneWidth, minPane), maxLeft)
            HStack(spacing: 0) {
                transferPane(title: L("Local site"),
                             path: $vm.localSitePath,
                             entries: vm.localEntries,
                             derived: vm.localDerived,
                             selectedIDs: vm.selectedLocalIDs,
                             listError: vm.localListError,
                             refresh: { vm.onRefreshLocalFiles?() },
                             up: { vm.goUpLocal() },
                             choose: { vm.onChooseLocalPath?() },
                             open: { vm.openLocal($0) },
                             select: { vm.selectLocal($0, flags: $1) },
                             transferTitle: L("Upload"),
                             transfer: { vm.uploadLocalSelection(anchor: $0) })
                    .frame(width: leftWidth)
                DSResizeDivider(axis: .vertical, help: L("Resize local and remote panes")) { delta in
                    localPaneWidth = min(max(localPaneWidth + delta, minPane), maxLeft)
                }
                transferPane(title: L("Remote site"),
                             path: $vm.remoteSitePath,
                             entries: vm.remoteEntries,
                             derived: vm.remoteDerived,
                             selectedIDs: vm.selectedRemoteIDs,
                             listError: vm.remoteListError,
                             refresh: { vm.onRefreshRemoteFiles?() },
                             up: { vm.goUpRemote() },
                             choose: nil,
                             open: { vm.openRemote($0) },
                             select: { vm.selectRemote($0, flags: $1) },
                             transferTitle: L("Download"),
                             transfer: { vm.downloadRemoteSelection(anchor: $0) })
                // Transparent NSDraggingDestination overlay so Finder and local-pane
                // drags land on the remote pane and queue uploads (P3 DnD).
                .overlay(SSHRemoteDropOverlay { urls in vm.onDropOnRemotePane?(urls) })
                .accessibilityIdentifier("ssh.transfer.remote.drop.target")
            }
        }
    }

    private func transferPane(title: String,
                              path: Binding<String>,
                              entries: [SSHFileEntry],
                              derived: SSHPaneDerived,
                              selectedIDs: Set<String>,
                              listError: String?,
                              refresh: @escaping () -> Void,
                              up: @escaping () -> Void,
                              choose: (() -> Void)?,
                              open: @escaping (SSHFileEntry) -> Void,
                              select: @escaping (SSHFileEntry, NSEvent.ModifierFlags) -> Void,
                              transferTitle: String,
                              transfer: @escaping (SSHFileEntry) -> Void) -> some View {
        // Derive a stable side key (local/remote) for accessibility identifiers
        // so UI automation can address each pane's controls (QA-MAC_SSH-001).
        let side = title.lowercased().hasPrefix("local") ? "local" : "remote"
        return VStack(spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                Text(title + ":")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                Button(action: up) { Image(systemName: "arrow.up") }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .help(L("Go to parent directory"))
                    .accessibilityLabel(L("Go to parent directory"))
                    .accessibilityIdentifier("ssh.transfer.\(side).up")
                TextField("/", text: path, onCommit: refresh)
                    .textFieldStyle(.plain)
                    .font(DS.Font.monoSmall)
                    .padding(.horizontal, DS.Space.xs)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.bg))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Palette.line))
                    .accessibilityIdentifier("ssh.transfer.\(side).path")
                if let choose {
                    Button(action: choose) { Image(systemName: "folder") }
                        .buttonStyle(.plain)
                        .frame(width: 28, height: 28)
                        .help(L("Choose local file or folder"))
                        .accessibilityLabel(L("Choose local file or folder"))
                        .accessibilityIdentifier("ssh.transfer.\(side).choose")
                }
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .help(L("Refresh %1$@", title.lowercased()))
                    .accessibilityLabel(L("Refresh %1$@", title))
                    .accessibilityIdentifier("ssh.transfer.\(side).refresh")
            }
            .padding(DS.Space.xs)
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            directoryTree(directories: derived.directories, path: path.wrappedValue, open: open)
                .frame(height: treeHeight)
            DSResizeDivider(axis: .horizontal, help: L("Resize directory tree")) { delta in
                treeHeight = min(max(treeHeight + delta, 76), 240)
            }
            fileTable(entries: entries,
                      selectedIDs: selectedIDs,
                      listError: listError,
                      isLocal: side == "local",
                      select: select,
                      open: open,
                      transferTitle: transferTitle,
                      transfer: transfer)
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            paneStatus(derived: derived, selectedIDs: selectedIDs)
                .frame(height: 28)
        }
    }

    private func directoryTree(directories: [SSHFileEntry], path: String, open: @escaping (SSHFileEntry) -> Void) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text(path.isEmpty ? "/" : path)
                    .font(DS.Font.monoSmall.weight(.semibold))
                    .lineLimit(1)
                    .foregroundColor(DS.Palette.text)
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.top, DS.Space.xs)
                ForEach(directories) { entry in
                    Button { open(entry) } label: {
                        HStack(spacing: DS.Space.xs) {
                            Image(systemName: entry.name == ".." ? "arrow.turn.up.left" : "folder")
                                .foregroundColor(DS.Palette.textSecondary)
                                .frame(width: 16)
                            Text(entry.name)
                                .lineLimit(1)
                            Spacer()
                        }
                        .font(DS.Font.caption)
                        .padding(.horizontal, DS.Space.sm)
                        .frame(height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(DS.Palette.bg.opacity(0.42))
    }

    private func fileTable(entries: [SSHFileEntry],
                           selectedIDs: Set<String>,
                           listError: String?,
                           isLocal: Bool,
                           select: @escaping (SSHFileEntry, NSEvent.ModifierFlags) -> Void,
                           open: @escaping (SSHFileEntry) -> Void,
                           transferTitle: String,
                           transfer: @escaping (SSHFileEntry) -> Void) -> some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    resizableHeader(L("Name"), width: $fileColumns.name, minWidth: 150)
                    resizableHeader(L("Size"), width: $fileColumns.size, minWidth: 68, alignment: .trailing)
                    resizableHeader(L("Kind"), width: $fileColumns.type, minWidth: 82)
                    resizableHeader(L("Modified"), width: $fileColumns.modified, minWidth: 112)
                }
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        if entries.isEmpty {
                            // Differentiate an empty directory from a failed
                            // listing so the user knows whether to retry or pick
                            // another path (UX-MAC_SSH-011).
                            Text(listError.map { L("Listing failed — %1$@", $0) } ?? L("This folder is empty."))
                                .font(DS.Font.caption)
                                .foregroundColor(listError == nil ? DS.Palette.textTertiary : DS.Palette.danger)
                                .multilineTextAlignment(.center)
                                .frame(width: fileColumns.total)
                                .frame(minHeight: 72)
                                .accessibilityIdentifier(listError == nil ? "ssh.file.empty" : "ssh.file.error")
                        } else {
                            ForEach(entries.indices, id: \.self) { index in
                                let entry = entries[index]
                                Button {
                                    let flags = NSEvent.modifierFlags
                                    select(entry, flags)
                                } label: {
                                    HStack(spacing: 0) {
                                        HStack(spacing: DS.Space.xs) {
                                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                                .foregroundColor(entry.isDirectory ? DS.Palette.textSecondary : DS.Palette.accent)
                                                .frame(width: 16)
                                            Text(entry.name)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer(minLength: 0)
                                        }
                                        .frame(width: fileColumns.name, alignment: .leading)
                                        Text(entry.size)
                                            .lineLimit(1)
                                            .monospacedDigit()
                                            .frame(width: fileColumns.size, alignment: .trailing)
                                        Text(entry.fileType)
                                            .lineLimit(1)
                                            .frame(width: fileColumns.type, alignment: .leading)
                                        Text(entry.modified)
                                            .lineLimit(1)
                                            .monospacedDigit()
                                            .frame(width: fileColumns.modified, alignment: .leading)
                                    }
                                    .font(DS.Font.caption)
                                    .foregroundColor(DS.Palette.text)
                                    .padding(.horizontal, DS.Space.xs)
                                    .frame(width: fileColumns.total, height: 26, alignment: .leading)
                                    .background(rowBackground(index: index, isSelected: selectedIDs.contains(entry.id)))
                                }
                                .buttonStyle(.plain)
                                // Mac users expect double-click to open a folder
                                // (UX-MAC_SSH-007). A simultaneous double-tap opens
                                // directories without breaking the single-click select.
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        if entry.isDirectory { open(entry) } else { transfer(entry) }
                                    }
                                )
                                .accessibilityIdentifier("ssh.file.row.\(entry.path)")
                                .contextMenu {
                                    if entry.isDirectory {
                                        Button(L("Open Folder")) { open(entry) }
                                    } else {
                                        Button(transferMenuTitle(transferTitle: transferTitle,
                                                                 selectedIDs: selectedIDs,
                                                                 entries: entries,
                                                                 anchor: entry)) {
                                            transfer(entry)
                                        }
                                    }
                                    Button(selectedIDs.contains(entry.id) ? L("Deselect") : L("Select")) {
                                        select(entry, .command)
                                    }
                                    // Bridge local entries to the rest of macOS:
                                    // reveal in Finder / copy the absolute path
                                    // (IMP-MAC_SSH-011). Remote paths aren't local
                                    // URLs, so these are local-pane only.
                                    if isLocal {
                                        Divider()
                                        Button(L("Reveal in Finder")) {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                                        }
                                        Button(L("Copy Path")) {
                                            let pasteboard = NSPasteboard.general
                                            pasteboard.clearContents()
                                            pasteboard.setString(entry.path, forType: .string)
                                        }
                                    }
                                    // Remote file management: mkdir/delete available
                                    // in the remote pane so single-entry operations
                                    // don't require opening a terminal. Rename requires
                                    // user input; it is wired but not surfaced here
                                    // pending a modal rename sheet.
                                    if !isLocal {
                                        Divider()
                                        Button(L("Copy Path")) {
                                            let pasteboard = NSPasteboard.general
                                            pasteboard.clearContents()
                                            pasteboard.setString(entry.path, forType: .string)
                                        }
                                        .accessibilityIdentifier("ssh.remote.copypath")
                                        Button(L("New Folder Here")) {
                                            let parent = entry.isDirectory ? entry.path
                                                : (entry.path as NSString).deletingLastPathComponent
                                            vm.onRemoteMkdir?((parent as NSString).appendingPathComponent("new_folder"))
                                        }
                                        .accessibilityIdentifier("ssh.remote.mkdir")
                                        Button(L("Delete"), role: .destructive) {
                                            vm.onRemoteDelete?(entry.path, entry.isDirectory)
                                        }
                                        .accessibilityIdentifier("ssh.remote.delete")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func transferMenuTitle(transferTitle: String,
                                   selectedIDs: Set<String>,
                                   entries: [SSHFileEntry],
                                   anchor: SSHFileEntry) -> String {
        let selectedFiles = entries.filter { selectedIDs.contains($0.id) && !$0.isDirectory }
        guard selectedIDs.contains(anchor.id), selectedFiles.count > 1 else { return transferTitle }
        return L("%1$@ %2$@ files", transferTitle, selectedFiles.count)
    }

    private func resizableHeader(_ title: String,
                                 width: Binding<CGFloat>,
                                 minWidth: CGFloat,
                                 alignment: Alignment = .leading) -> some View {
        SSHResizableHeader(title: title, width: width, minWidth: minWidth, alignment: alignment)
    }

    private func rowBackground(index: Int, isSelected: Bool) -> Color {
        if isSelected { return DS.Palette.selection }
        return index.isMultiple(of: 2) ? DS.Palette.surface.opacity(0.35) : Color.clear
    }

    // Status column: shows live percent while transferring plus an inline cancel
    // control; otherwise the plain status label (P1).
    @ViewBuilder
    private func statusCell(item: SSHTransferQueueItem) -> some View {
        HStack(spacing: DS.Space.xs) {
            if item.status == .transferring, let percent = item.progress {
                Text(L("%1$@%", percent))
                    .monospacedDigit()
                    .accessibilityIdentifier("ssh.transfer.queue.progress")
            } else {
                Text(item.status.rawValue)
            }
            if item.status == .queued || item.status == .transferring {
                Button { vm.cancelTransfer(item) } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help(L("Cancel transfer"))
                .accessibilityIdentifier("ssh.transfer.queue.cancel")
            }
        }
    }

    private func paneStatus(derived: SSHPaneDerived, selectedIDs: Set<String>) -> some View {
        let selectedCount = selectedIDs.count
        let totalFormatted = ByteCountFormatter.string(fromByteCount: Int64(derived.totalBytes), countStyle: .file)
        let statusText = selectedCount > 0
            ? (selectedCount == 1 ? L("Selected %1$@ item.", selectedCount) : L("Selected %1$@ items.", selectedCount))
            : L("%1$@ files. Total size: %2$@", derived.fileCount, totalFormatted)
        return HStack {
            Text(statusText)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("ssh.pane.status")
            Spacer()
        }
        .padding(.horizontal, DS.Space.sm)
    }

    private var queuePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SSHTransferState.allCases, id: \.self) { state in
                    Button {
                        vm.selectedQueueState = state
                    } label: {
                        Text(L("%1$@ transfers", state.rawValue))
                            .font(DS.Font.caption.weight(vm.selectedQueueState == state ? .semibold : .regular))
                            .padding(.horizontal, DS.Space.sm)
                            .frame(height: 30)
                            .background(vm.selectedQueueState == state ? DS.Palette.bg : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ssh.queue.tab.\(state.rawValue.lowercased())")
                }
                Spacer()
                Text(L("Queue: %1$@", vm.queueItems.contains { $0.status == .queued } ? "active" : "empty"))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .padding(.trailing, DS.Space.sm)
                Button(action: { vm.clearFinishedTransfers() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textTertiary)
                .disabled(!vm.queueItems.contains { $0.status != .queued })
                .help(L("Clear finished transfers"))
                .accessibilityLabel(L("Clear finished transfers"))
                .accessibilityIdentifier("ssh.queue.clearFinished")
                .padding(.trailing, DS.Space.sm)
            }
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        resizableHeader(L("Local"), width: $queueColumns.local, minWidth: 150)
                        resizableHeader(L("Direction"), width: $queueColumns.direction, minWidth: 74)
                        resizableHeader(L("Remote"), width: $queueColumns.remote, minWidth: 140)
                        resizableHeader(L("Size"), width: $queueColumns.size, minWidth: 56, alignment: .trailing)
                        resizableHeader(L("Status"), width: $queueColumns.status, minWidth: 74)
                    }
                    ScrollView(.vertical) {
                        let items = vm.queueItems.filter { $0.status == vm.selectedQueueState }
                        LazyVStack(spacing: 0) {
                            if items.isEmpty {
                                Text(L("No %1$@ transfers", vm.selectedQueueState.rawValue.lowercased()))
                                    .font(DS.Font.caption)
                                    .foregroundColor(DS.Palette.textTertiary)
                                    .frame(width: queueColumns.total)
                                    .frame(minHeight: 66)
                            } else {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    HStack(spacing: 0) {
                                        Text(item.localPath).frame(width: queueColumns.local, alignment: .leading)
                                        Text(item.direction.rawValue).frame(width: queueColumns.direction, alignment: .leading)
                                        Text(item.remotePath).frame(width: queueColumns.remote, alignment: .leading)
                                        Text(item.size).frame(width: queueColumns.size, alignment: .trailing)
                                        statusCell(item: item)
                                            .frame(width: queueColumns.status, alignment: .leading)
                                    }
                                    .font(DS.Font.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, DS.Space.xs)
                                    .frame(width: queueColumns.total, height: 24, alignment: .leading)
                                    .background(rowBackground(index: index, isSelected: false))
                                    // Recover a failed transfer / cancel an active
                                    // one in one click (IMP-MAC_SSH-010 / P1).
                                    .contextMenu {
                                        if item.status == .failed {
                                            Button(L("Retry Transfer")) { vm.retryTransfer(item) }
                                        }
                                        if item.status == .queued || item.status == .transferring {
                                            Button(L("Cancel Transfer")) { vm.cancelTransfer(item) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            logFooter
        }
    }

    // Scrollable log/status footer so transient transfer errors stay reviewable
    // instead of vanishing after a few lines (UX-MAC_SSH-010).
    private var logFooter: some View {
        VStack(spacing: 0) {
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            Button { showLog.toggle() } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: showLog ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(vm.transferStatus)
                        .font(DS.Font.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(L("Log"))
                        .font(DS.Font.caption2.weight(.semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                }
                .foregroundColor(DS.Palette.textSecondary)
                .padding(.horizontal, DS.Space.sm)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Show transfer log"))
            .accessibilityIdentifier("ssh.transfer.log.toggle")
            if showLog {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(vm.transferLogs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(DS.Font.monoSmall)
                                    .foregroundColor(DS.Palette.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, DS.Space.sm)
                        .padding(.vertical, DS.Space.xxs)
                    }
                    .frame(height: 96)
                    .background(DS.Palette.bg.opacity(0.42))
                    .accessibilityIdentifier("ssh.transfer.log")
                    .onChange(of: vm.transferLogs.count) { _ in
                        proxy.scrollTo(vm.transferLogs.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// NSView subclass that acts as an NSDraggingDestination for the remote pane.
// Accepts file-URL drags from Finder and from the local pane (NSFilenamesPboardType
// / fileURL UTI). On a valid drop it calls onDrop([URL]) which the surface maps
// to upload requests. The view is transparent and overlays the remote pane so the
// existing SwiftUI hit-testing is not disrupted when no drag is in progress.
private final class SSHRemotePaneDropNSView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFileURLs(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFileURLs(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func hasFileURLs(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true])
    }

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

// SwiftUI wrapper so the drop overlay can be placed with .overlay() inside the
// existing SwiftUI layout without breaking the view hierarchy.
private struct SSHRemoteDropOverlay: NSViewRepresentable {
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> SSHRemotePaneDropNSView {
        let v = SSHRemotePaneDropNSView()
        v.onDrop = onDrop
        return v
    }

    func updateNSView(_ nsView: SSHRemotePaneDropNSView, context: Context) {
        nsView.onDrop = onDrop
    }
}

private struct SSHResizableHeader: View {
    let title: String
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let alignment: Alignment
    @State private var startWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: alignment)
            Rectangle()
                .fill(DS.Palette.lineStrong.opacity(0.92))
                .frame(width: DS.ResizeDivider.gripThickness, height: 18)
                .padding(.horizontal, DS.Space.xs)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let base = startWidth ?? width
                            if startWidth == nil { startWidth = width }
                            width = max(minWidth, base + value.translation.width)
                        }
                        .onEnded { _ in startWidth = nil }
                )
                .help(L("Drag to resize %1$@", title))
        }
        .font(DS.Font.caption2.weight(.semibold))
        .foregroundColor(DS.Palette.textSecondary)
        .frame(width: width, alignment: alignment)
        .padding(.horizontal, DS.Space.xs)
        .frame(height: 26)
        .background(DS.Palette.surfaceRaised.opacity(0.42))
    }
}

private struct SSHHostFormSheet: View {
    @ObservedObject var vm: SSHSurfaceViewModel
    @FocusState private var hostFieldFocused: Bool

    private var portError: String? {
        let trimmed = vm.draft.portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let port = Int(trimmed), port > 0, port <= 65535 else {
            return L("Port must be a number between 1 and 65535.")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.editingHostID == nil ? L("New Host") : L("Edit Host"))
                        .font(DS.Font.caption2.weight(.semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .textCase(.uppercase)
                    if vm.editingHostID == nil {
                        // Clarify that saving a brand-new host also connects it,
                        // which is otherwise only signalled by the button label
                        // ("Save + Connect" vs "Save"). (UX-MAC_SSH-013)
                        Text(L("Saving connects to this host."))
                            .font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textTertiary)
                            .textCase(nil)
                    }
                }
                Spacer()
                Button { vm.cancelDraft() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityLabel(L("Close SSH host editor"))
                .accessibilityIdentifier("ssh.form.close")
                .help(L("Cancel"))
            }
            formField(L("Host"), requirement: "Required") {
                TextField(L("user@host or ssh-config alias"), text: $vm.draft.destination)
                    .textFieldStyle(.roundedBorder)
                    .focused($hostFieldFocused)
                    .accessibilityIdentifier("ssh.form.destination")
            }
            formField(L("Port"), requirement: L("Optional")) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    TextField("22", text: $vm.draft.portText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ssh.form.port")
                    if let portError {
                        Text(portError)
                            .font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.danger)
                            .accessibilityIdentifier("ssh.form.port.error")
                    }
                }
            }
            formField(L("Identity file"), requirement: L("Optional")) {
                HStack(spacing: DS.Space.xs) {
                    TextField(L("~/.ssh/id_ed25519"), text: $vm.draft.identityFileText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ssh.form.identityFile")
                    Button {
                        chooseIdentityFile()
                    } label: {
                        Label(L("Choose"), systemImage: "folder")
                    }
                    .help(L("Choose identity file"))
                    .accessibilityIdentifier("ssh.form.identityFile.choose")
                }
            }
            formField(L("Password"), requirement: L("Optional")) {
                VStack(alignment: .leading, spacing: 4) {
                    SecureField(
                        vm.draft.hasSavedPassword ? L("Leave blank to keep saved password") : L("Optional password"),
                        text: $vm.draft.passwordText
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ssh.form.password")
                    // Surface the "saved" state so editing a host makes the existing
                    // password visible without exposing its value (P2 hasSavedPassword).
                    if vm.draft.hasSavedPassword && vm.draft.passwordText.isEmpty {
                        Text(L("Password saved - leave blank to keep it."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier("ssh.form.password.savedHint")
                    }
                }
            }
            fieldLabel(L("SSH options"), requirement: L("Optional"))
            TextEditor(text: $vm.draft.optionLines)
                .font(DS.Font.monoSmall)
                .frame(minHeight: 84)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Palette.line))
                .accessibilityIdentifier("ssh.form.options")
            Divider()
            formField(L("Label"), requirement: L("Optional")) {
                TextField(L("Production server"), text: $vm.draft.label)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ssh.form.label")
            }
            if let error = vm.error {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
                    .accessibilityIdentifier("ssh.form.error")
            }
            HStack(spacing: DS.Space.sm) {
                Spacer()
                Button(L("Cancel")) { vm.cancelDraft() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("ssh.form.cancel")
                Button(vm.editingHostID == nil ? L("Save + Connect") : L("Save")) {
                    vm.onSave?(vm.draft)
                }
                    .disabled(vm.draft.destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || portError != nil)
                    .buttonStyle(DSPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ssh.form.save")
            }
        }
        .padding(DS.Space.lg)
        .frame(minWidth: 320, idealWidth: 460, maxWidth: 460)
        .background(DS.Palette.surfaceRaised)
        .onAppear { hostFieldFocused = true }
    }

    private func formField<Content: View>(_ label: String, requirement: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            fieldLabel(label, requirement: requirement)
            content()
        }
    }

    private func fieldLabel(_ label: String, requirement: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(label)
                .font(DS.Font.caption2.weight(.semibold))
                .foregroundColor(DS.Palette.textSecondary)
            Text(requirement)
                .font(DS.Font.caption2.weight(.semibold))
                .foregroundColor(requirement == "Required" ? DS.Palette.accent : DS.Palette.textTertiary)
        }
    }

    private func chooseIdentityFile() {
        if let picker = vm.identityFilePicker {
            if let path = picker() { vm.draft.identityFileText = path }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url {
            vm.draft.identityFileText = url.path
        }
    }
}

private struct SSHHostRow: View {
    let host: SSHHostProfile
    let connected: Bool
    // True when the SSH child exited without an explicit user disconnect;
    // shown as an orange "Disconnected" pill so the user knows to reconnect.
    let sessionDead: Bool
    // True when keyboard focus (arrow keys) has moved to this row; draws a
    // focus ring so it is visually distinct from the mouse-selected row.
    var isKeyboardHighlighted: Bool = false
    let onConnect: () -> Void
    let onOpenNewConnection: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onDisconnect: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "network")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(connected ? DS.Palette.accent : DS.Palette.textTertiary)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.label)
                        .font(DS.Font.bodyDense.weight(connected ? .semibold : .regular))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if connected {
                    // A text L("Connected") pill so the connected state isn't
                    // conveyed by color + a tiny glyph alone (UX-MAC_SSH-014).
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L("Connected"))
                            .font(DS.Font.caption2.weight(.semibold))
                    }
                    .foregroundColor(DS.Palette.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(DS.Palette.accent.opacity(0.14))
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Connected"))
                    // Disconnect button: visible only while connected so the
                    // user can end the session without deleting the host.
                    Button(action: onDisconnect) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Palette.textTertiary)
                    .help(L("Disconnect"))
                    .accessibilityLabel(L("Disconnect"))
                    .accessibilityIdentifier("ssh.host.disconnect.\(host.id.value.uuidString)")
                } else if sessionDead {
                    // Child exited without user disconnect: show an orange
                    // "Disconnected" pill so the dead-session state is visible.
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L("Disconnected"))
                            .font(DS.Font.caption2.weight(.semibold))
                    }
                    .foregroundColor(DS.Palette.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(DS.Palette.warning.opacity(0.14))
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Disconnected"))
                    .accessibilityIdentifier("ssh.host.pill.disconnected")
                }
                Button { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textTertiary)
                .help(L("Delete host"))
                .accessibilityLabel(L("Delete host"))
                .accessibilityIdentifier("ssh.host.delete.\(host.id.value.uuidString)")
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(connected ? DS.Palette.selection : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .stroke(
                        isKeyboardHighlighted
                            ? DS.Palette.accent.opacity(0.70)
                            : (connected ? DS.Palette.accent.opacity(0.42) : Color.clear),
                        lineWidth: isKeyboardHighlighted ? 2 : 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ssh.host.connect.\(host.id.value.uuidString)")
        .contextMenu {
            if connected {
                Button(L("Disconnect"), action: onDisconnect)
                    .accessibilityIdentifier("ssh.host.contextmenu.disconnect")
            }
            Button(L("Open New Connection"), action: onOpenNewConnection)
            Button(L("Edit Host"), action: onEdit)
            Button(L("Duplicate Host"), action: onDuplicate)
            Divider()
            Button(L("Delete Host"), role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog(
            "Delete \(host.label)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(L("Delete Host"), role: .destructive, action: onDelete)
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(connected
                 ? L("This host is connected. Deleting it will disconnect the session.")
                 : L("This permanently removes the saved host."))
        }
        .help(host.label)
        .accessibilityIdentifier("ssh.host.row.\(host.id.value.uuidString)")
    }

    private var subtitle: String {
        let endpoint = host.port.map { "\(host.destination):\($0)" } ?? host.destination
        // Surface when the host was last used so a glance answers "which host is
        // current / stale" without opening it (IMP-MAC_SSH-005).
        return "\(endpoint) · \(Self.lastUsedFormatter.localizedString(for: host.updatedAt, relativeTo: Date()))"
    }

    private static let lastUsedFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
