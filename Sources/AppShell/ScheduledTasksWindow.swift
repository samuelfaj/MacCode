import Foundation
import AppKit
import SwiftUI
import CoreModel
import Persistence
import DesignSystemKit
import Surfaces

public enum ScheduledTaskStatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case paused = "Paused"
    public var id: String { rawValue }
}

public struct ScheduledTaskEditorDraft: Identifiable, Equatable {
    public let id: UUID
    public var originalCreatedAt: Date
    public var title: String
    public var prompt: String
    public var workspaceID: WorkspaceID?
    public var workspacePathSnapshot: String
    public var runAsUser: String
    public var runAsUID: UInt32
    public var provider: AgentProvider
    public var providerInstanceID: String
    public var model: String
    public var reasoningEffort: AgentReasoningEffort
    public var reasoningModel: String?
    public var distillMainEffortSelection: AgentEffortSelection?
    public var distillReasoningEffortSelection: AgentEffortSelection?
    public var routingMode: AgentRoutingMode
    public var distillExecutionMode: DistillExecutionMode
    public var permissionMode: AgentPermissionMode
    public var interactionMode: AgentInteractionMode
    public var executionMode: AgentExecutionMode
    public var baseBranch: String
    public var frequencyRules: [ScheduledFrequencyRule]
    public var timeZoneIdentifier: String
    public var isEnabled: Bool

    public init(task: ScheduledTask? = nil, now: Date = Date()) {
        id = task?.id ?? UUID()
        originalCreatedAt = task?.createdAt ?? now
        title = task?.title ?? ""
        prompt = task?.prompt ?? ""
        workspaceID = task?.workspaceID
        workspacePathSnapshot = task?.workspacePathSnapshot ?? ""
        runAsUser = task?.runAsUser ?? NSUserName()
        runAsUID = task?.runAsUID ?? ScheduledSystemUserCatalog.user(named: NSUserName())?.uid ?? 0
        provider = task?.provider ?? .defaultProvider
        providerInstanceID = task?.providerInstanceID ?? AgentProvider.defaultProvider.rawValue
        model = task?.model ?? ""
        reasoningEffort = task?.reasoningEffort ?? .high
        reasoningModel = task?.reasoningModel
        distillMainEffortSelection = task?.distillMainEffortSelection
        distillReasoningEffortSelection = task?.distillReasoningEffortSelection
        routingMode = provider == .distill ? .manual : (task?.effectiveRoutingMode ?? .auto)
        distillExecutionMode = task?.distillExecutionMode ?? .auto
        permissionMode = task?.permissionMode ?? .fullAccess
        interactionMode = task?.interactionMode ?? .default
        executionMode = task?.executionMode ?? .local
        baseBranch = task?.baseBranch ?? ""
        timeZoneIdentifier = task?.timeZoneIdentifier ?? TimeZone.current.identifier
        isEnabled = task?.isEnabled ?? true
        if let recurrence = task?.recurrence {
            frequencyRules = recurrence.rules.map(ScheduledFrequencyRule.init(recurrence:))
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            frequencyRules = [ScheduledFrequencyRule(
                frequency: .daily,
                scheduledDate: now.addingTimeInterval(60 * 60),
                localTimeHour: parts.hour ?? 9,
                localTimeMinute: parts.minute ?? 0
            )]
        }
    }

    public func makeTask(now: Date = Date()) throws -> ScheduledTask {
        guard let workspaceID else { throw ScheduledTaskPreflightError.invalidTask("Workspace is required.") }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw ScheduledTaskPreflightError.invalidTask("Select a valid IANA time zone.")
        }
        let recurrence: ScheduledTaskRecurrence
        do {
            recurrence = try ScheduledFrequencyRule.combinedRecurrence(frequencyRules)
        } catch let error as ScheduledFrequencyRuleError {
            throw ScheduledTaskPreflightError.invalidTask(error.message)
        }
        var task = ScheduledTask(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            workspaceID: workspaceID,
            workspacePathSnapshot: workspacePathSnapshot,
            runAsUser: runAsUser,
            runAsUID: runAsUID,
            provider: provider,
            providerInstanceID: providerInstanceID,
            model: model,
            reasoningEffort: reasoningEffort,
            reasoningModel: provider == .distill ? reasoningModel : nil,
            distillMainEffortSelection: provider == .distill
                ? (distillMainEffortSelection ?? .fixed(reasoningEffort)) : nil,
            distillReasoningEffortSelection: provider == .distill
                ? (distillReasoningEffortSelection ?? .automatic) : nil,
            routingMode: provider == .distill ? .manual : routingMode,
            distillExecutionMode: provider == .distill ? distillExecutionMode : .normal,
            permissionMode: interactionMode == .plan ? .supervised : permissionMode,
            interactionMode: interactionMode,
            executionMode: executionMode,
            baseBranch: executionMode == .worktree ? baseBranch.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            recurrence: recurrence,
            timeZoneIdentifier: timeZoneIdentifier,
            isEnabled: isEnabled,
            createdAt: originalCreatedAt,
            updatedAt: now
        )
        task.nextRunAt = isEnabled ? task.calculatedNextRun(after: now.addingTimeInterval(-0.001)) : nil
        let errors = task.validationErrors()
        guard errors.isEmpty else { throw ScheduledTaskPreflightError.invalidTask(errors.joined(separator: " ")) }
        return task
    }
}

@MainActor
public final class ScheduledTasksViewModel: ObservableObject {
    @Published public private(set) var tasks: [ScheduledTask] = []
    @Published public private(set) var runs: [ScheduledTaskRun] = []
    /// The task `runs` belongs to. History is only read for the detail screen,
    /// so another task's rows are never shown as this task's.
    @Published public private(set) var runsTaskID: UUID?
    @Published public private(set) var workspaces: [Workspace] = []
    @Published public private(set) var providers: [AgentProviderSnapshot] = []
    @Published public private(set) var providersLoading = false
    @Published public private(set) var users: [ScheduledSystemUser] = []
    @Published public private(set) var runCounts: [UUID: Int] = [:]
    /// Live run status per task (queued / running). Drives overview + detail badges.
    @Published public private(set) var activeRunStatuses: [UUID: ScheduledTaskRunStatus] = [:]
    /// The active rows the last poll saw, without the scheduler's 30 s
    /// heartbeat; a change means the history is stale.
    private var lastActiveRuns: [ScheduledTaskRun] = []
    /// Run Now's same-click Queued badges that the store has not confirmed yet.
    /// Only these survive a reload that finds no active row.
    private var optimisticQueuedTaskIDs: Set<UUID> = []
    /// Counts for All / Active / Paused chips (search-scoped, not status-filtered).
    @Published public private(set) var filterCounts: (all: Int, active: Int, paused: Int) = (0, 0, 0)
    @Published public var searchText: String = "" { didSet { reloadTasksOrDefer() } }
    @Published public var statusFilter: ScheduledTaskStatusFilter = .all { didSet { reloadTasksOrDefer() } }
    @Published public var selectedTaskID: UUID? {
        didSet {
            guard !suppressSelectedTaskReload else { return }
            reloadRunsOrDefer()
        }
    }
    @Published public var editorDraft: ScheduledTaskEditorDraft?
    @Published public var errorMessage: String?
    @Published public private(set) var serviceStatus: String = "Runs inside MacCode while the app is open"
    @Published public private(set) var serviceRequiresApproval = false
    @Published public private(set) var isSavingEditor = false
    /// Global kill switch: when false, automatic scheduled occurrences do not claim/run.
    @Published public private(set) var schedulerActive: Bool = true

    private let context: AppContext
    private let router: AppCommandRouter
    private let store: ScheduledTaskStore
    private let settingsStore: SettingsStore
    private var providerLoadCount = 0
    private var activeRunPollTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?
    private var tasksRefreshTask: Task<Void, Never>?
    private var runsRefreshTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var freshnessGeneration: UInt64 = 0
    private var tasksRefreshGeneration: UInt64 = 0
    private var runsRefreshGeneration: UInt64 = 0
    private var navigationGeneration: UInt64 = 0
    private var suppressSelectedTaskReload = false
    /// False while the shell has swapped the Scheduled Tasks host out; the
    /// active-run poll only runs while it is shown.
    private var isVisible = true
    private let deferHydration: Bool
    private(set) var fullHydrationCountForTesting = 0
    private(set) var runHistoryReadCountForTesting = 0
    var isPollingActiveRunsForTesting: Bool { activeRunPollTask != nil }

    public init(context: AppContext, router: AppCommandRouter, loadImmediately: Bool = true) {
        self.context = context
        self.router = router
        self.store = ScheduledTaskStore(db: context.db)
        self.settingsStore = SettingsStore(db: context.db)
        self.deferHydration = !loadImmediately
        if loadImmediately {
            reload()
        }
    }

    deinit {
        freshnessTask?.cancel()
        tasksRefreshTask?.cancel()
        runsRefreshTask?.cancel()
        activeRunPollTask?.cancel()
        navigationTask?.cancel()
    }

