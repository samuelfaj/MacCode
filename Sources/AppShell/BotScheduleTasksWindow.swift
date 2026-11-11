import CoreModel
import DesignSystemKit
import Persistence
import Surfaces
import SwiftUI

public struct BotScheduleTaskItem: Identifiable, Equatable {
    public let id: BotRoutineID
    public let botID: BotID
    public var name: String
    public var prompt: String
    public var scheduleNote: String
    public var scheduleSpecJSON: String
    public var isEnabled: Bool
    public var botName: String
    public var botHandle: String
    public var botAvatarSymbol: String
    public var lastTestRunRequestedAt: Date?
    /// The workspace that lists the Bot (its active context binding, else its own
    /// `workspaceID`); Schedule Tasks groups the schedule under it.
    public var workspaceID: WorkspaceID?

    public init(routine: BotRoutine, bot: BotDefinition, workspaceID: WorkspaceID? = nil) {
        self.id = routine.definition.id
        self.botID = bot.id
        self.name = routine.definition.name
        self.prompt = routine.definition.prompt
        self.scheduleNote = routine.definition.scheduleNote
        self.scheduleSpecJSON = routine.definition.scheduleSpecJSON
        self.isEnabled = routine.activation.isEnabled
        self.botName = bot.name
        self.botHandle = bot.handle
        self.botAvatarSymbol = bot.avatarSymbol
        self.lastTestRunRequestedAt = routine.activation.lastTestRunRequestedAt
        self.workspaceID = workspaceID ?? bot.workspaceID
    }

    /// The schedule the scheduler runs: saved JSON, else the note it was written with.
    public var resolvedSpec: BotScheduleSpec? {
        BotScheduleSpec.decodeJSON(scheduleSpecJSON) ?? BotScheduleSpec.parseDisplayNote(scheduleNote)
    }

