import AppKit
import CoreModel
import DesignSystemKit
import Persistence
import Surfaces
import SwiftUI

// MARK: - Active surface projection

public struct ActiveSurfaceItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let workspaceID: WorkspaceID
    public let workspaceName: String
    public let surfaceID: SurfaceID
    public let title: String
    public let type: SurfaceType
}

/// Busy surfaces (terminal, ssh, browser, diff, ...) across workspaces. Agent App surfaces are excluded:
/// their runs already appear as active threads and there is no cheap dedupe.
public enum ActiveSurfaceProjector {
    public static func items(
        workspaces: [Workspace],
        isBusy: (SurfaceDescriptor) -> Bool
    ) -> [ActiveSurfaceItem] {
        var result: [ActiveSurfaceItem] = []
        for workspace in workspaces {
            for paneID in workspace.layout.paneIDs() {
                for descriptor in workspace.layout.find(paneID: paneID)?.surfaces ?? []
                where descriptor.type != .agentApp && isBusy(descriptor) {
                    result.append(ActiveSurfaceItem(
                        id: descriptor.id.value,
                        workspaceID: workspace.id,
                        workspaceName: workspace.name,
                        surfaceID: descriptor.id,
                        title: descriptor.title.isEmpty ? Self.fallbackTitle(for: descriptor.type) : descriptor.title,
                        type: descriptor.type
                    ))
                }
            }
        }
        return result
    }

    private static func fallbackTitle(for type: SurfaceType) -> String {
        switch type {
        case .terminal, .ssh: return "Terminal"
        case .browser: return "Browser"
        case .rightSidebarTool: return "Diff"
        default: return "Tab"
        }
    }

    @MainActor
    static func currentItems(context: AppContext) -> [ActiveSurfaceItem] {
        items(workspaces: context.state.window.workspaces.compactMap { context.state.workspaces[$0] }) {
            SurfaceRegistry.shared.surface($0.id)?.isBusy == true
        }
    }
}

// MARK: - View model