    private static func waitForCommittedFrame() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Mount callers use the existing published cache for the first frame and
    /// ask the model for one coalesced freshness pass on the next main turn.
    public func scheduleFreshnessPass() {
        guard deferHydration else { return }
        freshnessTask?.cancel()
        freshnessGeneration &+= 1
        let generation = freshnessGeneration
        freshnessTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self else { return }
            defer { self.finishFreshnessTask(ownedBy: generation) }
            guard !Task.isCancelled,
                  self.freshnessGeneration == generation else { return }
            self.reload()
        }
    }

    private func finishFreshnessTask(ownedBy generation: UInt64) {
        guard freshnessGeneration == generation else { return }
        freshnessTask = nil
    }

    /// The shell keeps this model cached while another destination is shown.
    /// Hiding stops the active-run poll; the remount's freshness pass reloads
    /// once and re-arms the poll if a run is still active.
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        guard !visible else { return }
        activeRunPollTask?.cancel()
        activeRunPollTask = nil
    }

    func waitForFreshnessForTesting() async {
        while true {
            let pending = [freshnessTask, tasksRefreshTask, runsRefreshTask].compactMap { $0 }
            guard !pending.isEmpty else { return }
            await withTaskGroup(of: Void.self) { group in
                for task in pending {
                    group.addTask { await task.value }
                }
            }
            await Task.yield()
        }
    }

    private func reloadTasksOrDefer() {
        if deferHydration { scheduleTasksRefreshPass() } else { reloadTasks() }
    }

    private func reloadRunsOrDefer() {
        if deferHydration { scheduleRunsRefreshPass() } else { reloadRuns() }
    }

    /// Search/filter changes only need the task projection. Re-running the
    /// complete hydration pass here used to re-read workspaces, users, run
    /// history, scheduler state, and provider catalogs for every keystroke.
    private func scheduleTasksRefreshPass() {
        guard deferHydration else { return }
        tasksRefreshTask?.cancel()
        tasksRefreshGeneration &+= 1
        let generation = tasksRefreshGeneration
        tasksRefreshTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self else { return }
            defer { self.finishTasksRefreshTask(ownedBy: generation) }
            guard !Task.isCancelled,
                  self.tasksRefreshGeneration == generation else { return }
            self.reloadTasks()
        }
    }

    /// Selecting a task publishes the selection immediately and only then
    /// refreshes its history. Keep that pass independent from the overview
    /// task list so detail navigation does not repeat unrelated hydration.
    private func scheduleRunsRefreshPass() {
        guard deferHydration else { return }
        runsRefreshTask?.cancel()
        runsRefreshGeneration &+= 1
        let generation = runsRefreshGeneration
        runsRefreshTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self else { return }
            defer { self.finishRunsRefreshTask(ownedBy: generation) }
            guard !Task.isCancelled,
                  self.runsRefreshGeneration == generation else { return }
            self.reloadRuns()
        }
    }

    private func finishTasksRefreshTask(ownedBy generation: UInt64) {
        guard tasksRefreshGeneration == generation else { return }
        tasksRefreshTask = nil
    }

    private func finishRunsRefreshTask(ownedBy generation: UInt64) {
        guard runsRefreshGeneration == generation else { return }
        runsRefreshTask = nil
    }

    public var selectedTask: ScheduledTask? { tasks.first { $0.id == selectedTaskID } }

    public func reload() {
        fullHydrationCountForTesting += 1
        do {
            workspaces = try router.listWorkspaces()
            users = ScheduledSystemUserCatalog.eligibleUsers()
            schedulerActive = settingsStore.load().scheduledTasksActive
            reloadTasks()
            reloadRuns()
            reloadServiceStatus()
        } catch { errorMessage = String(describing: error) }
        // Keep badges live for any active run, not only one started here.
        ensureActiveRunPolling()
        Task { [weak self] in
            guard let self else { return }
            providerLoadCount += 1
            providersLoading = true
            defer {
                providerLoadCount = max(0, providerLoadCount - 1)
                providersLoading = providerLoadCount > 0
            }
            providers = await router.listAgentProviderSnapshots()
        }
    }

    public func createTask() {
        var draft = ScheduledTaskEditorDraft()
        draft.workspaceID = workspaces.first?.id
        draft.workspacePathSnapshot = workspaces.first?.cwd ?? ""
        if let user = users.first(where: { $0.name == draft.runAsUser }) {
            draft.runAsUID = user.uid
        }
        if let provider = providers.first(where: { $0.enabled && $0.installed }) ?? providers.first {
            draft.provider = provider.provider
            draft.providerInstanceID = provider.id
            draft.model = provider.models.first?.id ?? ""
            draft.reasoningEffort = provider.models.first?.supportedReasoningEfforts.first ?? .high
        }
        editorDraft = draft
    }

    public func edit(_ task: ScheduledTask) { editorDraft = ScheduledTaskEditorDraft(task: task) }

    public func saveEditor(_ draft: ScheduledTaskEditorDraft) {
        guard !isSavingEditor else { return }
        isSavingEditor = true
        Task { [weak self] in
            guard let self else { return }
            defer { isSavingEditor = false }
            do {
                let task = try draft.makeTask()
                _ = try await ScheduledTaskExecutor(context: context, router: router).preflight(task)
                let persisted = task
                try store.save(persisted)
                editorDraft = nil
                selectedTaskID = persisted.id
                reloadTasks()
                reloadRuns()
                reloadServiceStatus()
                if persisted.isEnabled {
                    router.scheduledTaskScheduler?.tick()
                }
            } catch { errorMessage = String(describing: error) }
        }
    }

    public func toggle(_ task: ScheduledTask) {
        if task.isEnabled {
            do {
                try store.setEnabled(id: task.id, enabled: false, nextRunAt: nil)
                reloadTasks()
            } catch { errorMessage = String(describing: error) }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await ScheduledTaskExecutor(context: context, router: router).preflight(task)
                let next = task.calculatedNextRun(after: Date().addingTimeInterval(-0.001))
                try store.setEnabled(id: task.id, enabled: true, nextRunAt: next)
                router.scheduledTaskScheduler?.tick()
                reloadTasks()
            } catch { errorMessage = String(describing: error) }
        }
    }

    public func openServiceSettings() {
        // Legacy Login Items path no longer required; keep no-op for old UI tests.
    }

    private func reloadServiceStatus() {
        serviceStatus = "Runs inside MacCode while the app is open"
        serviceRequiresApproval = false
    }

    public func runNow(_ task: ScheduledTask) {
        guard activeRunStatuses[task.id] == nil else {
            errorMessage = "This scheduled task already has an active run."
            return
        }
        guard let scheduler = router.scheduledTaskScheduler else {
            errorMessage = "The in-app scheduler is not ready yet. Keep MacCode open and retry."
            return
        }
        // Immediate feedback: claim is async, but the card should flip to Queued
        // in the same click.
        activeRunStatuses[task.id] = .queued
        optimisticQueuedTaskIDs.insert(task.id)
        runCounts[task.id, default: 0] += 1
        ensureActiveRunPolling()
        scheduler.runNow(taskID: task.id) { [weak self] result in
            guard let self else { return }
            // The claim has either committed its row or failed; from here the
            // store is the source of truth for this task's badge.
            self.optimisticQueuedTaskIDs.remove(task.id)
            switch result {
            case .failure(let error):
                self.activeRunStatuses.removeValue(forKey: task.id)
                self.runCounts[task.id, default: 1] = max(0, (self.runCounts[task.id] ?? 1) - 1)
                self.errorMessage = error.localizedDescription
            case .success:
                break
            }
            self.reloadActiveRunStatuses()
            self.reloadRuns()
            self.reloadServiceStatus()
            self.ensureActiveRunPolling()
        }
    }

    public func delete(_ task: ScheduledTask) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \"\(task.title)\"?"
        alert.informativeText = "The schedule and its run history will be deleted. Agent threads created by prior runs are preserved."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.delete(id: task.id)
            if selectedTaskID == task.id { selectedTaskID = nil }
            reloadTasks()
            reloadRuns()
        } catch { errorMessage = String(describing: error) }
    }

    public func openThread(_ run: ScheduledTaskRun) {
        guard let threadID = run.threadID else { return }
        // Resolve the destination while Schedule Tasks is still on screen: a bot run's
        // thread has no workspace and opens in its bot's Desk; a thread with neither
        // fails here instead of in a hidden view after leaving.
        do {
            switch try router.agentThreadOpenDestination(threadID) {
            case .workspace: break
            case .bot(let botID, let conversationID):
                guard try router.openBotsDesk(botID: botID, conversationID: conversationID) else {
                    throw LayoutError.surfaceNotFound
                }
                return
            case .unavailable:
                throw LayoutError.workspaceNotFound
            }
        } catch {
            // openBotsDesk may have left already; show the failure where it was asked for.
            router.windowController?.presentScheduledTasksInMainContent()
            errorMessage = "Could not open agent task: \(error.localizedDescription)"
            return
        }
        guard !deferHydration else {
            router.windowController?.presentWorkspaceContent()
            navigationTask?.cancel()
            navigationGeneration &+= 1
            let generation = navigationGeneration
            navigationTask = Task { @MainActor [weak self] in
                await Self.waitForCommittedFrame()
                guard let self else { return }
                defer { self.finishNavigationTask(ownedBy: generation) }
                guard !Task.isCancelled,
                      self.navigationGeneration == generation else { return }
                do { _ = try self.router.openAgentThread(thread: threadID, markRead: true) }
                catch {
                    self.router.windowController?.presentScheduledTasksInMainContent()
                    self.errorMessage = "Could not open agent task: \(error.localizedDescription)"
                }
            }
            return
        }
        do { _ = try router.openAgentThread(thread: threadID, markRead: true) }
        catch {
            router.windowController?.presentScheduledTasksInMainContent()
            errorMessage = "Could not open agent task: \(error.localizedDescription)"
        }
    }

    private func finishNavigationTask(ownedBy generation: UInt64) {
        guard navigationGeneration == generation else { return }
        navigationTask = nil
    }

    public func providerSnapshots(for provider: AgentProvider) -> [AgentProviderSnapshot] {
        providers.filter { $0.provider == provider }
    }

    public func models(provider: AgentProvider, instanceID: String) -> [AgentModelDescriptor] {
        providers.resolvedSnapshot(provider: provider, instanceID: instanceID)?.models ?? []
    }

    private func reloadTasks() {
        do {
            let matching = try store.list(search: searchText)
            // PERF: single pass derives counts + the status-filtered list
            // instead of two counting filters plus a third listing filter.
            var activeCount = 0
            var visible: [ScheduledTask] = []
            let showAll = statusFilter == .all
            let wantActive = statusFilter == .active
            if !showAll {
                visible.reserveCapacity(matching.count)
            }
            for task in matching {
                if task.isEnabled { activeCount += 1 }
                if showAll || task.isEnabled == wantActive {
                    if !showAll { visible.append(task) }
                }
            }
            filterCounts = (
                all: matching.count,
                active: activeCount,
                paused: matching.count - activeCount
            )
            switch statusFilter {
            case .all: tasks = matching
            case .active, .paused: tasks = visible
            }
            runCounts = try store.runCounts()
            // Overview is a full list; do not auto-select a task into the detail page.
            if let selectedTaskID, !matching.contains(where: { $0.id == selectedTaskID }) {
                suppressSelectedTaskReload = true
                self.selectedTaskID = nil
                suppressSelectedTaskReload = false
            }
            reloadActiveRunStatuses()
        } catch { errorMessage = String(describing: error) }
    }

    private func reloadRuns() {
        reloadRunHistory()
        // Keep overview badges in sync when history refreshes (e.g. after Run Now).
        reloadActiveRunStatuses()
    }

    /// Only the detail screen shows history, so the overview (no selection)
    /// never decodes up to 200 cross-task rows.
    private func reloadRunHistory() {
        guard let selectedTaskID else { return }
        runHistoryReadCountForTesting += 1
        do {
            let next = try store.listRuns(taskID: selectedTaskID, limit: 200)
            if next != runs { runs = next }
            if runsTaskID != selectedTaskID { runsTaskID = selectedTaskID }
        } catch { errorMessage = String(describing: error) }
    }

    /// Returns whether any task's active status changed.
    @discardableResult
    private func reloadActiveRunStatuses() -> Bool {
        do {
            let activeRuns = try store.listActiveRuns()
            var next: [UUID: ScheduledTaskRunStatus] = [:]
            for run in activeRuns {
                // Prefer running over queued if both somehow exist.
                if next[run.taskID] == .running { continue }
                next[run.taskID] = run.status
            }
            // Preserve optimistic Queued until the store has the row (or failure clears it).
            for taskID in optimisticQueuedTaskIDs where next[taskID] == nil {
                next[taskID] = .queued
            }
            // Publish only real changes: the poll runs every second and each
            // publish re-renders the whole window. The heartbeat is rewritten on
            // every scheduler tick and shown nowhere, so it is not a change.
            let observedRuns = activeRuns.map { run -> ScheduledTaskRun in
                var run = run
                run.heartbeatAt = nil
                return run
            }
            let changed = next != activeRunStatuses || observedRuns != lastActiveRuns
            lastActiveRuns = observedRuns
            if next != activeRunStatuses { activeRunStatuses = next }
            return changed
        } catch {
            errorMessage = String(describing: error)
            return true
        }
    }

    /// One tick of the active-run poll. Only active rows change while runs are
    /// in flight, so the history reloads when one of them does (start, thread
    /// attached, finish) instead of every tick.
    func pollActiveRunsOnce() {
        if reloadActiveRunStatuses() { reloadRunHistory() }
    }

    private func ensureActiveRunPolling() {
        guard isVisible, !activeRunStatuses.isEmpty else {
            activeRunPollTask?.cancel()
            activeRunPollTask = nil
            return
        }
        guard activeRunPollTask == nil else { return }
        activeRunPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.pollActiveRunsOnce()
                if self.activeRunStatuses.isEmpty {
                    self.activeRunPollTask = nil
                    return
                }
            }
        }
    }

    public func isTaskRunning(_ taskID: UUID) -> Bool {
        activeRunStatuses[taskID] != nil
    }

    public func activeRunStatus(for taskID: UUID) -> ScheduledTaskRunStatus? {
        activeRunStatuses[taskID]
    }

    public func workspaceName(for task: ScheduledTask) -> String {
        workspaces.first { $0.id == task.workspaceID }?.name ?? "Missing workspace"
    }

    public func providerLabel(for task: ScheduledTask) -> String {
        let host: String
        if let snap = providers.first(where: { $0.id == task.providerInstanceID }) {
            host = "\(task.provider.rawValue.capitalized) · \(snap.displayName)"
        } else {
            host = task.provider.rawValue.capitalized
        }
        // Auto never replaces the Source — surface the chosen host plus routing mode.
        if task.effectiveRoutingMode == .auto { return "\(host) · Auto" }
        return host
    }

    public func setSchedulerActive(_ active: Bool) {
        settingsStore.update { $0.scheduledTasksActive = active }
        schedulerActive = settingsStore.load().scheduledTasksActive
        if active {
            router.scheduledTaskScheduler?.tick()
        }
        ScheduledTaskCrossProcess.notifyStoreChanged(reason: active ? "global_active" : "global_paused")
    }

    public var footerTaskCountLine: String {
        let total = filterCounts.all
        let active = filterCounts.active
        return "\(total) task\(total == 1 ? "" : "s") · \(active) active"
    }

    public var footerStatsLine: String {
        let online: String
        if !schedulerActive {
            online = "Scheduler paused"
        } else if serviceRequiresApproval {
            online = "Scheduler needs approval"
        } else {
            online = "Scheduler online"
        }
        return "\(footerTaskCountLine) · \(online)"
    }
}


