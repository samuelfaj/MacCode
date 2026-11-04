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

    /// Next run is when this task would actually fire, not whether it is armed.
    /// An enabled task still does not run while global autonomy is paused.
    public func nextRunLabel(isAutonomyActive: Bool) -> String {
        if !isEnabled { return "Paused" }
        if !isAutonomyActive { return "Scheduler paused" }
        return "While MacCode is open"
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
        let tasks = all == 1 ? "1 task" : "\(all) tasks"
        let live = active == 1 ? "1 active" : "\(active) active"
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

    private var subtitle: String {
        if scopeBotID != nil, vm.isAutonomyActive {
            return "Tasks this bot runs automatically while MacCode is open"
        }
        return vm.scheduleTasksSubtitle
    }

    private var overviewScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Scheduled Tasks")
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
                        Label("New Task", systemImage: "plus")
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
                        title: "No scheduled tasks yet",
                        subtitle: "Create a task to have this bot work on a schedule."
                    ) {
                        Button {
                            if let scopeBotID {
                                vm.scheduleTaskDraft = BotScheduleTaskDraft(botID: scopeBotID)
                            }
                        } label: {
                            Label("New Task", systemImage: "plus")
                        }
                        .buttonStyle(DSPrimaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DSEmptyState(
                        icon: "calendar.badge.clock",
                        title: vm.scheduleTaskSearchText.isEmpty ? "No scheduled tasks" : "No matching tasks",
                        subtitle: vm.scheduleTaskSearchText.isEmpty
                            ? "Create a task to run a bot automatically while MacCode is open."
                            : "Try another search or clear the status filter."
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
                                onOpen: { vm.editScheduleTask(item) },
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
            accessibilityLabel: vm.isAutonomyActive ? "Schedules active" : "Schedules paused",
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
            placeholder: "Search tasks",
            identifier: "bots.scheduleTasks.search",
            accessibilityLabel: "Search tasks"
        )
        .accessibilityLabel("Search tasks")
    }

    private var footerBar: some View {
        AgentListFooterBar(
            caption: footerCaption,
            pillTitle: vm.isAutonomyActive ? "Scheduler online" : "Scheduler paused",
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
                        Text("Starting Bot computer…")
                            .font(DS.Font.caption.weight(.medium))
                            .foregroundColor(DS.Palette.textSecondary)
                            .accessibilityIdentifier("bots.scheduleTasks.starting")
                    } else {
                        DSPill("Running", tone: .success)
                    }
                }
                .accessibilityIdentifier("bots.scheduleTasks.running")
            } else if item.isEnabled {
                DSPill("Active", tone: .success)
            } else {
                DSPill("Paused", tone: .neutral)
            }
        } meta: {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                AgentOverviewMetaColumn(
                    title: "Schedule",
                    value: item.scheduleNote.isEmpty ? "When noted in the task" : item.scheduleNote
                )
                AgentOverviewMetaColumn(
                    title: "Next run",
                    value: item.nextRunLabel(isAutonomyActive: isAutonomyActive)
                )
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Text(item.lastTestRunRequestedAt == nil ? "0" : "1")
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.textSecondary)
                        .monospacedDigit()
                }
                .frame(width: 44, alignment: .trailing)
            }
        } trailing: {
            Menu {
                Button(item.isEnabled ? "Pause" : "Resume", action: onToggle)
                Button("Run Now", action: onRunNow).disabled(isRunning)
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
            title: draft.isNew ? "New Scheduled Task" : "Edit Scheduled Task",
            subtitle: "Run a Bot on a schedule, with its own identity, memory and tools.",
            saveTitle: "Save",
            saveIdentifier: "bots.scheduleTasks.save",
            onBack: onBack,
            onSave: { onSave(draft) },
            content: {
                ScheduleEditorSection("Task", identifier: "bots.scheduleTasks.editorSection.Task") {
                    ScheduleEditorRow("Bot", showsDivider: false) {
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
                            placeholder: "Name, e.g. Morning scan",
                            text: $draft.name,
                            identifier: "bots.scheduleTasks.editor.name"
                        )
                        ScheduleEditorPromptBox(
                            placeholder: "Describe what the Bot should do",
                            text: $draft.prompt,
                            identifier: "bots.scheduleTasks.editor.instruction",
                            label: "Instruction"
                        )
                    }
                    .padding(DS.Space.md)
                }
                BotScheduleSpecEditor(
                    spec: $draft.spec,
                    providers: providers,
                    providersLoading: providersLoading
                )
                ScheduleEditorSection("Run options", identifier: "bots.scheduleTasks.editorSection.Run options") {
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
                    ScheduleEditorRow("Concurrent runs", hint: "How many runs of this task may be active at once") {
                        ScheduleConcurrencyPicker(selection: Binding(
                            get: { draft.spec.effectiveMaxConcurrentRuns },
                            set: { draft.spec.maxConcurrentRuns = $0 }
                        ))
                        .accessibilityIdentifier("bots.scheduleTasks.editor.concurrency")
                    }
                    ScheduleEditorRow("Use Bot default location", hint: "Where the run executes: Mac, a VM or a workspace") {
                        Toggle("Use bot default", isOn: Binding(
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
                ScheduleEditorSection("Status", identifier: "bots.scheduleTasks.editorSection.Status") {
                    ScheduleEditorRow("Active", hint: "Paused tasks keep their schedule but do not run", showsDivider: false) {
                        Toggle("Active", isOn: $draft.isEnabled)
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
            editorGroup("Details") {
                if AgentSourceCapsulePresentation.isVisible(entryCount: specSourceEntries.count) {
                    formRow("Provider") {
                        specSourceCapsule
                            .accessibilityIdentifier("bots.scheduleTasks.editor.provider")
                    }
                }
                if spec.provider != .distill {
                    formRow("Model routing") {
                        HStack(spacing: DS.Space.sm) {
                            if providersLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Loading providers")
                            }
                            Toggle("Auto", isOn: Binding(
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
                    formRow("Model") {
                        Text("Auto selects the best model for the selected provider at run time.")
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if spec.provider == .distill {
                    // Same Main / Worker pills and modal sheets as the Agent App and Bot Desk composer.
                    formRow("Model") { specDistillModelPills }
                } else {
                    formRow("Model") {
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

            editorGroup("Frequency") {
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
            ?? (spec.model.isEmpty ? (spec.provider == .distill ? "Select Main model" : "Model") : spec.model)
        let effort = spec.provider == .distill
            ? (spec.distillMainEffortSelection ?? .fixed(spec.reasoningEffort)).effort?.displayName ?? "Auto"
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
            emptyListTitle: providersLoading ? "Loading models..." : "No models available",
            workerEmptyListTitle: providersLoading
                ? "Loading models..." : "No models yet. Connect an account on the start screen.",
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
                AgentCompactMenuSection("Model")
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
                AgentCompactMenuSection("Reasoning")
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
            onOpen: { vm.editScheduleTask(item) },
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