@MainActor
public final class ActiveThreadsViewModel: ObservableObject {
    public enum Tab: String, CaseIterable, Identifiable {
        case active
        case lastFinished

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .active: return "Active"
            case .lastFinished: return "Last Finished"
            }
        }
    }

    @Published public private(set) var activeItems: [PetActiveThreadItem] = []
    @Published public private(set) var activeSurfaces: [ActiveSurfaceItem] = []
    @Published public private(set) var finishedItems: [FinishedThreadItem] = []
    @Published var pendingActivityRoute: NotificationRouteIntent?
    @Published public var selectedTab: Tab = .active
    @Published public var errorMessage: String?

    private let context: AppContext
    private let router: AppCommandRouter
    private var startedAtByThread: [AgentThreadID: Date] = [:]
    private var lastActiveThreadIDs: Set<AgentThreadID> = []
    private var freshnessTask: Task<Void, Never>?
    private var tabRefreshTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var freshnessGeneration: UInt64 = 0
    private var tabRefreshGeneration: UInt64 = 0
    private var navigationGeneration: UInt64 = 0
    fileprivate let deferHydration: Bool
    var activityRouter: AppCommandRouter { router }

    public init(context: AppContext, router: AppCommandRouter, loadImmediately: Bool = true) {
        self.context = context
        self.router = router
        self.deferHydration = !loadImmediately
        if loadImmediately {
            reload()
        }
    }

    deinit {
        freshnessTask?.cancel()
        tabRefreshTask?.cancel()
        navigationTask?.cancel()
    }

    private static func waitForCommittedFrame() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Use the published cache for the first frame, then perform one
    /// cancellation-safe repository/coordinator refresh.
    public func scheduleFreshnessPass() {
        guard deferHydration else { return }
        freshnessTask?.cancel()
        freshnessGeneration &+= 1
        let generation = freshnessGeneration
        freshnessTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self,
                  !Task.isCancelled,
                  self.freshnessGeneration == generation else { return }
            defer {
                if self.freshnessGeneration == generation {
                    self.freshnessTask = nil
                }
            }
            self.reload()
        }
    }

    public var activeCount: Int { activeItems.count + activeSurfaces.count }
    public var finishedCount: Int { finishedItems.count }

    public var footerLine: String {
        let activeLabel = activeCount == 1 ? "1 active" : "\(activeCount) active"
        let finishedLabel = finishedCount == 1 ? "1 recent finished" : "\(finishedCount) recent finished"
        return "\(activeLabel) · \(finishedLabel)"
    }

    public var subtitle: String {
        switch selectedTab {
        case .active:
            if activeCount == 0 {
                return "Nothing running right now"
            }
            let threads = activeItems.count
            let tabs = activeSurfaces.count
            var parts: [String] = []
            if threads > 0 { parts.append(threads == 1 ? "1 agent thread" : "\(threads) agent threads") }
            if tabs > 0 { parts.append(tabs == 1 ? "1 tab" : "\(tabs) tabs") }
            return parts.joined(separator: " and ") + (activeCount == 1 ? " is running" : " are running")
        case .lastFinished:
            return "Recent completed, failed, cancelled, and interrupted runs"
        }
    }

    public func reload() {
        reloadActive()
        reloadFinished()
    }

    public func reloadActive() {
        // Primary threads only — delegated bot-peer runs show under Subagents.
        reloadActiveSurfaces()
        let threadIDs = Array(context.coordinator.primaryActiveThreadIdsSnapshot())
        let activeSet = Set(threadIDs)
        lastActiveThreadIDs = activeSet
        startedAtByThread = startedAtByThread.filter { activeSet.contains($0.key) }

        let missingStartedAt = threadIDs.filter { startedAtByThread[$0] == nil }
        var runIdByThread: [AgentThreadID: AgentRunID] = [:]
        var runIDs: [AgentRunID] = []
        runIDs.reserveCapacity(missingStartedAt.count)
        for threadID in missingStartedAt {
            guard let runId = context.coordinator.activeRunId(threadId: threadID) else { continue }
            runIdByThread[threadID] = runId
            runIDs.append(runId)
        }
        let stamps = (try? context.runRepo.startedAt(ids: runIDs)) ?? [:]
        for threadID in missingStartedAt {
            if let runId = runIdByThread[threadID], let startedAt = stamps[runId] {
                startedAtByThread[threadID] = startedAt
            } else if let durable = try? context.coordinator.durableActiveRunChrome(threadId: threadID) {
                startedAtByThread[threadID] = durable.startedAt
            } else {
                startedAtByThread[threadID] = Date()
            }
        }

        let chrome = (try? context.threadRepo.listChrome(ids: threadIDs)) ?? [:]
        activeItems = PetActiveThreadProjector.items(threadIDs: threadIDs) { [weak self] threadID in
            guard let self, let meta = chrome[threadID] else { return nil }
            let workspaceName = meta.workspaceId.flatMap { self.context.state.workspaces[$0]?.name }
            return (
                workspaceID: meta.workspaceId,
                workspaceName: workspaceName,
                providerName: PetActiveThreadProjector.providerLabel(meta.provider),
                threadTitle: meta.title,
                startedAt: self.startedAtByThread[threadID],
                lastUpdatePreview: nil
            )
        }
    }

    public func reloadActiveSurfaces() {
        let next = ActiveSurfaceProjector.currentItems(context: context)
        if next != activeSurfaces { activeSurfaces = next }
    }

    /// Cheap live pass: surfaces always, thread repo reads only when the
    /// active thread set changed.
    public func refreshLive() {
        let current = Set(context.coordinator.primaryActiveThreadIdsSnapshot())
        if current != lastActiveThreadIDs {
            // A run that left the active set must appear in Last Finished without a tab switch.
            let finished = !lastActiveThreadIDs.subtracting(current).isEmpty
            reloadActive()
            if finished { reloadFinished() }
        } else {
            reloadActiveSurfaces()
        }
    }

    public func openSurface(_ item: ActiveSurfaceItem) {
        router.windowController?.presentWorkspaceContent()
        do {
            try router.selectWorkspace(item.workspaceID)
            try router.focusSurface(workspace: item.workspaceID, surface: item.surfaceID)
        } catch {
            errorMessage = "Could not open terminal: \(error.localizedDescription)"
        }
    }

    public func reloadFinished() {
        do {
            let runs = try context.runRepo.listRecentFinished(limit: 50)
            let chrome = try context.threadRepo.listChrome(ids: runs.map(\.threadId))
            finishedItems = runs.map { run in
                let meta = chrome[run.threadId]
                let workspaceID = meta?.workspaceId
                let workspaceName = workspaceID.flatMap { context.state.workspaces[$0]?.name }
                return FinishedThreadItem(
                    run: run,
                    threadTitle: meta?.title,
                    workspaceID: workspaceID,
                    workspaceName: workspaceName,
                    providerName: PetActiveThreadProjector.providerLabel(run.provider)
                )
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Tab changes only need the selected projection. Re-running `reload()`
    /// here also rebuilt the active projection and durable start-time map,
    /// which made a rapid Active ↔ Last Finished switch do twice the SQLite
    /// work and republish both lists.
    public func scheduleTabRefresh(_ tab: Tab) {
        guard deferHydration else { return }
        // The initial full pass already owns all projections. Let it finish
        // rather than enqueueing a second read for a click in the same turn.
        guard freshnessTask == nil else { return }
        tabRefreshTask?.cancel()
        tabRefreshGeneration &+= 1
        let generation = tabRefreshGeneration
        tabRefreshTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self else { return }
            defer {
                if self.tabRefreshGeneration == generation {
                    self.tabRefreshTask = nil
                }
            }
            guard !Task.isCancelled,
                  self.tabRefreshGeneration == generation,
                  self.selectedTab == tab else { return }
            switch tab {
            case .active:
                self.reloadActive()
            case .lastFinished:
                self.reloadFinished()
            }
        }
    }

    public func openActive(_ item: PetActiveThreadItem) {
        if case .botsDesk(let botID) = item.route {
            // Publish the shell destination in the click turn. Only the exact
            // Bot lookup/Desk hydration waits for the deferred pass.
            router.windowController?.presentBotsInMainContent()
            guard !deferHydration else {
                navigationTask?.cancel()
                navigationGeneration &+= 1
                let generation = navigationGeneration
                navigationTask = Task { @MainActor [weak self] in
                    await Self.waitForCommittedFrame()
                    guard let self,
                          !Task.isCancelled,
                          self.navigationGeneration == generation else { return }
                    defer {
                        if self.navigationGeneration == generation {
                            self.navigationTask = nil
                        }
                    }
                    do {
                        guard try self.router.openBotsDesk(botID: botID) else {
                            self.errorMessage = "Could not open bot Desk."
                            return
                        }
                    } catch {
                        self.errorMessage = "Could not open bot Desk: \(error.localizedDescription)"
                    }
                }
                return
            }
            do {
                guard try router.openBotsDesk(botID: botID) else {
                    errorMessage = "Could not open bot Desk."
                    return
                }
            } catch {
                errorMessage = "Could not open bot Desk: \(error.localizedDescription)"
            }
            return
        }
        openThread(item.threadID, workspaceID: workspaceID(from: item.route))
    }

    public func openFinished(_ item: FinishedThreadItem) {
        openThread(item.threadID, workspaceID: item.workspaceID)
    }

    func openEvidence(_ item: ActivityWireItem, path: String?) {
        guard let threadUUID = item.thread_id.flatMap(UUID.init(uuidString:)),
              let workspaceUUID = item.workspace_id.flatMap(UUID.init(uuidString:)),
              let turnCount = item.checkpoint_turn_count, turnCount > 0,
              let runUUID = item.run_id.flatMap(UUID.init(uuidString:)) else {
            errorMessage = "This activity has no valid checkpoint destination."
            return
        }
        openThread(
            AgentThreadID(threadUUID), workspaceID: WorkspaceID(workspaceUUID),
            checkpoint: (turnCount, AgentRunID(runUUID), path)
        )
    }

    func openActivity(_ item: ActivityWireItem) {
        // A new open owns the alert; an older failure must not outlive it.
        errorMessage = nil
        if item.id.hasPrefix("scheduled-occurrence:") {
            guard let windowController = router.windowController else {
                errorMessage = "Open Schedule Tasks from the main window to review this task."
                return
            }
            windowController.presentScheduledTasksInMainContent()
            return
        }
        if let notificationID = item.notification_id, item.bot_id == nil {
            do {
                guard let notification = try NotificationRepository(db: context.db).get(id: notificationID),
                      let route = PetAttentionStore.notificationRoute(notification) else {
                    errorMessage = "This activity has no valid destination."
                    return
                }
                open(route)
            } catch {
                errorMessage = "Could not load activity destination: \(error.localizedDescription)"
            }
            return
        }
        if let botID = item.bot_id.flatMap(UUID.init(uuidString:)) {
            openBot(BotID(botID), conversationID: item.conversation_id.flatMap(UUID.init(uuidString:)).map(BotConversationID.init))
            return
        }
        if let threadID = item.thread_id.flatMap(UUID.init(uuidString:)) {
            openThread(AgentThreadID(threadID), workspaceID: item.workspace_id.flatMap(UUID.init(uuidString:)).map(WorkspaceID.init), finalMessageID: item.final_message_id.flatMap(UUID.init(uuidString:)).map(AgentMessageID.init))
            return
        }
        if let surfaceID = item.surface_id.flatMap(UUID.init(uuidString:)),
           let workspaceID = item.workspace_id.flatMap(UUID.init(uuidString:)) {
            open(.surface(surfaceID: SurfaceID(surfaceID), workspaceID: WorkspaceID(workspaceID)))
            return
        }
        errorMessage = "This activity has no conversation destination."
    }

    private func open(_ route: PetAttentionRoute) {
        do {
            switch route {
            case .agentThread(let threadID, let workspaceID): openThread(threadID, workspaceID: workspaceID)
            case .surface(let surfaceID, let workspaceID):
                guard let workspaceID else { errorMessage = "This activity has no valid destination."; return }
                try router.selectWorkspace(workspaceID)
                try router.focusSurface(workspace: workspaceID, surface: surfaceID)
            case .workspace(let workspaceID): try router.selectWorkspace(workspaceID)
            case .settings(let route):
                if let windowController = router.windowController {
                    windowController.presentSettingsInMainContent(route: route)
                    return
                }
                guard let settings = (NSApp.delegate as? AppDelegate)?.settings,
                      settings.show(route: route) else {
                    errorMessage = "Could not open activity settings destination."
                    return
                }
            case .botsDesk(let botID): openBot(botID, conversationID: nil)
            }
        } catch { errorMessage = "Could not open activity destination: \(error.localizedDescription)" }
    }

    private func workspaceID(from route: PetAttentionRoute) -> WorkspaceID? {
        if case .agentThread(_, let workspaceID) = route {
            return workspaceID
        }
        return nil
    }

    /// `openBotsDesk` has already left Activity when it fails.
    func openBotDesk(_ item: ActiveBotScreenItem) { openBot(item.botID, conversationID: nil) }

    private func openBot(_ botID: BotID, conversationID: BotConversationID?) {
        do {
            guard try router.openBotsDesk(botID: botID, conversationID: conversationID) else {
                throw LayoutError.surfaceNotFound
            }
        } catch { reportAfterLeaving("Could not open bot: \(error.localizedDescription)") }
    }

    /// A failure found after Activity was replaced would wait on this hidden model and
    /// pop up on a later visit, over whatever row is selected then. Show it now, in
    /// Activity, where the user asked for the open.
    private func reportAfterLeaving(_ message: String) {
        router.windowController?.presentActiveThreadsInMainContent()
        errorMessage = message
    }

    private func openThread(_ threadID: AgentThreadID, workspaceID: WorkspaceID?, finalMessageID: AgentMessageID? = nil, checkpoint: (Int, AgentRunID, String?)? = nil) {
        // Resolve the destination while Activity is still on screen: a bot thread opens
        // its Desk, and a thread with no open workspace fails here, on the clicked row.
        let destination: AgentThreadOpenDestination
        do { destination = try router.agentThreadOpenDestination(threadID) }
        catch { errorMessage = "Could not open thread: \(error.localizedDescription)"; return }
        switch destination {
        case .workspace: break
        case .bot(let botID, let conversationID):
            openBot(botID, conversationID: conversationID)
            return
        case .unavailable:
            errorMessage = "Could not open thread: \(LayoutError.workspaceNotFound.localizedDescription)"
            return
        }
        // Leave the shell destination first so the workspace cache can paint.
        router.windowController?.presentWorkspaceContent()
        guard deferHydration || finalMessageID != nil || checkpoint != nil else {
            do { _ = try router.openAgentThread(thread: threadID, markRead: false) }
            catch { reportAfterLeaving("Could not open thread: \(error.localizedDescription)") }
            return
        }
        navigationTask?.cancel()
        navigationGeneration &+= 1
        let generation = navigationGeneration
        navigationTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self,
                  !Task.isCancelled,
                  self.navigationGeneration == generation else { return }
            defer {
                if self.navigationGeneration == generation {
                    self.navigationTask = nil
                }
            }
            do {
                let descriptor = try self.router.openAgentThread(thread: threadID, markRead: false)
                if let finalMessageID {
                    guard let surface = SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface else { throw LayoutError.surfaceNotFound }
                    try await surface.viewModel.revealMessage(id: finalMessageID, expectedThreadID: threadID)
                }
                if let checkpoint {
                    guard let surface = SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface else { throw LayoutError.surfaceNotFound }
                    try await surface.viewModel.revealCheckpoint(
                        checkpointTurnCount: checkpoint.0, expectedRunID: checkpoint.1, path: checkpoint.2
                    )
                    guard !Task.isCancelled, self.navigationGeneration == generation else { return }
                }
            } catch {
                guard !(error is CancellationError), self.navigationGeneration == generation else { return }
                if let revealError = error as? AgentAppSurfaceMessageRevealError, case .selectionChanged = revealError { return }
                self.reportAfterLeaving("Could not open thread: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Finished row model

public struct FinishedThreadItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let runID: AgentRunID
    public let threadID: AgentThreadID
    public let workspaceID: WorkspaceID?
    public let title: String
    public let detail: String
    public let status: AgentRunStatus
    public let finishedAt: Date?
    public let startedAt: Date

    public init(
        run: AgentRun,
        threadTitle: String?,
        workspaceID: WorkspaceID?,
        workspaceName: String?,
        providerName: String?
    ) {
        self.id = "finished:\(run.id.value.uuidString)"
        self.runID = run.id
        self.threadID = run.threadId
        self.workspaceID = workspaceID
        let safeTitle = PetAttentionRedactor.safeContextLabel(threadTitle) ?? "Agent thread"
        self.title = safeTitle
        let workspace = PetAttentionRedactor.safeContextLabel(workspaceName) ?? "Other"
        let provider = providerName ?? PetActiveThreadProjector.providerLabel(run.provider)
        let model = run.model.isEmpty ? provider : "\(provider) · \(run.model)"
        self.detail = "\(workspace) · \(model)"
        self.status = run.status
        self.finishedAt = run.finishedAt
        self.startedAt = run.startedAt
    }
}

// MARK: - Root view

public struct ActiveThreadsRootView: View {
    @ObservedObject private var vm: ActiveThreadsViewModel
    @ObservedObject private var botsVM: BotsViewModel

    public init(vm: ActiveThreadsViewModel, botsVM: BotsViewModel) {
        self.vm = vm
        self.botsVM = botsVM
    }

    public var body: some View {
        VStack(spacing: 0) {
            ActivityRootView(router: vm.activityRouter, route: vm.pendingActivityRoute, consumeRoute: {
                vm.pendingActivityRoute = nil
            }, openThread: { item in
                vm.openActivity(item)
            }, openEvidence: { item, path in
                vm.openEvidence(item, path: path)
            })
        }
        .onAppear { botsVM.reloadActiveBotItems() }
        .onChange(of: botsVM.activeBotCount) { _ in botsVM.reloadActiveBotItems() }
        .alert("Could not open conversation", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    private var overviewHeader: some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Active Threads")
                    .font(DS.Font.title.weight(.semibold))
                    .foregroundColor(DS.Palette.text)
                Text(vm.subtitle)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            Spacer(minLength: DS.Space.lg)
            if let badge = PetActiveThreadCountFormatter.badgeText(count: vm.activeCount) {
                Text(badge)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 28, minHeight: 28)
                    .background(Circle().fill(Color.blue))
                    .accessibilityLabel(PetActiveThreadCountFormatter.activeItemsAccessibilityValue(count: vm.activeCount))
            }
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.top, DS.Space.xxl)
        .padding(.bottom, DS.Space.xl)
    }

    private var tabBar: some View {
        HStack(spacing: DS.Space.md) {
            ForEach(ActiveThreadsViewModel.Tab.allCases, id: \.self) { tab in
                let count: Int = {
                    switch tab {
                    case .active: return vm.activeCount
                    case .lastFinished: return vm.finishedCount
                    }
                }()
                AgentListFilterChip(
                    title: tab.title,
                    count: count,
                    selected: vm.selectedTab == tab,
                    identifier: "activeThreads.tab.\(tab.rawValue)"
                ) {
                    vm.selectedTab = tab
                    vm.scheduleTabRefresh(tab)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.bottom, DS.Space.xl)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.selectedTab {
        case .active:
            activeList
        case .lastFinished:
            finishedList
        }
    }

    private var activeList: some View {
        Group {
            if vm.activeItems.isEmpty && vm.activeSurfaces.isEmpty {
                DSEmptyState(
                    icon: "bolt.horizontal.circle",
                    title: "No active threads",
                    subtitle: "Agent runs and busy terminals will show up here with workspace context."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(vm.activeItems) { item in
                            ActiveThreadCard(item: item) {
                                vm.openActive(item)
                            }
                        }
                        ForEach(vm.activeSurfaces) { item in
                            ActiveTerminalCard(item: item) {
                                vm.openSurface(item)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
                .accessibilityIdentifier("activeThreads.activeList")
            }
        }
    }

    private var finishedList: some View {
        Group {
            if vm.finishedItems.isEmpty {
                DSEmptyState(
                    icon: "checkmark.circle",
                    title: "No recent finished runs",
                    subtitle: "Completed, failed, cancelled, and interrupted runs appear here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(vm.finishedItems) { item in
                            FinishedThreadCard(item: item) {
                                vm.openFinished(item)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
                .accessibilityIdentifier("activeThreads.finishedList")
            }
        }
    }

    private var footerBar: some View {
        AgentListFooterBar(
            caption: vm.footerLine,
            pillTitle: vm.activeCount > 0 ? "Live" : "Idle",
            pillTone: vm.activeCount > 0 ? .warning : .neutral
        )
        .accessibilityLabel(vm.footerLine)
    }
}

// MARK: - Cards

private struct ActiveThreadCard: View {
    let item: PetActiveThreadItem
    let onOpen: () -> Void

    var body: some View {
        AgentOverviewCard(
            icon: "bolt.horizontal.circle.fill",
            iconColor: Color.blue,
            title: item.title,
            subtitle: item.detail ?? item.workspaceName ?? "Agent",
            preview: {
                guard let preview = item.lastUpdatePreview, !preview.isEmpty else { return nil }
                return preview
            }(),
            identifier: "activeThreads.active.\(item.threadID.value.uuidString.lowercased())",
            onOpen: onOpen
        ) {
            DSPill("Running", tone: .warning)
        } meta: {
            EmptyView()
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
        }
    }
}

private struct ActiveTerminalCard: View {
    let item: ActiveSurfaceItem
    let onOpen: () -> Void

    private var icon: String {
        switch item.type {
        case .terminal: return "terminal"
        case .ssh: return "network"
        case .browser: return "globe"
        case .rightSidebarTool: return "doc.text.magnifyingglass"
        default: return "square.stack"
        }
    }

    var body: some View {
        AgentOverviewCard(
            icon: icon,
            iconColor: Color.blue,
            title: item.title,
            subtitle: item.workspaceName,
            identifier: "activeThreads.terminal.\(item.id.uuidString.lowercased())",
            onOpen: onOpen
        ) {
            HStack(spacing: DS.Space.sm) {
                ProgressView().controlSize(.small)
                DSPill("Running", tone: .warning)
            }
        } meta: {
            EmptyView()
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
        }
    }
}

private struct FinishedThreadCard: View {
    let item: FinishedThreadItem
    let onOpen: () -> Void

    var body: some View {
        AgentOverviewCard(
            icon: statusIcon,
            iconColor: statusColor,
            title: item.title,
            subtitle: item.detail,
            identifier: "activeThreads.finished.\(item.runID.value.uuidString.lowercased())",
            onOpen: onOpen
        ) {
            statusPill
        } meta: {
            AgentOverviewMetaColumn(
                title: "Finished",
                value: finishedLabel,
                alignment: .trailing,
                multilineTextAlignment: .trailing
            )
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
        }
    }

    private var finishedLabel: String {
        guard let finished = item.finishedAt else { return "—" }
        return finished.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private var statusIcon: String {
        switch item.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .interrupted: return "exclamationmark.triangle.fill"
        case .pending, .running: return "circle"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: return DS.Palette.success
        case .failed: return DS.Palette.danger
        case .cancelled, .interrupted: return DS.Palette.warning
        case .pending, .running: return DS.Palette.textTertiary
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch item.status {
        case .completed: DSPill("Completed", tone: .success)
        case .failed: DSPill("Failed", tone: .danger)
        case .cancelled: DSPill("Cancelled", tone: .neutral)
        case .interrupted: DSPill("Interrupted", tone: .warning)
        case .pending: DSPill("Pending", tone: .warning)
        case .running: DSPill("Running", tone: .warning)
        }
    }
}