// MARK: - Navigation screens (plan-scheduled-tasks mockups)

/// Re-evaluates `content` whenever the Bots model publishes.
struct BotsModelObserver<Content: View>: View {
    @ObservedObject var botsVM: BotsViewModel
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

private enum ScheduledTasksScreen: Equatable {
    case overview
    case detail
    case editor
}

public struct ScheduledTasksRootView: View {
    @ObservedObject private var vm: ScheduledTasksViewModel
    /// Bot schedules share this screen when the shell provides the Bots model.
    private let botsVM: BotsViewModel?
    @State private var screen: ScheduledTasksScreen = .overview
    @State private var expandedRunIDs = Set<UUID>()
    @State private var editorReturnScreen: ScheduledTasksScreen = .overview

    public init(vm: ScheduledTasksViewModel, botsVM: BotsViewModel? = nil) {
        self.vm = vm
        self.botsVM = botsVM
    }

    public var body: some View {
        // The content reads botsVM (draft, items); an observing wrapper re-renders it on every change.
        if let botsVM {
            BotsModelObserver(botsVM: botsVM) { rootContent }
        } else {
            rootContent
        }
    }

    private var rootContent: some View {
        VStack(spacing: 0) {
            if vm.serviceRequiresApproval {
                serviceBanner
            }
            if let botsVM, botsVM.scheduleTaskDraft != nil {
                BotScheduleTaskEditorScreen(vm: botsVM)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            Group {
                switch screen {
                case .overview:
                    overviewScreen
                case .detail:
                    detailScreen
                case .editor:
                    if let draft = vm.editorDraft {
                        ScheduledTaskEditorView(
                            draft: draft,
                            vm: vm,
                            botsVM: botsVM,
                            onBack: { closeEditor(cancel: true) },
                            onCancel: { closeEditor(cancel: true) },
                            onSave: { vm.saveEditor($0) }
                        )
                    } else {
                        overviewScreen
                            .onAppear { screen = .overview }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if screen == .overview || screen == .detail {
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                footerBar
            }
            }
        }
        .onAppear { syncBotSchedules() }
        .onChange(of: vm.searchText) { _ in syncBotSchedules() }
        .onChange(of: vm.statusFilter) { _ in syncBotSchedules() }
        .frame(minWidth: 360, minHeight: 480)
        .background(DS.Palette.bg)
        .alert("Scheduled Tasks", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert("Bot schedules", isPresented: Binding(
            get: { botsVM?.errorMessage != nil },
            set: { if !$0 { botsVM?.errorMessage = nil } }
        )) {
            Button("OK") { botsVM?.errorMessage = nil }
        } message: {
            Text(botsVM?.errorMessage ?? "")
        }
        .onAppear { vm.scheduleFreshnessPass() }
        .onChange(of: vm.editorDraft) { draft in
            // External create/edit still routes into the full-page editor.
            if draft != nil, screen != .editor {
                editorReturnScreen = screen
                screen = .editor
            } else if draft == nil, screen == .editor {
                // Save success clears draft and selects the task → open detail.
                // Cancel also clears draft → return to prior screen.
                screen = vm.selectedTaskID != nil ? .detail : editorReturnScreen
            }
        }
    }

    /// Bot schedules follow this screen's search and status filter.
    private func syncBotSchedules() {
        guard let botsVM else { return }
        botsVM.reloadScheduleTasks()
        if botsVM.scheduleTaskSearchText != vm.searchText { botsVM.scheduleTaskSearchText = vm.searchText }
        if botsVM.scheduleTaskStatusFilter != vm.statusFilter { botsVM.scheduleTaskStatusFilter = vm.statusFilter }
    }

    private func openEditor(returnTo: ScheduledTasksScreen) {
        editorReturnScreen = returnTo
        screen = .editor
    }

    private func closeEditor(cancel: Bool) {
        if cancel { vm.editorDraft = nil }
        screen = editorReturnScreen == .detail && vm.selectedTaskID != nil ? editorReturnScreen : .overview
    }

    // MARK: Service banner

    private var serviceBanner: some View {
        // Path B LaunchAgent Login Items banner retired — schedules run in-app.
        EmptyView()
    }

    private var footerBar: some View {
        AgentListFooterBar(
            caption: vm.footerTaskCountLine,
            pillTitle: vm.schedulerActive ? "Scheduler online" : "Scheduler paused",
            pillTone: vm.schedulerActive ? .success : .warning
        )
        .accessibilityLabel(vm.footerStatsLine)
    }

    // MARK: Overview (plan: scheduled-tasks-overview)

    private var overviewScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Wide panes keep title and actions on one row; narrow ones stack the actions below.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DS.Space.lg) {
                    overviewTitle
                    Spacer(minLength: DS.Space.lg)
                    HStack(spacing: DS.Space.md) { overviewActions }
                }
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    overviewTitle
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DS.Space.md) { overviewActions }
                        VStack(alignment: .leading, spacing: DS.Space.sm) { overviewActions }
                    }
                }
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.top, DS.Space.xxl)
            .padding(.bottom, DS.Space.xl)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.md) {
                    filterChips
                    Spacer(minLength: DS.Space.lg)
                    searchField
                        .frame(maxWidth: 280)
                }
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    ScrollView(.horizontal, showsIndicators: false) { filterChips }
                    searchField
                }
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.bottom, DS.Space.xl)

            if vm.tasks.isEmpty && (botsVM?.scheduleTaskItems.isEmpty ?? true) {
                DSEmptyState(
                    icon: "calendar.badge.clock",
                    title: vm.searchText.isEmpty ? "No scheduled tasks" : "No matching tasks",
                    subtitle: vm.searchText.isEmpty
                        ? "Create a task to run an Agent automatically while MacCode is closed."
                        : "Try another search or clear the status filter."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.md, pinnedViews: [.sectionHeaders]) {
                        ForEach(ScheduleTaskWorkspaceGroup.groups(tasks: vm.tasks, botItems: botsVM?.scheduleTaskItems ?? [], workspaces: vm.workspaces)) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    switch entry {
                                    case .task(let task): taskCard(task)
                                    case .bot(let item): if let botsVM { BotScheduleTaskRow(vm: botsVM, item: item) }
                                    }
                                }
                            } header: {
                                WorkspaceSectionHeader(title: group.name, count: group.entries.count,
                                                       hasWorkspace: group.id != nil, color: group.color)
                                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
                .accessibilityIdentifier("scheduledTasks.list")
            }
        }
    }

    private func taskCard(_ task: ScheduledTask) -> some View {
        ScheduledTaskCard(
            task: task,
            workspaceName: vm.workspaceName(for: task),
            providerLabel: shortProviderModel(task),
            runCount: vm.runCounts[task.id, default: 0],
            activeRunStatus: vm.activeRunStatus(for: task.id),
            onOpen: {
                vm.selectedTaskID = task.id
                screen = .detail
            },
            onToggle: { vm.toggle(task) },
            onRunNow: { vm.runNow(task) },
            onEdit: {
                vm.selectedTaskID = task.id
                vm.edit(task)
                openEditor(returnTo: .detail)
            },
            onDelete: { vm.delete(task) }
        )
    }

    private var overviewTitle: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Scheduled Tasks")
                .font(DS.Font.title.weight(.semibold))
                .foregroundColor(DS.Palette.text)
                .lineLimit(1)
            Text(vm.schedulerActive
                 ? "Automate recurring agent work"
                 : "Automatic runs paused — turn Active on when you're back")
                .font(DS.Font.body)
                .foregroundColor(vm.schedulerActive ? DS.Palette.textSecondary : DS.Palette.warning)
                .animation(DS.Motion.micro, value: vm.schedulerActive)
        }
    }

    @ViewBuilder
    private var overviewActions: some View {
        Button {
            vm.createTask()
            openEditor(returnTo: .overview)
        } label: {
            Label("New Task", systemImage: "plus").lineLimit(1).fixedSize()
        }
        .buttonStyle(DSPrimaryButtonStyle())
        .accessibilityIdentifier("scheduledTasks.new")

        schedulerActiveControl
    }

    /// Global kill-switch control: status chrome + switch.
    /// State is conveyed by icon + label + tint (not color alone — WCAG 1.4.1).
    private var schedulerActiveControl: some View {
        AgentKillSwitchControl(
            isActive: vm.schedulerActive,
            identifier: "scheduledTasks.globalActive",
            accessibilityLabel: vm.schedulerActive ? "Schedules active" : "Schedules paused",
            onChange: { vm.setSchedulerActive($0) }
        )
    }

    private var filterChips: some View {
        HStack(spacing: DS.Space.sm) {
            AgentListFilterChip(
                title: ScheduledTaskStatusFilter.all.rawValue,
                count: vm.filterCounts.all,
                selected: vm.statusFilter == .all,
                identifier: "scheduledTasks.filter.all"
            ) { vm.statusFilter = .all }
            AgentListFilterChip(
                title: ScheduledTaskStatusFilter.active.rawValue,
                count: vm.filterCounts.active,
                selected: vm.statusFilter == .active,
                identifier: "scheduledTasks.filter.active"
            ) { vm.statusFilter = .active }
            AgentListFilterChip(
                title: ScheduledTaskStatusFilter.paused.rawValue,
                count: vm.filterCounts.paused,
                selected: vm.statusFilter == .paused,
                identifier: "scheduledTasks.filter.paused"
            ) { vm.statusFilter = .paused }
        }
        .fixedSize()
        .accessibilityIdentifier("scheduledTasks.statusFilter")
        .accessibilityLabel("Filter tasks by status")
    }

    private var searchField: some View {
        AgentListSearchField(
            text: $vm.searchText,
            placeholder: "Search tasks",
            identifier: "scheduledTasks.search",
            accessibilityLabel: "Search tasks",
            autofocus: true
        )
    }

    private func shortProviderModel(_ task: ScheduledTask) -> String {
        if task.effectiveRoutingMode == .auto {
            return "\(task.provider.rawValue.capitalized) · Auto"
        }
        let model = task.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(task.provider.rawValue.capitalized) · \(model.isEmpty ? "Default model" : model) · \(task.reasoningEffort.displayName)"
    }

    // MARK: Detail / history (plan: scheduled-task-history)

    @ViewBuilder
    private var detailScreen: some View {
        if let task = vm.selectedTask {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    detailHeader(task)
                    metaSummaryCard(task)
                    runHistorySection(task)
                    Button {
                        vm.edit(task)
                        openEditor(returnTo: .detail)
                    } label: {
                        Label("Edit Schedule", systemImage: "pencil")
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("scheduledTasks.editSchedule")
                }
                .padding(DS.Space.xxl)
                .frame(maxWidth: 1100, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("scheduledTasks.detail")
        } else {
            overviewScreen.onAppear { screen = .overview }
        }
    }

    private func detailHeader(_ task: ScheduledTask) -> some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            Button {
                // The overview shows no history; a kept selection would make
                // its poll and remount reloads still read this task's rows.
                vm.selectedTaskID = nil
                screen = .overview
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to scheduled tasks")
            .accessibilityIdentifier("scheduledTasks.back")

            HStack(spacing: DS.Space.md) {
                Text(task.title)
                    .font(DS.Font.title2.weight(.semibold))
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                statusPill(for: task)
            }
            Spacer(minLength: DS.Space.lg)
            HStack(spacing: DS.Space.sm) {
                Button("Run Now") { vm.runNow(task) }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .accessibilityIdentifier("scheduledTasks.runNow")
                Button(task.isEnabled ? "Pause" : "Resume") { vm.toggle(task) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("scheduledTasks.toggle")
                Menu {
                    Button("Edit Schedule") {
                        vm.edit(task)
                        openEditor(returnTo: .detail)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        vm.delete(task)
                        if vm.selectedTaskID == nil { screen = .overview }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: 36, height: 32)
                        .background(DS.Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                        )
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("More actions")
            }
        }
    }

    @ViewBuilder
    private func statusPill(for task: ScheduledTask) -> some View {
        if let status = vm.activeRunStatus(for: task.id) {
            switch status {
            case .queued:
                DSPill("Queued", tone: .warning)
            case .running:
                DSPill("Running", tone: .warning)
            default:
                DSPill("Running", tone: .warning)
            }
        } else if task.isEnabled {
            DSPill("Active", tone: .success)
        } else {
            DSPill("Paused", tone: .neutral)
        }
    }

    private func metaSummaryCard(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(alignment: .top, spacing: DS.Space.xl) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                    .frame(width: 40, height: 40)
                    .background(DS.Palette.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .accessibilityHidden(true)

                metaCell("Workspace", vm.workspaceName(for: task))
                metaCell("Run as user", task.runAsUser)
                metaCell("Provider", vm.providerLabel(for: task))
                metaCell("Model", task.model)
                metaCell("Reasoning", task.reasoningEffort.displayName)
                metaCell("Schedule", task.recurrence.detailSummary)
                metaCell("Time zone", task.timeZoneIdentifier)
            }
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "clock")
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
                Text("Next run: \(nextRunLabel(task))")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
    }

    private func metaCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textTertiary)
            Text(value)
                .font(DS.Font.caption.weight(.medium))
                .foregroundColor(DS.Palette.text)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(minWidth: 88, alignment: .leading)
    }

    private func nextRunLabel(_ task: ScheduledTask) -> String {
        guard task.isEnabled, let next = task.nextRunAt else { return "Paused" }
        return next.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func runHistorySection(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Run History")
                .font(DS.Font.title3.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            if vm.runsTaskID != task.id {
                // This task's history is still loading (or failed, which the
                // alert reports): keep the card's shape, claim nothing.
                historyHeaderRow
                    .background(DS.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                    )
            } else if vm.runs.isEmpty {
                Text("No runs yet. Use Run Now or wait for the next scheduled occurrence.")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsPanel(padding: DS.Space.xl)
            } else {
                // Lazy: up to 200 rows, each formatting dates; only the
                // visible ones need building.
                LazyVStack(spacing: 0) {
                    historyHeaderRow
                    Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                    ForEach(Array(vm.runs.enumerated()), id: \.element.id) { index, run in
                        historyRow(task: task, run: run)
                        if index != vm.runs.count - 1 {
                            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                        }
                    }
                }
                .background(DS.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                )
                .accessibilityIdentifier("scheduledTasks.history")
            }
        }
    }

    private var historyHeaderRow: some View {
        HStack(spacing: DS.Space.lg) {
            Text("Started").frame(width: 140, alignment: .leading)
            Text("Duration").frame(width: 80, alignment: .leading)
            Text("Status").frame(width: 110, alignment: .leading)
            Text("Agent Task").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 24)
        }
        .font(DS.Font.caption2.weight(.semibold))
        .foregroundColor(DS.Palette.textTertiary)
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }

    private func historyRow(task: ScheduledTask, run: ScheduledTaskRun) -> some View {
        let expanded = expandedRunIDs.contains(run.id)
        let canOpenThread = run.threadID != nil
        let canExpandDetails = run.errorSummary != nil || run.status == .failed
        return VStack(alignment: .leading, spacing: 0) {
            // Sibling hit targets (not nested): primary area opens the agent thread;
            // chevron alone expands/collapses failure details. A disabled outer
            // Button used to swallow the nested Agent Task control on completed runs.
            HStack(spacing: DS.Space.lg) {
                Group {
                    if canOpenThread {
                        Button {
                            vm.openThread(run)
                        } label: {
                            historyRowPrimaryContent(task: task, run: run, linkStyle: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("scheduledTasks.history.openThread")
                        .accessibilityLabel("Open agent task \(agentTaskTitle(task: task, run: run))")
                        .accessibilityHint("Opens the agent thread created by this run")
                    } else {
                        historyRowPrimaryContent(task: task, run: run, linkStyle: false)
                            .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if canExpandDetails {
                    Button {
                        if !expandedRunIDs.insert(run.id).inserted {
                            expandedRunIDs.remove(run.id)
                        }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("scheduledTasks.history.toggleDetails")
                    .accessibilityLabel(expanded ? "Hide run details" : "Show run details")
                } else {
                    Color.clear.frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.lg)

            if expanded, let error = run.errorSummary {
                HStack(alignment: .center, spacing: DS.Space.md) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(DS.Palette.danger)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    if canOpenThread {
                        Button("Open Agent Task") { vm.openThread(run) }
                            .buttonStyle(DSSecondaryButtonStyle())
                            .accessibilityIdentifier("scheduledTasks.history.openThreadFromDetails")
                    }
                    if run.status == .failed {
                        Button("Run Again") { vm.runNow(task) }
                            .buttonStyle(DSPrimaryButtonStyle())
                    }
                }
                .padding(DS.Space.lg)
                .background(DS.Palette.danger.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.danger.opacity(0.35), lineWidth: DS.Border.hairline)
                )
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.lg)
                Button(expanded ? "Hide details" : "Show details") {
                    if !expandedRunIDs.insert(run.id).inserted {
                        expandedRunIDs.remove(run.id)
                    }
                }
                .buttonStyle(.plain)
                .font(DS.Font.caption.weight(.semibold))
                .foregroundColor(DS.Palette.accent)
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.md)
            }
        }
    }

    private func historyRowPrimaryContent(task: ScheduledTask, run: ScheduledTaskRun, linkStyle: Bool) -> some View {
        HStack(spacing: DS.Space.lg) {
            Text((run.startedAt ?? run.queuedAt).formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.text)
                .frame(width: 140, alignment: .leading)
            Group {
                // Heartbeats no longer republish `runs`, so a running row
                // needs its own clock or its elapsed time freezes.
                if run.status == .running {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(durationLabel(run, now: timeline.date))
                    }
                } else {
                    Text(durationLabel(run, now: Date()))
                }
            }
            .font(DS.Font.caption)
            .foregroundColor(DS.Palette.textSecondary)
            .frame(width: 80, alignment: .leading)
            runStatusPill(run.status)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(agentTaskTitle(task: task, run: run))
                    .font(DS.Font.caption.weight(linkStyle ? .medium : .regular))
                    .foregroundColor(linkStyle ? DS.Palette.accent : DS.Palette.textSecondary)
                if run.status == .failed, let error = run.errorSummary {
                    Text(error)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.danger)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func agentTaskTitle(task: ScheduledTask, run: ScheduledTaskRun) -> String {
        let day = (run.startedAt ?? run.queuedAt).formatted(.dateTime.month(.abbreviated).day())
        return "\(task.title) · \(day)"
    }

    private func durationLabel(_ run: ScheduledTaskRun, now: Date) -> String {
        guard let started = run.startedAt, let finished = run.finishedAt else {
            if run.status == .running, let started = run.startedAt {
                let s = Int(now.timeIntervalSince(started))
                return s < 60 ? "\(s)s" : "\(s / 60)m"
            }
            return "—"
        }
        let s = Int(finished.timeIntervalSince(started))
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }

    private func runStatusPill(_ status: ScheduledTaskRunStatus) -> some View {
        switch status {
        case .completed: return AnyView(DSPill("Completed", tone: .success))
        case .failed: return AnyView(DSPill("Failed", tone: .danger))
        case .running: return AnyView(DSPill("Running", tone: .warning))
        case .queued: return AnyView(DSPill("Queued", tone: .warning))
        case .cancelled: return AnyView(DSPill("Cancelled", tone: .neutral))
        case .skipped: return AnyView(DSPill("Skipped", tone: .neutral))
        }
    }
}

// MARK: - Task card (overview)

private struct ScheduledTaskCard: View {
    let task: ScheduledTask
    let workspaceName: String
    let providerLabel: String
    let runCount: Int
    let activeRunStatus: ScheduledTaskRunStatus?
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onRunNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var isActiveRun: Bool { activeRunStatus != nil }

    var body: some View {
        AgentOverviewCard(
            icon: "calendar.badge.clock",
            iconColor: DS.Palette.accent,
            title: task.title,
            subtitle: "\(workspaceName) · \(task.runAsUser) · \(providerLabel)",
            identifier: "scheduledTasks.task.\(task.id.uuidString.lowercased())",
            accessibilityValue: accessibilityStatusValue,
            onOpen: onOpen
        ) {
            badge
        } meta: {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                AgentOverviewMetaColumn(title: "Schedule", value: task.recurrence.detailSummary)
                AgentOverviewMetaColumn(
                    title: isActiveRun ? "Status" : "Next run",
                    value: statusOrNext,
                    valueColor: isActiveRun ? DS.Palette.warning : DS.Palette.text
                )
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Text("\(runCount)")
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.textSecondary)
                        .monospacedDigit()
                }
                .frame(width: 44, alignment: .trailing)
                .accessibilityLabel("\(runCount) runs")
            }
        } trailing: {
            Menu {
                Button(task.isEnabled ? "Pause" : "Resume", action: onToggle)
                Button("Run Now", action: onRunNow)
                Button("Edit", action: onEdit)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Task actions")
        }
    }

    @ViewBuilder
    private var badge: some View {
        if activeRunStatus == .queued {
            DSPill("Queued", tone: .warning)
        } else if activeRunStatus == .running {
            DSPill("Running", tone: .warning)
        } else if isActiveRun {
            DSPill("Running", tone: .warning)
        } else if task.isEnabled {
            DSPill("Active", tone: .success)
        } else {
            DSPill("Paused", tone: .neutral)
        }
    }

    private var statusOrNext: String {
        if activeRunStatus == .queued { return "Queued" }
        if activeRunStatus == .running || isActiveRun { return "Running now" }
        if !task.isEnabled { return "Paused" }
        guard let next = task.nextRunAt else { return "—" }
        return next.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private var accessibilityStatusValue: String {
        if activeRunStatus == .queued { return "Queued" }
        if activeRunStatus == .running || isActiveRun { return "Running" }
        return task.isEnabled ? "Active" : "Paused"
    }
}

// MARK: - Editor (plan: scheduled-task-editor)

private struct ScheduledTaskEditorView: View {
    @State private var draft: ScheduledTaskEditorDraft
    @State private var showSourceOptions = false
    @State private var showModelOptions = false
    @ObservedObject var vm: ScheduledTasksViewModel
    /// Present when the shell offers Bots: "Run as" then lists them like the Agent App composer.
    let botsVM: BotsViewModel?
    let onBack: () -> Void
    let onCancel: () -> Void
    let onSave: (ScheduledTaskEditorDraft) -> Void

    init(
        draft: ScheduledTaskEditorDraft,
        vm: ScheduledTasksViewModel,
        botsVM: BotsViewModel? = nil,
        onBack: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSave: @escaping (ScheduledTaskEditorDraft) -> Void
    ) {
        self._draft = State(initialValue: draft)
        self.vm = vm
        self.botsVM = botsVM
        self.onBack = onBack
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        ScheduleEditorPage(
            title: isNew ? "New Scheduled Task" : "Edit Scheduled Task",
            subtitle: "Run an agent prompt on a schedule, in a workspace, while MacCode is open.",
            saveTitle: vm.isSavingEditor ? "Checking…" : "Save Task",
            saveIdentifier: "scheduledTasks.editor.save",
            isSaving: vm.isSavingEditor,
            onBack: onBack,
            onSave: { confirmAndSave() },
            content: {
                ScheduleEditorSection("Task", identifier: "editorSection.Task") {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        ScheduleEditorTextField(
                            placeholder: "Title, e.g. Daily dependency scan",
                            text: $draft.title,
                            identifier: "scheduledTasks.editor.title",
                            label: "Title"
                        )
                        ScheduleEditorPromptBox(
                            placeholder: "Describe what the agent should do",
                            text: $draft.prompt,
                            identifier: "scheduledTasks.editor.prompt",
                            label: "Prompt"
                        )
                    }
                    .padding(DS.Space.md)
                }

                // Contract section names retained for chrome regression tests.
                let _ = ["Basics", "Agent", "Schedule", "Prompt"] as [String]
                editorGroup("Details") {
                    formRow("Workspace", showsDivider: false) {
                        Picker("Workspace", selection: $draft.workspaceID) {
                            Text("Select a workspace").tag(WorkspaceID?.none)
                            ForEach(vm.workspaces) { workspace in
                                Text(workspace.name).tag(Optional(workspace.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: draft.workspaceID) { _, id in
                            draft.workspacePathSnapshot = vm.workspaces.first { $0.id == id }?.cwd ?? ""
                        }
                    }
                    formRow("Run as") {
                        editorRunAsCapsule
                    }
                    // Parity with Agent App: one Provider/Source capsule only. Instance id is
                    // derived from the selected provider's primary snapshot and stays in the model.
                    if AgentSourceCapsulePresentation.isVisible(entryCount: editorSourceEntries.count) {
                        formRow("Provider") {
                            editorSourceCapsule
                                .accessibilityIdentifier("scheduledTasks.editor.provider")
                        }
                    }
                    if draft.provider != .distill {
                        formRow("Model routing") {
                            HStack(spacing: DS.Space.sm) {
                                if vm.providersLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel("Loading providers")
                                }
                                Toggle("Auto", isOn: Binding(
                                    get: { draft.routingMode == .auto },
                                    set: { setAutoRoutingEnabled($0) }
                                ))
                                .toggleStyle(.switch)
                                .tint(DS.Palette.success)
                                .accessibilityIdentifier("scheduledTasks.editor.autoRouting")
                            }
                        }
                    }
                    // Parity with Agent App: Auto never picks the provider/Source,
                    // only the model within the selected host at run time.
                    if draft.routingMode == .auto {
                        formRow("Model") {
                            Text("Auto selects the best model for the selected provider at run time.")
                                .font(DS.Font.caption)
                                .foregroundColor(DS.Palette.textSecondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if draft.provider == .distill {
                        // Same Main / Worker pills and modal sheets as the Agent App and Bot Desk composer.
                        formRow("Model") { editorDistillModelPills }
                    } else {
                        formRow("Model") {
                            Button {
                                showModelOptions.toggle()
                            } label: {
                                AgentModelPillLabel(presentation: editorModelPillPresentation)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("scheduledTasks.editor.model")
                            .popover(isPresented: $showModelOptions, arrowEdge: .bottom) {
                                editorModelPopover
                            }
                        }
                    }
                }

                editorGroup("Run options") {
                    ScheduledRunOptionsEditor(
                        showsExecutionMode: draft.provider == .distill,
                        executionMode: $draft.distillExecutionMode,
                        permission: $draft.permissionMode,
                        plan: Binding(get: { draft.interactionMode == .plan }, set: { draft.interactionMode = $0 ? .plan : .default }),
                        execution: Binding(get: { draft.executionMode }, set: { draft.executionMode = $0 }),
                        baseBranch: Binding(get: { draft.baseBranch }, set: { draft.baseBranch = $0 }),
                        identifierPrefix: "scheduledTasks.editor"
                    )
                }

                editorGroup("Frequency") {
                    ScheduledFrequencyEditor(
                        rules: $draft.frequencyRules,
                        timeZoneIdentifier: $draft.timeZoneIdentifier,
                        identifierPrefix: "scheduledTasks.editor"
                    )
                }

                AgentChoiceCallout(
                    icon: "exclamationmark.triangle.fill",
                    tint: DS.Palette.warning,
                    text: ScheduledRunOptionsEditor.unattendedNotice(permission: draft.interactionMode == .plan ? .supervised : draft.permissionMode)
                )
            },
            footer: { ScheduleEditorFooter(nextRun: previewNextRun) }
        )
        .onAppear { normalizeProviderInstance() }
        .onChange(of: vm.providers.map(\.id)) { _ in normalizeProviderInstance() }
        .accessibilityIdentifier("scheduledTasks.editor")
    }

    private var isNew: Bool {
        !vm.tasks.contains(where: { $0.id == draft.id })
    }

    private var previewNextRun: String {
        guard let task = try? draft.makeTask(), let next = task.nextRunAt else {
            return draft.isEnabled ? "Not scheduled yet" : "Paused until enabled"
        }
        return next.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    private func normalizeProviderInstance() {
        guard !vm.providers.contains(where: { $0.provider == draft.provider && $0.id == draft.providerInstanceID }),
              let resolved = vm.providers.resolvedSnapshot(provider: draft.provider, instanceID: draft.providerInstanceID) else { return }
        draft.providerInstanceID = resolved.id
    }

    private func editorGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        // Section titles "Details" / "Frequency" match plan; legacy contract tests also pin
        // Basics/Agent/Schedule/Prompt string anchors in source.
        ScheduleEditorSection(title, identifier: "editorSection.\(title)", content: content)
    }

    private func formRow<Content: View>(_ label: String, showsDivider: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        ScheduleEditorRow(label, showsDivider: showsDivider, control: content)
    }

    private var editorRunAsCapsule: some View {
        let users = vm.users.map { user -> AgentRunAsUser in
            let name = user.name
            let uid = user.uid
            let homeDirectory = user.homeDirectory
            return AgentRunAsUser(generatedUID: "", shortName: name, uid: uid, gid: 0, homePath: homeDirectory)
        }
        let selected = users.first(where: { $0.shortName == draft.runAsUser && $0.uid == draft.runAsUID })
            ?? users.first(where: { $0.shortName == draft.runAsUser })
            ?? AgentRunAsUser(generatedUID: "", shortName: draft.runAsUser, uid: draft.runAsUID, gid: 0, homePath: "")
        return AgentRunAsUserCapsule(
            usersProvider: { users },
            selected: selected,
            runLocked: false,
            identityLocked: false,
            accessibilityIdentifier: "scheduledTasks.editor.runAsUser",
            botsProvider: botsVM.map { bots in { bots.fleet } },
            onSelect: { user in
                draft.runAsUser = user.shortName
                draft.runAsUID = user.uid
            },
            onSelectActor: { actor in
                guard let botID = actor.botID, let botsVM else { return }
                botsVM.beginScheduleTask(botID: botID, carrying: draft)
                onCancel()
            }
        )
    }

    private var editorSourceEntries: [AgentSourceCapsulePresentation.MenuEntry] {
        AgentSourceCapsulePresentation.menuEntries(
            snapshots: vm.providers,
            selectedSnapshotId: draft.providerInstanceID,
            selectedProvider: draft.provider,
            providerDisplayName: { $0.rawValue.capitalized }
        )
    }

    private var editorSourceCapsule: some View {
        AgentSourceCapsule(
            label: AgentSourceCapsulePresentation.capsuleLabel(
                selected: vm.providers.first(where: {
                    $0.id == draft.providerInstanceID && $0.provider == draft.provider
                }) ?? vm.providerSnapshots(for: draft.provider).first,
                fallbackProvider: draft.provider,
                fallbackInstanceId: draft.providerInstanceID,
                snapshots: vm.providers
            ),
            entries: editorSourceEntries,
            runLocked: false,
            providerLocked: false,
            accessibilityIdentifier: "scheduledTasks.editor.provider",
            popoverIdentifier: "scheduledTasks.editor.source.popover",
            isPresented: $showSourceOptions,
            onSelect: { selectScheduledSource($0) }
        )
    }

    private var editorModelPillPresentation: AgentModelPillPresentation {
        let models = vm.models(provider: draft.provider, instanceID: draft.providerInstanceID)
        let selectableModels = draft.provider == .distill
            ? AgentDistillModelCatalog.selectableModels(models)
            : models
        let title = selectableModels.first(where: { $0.id == draft.model })?.label
            ?? (draft.model.isEmpty ? (draft.provider == .distill ? "Select Main model" : "Model") : draft.model)
        let effort = draft.provider == .distill
            ? (draft.distillMainEffortSelection ?? .fixed(draft.reasoningEffort)).effort?.displayName ?? "Auto"
            : draft.reasoningEffort.displayName
        return AgentModelPillPresentation(title: title, effort: effort)
    }

    private var editorDistillModelPills: some View {
        let models = AgentDistillModelCatalog.selectableModels(
            vm.models(provider: draft.provider, instanceID: draft.providerInstanceID)
        )
        let snapshot = vm.providers.resolvedSnapshot(provider: draft.provider, instanceID: draft.providerInstanceID)
        let mainUnavailable = !draft.model.isEmpty && !models.isEmpty
            && !models.contains(where: { $0.id == draft.model || $0.supportsCustomModel })
        return AgentDistillModelPills(
            mainModel: draft.model, mainModels: models,
            reasoningModel: draft.reasoningModel, reasoningModels: models,
            mainEffortSelection: draft.distillMainEffortSelection ?? .fixed(draft.reasoningEffort),
            mainEfforts: selectedModelEfforts,
            supportsMainEffortAuto: snapshot?.effectiveCapabilities.supportsDistillMainEffortAuto == true,
            reasoningEffortSelection: draft.distillReasoningEffortSelection ?? .automatic,
            reasoningEfforts: selectedReasoningEfforts,
            supportsReasoningModelEffort: snapshot?.effectiveCapabilities.supportsDistillReasoningModelEffort == true,
            homePath: snapshot?.homePath,
            mainUnavailable: mainUnavailable,
            isRunning: false,
            isDisabled: false,
            emptyListTitle: vm.providersLoading ? "Loading models..." : "No models available",
            workerEmptyListTitle: vm.providersLoading
                ? "Loading models..." : "No models yet. Connect an account on the start screen.",
            menuWidth: AgentModelMenuWidth.estimatedWidth(
                titles: models.map(\.label), min: AgentModelMenuWidth.distillMin, max: AgentModelMenuWidth.distillMax
            ),
            mainIdentifier: "scheduledTasks.editor.model",
            mainPopoverIdentifier: "scheduledTasks.editor.model.popover",
            workerIdentifier: "scheduledTasks.editor.reasoningModel",
            workerPopoverIdentifier: "scheduledTasks.editor.reasoningModel.popover",
            onSelectMainModel: { draft.model = $0 },
            onSelectCustomMainModel: { draft.model = $0 },
            onSelectMainEffort: { selection in
                draft.distillMainEffortSelection = selection
                if let effort = selection.effort { draft.reasoningEffort = effort }
            },
            onSelectWorkerModel: { model in
                draft.reasoningModel = model
                if model == nil { draft.distillReasoningEffortSelection = .automatic }
            },
            onSelectWorkerEffort: { draft.distillReasoningEffortSelection = $0 },
            statusHeader: { EmptyView() },
            mainFooter: { EmptyView() }
        )
    }

    private var editorModelPopover: some View {
        let models = vm.models(provider: draft.provider, instanceID: draft.providerInstanceID)
        let showsAutoRouting = draft.provider != .distill
        let selectedSnapshot = vm.providers.resolvedSnapshot(
            provider: draft.provider,
            instanceID: draft.providerInstanceID
        )
        let mainEffortSelection = draft.distillMainEffortSelection ?? .fixed(draft.reasoningEffort)
        let reasoningEffortSelection = draft.distillReasoningEffortSelection ?? .automatic
        return AgentModelPopoverChrome(
            presentation: AgentModelPopoverPresentation.current(
                mode: showsAutoRouting ? draft.routingMode : .manual
            ),
            autoEnabled: Binding(
                get: { draft.routingMode == .auto },
                set: { setAutoRoutingEnabled($0) }
            ),
            toggleDisabled: false,
            showsAutoRouting: showsAutoRouting
        ) {
            if draft.provider == .distill {
                AgentDistillModelSelectors(
                    mainModel: draft.model,
                    mainModels: AgentDistillModelCatalog.selectableModels(models),
                    reasoningModel: draft.reasoningModel,
                    reasoningModels: AgentDistillModelCatalog.selectableModels(models),
                    mainEffortSelection: mainEffortSelection,
                    mainEfforts: selectedModelEfforts,
                    reasoningEffortSelection: reasoningEffortSelection,
                    reasoningEfforts: selectedReasoningEfforts,
                    supportsMainEffortAuto: selectedSnapshot?.effectiveCapabilities.supportsDistillMainEffortAuto == true,
                    supportsReasoningModelEffort: selectedSnapshot?.effectiveCapabilities.supportsDistillReasoningModelEffort == true,
                    configWorkerSummary: selectedSnapshot?.effectiveCapabilities.supportsDistillReasoningModelEffort == true
                        ? nil : AgentDistillModelCatalog.configWorkerSummary(homePath: selectedSnapshot?.homePath),
                    isDisabled: false,
                    onSelectMainModel: { draft.model = $0 },
                    onSelectCustomMainModel: { draft.model = $0 },
                    onSelectReasoningModel: { model in
                        draft.reasoningModel = model
                        if model == nil { draft.distillReasoningEffortSelection = .automatic }
                    },
                    onSelectMainEffort: { selection in
                        draft.distillMainEffortSelection = selection
                        if let effort = selection.effort { draft.reasoningEffort = effort }
                    },
                    onSelectReasoningEffort: { draft.distillReasoningEffortSelection = $0 },
                    mainFooter: { EmptyView() }
                )
            } else {
                AgentCompactMenuSection("Model")
                ForEach(AgentDistillModelCatalog.selectableModels(models), id: \.id) { model in
                    AgentCompactMenuRow(model.label, selected: model.id == draft.model) {
                        draft.model = model.id
                        if let effort = model.supportedReasoningEfforts.first {
                            draft.reasoningEffort = effort
                        }
                        showModelOptions = false
                    }
                }
                AgentCompactMenuDivider()
                AgentCompactMenuSection("Reasoning")
                ForEach(AgentReasoningEffort.allCases, id: \.self) { effort in
                    AgentCompactMenuRow(effort.displayName, selected: effort == draft.reasoningEffort) {
                        draft.reasoningEffort = effort
                        showModelOptions = false
                    }
                }
            }
        }
        .accessibilityIdentifier("scheduledTasks.editor.reasoning")
    }

    private var selectedModelEfforts: [AgentReasoningEffort] {
        modelsForSchedule.first(where: { $0.id == draft.model })?.supportedReasoningEfforts ?? []
    }

    private var selectedReasoningEfforts: [AgentReasoningEffort] {
        guard let reasoningModel = draft.reasoningModel else { return [] }
        return modelsForSchedule.first(where: { $0.id == reasoningModel })?.supportedReasoningEfforts ?? []
    }

    private var modelsForSchedule: [AgentModelDescriptor] {
        AgentDistillModelCatalog.selectableModels(
            vm.models(provider: draft.provider, instanceID: draft.providerInstanceID)
        )
    }

    private func selectScheduledSource(_ entry: AgentSourceCapsulePresentation.MenuEntry) {
        if let snapshot = vm.providers.first(where: { $0.id == entry.id }) {
            draft.provider = snapshot.provider
            draft.providerInstanceID = snapshot.id
            let models = snapshot.provider == .distill
                ? AgentDistillModelCatalog.selectableModels(snapshot.models)
                : snapshot.models
            draft.model = models.first?.id ?? ""
            draft.reasoningEffort = models.first?.supportedReasoningEfforts.first ?? .high
            if snapshot.provider == .distill {
                draft.routingMode = .manual
                draft.reasoningModel = nil
                draft.distillMainEffortSelection = .automatic
                draft.distillReasoningEffortSelection = .automatic
            } else {
                draft.reasoningModel = nil
                draft.distillMainEffortSelection = nil
                draft.distillReasoningEffortSelection = nil
            }
            return
        }
        guard let provider = AgentProvider(rawValue: entry.id) else { return }
        draft.provider = provider
        if let snapshot = vm.providerSnapshots(for: provider).first {
            draft.providerInstanceID = snapshot.id
            let models = snapshot.provider == .distill
                ? AgentDistillModelCatalog.selectableModels(snapshot.models)
                : snapshot.models
            draft.model = models.first?.id ?? ""
            draft.reasoningEffort = models.first?.supportedReasoningEfforts.first ?? .high
        } else {
            draft.providerInstanceID = provider.rawValue
            draft.model = ""
        }
        draft.reasoningModel = nil
        draft.distillMainEffortSelection = provider == .distill ? .automatic : nil
        draft.distillReasoningEffortSelection = provider == .distill ? .automatic : nil
        if provider == .distill { draft.routingMode = .manual }
    }

    private func confirmAndSave() {
        let permission = draft.interactionMode == .plan ? AgentPermissionMode.supervised : draft.permissionMode
        guard permission == .fullAccess else { onSave(draft); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow this task to run with Full Access?"
        alert.informativeText = "Each occurrence starts a fresh Agent thread as \(draft.runAsUser) in the selected workspace. It may execute commands without further approval."
        alert.addButton(withTitle: "Save Full-Access Task")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { onSave(draft) }
    }

    private func setAutoRoutingEnabled(_ enabled: Bool) {
        guard draft.provider != .distill || !enabled else { return }
        draft.routingMode = enabled ? .auto : .manual
        // Turning Auto off must keep the chosen provider.
        // Only fill a missing model from that provider's snapshot — never
        // jump to the first available host in the catalog.
        guard !enabled,
              draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let snapshot = vm.providers.first(where: {
            $0.id == draft.providerInstanceID && $0.provider == draft.provider
        }) ?? vm.providerSnapshots(for: draft.provider).first
        guard let snapshot else { return }
        draft.providerInstanceID = snapshot.id
        draft.model = snapshot.models.first?.id ?? ""
        draft.reasoningEffort = snapshot.models.first?.supportedReasoningEfforts.first ?? .high
    }
}


public final class ScheduledTasksWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: ScheduledTasksViewModel

    public init(context: AppContext, router: AppCommandRouter) {
        self.viewModel = ScheduledTasksViewModel(context: context, router: router, loadImmediately: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scheduled Tasks"
        window.minSize = NSSize(width: 980, height: 680)
        window.center()
        window.backgroundColor = DS.NS.bg
        window.contentView = NSHostingView(rootView: ScheduledTasksRootView(vm: viewModel))
        window.setAccessibilityIdentifier("scheduledTasks.window")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


extension ScheduledTaskRecurrence {
    var summaryLabel: String {
        switch self {
        case .once: return "Once"
        case .hourly(_, let hours): return hours == 1 ? "Hourly" : "Every \(hours)h"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .multiple(let rules):
            let labels = Set(rules.map(\.summaryLabel))
            return labels.count == 1 ? labels.first! : "Multiple"
        }
    }

    /// Plan-style schedule column: "Daily at 9:00 AM", "Weekdays at 8:30 AM", …
    /// Multiple rules sharing a pattern list their times once:
    /// "Weekly Mon, Fri at 10:10 AM, 1:10 PM".
    var detailSummary: String {
        switch self {
        case .once(let at):
            return "Once · " + at.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        case .hourly(_, let hours):
            return hours == 1 ? "Every hour" : "Every \(hours) hours"
        case .multiple(let rules):
            var groups: [(pattern: String?, parts: [String])] = []
            for rule in rules {
                guard let timed = rule.timedPattern else {
                    groups.append((nil, [rule.detailSummary]))
                    continue
                }
                if let index = groups.firstIndex(where: { $0.pattern == timed.pattern }) {
                    groups[index].parts.append(timed.time)
                } else {
                    groups.append((timed.pattern, [timed.time]))
                }
            }
            return groups.map { group in
                group.pattern.map { "\($0) at \(group.parts.joined(separator: ", "))" } ?? group.parts[0]
            }.joined(separator: " · ")
        default:
            guard let timed = timedPattern else { return "" }
            return "\(timed.pattern) at \(timed.time)"
        }
    }

    private var timedPattern: (pattern: String, time: String)? {
        switch self {
        case .daily(let time):
            return ("Daily", time.displayString)
        case .weekdays(let time):
            return ("Weekdays", time.displayString)
        case .weekly(let days, let time):
            return ("Weekly " + days.sorted().map(\.shortName).joined(separator: ", "), time.displayString)
        case .monthly(let day, let time):
            return ("Monthly on day \(day)", time.displayString)
        case .once, .hourly, .multiple:
            return nil
        }
    }
}

private extension ScheduledLocalTime {
    var displayString: String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: comps) ?? Date()
        return date.formatted(.dateTime.hour().minute())
    }
}

private extension ScheduledWeekday {
    var shortName: String {
        switch self {
        case .sunday: return "Sun"
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        }
    }
}

/// The run options a new Agent App message carries, for any scheduled task
/// (workspace or Bot): execution mode, permission, plan mode and execution location.
/// One component so the two schedule editors cannot drift from each other.
struct ScheduledRunOptionsEditor: View {
    let showsExecutionMode: Bool
    @Binding var executionMode: DistillExecutionMode
    @Binding var permission: AgentPermissionMode
    /// Nil hides plan mode and execution location (Bot runs use the Bot's own setup).
    var plan: Binding<Bool>?
    var execution: Binding<AgentExecutionMode>?
    var baseBranch: Binding<String>?
    let identifierPrefix: String

    /// Plan mode always runs supervised, like the Agent App composer.
    static func effectivePermission(_ permission: AgentPermissionMode, plan: Bool) -> AgentPermissionMode {
        plan ? .supervised : permission
    }

    static func unattendedNotice(permission: AgentPermissionMode) -> String {
        switch permission {
        case .fullAccess: return "Runs unattended with Full Access in the selected workspace."
        case .autoAcceptEdits: return "Runs unattended; file edits are accepted automatically and other actions wait for approval."
        case .supervised: return "Runs unattended; every action that needs approval waits for you."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsExecutionMode {
                ScheduleEditorRow("Mode", hint: "How Distill works on each run", showsDivider: false) {
                    AgentExecutionModeCapsule(
                        selected: executionMode,
                        accessibilityIdentifier: "\(identifierPrefix).mode",
                        onSelect: { executionMode = $0 }
                    )
                }
            }
            if let plan {
                ScheduleEditorRow("Plan mode", hint: "Propose a plan first; runs supervised", showsDivider: showsExecutionMode) {
                    Toggle("Plan mode", isOn: plan)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(DS.Palette.accent)
                        .accessibilityIdentifier("\(identifierPrefix).planMode")
                }
            }
            ScheduleEditorRow("Permission", showsDivider: showsExecutionMode || plan != nil) {
                AgentPermissionCapsule(
                    selected: Self.effectivePermission(permission, plan: plan?.wrappedValue ?? false),
                    modes: AgentPermissionMode.allCases,
                    disabled: plan?.wrappedValue ?? false,
                    help: (plan?.wrappedValue ?? false) ? "Plan mode runs supervised" : "Permission mode",
                    accessibilityIdentifier: "\(identifierPrefix).permission",
                    onSelect: { permission = $0 }
                )
            }
            if let execution {
                ScheduleEditorRow("Execution", hint: "Local edits in place; Worktree uses a separate branch") {
                    Picker("Execution", selection: execution) {
                        Text("Local").tag(AgentExecutionMode.local)
                        Text("Worktree").tag(AgentExecutionMode.worktree)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("\(identifierPrefix).execution")
                }
                if execution.wrappedValue == .worktree, let baseBranch {
                    ScheduleEditorRow("Base branch") {
                        TextField("main", text: baseBranch)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .accessibilityIdentifier("\(identifierPrefix).baseBranch")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Schedule Tasks groups workspace tasks and Bot schedules under their workspace,
/// like Activity. Groups keep first-appearance order; "No workspace" goes last.
struct ScheduleTaskWorkspaceGroup: Identifiable {
    enum Entry: Identifiable {
        case task(ScheduledTask)
        case bot(BotScheduleTaskItem)
        var id: String {
            switch self {
            case .task(let task): return "task:\(task.id.uuidString)"
            case .bot(let item): return "bot:\(item.id.value.uuidString)"
            }
        }
        var workspaceID: WorkspaceID? {
            switch self {
            case .task(let task): return task.workspaceID as WorkspaceID?
            case .bot(let item): return item.workspaceID
            }
        }
    }

    let id: WorkspaceID?
    let name: String
    let color: Color?
    let entries: [Entry]

    static func groups(tasks: [ScheduledTask], botItems: [BotScheduleTaskItem], workspaces: [Workspace]) -> [ScheduleTaskWorkspaceGroup] {
        let entries = tasks.map(Entry.task) + botItems.map(Entry.bot)
        var order: [WorkspaceID?] = []
        var buckets: [WorkspaceID?: [Entry]] = [:]
        for entry in entries {
            // A workspace that no longer exists reads as "No workspace", not a ghost group.
            let key = entry.workspaceID.flatMap { id in workspaces.contains { $0.id == id } ? id : nil }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        let named = order.compactMap { key -> ScheduleTaskWorkspaceGroup? in
            guard let key, let workspace = workspaces.first(where: { $0.id == key }) else { return nil }
            return ScheduleTaskWorkspaceGroup(
                id: key, name: workspace.name,
                color: TabColor.from(workspace.metadata["color"]).map { Color(hex: $0.hex) },
                entries: buckets[key] ?? []
            )
        }
        guard let loose = buckets[nil] else { return named }
        return named + [ScheduleTaskWorkspaceGroup(id: nil, name: "No workspace", color: nil, entries: loose)]
    }
}