    /// Next run is when this task would actually fire, not whether it is armed.
    /// An enabled task still does not run while global autonomy is paused.
    public func nextRunLabel(isAutonomyActive: Bool, now: Date = Date()) -> String {
        if !isEnabled { return L("Paused") }
        if !isAutonomyActive { return L("Scheduler paused") }
        guard let next = resolvedSpec?.nextOccurrence(after: now) else { return "—" }
        return next.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// One Run History row of a Bot schedule: the recorded run plus the agent run it started.
public struct BotRoutineRunRow: Identifiable, Equatable {
    public let record: BotRoutineRunRecord
    public let agentRun: AgentRun?

    public var id: String { record.id }

    public var canOpen: Bool { record.conversationID != nil && record.result == "started" }

    public enum Status: Equatable { case running, completed, failed, cancelled, skipped, started }

    public var status: Status {
        switch record.result {
        case "failed": return .failed
        case "skipped": return .skipped
        default: break
        }
        switch agentRun?.status {
        case .pending, .running: return .running
        case .completed: return .completed
        case .failed, .interrupted: return .failed
        case .cancelled: return .cancelled
        case nil: return .started
        }
    }

    public var errorText: String? {
        record.error ?? record.skipReason ?? (status == .failed ? agentRun?.errorMessage : nil)
    }

    public func duration(now: Date) -> String {
        guard let run = agentRun else { return "—" }
        let seconds = Int(((run.finishedAt ?? (status == .running ? now : run.startedAt)).timeIntervalSince(run.startedAt)))
        guard seconds >= 0, run.finishedAt != nil || status == .running else { return "—" }
        if seconds < 60 { return "\(seconds)s" }
        if run.finishedAt == nil { return "\(seconds / 60)m" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

public struct BotScheduleTaskDraft: Identifiable, Equatable {
    public var id: BotRoutineID
    public var botID: BotID
    public var name: String
    public var prompt: String
    public var scheduleNote: String
    public var spec: BotScheduleSpec
    public var isEnabled: Bool
    public var isNew: Bool

    public init(botID: BotID) {
        self.id = BotRoutineID()
        self.botID = botID
        self.name = ""
        self.prompt = ""
        self.scheduleNote = ""
        self.spec = BotScheduleSpec()
        self.isEnabled = true
        self.isNew = true
    }

    public init(item: BotScheduleTaskItem) {
        self.id = item.id
        self.botID = item.botID
        self.name = item.name
        self.prompt = item.prompt
        self.scheduleNote = item.scheduleNote
        var resolvedSpec = BotScheduleSpec.resolved(json: item.scheduleSpecJSON, note: item.scheduleNote)
        if resolvedSpec.provider == .distill { resolvedSpec.routingMode = .manual }
        self.spec = resolvedSpec
        self.isEnabled = item.isEnabled
        self.isNew = false
    }
}

/// Pure seams for the bot-scoped Schedule Tasks screen.
enum BotScheduleScope {
    static func items(_ items: [BotScheduleTaskItem], botID: BotID) -> [BotScheduleTaskItem] {
        items.filter { $0.botID == botID }
    }

    /// Counts over the search-filtered, status-unfiltered set, matching the global `applyScheduleTaskFilters`.
    static func counts(_ items: [BotScheduleTaskItem], query: String) -> (all: Int, active: Int, paused: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = trimmed.isEmpty ? items : items.filter { item in
            [item.name, item.botName, item.prompt, item.scheduleNote]
                .contains { $0.range(of: trimmed, options: .caseInsensitive) != nil }
        }
        let active = searched.filter(\.isEnabled).count
        return (searched.count, active, searched.count - active)
    }

    /// Search + status filter over one bot's routines, same rules as the global list.
    static func visible(_ items: [BotScheduleTaskItem], query: String, filter: ScheduledTaskStatusFilter) -> [BotScheduleTaskItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = trimmed.isEmpty ? items : items.filter { item in
            [item.name, item.botName, item.prompt, item.scheduleNote]
                .contains { $0.range(of: trimmed, options: .caseInsensitive) != nil }
        }
        switch filter {
        case .all: return searched
        case .active: return searched.filter(\.isEnabled)
        case .paused: return searched.filter { !$0.isEnabled }
        }
    }

    static func footerLine(all: Int, active: Int) -> String {
        let tasks = all == 1 ? L("1 task") : L("%1$@ tasks", all)
        let live = active == 1 ? L("1 active") : L("%1$@ active", active)
        return "\(tasks) · \(live)"
    }
}

public struct BotScheduleTasksRootView: View {
    @ObservedObject private var vm: BotsViewModel
    private let scopeBotID: BotID?
    @State private var scopedSource: [BotScheduleTaskItem] = []

    public init(vm: BotsViewModel, scopeBotID: BotID? = nil) {
        self.vm = vm
        self.scopeBotID = scopeBotID
    }

    public var body: some View {
        VStack(spacing: 0) {
            if vm.scheduleTaskDraft != nil {
                editorScreen
            } else if let detail = vm.scheduleTaskDetailItem {
                BotScheduleTaskDetailScreen(vm: vm, item: detail)
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                footerBar
            } else {
                overviewScreen
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                footerBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.bg)
        .accessibilityIdentifier("bots.scheduleTasks.screen")
        .onAppear {
            vm.scheduleFreshnessPass()
            reloadScopedSource()
        }
        .onChange(of: vm.scheduleTaskItems) { _ in reloadScopedSource() }
        .onChange(of: vm.routines.map(\.definition)) { _ in reloadScopedSource() }
    }

    private var visibleItems: [BotScheduleTaskItem] {
        guard scopeBotID != nil else { return vm.scheduleTaskItems }
        return BotScheduleScope.visible(scopedSource, query: vm.scheduleTaskSearchText, filter: vm.scheduleTaskStatusFilter)
    }

    private var chipCounts: (all: Int, active: Int, paused: Int) {
        guard scopeBotID != nil else { return vm.scheduleTaskFilterCounts }
        return BotScheduleScope.counts(scopedSource, query: vm.scheduleTaskSearchText)
    }

    /// Reads the bot's routines from the store so chip counts see the unfiltered set.
    private func reloadScopedSource() {
        guard let scopeBotID else { return }
        let routines = (try? vm.executionDestinationStore.listRoutines(botID: scopeBotID)) ?? []
        guard let bot = vm.fleet.first(where: { $0.id == scopeBotID }) else {
            scopedSource = []
            return
        }
        let workspaceID = vm.scheduleWorkspace(for: bot)
        scopedSource = routines.map { BotScheduleTaskItem(routine: $0, bot: bot, workspaceID: workspaceID) }
    }

    private func openLastRun(_ item: BotScheduleTaskItem) {
        if let last = vm.routineRunSummaries[item.id]?.last {
            vm.openRoutineRunConversation(last, botID: item.botID)
        }
    }

    private var subtitle: String {
        if scopeBotID != nil, vm.isAutonomyActive {
            return L("Tasks this bot runs automatically while MacCode is open")
        }
        return vm.scheduleTasksSubtitle
    }

    private var overviewScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(L("Scheduled Tasks"))
                        .font(DS.Font.title.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    Text(subtitle)
                        .font(DS.Font.body)
                        .foregroundColor(vm.isAutonomyActive ? DS.Palette.textSecondary : DS.Palette.warning)
                }
                Spacer(minLength: DS.Space.lg)
                HStack(spacing: DS.Space.md) {
                    Button {
                        if let scopeBotID {
                            vm.scheduleTaskDraft = BotScheduleTaskDraft(botID: scopeBotID)
                        } else {
                            vm.createScheduleTask()
                        }
                    } label: {
                        Label(L("New Task"), systemImage: "plus")
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .accessibilityIdentifier("bots.scheduleTasks.new")

                    autonomyControl
                }
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.top, DS.Space.xxl)
            .padding(.bottom, DS.Space.xl)

            HStack(spacing: DS.Space.md) {
                filterChips
                Spacer(minLength: DS.Space.lg)
                searchField
                    .frame(maxWidth: 280)
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.bottom, DS.Space.xl)

            if visibleItems.isEmpty {
                if scopeBotID != nil, scopedSource.isEmpty {
                    DSEmptyState(
                        icon: "calendar.badge.clock",
                        title: L("No scheduled tasks yet"),
                        subtitle: L("Create a task to have this bot work on a schedule.")
                    ) {
                        Button {
                            if let scopeBotID {
                                vm.scheduleTaskDraft = BotScheduleTaskDraft(botID: scopeBotID)
                            }
                        } label: {
                            Label(L("New Task"), systemImage: "plus")
                        }
                        .buttonStyle(DSPrimaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DSEmptyState(
                        icon: "calendar.badge.clock",
                        title: vm.scheduleTaskSearchText.isEmpty ? L("No scheduled tasks") : L("No matching tasks"),
                        subtitle: vm.scheduleTaskSearchText.isEmpty
                            ? L("Create a task to run a bot automatically while MacCode is open.")
                            : L("Try another search or clear the status filter.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(visibleItems) { item in
                            BotScheduleTaskCard(
                                item: item,
                                isAutonomyActive: vm.isAutonomyActive,
                                isRunning: vm.isRoutineRunning(id: item.id),
                                isStarting: vm.isRoutineStartingGuest(id: item.id),
                                lastRun: vm.routineRunSummaries[item.id]?.last,
                                runCount: vm.routineRunSummaries[item.id]?.count ?? 0,
                                onOpenLastRun: { openLastRun(item) },
                                onOpen: { vm.openScheduleTaskDetail(item) },
                                onToggle: { vm.setRoutineEnabled(id: item.id, enabled: !item.isEnabled) },
                                onRunNow: { vm.runRoutineNow(id: item.id) },
                                onEdit: { vm.editScheduleTask(item) },
                                onDelete: { vm.deleteScheduleTask(item) }
                            )
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
                .accessibilityIdentifier("bots.scheduleTasks.list")
            }
        }
    }

    private var autonomyControl: some View {
        AgentKillSwitchControl(
            isActive: vm.isAutonomyActive,
            identifier: "bots.scheduleTasks.globalActive",
            accessibilityLabel: vm.isAutonomyActive ? L("Schedules active") : L("Schedules paused"),
            onChange: { vm.setAutonomyActive($0) }
        )
    }

    private var filterChips: some View {
        HStack(spacing: DS.Space.sm) {
            AgentListFilterChip(
                title: ScheduledTaskStatusFilter.all.rawValue,
                count: chipCounts.all,
                selected: vm.scheduleTaskStatusFilter == .all,
                identifier: "bots.scheduleTasks.filter.all"
            ) { vm.scheduleTaskStatusFilter = .all }
            AgentListFilterChip(
                title: ScheduledTaskStatusFilter.active.rawValue,
                count: chipCounts.active,
                selected: vm.scheduleTaskStatusFilter == .active,
                identifier: "bots.scheduleTasks.filter.active"
            ) { vm.scheduleTaskStatusFilter = .active }
            AgentListFilterChip(
                title: ScheduledTaskStatusFilter.paused.rawValue,
                count: chipCounts.paused,
                selected: vm.scheduleTaskStatusFilter == .paused,
                identifier: "bots.scheduleTasks.filter.paused"
            ) { vm.scheduleTaskStatusFilter = .paused }
        }
        .accessibilityIdentifier("bots.scheduleTasks.statusFilter")
    }

    private var searchField: some View {
        AgentListSearchField(
            text: $vm.scheduleTaskSearchText,
            placeholder: L("Search tasks"),
            identifier: "bots.scheduleTasks.search",
            accessibilityLabel: L("Search tasks")
        )
        .accessibilityLabel(L("Search tasks"))
    }

    private var footerBar: some View {
        AgentListFooterBar(
            caption: footerCaption,
            pillTitle: vm.isAutonomyActive ? L("Scheduler online") : L("Scheduler paused"),
            pillTone: vm.isAutonomyActive ? .success : .warning
        )
        .accessibilityLabel(footerCaption)
    }

    private var footerCaption: String {
        guard scopeBotID != nil else { return vm.scheduleTasksFooterLine }
        let counts = chipCounts
        return BotScheduleScope.footerLine(all: counts.all, active: counts.active)
    }

    @ViewBuilder
    private var editorScreen: some View {
        if let draft = vm.scheduleTaskDraft {
            BotScheduleTaskEditorView(
                draft: draft,
                bots: vm.fleet,
                providers: vm.providers,
                providersLoading: false,
                destinationStore: vm.executionDestinationStore,
                workspaces: vm.executionWorkspaces,
                onBack: { vm.scheduleTaskDraft = nil },
                onSave: { vm.saveScheduleTask($0) }
            )
        }
    }
}

struct BotScheduleTaskCard: View {
    let item: BotScheduleTaskItem
    let isAutonomyActive: Bool
    var isRunning = false
    var isStarting = false
    var lastRun: BotRoutineRunRecord? = nil
    var runCount = 0
    var onOpenLastRun: () -> Void = {}
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onRunNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        AgentOverviewCard(
            icon: "calendar.badge.clock",
            iconColor: DS.Palette.accent,
            title: item.name,
            subtitle: "\(item.botName) · @\(item.botHandle)",
            identifier: "bots.scheduleTasks.task.\(item.id.value.uuidString.lowercased())",
            avatar: BotsAvatarView(
                name: item.botName, handle: item.botHandle, symbol: item.botAvatarSymbol,
                size: 36, attention: isRunning ? .working : .none
            ),
            onOpen: onOpen
        ) {
            if isRunning {
                HStack(spacing: DS.Space.xs) {
                    ProgressView().controlSize(.small)
                    if isStarting {
                        Text(L("Starting Bot computer…"))
                            .font(DS.Font.caption.weight(.medium))
                            .foregroundColor(DS.Palette.textSecondary)
                            .accessibilityIdentifier("bots.scheduleTasks.starting")
                    } else {
                        DSPill(L("Running"), tone: .success)
                    }
                }
                .accessibilityIdentifier("bots.scheduleTasks.running")
            } else if item.isEnabled {
                DSPill(L("Active"), tone: .success)
            } else {
                DSPill(L("Paused"), tone: .neutral)
            }
        } meta: {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                AgentOverviewMetaColumn(
                    title: L("Schedule"),
                    value: item.scheduleNote.isEmpty ? L("When noted in the task") : item.scheduleNote
                )
                AgentOverviewMetaColumn(
                    title: L("Next run"),
                    value: item.nextRunLabel(isAutonomyActive: isAutonomyActive)
                )
                AgentOverviewMetaColumn(
                    title: L("Last run"),
                    value: ScheduleLastRunLabel.text(date: lastRun?.executedAt, failed: lastRun?.result == "failed"),
                    valueColor: lastRun?.result == "failed" ? DS.Palette.danger : DS.Palette.text,
                    action: lastRun?.conversationID == nil ? nil : onOpenLastRun,
                    actionHelp: L("Open the conversation of this run")
                )
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Text(L("%1$@", runCount))
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.textSecondary)
                        .monospacedDigit()
                }
                .frame(width: 44, alignment: .trailing)
                .accessibilityLabel(L("%1$@ runs", runCount))
            }
        } trailing: {
            Menu {
                Button(item.isEnabled ? L("Pause") : L("Resume"), action: onToggle)
                Button(L("Run Now"), action: onRunNow).disabled(isRunning)
                Button(L("Edit"), action: onEdit)
                Divider()
                Button(L("Delete"), role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(L("Task actions"))
        }
    }
}

struct BotScheduleTaskEditorView: View {
    @State private var draft: BotScheduleTaskDraft
    let bots: [BotDefinition]
    let providers: [AgentProviderSnapshot]
    let providersLoading: Bool
    let destinationStore: BotStore
    let workspaces: [Workspace]
    let onBack: () -> Void
    let onSave: (BotScheduleTaskDraft) -> Void

    init(
        draft: BotScheduleTaskDraft,
        bots: [BotDefinition],
        providers: [AgentProviderSnapshot],
        providersLoading: Bool,
        destinationStore: BotStore,
        workspaces: [Workspace],
        onBack: @escaping () -> Void,
        onSave: @escaping (BotScheduleTaskDraft) -> Void
    ) {
        self._draft = State(initialValue: draft)
        self.bots = bots
        self.providers = providers
        self.providersLoading = providersLoading
        self.destinationStore = destinationStore
        self.workspaces = workspaces
        self.onBack = onBack
        self.onSave = onSave
    }

    var body: some View {
        ScheduleEditorPage(
            title: draft.isNew ? L("New Scheduled Task") : L("Edit Scheduled Task"),
            subtitle: L("Run a Bot on a schedule, with its own identity, memory and tools."),
            saveTitle: L("Save"),
            saveIdentifier: "bots.scheduleTasks.save",
            onBack: onBack,
            onSave: { onSave(draft) },
            content: {
                ScheduleEditorSection(L("Task"), identifier: "bots.scheduleTasks.editorSection.Task") {
                    ScheduleEditorRow(L("Bot"), showsDivider: false) {
                        Picker("", selection: $draft.botID) {
                            ForEach(bots, id: \.id) { bot in
                                Text(bot.name).tag(bot.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("bots.scheduleTasks.editor.bot")
                    }
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        ScheduleEditorTextField(
                            placeholder: L("Name, e.g. Morning scan"),
                            text: $draft.name,
                            identifier: "bots.scheduleTasks.editor.name"
                        )
                        ScheduleEditorPromptBox(
                            placeholder: L("Describe what the Bot should do"),
                            text: $draft.prompt,
                            identifier: "bots.scheduleTasks.editor.instruction",
                            label: L("Instruction")
                        )
                    }
                    .padding(DS.Space.md)
                }
                BotScheduleSpecEditor(
                    spec: $draft.spec,
                    providers: providers,
                    providersLoading: providersLoading
                )
                ScheduleEditorSection(L("Run options"), identifier: "bots.scheduleTasks.editorSection.Run options") {
                    ScheduledRunOptionsEditor(
                        showsExecutionMode: draft.spec.provider == .distill,
                        executionMode: Binding(
                            get: { draft.spec.distillExecutionMode ?? .auto },
                            set: { draft.spec.distillExecutionMode = $0 }
                        ),
                        permission: Binding(
                            get: { draft.spec.permissionMode ?? .fullAccess },
                            set: { draft.spec.permissionMode = $0 }
                        ),
                        identifierPrefix: "bots.scheduleTasks.editor"
                    )
                    ScheduleEditorRow(L("Concurrent runs"), hint: L("How many runs of this task may be active at once")) {
                        ScheduleConcurrencyPicker(selection: Binding(
                            get: { draft.spec.effectiveMaxConcurrentRuns },
                            set: { draft.spec.maxConcurrentRuns = $0 }
                        ))
                        .accessibilityIdentifier("bots.scheduleTasks.editor.concurrency")
                    }
                    ScheduleEditorRow(L("Use Bot default location"), hint: L("Where the run executes: Mac, a VM or a workspace")) {
                        Toggle(L("Use bot default"), isOn: Binding(
                            get: { draft.spec.executionDestination == nil },
                            set: { draft.spec.executionDestination = $0 ? nil : ((try? destinationStore.executionDestination(botID: draft.botID)) ?? .mac) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(DS.Palette.accent)
                    }
                    if draft.spec.executionDestination != nil {
                        VStack(alignment: .leading) {
                            BotExecutionDestinationPicker(selection: Binding(
                                get: { draft.spec.executionDestination ?? .mac },
                                set: { draft.spec.executionDestination = $0 }
                            ), bot: bots.first { $0.id == draft.botID }, store: destinationStore, workspaces: workspaces)
                        }
                        .padding(DS.Space.lg)
                    }
                }
                ScheduleEditorSection(L("Status"), identifier: "bots.scheduleTasks.editorSection.Status") {
                    ScheduleEditorRow(L("Active"), hint: L("Paused tasks keep their schedule but do not run"), showsDivider: false) {
                        Toggle(L("Active"), isOn: $draft.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(DS.Palette.success)
                            .accessibilityIdentifier("bots.scheduleTasks.editor.active")
                    }
                }
                AgentChoiceCallout(
                    icon: "exclamationmark.triangle.fill",
                    tint: DS.Palette.warning,
                    text: BotRoutineCopy.testRunHonestyCaption
                )
            },
            footer: { EmptyView() }
        )
    }
}

/// Same Frequency + Provider / Model (Auto) / Reasoning rows as Agent App Schedule Tasks.
struct BotScheduleSpecEditor: View {
    @Binding var spec: BotScheduleSpec
    let providers: [AgentProviderSnapshot]
    let providersLoading: Bool
    @State private var showSourceOptions = false
    @State private var showModelOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxl) {
            editorGroup(L("Details")) {
                if AgentSourceCapsulePresentation.isVisible(entryCount: specSourceEntries.count) {
                    formRow(L("Provider")) {
                        specSourceCapsule
                            .accessibilityIdentifier("bots.scheduleTasks.editor.provider")
                    }
                }
                if spec.provider != .distill {
                    formRow(L("Model routing")) {
                        HStack(spacing: DS.Space.sm) {
                            if providersLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel(L("Loading providers"))
                            }
                            Toggle(L("Auto"), isOn: Binding(
                                get: { spec.routingMode == .auto },
                                set: { enabled in
                                    spec.routingMode = spec.provider == .distill ? .manual : (enabled ? .auto : .manual)
                                }
                            ))
                            .toggleStyle(.switch)
                            .tint(DS.Palette.success)
                            .accessibilityIdentifier("bots.scheduleTasks.editor.autoRouting")
                        }
                    }
                }
                if spec.provider != .distill && spec.routingMode == .auto {
                    formRow(L("Model")) {
                        Text(L("Auto selects the best model for the selected provider at run time."))
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if spec.provider == .distill {
                    // Same Main / Worker pills and modal sheets as the Agent App and Bot Desk composer.
                    formRow(L("Model")) { specDistillModelPills }
                } else {
                    formRow(L("Model")) {
                        Button {
                            showModelOptions.toggle()
                        } label: {
                            AgentModelPillLabel(presentation: specModelPillPresentation)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bots.scheduleTasks.editor.model")
                        .popover(isPresented: $showModelOptions, arrowEdge: .bottom) {
                            specModelPopover
                        }
                    }
                }
            }

            editorGroup(L("Frequency")) {
                ScheduledFrequencyEditor(
                    rules: $spec.frequencyRules,
                    timeZoneIdentifier: $spec.timeZoneIdentifier,
                    identifierPrefix: "bots.scheduleTasks.editor"
                )
            }
        }
        .onAppear { normalizeProviderInstance() }
        .onChange(of: providers.map(\.id)) { _ in normalizeProviderInstance() }
        .accessibilityIdentifier("bots.scheduleTasks.editor.spec")
    }

    static func models(providers: [AgentProviderSnapshot], provider: AgentProvider, instanceID: String) -> [AgentModelDescriptor] {
        providers.resolvedSnapshot(provider: provider, instanceID: instanceID)?.models ?? []
    }

    private var models: [AgentModelDescriptor] {
        Self.models(providers: providers, provider: spec.provider, instanceID: spec.providerInstanceID)
    }

    private func normalizeProviderInstance() {
        guard !providers.contains(where: { $0.provider == spec.provider && $0.id == spec.providerInstanceID }),
              let resolved = providers.resolvedSnapshot(provider: spec.provider, instanceID: spec.providerInstanceID) else { return }
        spec.providerInstanceID = resolved.id
    }

    private func snapshots(for provider: AgentProvider) -> [AgentProviderSnapshot] {
        providers.filter { $0.provider == provider }
    }

    private var specSourceEntries: [AgentSourceCapsulePresentation.MenuEntry] {
        AgentSourceCapsulePresentation.menuEntries(
            snapshots: providers,
            selectedSnapshotId: spec.providerInstanceID,
            selectedProvider: spec.provider,
            providerDisplayName: { $0.rawValue.capitalized }
        )
    }

    private var specSourceCapsule: some View {
        AgentSourceCapsule(
            label: AgentSourceCapsulePresentation.capsuleLabel(
                selected: providers.resolvedSnapshot(provider: spec.provider, instanceID: spec.providerInstanceID),
                fallbackProvider: spec.provider,
                fallbackInstanceId: spec.providerInstanceID,
                snapshots: providers
            ),
            entries: specSourceEntries,
            runLocked: false,
            providerLocked: false,
            accessibilityIdentifier: "bots.scheduleTasks.editor.provider",
            popoverIdentifier: "bots.scheduleTasks.editor.source.popover",
            isPresented: $showSourceOptions,
            onSelect: { selectSpecSource($0) }
        )
    }

    private var specModelPillPresentation: AgentModelPillPresentation {
        let selectableModels = spec.provider == .distill
            ? AgentDistillModelCatalog.selectableModels(models)
            : models
        let title = selectableModels.first(where: { $0.id == spec.model })?.label
            ?? (spec.model.isEmpty ? (spec.provider == .distill ? L("Select Main model") : L("Model")) : spec.model)
        let effort = spec.provider == .distill
            ? (spec.distillMainEffortSelection ?? .fixed(spec.reasoningEffort)).effort?.displayName ?? L("Auto")
            : spec.reasoningEffort.displayName
        return AgentModelPillPresentation(title: title, effort: effort)
    }

    private var specDistillModelPills: some View {
        let selectable = AgentDistillModelCatalog.selectableModels(models)
        let snapshot = providers.resolvedSnapshot(provider: spec.provider, instanceID: spec.providerInstanceID)
        let mainUnavailable = !spec.model.isEmpty && !selectable.isEmpty
            && !selectable.contains(where: { $0.id == spec.model || $0.supportsCustomModel })
        return AgentDistillModelPills(
            mainModel: spec.model, mainModels: selectable,
            reasoningModel: spec.reasoningModel, reasoningModels: selectable,
            mainEffortSelection: spec.distillMainEffortSelection ?? .fixed(spec.reasoningEffort),
            mainEfforts: selectedMainEfforts,
            supportsMainEffortAuto: snapshot?.effectiveCapabilities.supportsDistillMainEffortAuto == true,
            reasoningEffortSelection: spec.distillReasoningEffortSelection ?? .automatic,
            reasoningEfforts: selectedReasoningEfforts,
            supportsReasoningModelEffort: snapshot?.effectiveCapabilities.supportsDistillReasoningModelEffort == true,
            homePath: snapshot?.homePath,
            mainUnavailable: mainUnavailable,
            isRunning: false,
            isDisabled: false,
            emptyListTitle: providersLoading ? L("Loading models...") : L("No models available"),
            workerEmptyListTitle: providersLoading
                ? L("Loading models...") : L("No models yet. Connect an account on the start screen."),
            menuWidth: AgentModelMenuWidth.estimatedWidth(
                titles: selectable.map(\.label), min: AgentModelMenuWidth.distillMin, max: AgentModelMenuWidth.distillMax
            ),
            mainIdentifier: "bots.scheduleTasks.editor.model",
            mainPopoverIdentifier: "bots.scheduleTasks.editor.model.popover",
            workerIdentifier: "bots.scheduleTasks.editor.reasoningModel",
            workerPopoverIdentifier: "bots.scheduleTasks.editor.reasoningModel.popover",
            onSelectMainModel: { spec.model = $0 },
            onSelectCustomMainModel: { spec.model = $0 },
            onSelectMainEffort: { selection in
                spec.distillMainEffortSelection = selection
                if let effort = selection.effort { spec.reasoningEffort = effort }
            },
            onSelectWorkerModel: { spec.reasoningModel = $0 },
            onSelectWorkerEffort: { spec.distillReasoningEffortSelection = $0 },
            statusHeader: { EmptyView() },
            mainFooter: { EmptyView() }
        )
    }

    private var specModelPopover: some View {
        let showsAutoRouting = spec.provider != .distill
        let snapshot = providers.resolvedSnapshot(provider: spec.provider, instanceID: spec.providerInstanceID)
        let mainEffortSelection = spec.distillMainEffortSelection ?? .fixed(spec.reasoningEffort)
        let reasoningEffortSelection = spec.distillReasoningEffortSelection ?? .automatic
        return AgentModelPopoverChrome(
            presentation: AgentModelPopoverPresentation.current(
                mode: showsAutoRouting ? spec.routingMode : .manual
            ),
            autoEnabled: Binding(
                get: { spec.routingMode == .auto },
                set: { enabled in
                    spec.routingMode = spec.provider == .distill ? .manual : (enabled ? .auto : .manual)
                }
            ),
            toggleDisabled: false,
            showsAutoRouting: showsAutoRouting
        ) {
            if spec.provider == .distill {
                AgentDistillModelSelectors(
                    mainModel: spec.model,
                    mainModels: AgentDistillModelCatalog.selectableModels(models),
                    reasoningModel: spec.reasoningModel,
                    reasoningModels: AgentDistillModelCatalog.selectableModels(models),
                    mainEffortSelection: mainEffortSelection,
                    mainEfforts: selectedMainEfforts,
                    reasoningEffortSelection: reasoningEffortSelection,
                    reasoningEfforts: selectedReasoningEfforts,
                    supportsMainEffortAuto: snapshot?.effectiveCapabilities.supportsDistillMainEffortAuto == true,
                    supportsReasoningModelEffort: snapshot?.effectiveCapabilities.supportsDistillReasoningModelEffort == true,
                    configWorkerSummary: snapshot?.effectiveCapabilities.supportsDistillReasoningModelEffort == true
                        ? nil : AgentDistillModelCatalog.configWorkerSummary(homePath: snapshot?.homePath),
                    isDisabled: false,
                    onSelectMainModel: { model in
                        spec.model = model
                    },
                    onSelectCustomMainModel: { model in spec.model = model },
                    onSelectReasoningModel: { spec.reasoningModel = $0 },
                    onSelectMainEffort: { selection in
                        spec.distillMainEffortSelection = selection
                        if let effort = selection.effort { spec.reasoningEffort = effort }
                    },
                    onSelectReasoningEffort: { spec.distillReasoningEffortSelection = $0 },
                    mainFooter: { EmptyView() }
                )
            } else {
                AgentCompactMenuSection(L("Model"))
                ForEach(AgentDistillModelCatalog.selectableModels(models), id: \.id) { model in
                    AgentCompactMenuRow(model.label, selected: model.id == spec.model) {
                        spec.model = model.id
                        if let effort = model.supportedReasoningEfforts.first {
                            spec.reasoningEffort = effort
                        }
                        showModelOptions = false
                    }
                }
                AgentCompactMenuDivider()
                AgentCompactMenuSection(L("Reasoning"))
                ForEach(AgentReasoningEffort.allCases, id: \.self) { effort in
                    AgentCompactMenuRow(effort.displayName, selected: effort == spec.reasoningEffort) {
                        spec.reasoningEffort = effort
                        showModelOptions = false
                    }
                }
            }
        }
        .accessibilityIdentifier("bots.scheduleTasks.editor.reasoning")
    }

    private var selectedMainEfforts: [AgentReasoningEffort] {
        models.first(where: { $0.id == spec.model })?.supportedReasoningEfforts ?? []
    }

    private var selectedReasoningEfforts: [AgentReasoningEffort] {
        guard let reasoningModel = spec.reasoningModel else { return [] }
        return models.first(where: { $0.id == reasoningModel })?.supportedReasoningEfforts ?? []
    }

    private func selectSpecSource(_ entry: AgentSourceCapsulePresentation.MenuEntry) {
        if let snapshot = providers.first(where: { $0.id == entry.id }) {
            spec.provider = snapshot.provider
            spec.providerInstanceID = snapshot.id
            let models = snapshot.provider == .distill
                ? AgentDistillModelCatalog.selectableModels(snapshot.models)
                : snapshot.models
            spec.model = models.first?.id ?? ""
            spec.reasoningEffort = models.first?.supportedReasoningEfforts.first ?? .medium
            if snapshot.provider == .distill {
                spec.routingMode = .manual
                spec.distillMainEffortSelection = .automatic
                spec.distillReasoningEffortSelection = .automatic
            } else {
                spec.distillMainEffortSelection = nil
                spec.distillReasoningEffortSelection = nil
            }
            spec.reasoningModel = nil
            return
        }
        guard let provider = AgentProvider(rawValue: entry.id) else { return }
        spec.provider = provider
        if let snapshot = snapshots(for: provider).first {
            spec.providerInstanceID = snapshot.id
            let models = snapshot.provider == .distill
                ? AgentDistillModelCatalog.selectableModels(snapshot.models)
                : snapshot.models
            spec.model = models.first?.id ?? ""
            spec.reasoningEffort = models.first?.supportedReasoningEfforts.first ?? .medium
        } else {
            spec.providerInstanceID = provider.rawValue
            spec.model = ""
        }
        spec.reasoningModel = nil
        spec.distillMainEffortSelection = provider == .distill ? .automatic : nil
        spec.distillReasoningEffortSelection = provider == .distill ? .automatic : nil
        if provider == .distill { spec.routingMode = .manual }
    }

    private func editorGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ScheduleEditorSection(title, identifier: "bots.scheduleTasks.editorSection.\(title)", content: content)
    }

    private func formRow<Content: View>(_ label: String, showsDivider: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        ScheduleEditorRow(label, showsDivider: showsDivider, control: content)
    }
}

/// Bot schedules inside the Schedule Tasks screen: the same cards and actions as the Bots screen.
/// One Bot schedule card wired to the Bots model; Schedule Tasks mounts it inside its workspace group.
struct BotScheduleTaskRow: View {
    @ObservedObject var vm: BotsViewModel
    let item: BotScheduleTaskItem

    var body: some View {
        BotScheduleTaskCard(
            item: item,
            isAutonomyActive: vm.isAutonomyActive,
            isRunning: vm.isRoutineRunning(id: item.id),
            isStarting: vm.isRoutineStartingGuest(id: item.id),
            lastRun: vm.routineRunSummaries[item.id]?.last,
            runCount: vm.routineRunSummaries[item.id]?.count ?? 0,
            onOpenLastRun: {
                if let last = vm.routineRunSummaries[item.id]?.last {
                    vm.openRoutineRunConversation(last, botID: item.botID)
                }
            },
            onOpen: { vm.openScheduleTaskDetail(item) },
            onToggle: { vm.setRoutineEnabled(id: item.id, enabled: !item.isEnabled) },
            onRunNow: { vm.runRoutineNow(id: item.id) },
            onEdit: { vm.editScheduleTask(item) },
            onDelete: { vm.deleteScheduleTask(item) }
        )
    }
}

/// Full-page editor for one bot schedule, shown in place of the Schedule Tasks overview.
struct BotScheduleTaskEditorScreen: View {
    @ObservedObject var vm: BotsViewModel

    var body: some View {
        if let draft = vm.scheduleTaskDraft {
            BotScheduleTaskEditorView(
                draft: draft,
                bots: vm.fleet,
                providers: vm.providers,
                providersLoading: false,
                destinationStore: vm.executionDestinationStore,
                workspaces: vm.executionWorkspaces,
                onBack: { vm.scheduleTaskDraft = nil },
                onSave: { vm.saveScheduleTask($0) }
            )
        }
    }
}

/// "Last run" text shared by the Agent and Bot schedule cards.
enum ScheduleLastRunLabel {
    static func text(date: Date?, failed: Bool) -> String {
        guard let date else { return L("Never") }
        let when = date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return failed ? "Failed · \(when)" : when
    }
}

/// Run History of one Bot schedule: the page a card opens, like an Agent scheduled task's.
struct BotScheduleTaskDetailScreen: View {
    @ObservedObject var vm: BotsViewModel
    let item: BotScheduleTaskItem

    private var spec: BotScheduleSpec? { item.resolvedSpec }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                header
                summaryCard
                historySection
                Button {
                    vm.editScheduleTask(item)
                } label: {
                    Label(L("Edit Schedule"), systemImage: "pencil")
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .accessibilityIdentifier("bots.scheduleTasks.detail.edit")
            }
            .padding(DS.Space.xxl)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("bots.scheduleTasks.detail")
        .task(id: item.id) {
            vm.reloadScheduleDetailRuns()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if vm.scheduleDetailRuns.contains(where: { $0.status == .running }) { vm.reloadScheduleDetailRuns() }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            Button { vm.closeScheduleTaskDetail() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Back to scheduled tasks"))
            .accessibilityIdentifier("bots.scheduleTasks.detail.back")

            HStack(spacing: DS.Space.md) {
                Text(item.name)
                    .font(DS.Font.title2.weight(.semibold))
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                statusPill
            }
            Spacer(minLength: DS.Space.lg)
            HStack(spacing: DS.Space.sm) {
                Button(L("Run Now")) { vm.runRoutineNow(id: item.id) }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(vm.isRoutineRunning(id: item.id))
                    .accessibilityIdentifier("bots.scheduleTasks.detail.runNow")
                Button(item.isEnabled ? L("Pause") : L("Resume")) {
                    vm.setRoutineEnabled(id: item.id, enabled: !item.isEnabled)
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .accessibilityIdentifier("bots.scheduleTasks.detail.toggle")
                Menu {
                    Button(L("Edit Schedule")) { vm.editScheduleTask(item) }
                    Divider()
                    Button(L("Delete"), role: .destructive) { vm.deleteScheduleTask(item) }
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
                .accessibilityLabel(L("More actions"))
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if vm.isRoutineRunning(id: item.id) {
            DSPill(L("Running"), tone: .success)
        } else if item.isEnabled {
            DSPill(L("Active"), tone: .success)
        } else {
            DSPill(L("Paused"), tone: .neutral)
        }
    }

    private var summaryCard: some View {
        let workspace = vm.executionWorkspaces.first { $0.id == item.workspaceID }?.name ?? "—"
        let model: String = {
            guard let spec else { return "—" }
            if spec.provider != .distill && spec.routingMode == .auto { return L("Auto") }
            return spec.model.isEmpty ? L("Default model") : spec.model
        }()
        return VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(alignment: .top, spacing: DS.Space.xl) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                    .frame(width: 40, height: 40)
                    .background(DS.Palette.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .accessibilityHidden(true)
                metaCell(L("Workspace"), workspace)
                metaCell(L("Bot"), "\(item.botName) · @\(item.botHandle)")
                metaCell(L("Provider"), spec?.provider.rawValue.capitalized ?? "—")
                metaCell(L("Model"), model)
                metaCell(L("Reasoning"), spec?.reasoningEffort.displayName ?? "—")
                metaCell(L("Schedule"), item.scheduleNote.isEmpty ? "—" : item.scheduleNote)
                metaCell(L("Time zone"), spec?.timeZoneIdentifier ?? "—")
            }
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "clock")
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
                Text(L("Next run: %1$@", item.nextRunLabel(isAutonomyActive: vm.isAutonomyActive)))
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

    private var historySection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(L("Run History"))
                .font(DS.Font.title3.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            if vm.scheduleDetailRuns.isEmpty {
                Text(L("No runs yet. Use Run Now or wait for the next scheduled occurrence."))
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsPanel(padding: DS.Space.xl)
            } else {
                LazyVStack(spacing: 0) {
                    historyHeader
                    ForEach(vm.scheduleDetailRuns) { row in
                        Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                        historyRow(row)
                    }
                }
                .background(DS.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                )
                .accessibilityIdentifier("bots.scheduleTasks.detail.history")
            }
        }
    }

    private var historyHeader: some View {
        HStack(spacing: DS.Space.lg) {
            Text(L("Started")).frame(width: 140, alignment: .leading)
            Text(L("Duration")).frame(width: 80, alignment: .leading)
            Text(L("Status")).frame(width: 110, alignment: .leading)
            Text(L("Agent Task")).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(DS.Font.caption2.weight(.semibold))
        .foregroundColor(DS.Palette.textTertiary)
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }

    @ViewBuilder
    private func historyRow(_ row: BotRoutineRunRow) -> some View {
        let content = HStack(spacing: DS.Space.lg) {
            Text(row.record.executedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.text)
                .frame(width: 140, alignment: .leading)
            Group {
                if row.status == .running {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in Text(row.duration(now: timeline.date)) }
                } else {
                    Text(row.duration(now: Date()))
                }
            }
            .font(DS.Font.caption)
            .foregroundColor(DS.Palette.textSecondary)
            .frame(width: 80, alignment: .leading)
            statusPill(row.status)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(taskTitle(row))
                    .font(DS.Font.caption.weight(row.canOpen ? .medium : .regular))
                    .foregroundColor(row.canOpen ? DS.Palette.accent : DS.Palette.textSecondary)
                if let error = row.errorText {
                    Text(error)
                        .font(DS.Font.caption2)
                        .foregroundColor(row.status == .skipped ? DS.Palette.textSecondary : DS.Palette.danger)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        if row.canOpen {
            Button { vm.openRoutineRunConversation(row.record, botID: item.botID) } label: { content }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Open agent task %1$@", taskTitle(row)))
                .accessibilityIdentifier("bots.scheduleTasks.detail.openRun")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    private func taskTitle(_ row: BotRoutineRunRow) -> String {
        "\(item.name) · \(row.record.executedAt.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func statusPill(_ status: BotRoutineRunRow.Status) -> some View {
        switch status {
        case .completed: return AnyView(DSPill(L("Completed"), tone: .success))
        case .failed: return AnyView(DSPill(L("Failed"), tone: .danger))
        case .running: return AnyView(DSPill(L("Running"), tone: .warning))
        case .started: return AnyView(DSPill(L("Started"), tone: .neutral))
        case .cancelled: return AnyView(DSPill(L("Cancelled"), tone: .neutral))
        case .skipped: return AnyView(DSPill(L("Skipped"), tone: .neutral))
        }
    }
}
