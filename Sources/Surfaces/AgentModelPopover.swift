import AppKit
import CoreModel
import DesignSystemKit
import AgentRuntime
import SwiftUI

/// Shared Model popover chrome for Agent App and Bots Desk.
///
/// WHY: Desk Auto was a header-only fork of the Agent App popover. Auto-on
/// must paint the same orchestration card from one component.

public enum AgentModelPopoverTransition: Equatable {
    case none
    case fadeAndSlide
}

public struct AgentModelPopoverPresentation: Equatable {
    public static let autoDisclaimer = "MacCode will automatically orchestrate the model to maximize quality while using the fewest tokens."
    public static let autoStatus = "Orchestration active"
    public static let autoAccessibilityLabel = "Automatic model routing"
    public static let autoAccessibilityHint = "Turns automatic model routing on or off."

    public let mode: AgentRoutingMode
    public let reduceMotion: Bool
    public let autoRoutingLoading: Bool

    public init(mode: AgentRoutingMode, reduceMotion: Bool, autoRoutingLoading: Bool = false) {
        self.mode = mode
        self.reduceMotion = reduceMotion
        self.autoRoutingLoading = autoRoutingLoading
    }

    public static func current(mode: AgentRoutingMode, autoRoutingLoading: Bool = false) -> Self {
        Self(
            mode: mode,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            autoRoutingLoading: autoRoutingLoading
        )
    }

    public var showsModelControls: Bool { mode != .auto }
    public var showsReasoningControls: Bool { mode != .auto }
    public var showsServiceTierControls: Bool { mode != .auto }
    public var showsDisclaimer: Bool { mode == .auto }
    public var showsAutoLoadingIndicator: Bool { autoRoutingLoading }
    public var autoToggleEnabled: Bool { !autoRoutingLoading }
    public var transition: AgentModelPopoverTransition {
        reduceMotion ? .none : .fadeAndSlide
    }
    public var accessibilityLabel: String { Self.autoAccessibilityLabel }
    public var accessibilityValue: String { mode == .auto ? "On" : "Off" }
    public var accessibilityHint: String { Self.autoAccessibilityHint }
    public var disclaimer: String { Self.autoDisclaimer }
}

public struct AgentModelAutoRoutingCard: View {
    public let presentation: AgentModelPopoverPresentation

    public init(presentation: AgentModelPopoverPresentation) {
        self.presentation = presentation
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            ZStack {
                Ellipse()
                    .stroke(
                        LinearGradient(
                            colors: [DS.Palette.accent, DS.Palette.success],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: 40, height: 20)
                    .rotationEffect(.degrees(-12))
                Image(systemName: "sparkles")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(DS.Palette.text)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text(presentation.disclaimer)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Palette.success)
                    Text(AgentModelPopoverPresentation.autoStatus)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                }
            }
        }
        .padding(DS.Space.lg)
        .frame(minWidth: 280, idealWidth: 360, maxWidth: 360, alignment: .leading)
        .background(
            LinearGradient(
                colors: [DS.Palette.surfaceRaised, DS.Palette.success.opacity(0.12)],
                startPoint: .leading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Palette.accent.opacity(0.22), lineWidth: DS.Border.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.model.auto.card")
    }
}

public enum AgentDistillModelCatalog {
    public static func shouldShowAutoOption(setupAvailable: Bool, catalogHasAuto: Bool, selectedAuto: Bool) -> Bool {
        setupAvailable || catalogHasAuto || selectedAuto
    }

    public static func selectableModels(_ models: [AgentModelDescriptor]) -> [AgentModelDescriptor] {
        models.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public static func mainPillTitle(model: String, models: [AgentModelDescriptor]) -> String {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Select model" }
        return shortLabel(models.first(where: { $0.id == model })?.label ?? model)
    }

    public static func concreteWorkerModels(_ models: [AgentModelDescriptor]) -> [AgentModelDescriptor] {
        selectableModels(models).filter { $0.id != "auto" }
    }

    public static func workerPillTitle(reasoningModel: String?, models: [AgentModelDescriptor], supportsSessionWorker: Bool, homePath: String?, mainModel: String? = nil) -> String {
        if mainModel == "auto" { return "Auto profile" }
        guard supportsSessionWorker else { return "\(configuredWorker(homePath: homePath).worker) (config)" }
        guard let reasoningModel, !reasoningModel.isEmpty else { return "Off" }
        return shortLabel(models.first(where: { $0.id == reasoningModel })?.label ?? reasoningModel)
    }

    public static func workerUnavailable(reasoningModel: String?, models: [AgentModelDescriptor]) -> Bool {
        guard let reasoningModel, !reasoningModel.isEmpty else { return false }
        return !models.contains(where: { $0.id == reasoningModel })
    }

    public static func pillWidth(_ label: String, cap: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let measured = (label as NSString).size(withAttributes: [.font: font]).width
        let spacing = CGFloat(label.components(separatedBy: " · ").count) * DS.Space.xs
        return min(cap, max(44, ceil(measured + 8 + spacing)))
    }

    public static let searchThreshold = 6
    public static let defaultWidth: CGFloat = 280

    public static func shortLabel(_ label: String) -> String {
        guard let suffix = label.range(of: " (", options: .backwards), label.hasSuffix(")") else { return label }
        return String(label[..<suffix.lowerBound])
    }

    public static func effortOptionLabels(_ efforts: [AgentReasoningEffort]) -> [String] {
        ["Auto"] + efforts.map(\.displayName)
    }

    public static func configuredWorker(homePath: String?) -> (worker: String, effort: String) {
        let home = DistillProvisioner.homeURL(instanceHomePath: homePath)
        let config = DistillModelsConfig.read(home: home)
        return (config.worker.map(shortLabel) ?? "Off", config.workerEffort ?? "Auto")
    }

    public static func configWorkerSummary(homePath: String?) -> String {
        let config = configuredWorker(homePath: homePath)
        return "From Distill config: \(config.worker) · \(config.effort)"
    }

    public static func providerGroups(_ models: [AgentModelDescriptor]) -> [(String, [AgentModelDescriptor])] {
        let order = ["Grok", "ChatGPT", "Claude", "OpenRouter", "Custom"]
        let grouped = Dictionary(grouping: models) { model in
            if model.id.hasPrefix("chatgpt/") { return "ChatGPT" }
            if model.id.hasPrefix("claude/") { return "Claude" }
            if model.id.hasPrefix("openrouter/") { return "OpenRouter" }
            if model.id.contains("/") { return "Custom" }
            return "Grok"
        }
        return order.compactMap { name in grouped[name].map { (name, $0) } }
    }

    public static func filtered(_ models: [AgentModelDescriptor], query: String) -> [AgentModelDescriptor] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return models }
        return models.filter {
            $0.label.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
    }

}

public struct AgentEffortChipRow: View {
    public let selection: AgentEffortSelection
    public let efforts: [AgentReasoningEffort]
    public let disabled: Bool
    public let onSelect: (AgentEffortSelection) -> Void

    public init(selection: AgentEffortSelection, efforts: [AgentReasoningEffort], disabled: Bool = false, onSelect: @escaping (AgentEffortSelection) -> Void) {
        self.selection = selection
        self.efforts = efforts
        self.disabled = disabled
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            chip("Auto", selected: selection.isAutomatic) { onSelect(.automatic) }
            ForEach(Self.ordered(efforts), id: \.self) { effort in
                chip(effort.displayName, selected: selection.effort == effort) { onSelect(.fixed(effort)) }
            }
        }
    }

    /// Lightest to heaviest, whatever order the catalog advertised.
    static func ordered(_ efforts: [AgentReasoningEffort]) -> [AgentReasoningEffort] {
        let rank = AgentReasoningEffort.allCases
        return efforts.sorted { (rank.firstIndex(of: $0) ?? 0) < (rank.firstIndex(of: $1) ?? 0) }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(DS.Font.caption).padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
                .background(selected ? DS.Palette.accent : DS.Palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? DS.Palette.accent : DS.Palette.line, lineWidth: DS.Border.hairline))
                .foregroundStyle(selected ? DS.Palette.onAccent : DS.Palette.text)
        }
        .buttonStyle(.plain).disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

public struct AgentDistillMainModelSection<Footer: View>: View {
    public let mainModel: String
    public let mainModels: [AgentModelDescriptor]
    public let customMainModels: [String]
    public let reasoningModel: String?
    public let mainEffortSelection: AgentEffortSelection
    public let mainEfforts: [AgentReasoningEffort]
    public let supportsMainEffortAuto: Bool
    public let width: CGFloat?
    public let isDisabled: Bool
    public let emptyListTitle: String
    public let onSelectMainModel: (String) -> Void
    public let onSelectCustomMainModel: (String) -> Void
    public let onSelectMainEffort: (AgentEffortSelection) -> Void
    private let footer: Footer
    @State private var filterQuery = ""

    public init(
        mainModel: String,
        mainModels: [AgentModelDescriptor],
        customMainModels: [String] = [],
        reasoningModel: String? = nil,
        mainEffortSelection: AgentEffortSelection = .automatic,
        mainEfforts: [AgentReasoningEffort] = [],
        supportsMainEffortAuto: Bool = false,
        width: CGFloat? = nil,
        isDisabled: Bool,
        emptyListTitle: String = "No models yet. Connect an account on the start screen.",
        onSelectMainModel: @escaping (String) -> Void,
        onSelectCustomMainModel: @escaping (String) -> Void,
        onSelectMainEffort: @escaping (AgentEffortSelection) -> Void = { _ in },
        @ViewBuilder footer: () -> Footer
    ) {
        self.mainModel = mainModel
        self.mainModels = mainModels
        self.customMainModels = customMainModels
        self.reasoningModel = reasoningModel
        self.mainEffortSelection = mainEffortSelection
        self.mainEfforts = mainEfforts
        self.supportsMainEffortAuto = supportsMainEffortAuto
        self.width = width
        self.isDisabled = isDisabled
        self.emptyListTitle = emptyListTitle
        self.onSelectMainModel = onSelectMainModel
        self.onSelectCustomMainModel = onSelectCustomMainModel
        self.onSelectMainEffort = onSelectMainEffort
        self.footer = footer()
    }

    public var body: some View {
        let selectable = AgentDistillModelCatalog.selectableModels(mainModels)
        let trimmedQuery = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFiltering = !trimmedQuery.isEmpty
        let matches = AgentDistillModelCatalog.filtered(selectable, query: trimmedQuery)
        let displayed = isFiltering
            ? matches
            : selectable
        let customMatches = isFiltering
            ? customMainModels.filter { $0.lowercased().contains(trimmedQuery.lowercased()) }
            : customMainModels
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                AgentCompactMenuSection("Main model")
                Text("Leads the conversation: plans, reviews, answers.")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textSecondary)
            }
                .accessibilityIdentifier("agent.distill.mainModel.section")
            if isMainUnavailable(in: selectable) {
                Text("Selected Main model unavailable: \(mainModel). Choose a model below or add it as Custom.")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: rowWidth, alignment: .leading)
                    .padding(.bottom, DS.Space.xs)
            }
            if selectable.isEmpty {
                Text(emptyListTitle)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: rowWidth, alignment: .leading)
            } else {
                if selectable.count > AgentDistillModelCatalog.searchThreshold {
                    AgentModelSearchField(query: $filterQuery, width: rowWidth, accessibilityIdentifier: "agent.distill.mainModel.search")
                        .disabled(isDisabled)
                }
                if isFiltering && matches.isEmpty && customMatches.isEmpty {
                    Text("No models match \"\(trimmedQuery)\".")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: rowWidth, alignment: .leading)
                }
                modelRows(displayed)
                ForEach(customMatches, id: \.self) { model in
                    AgentCompactMenuRow(model, selected: model == mainModel, width: rowWidth) {
                        onSelectCustomMainModel(model)
                    }
                    .disabled(isDisabled)
                    .help(model)
                }
                footer
            }
            AgentCompactMenuDivider(width: rowWidth)
            AgentCompactMenuSection("Main effort")
                .accessibilityIdentifier("agent.distill.mainEffort.section")
            AgentEffortChipRow(selection: mainEffortSelection, efforts: mainEfforts, disabled: isDisabled, onSelect: onSelectMainEffort)
            if let effort = mainEffortSelection.effort, !mainEfforts.isEmpty, !mainEfforts.contains(effort) {
                Text("Selected Main effort \(effort.displayName) is unavailable for this model. Choose Auto or a supported level.")
                    .font(DS.Font.caption2).foregroundColor(DS.Palette.warning)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main model selection")
        .accessibilityIdentifier("agent.distill.mainModel")
    }

    private var rowWidth: CGFloat { width ?? AgentDistillModelCatalog.defaultWidth }

    private func isMainUnavailable(in selectable: [AgentModelDescriptor]) -> Bool {
        guard !mainModel.isEmpty,
              mainModel != "auto",
              !selectable.contains(where: { $0.id == mainModel }),
              !customMainModels.contains(mainModel) else { return false }
        return true
    }

    @ViewBuilder
    private func modelRows(_ displayed: [AgentModelDescriptor]) -> some View {
        if !displayed.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AgentDistillModelCatalog.providerGroups(displayed), id: \.0) { provider, models in
                        Text(provider.uppercased()).font(DS.Font.caption2).foregroundColor(DS.Palette.textSecondary).padding(.horizontal, DS.Space.sm).padding(.top, DS.Space.xs)
                        ForEach(models, id: \.id) { modelRow($0) }
                    }
                }
            }
            .frame(width: rowWidth)
            .frame(maxHeight: 308)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AgentDistillModelCatalog.providerGroups(displayed), id: \.0) { provider, models in
                        Text(provider.uppercased()).font(DS.Font.caption2).foregroundColor(DS.Palette.textSecondary).padding(.horizontal, DS.Space.sm).padding(.top, DS.Space.xs)
                        ForEach(models, id: \.id) { modelRow($0) }
                    }
            }
        }
    }

    private func modelRow(_ model: AgentModelDescriptor) -> some View {
        AgentCompactMenuRow(
            AgentDistillModelCatalog.shortLabel(model.label),
            detail: model.contextWindowLabel,
            selected: model.id == mainModel,
            width: rowWidth
        ) {
            onSelectMainModel(model.id)
        }
        .disabled(isDisabled)
        .help("\(model.label)\n\(model.id)")
    }
}

public struct AgentDistillReasoningModelSection: View {
    public let mainModel: String
    public let reasoningModel: String?
    public let reasoningModels: [AgentModelDescriptor]
    public let reasoningEffortSelection: AgentEffortSelection
    public let reasoningEfforts: [AgentReasoningEffort]
    public let supportsReasoningModelEffort: Bool
    public let configWorkerSummary: String?
    public let width: CGFloat?
    public let isDisabled: Bool
    public let emptyListTitle: String
    public let onSelectReasoningModel: (String?) -> Void
    public let onSelectReasoningEffort: (AgentEffortSelection) -> Void
    @State private var filterQuery = ""

    public init(
        mainModel: String,
        reasoningModel: String?,
        reasoningModels: [AgentModelDescriptor],
        reasoningEffortSelection: AgentEffortSelection = .automatic,
        reasoningEfforts: [AgentReasoningEffort] = [],
        supportsReasoningModelEffort: Bool = false,
        configWorkerSummary: String? = nil,
        width: CGFloat? = nil,
        isDisabled: Bool,
        emptyListTitle: String = "No models yet. Connect an account on the start screen.",
        onSelectReasoningModel: @escaping (String?) -> Void,
        onSelectReasoningEffort: @escaping (AgentEffortSelection) -> Void = { _ in }
    ) {
        self.mainModel = mainModel
        self.reasoningModel = reasoningModel
        self.reasoningModels = reasoningModels
        self.reasoningEffortSelection = reasoningEffortSelection
        self.reasoningEfforts = reasoningEfforts
        self.supportsReasoningModelEffort = supportsReasoningModelEffort
        self.configWorkerSummary = configWorkerSummary
        self.width = width
        self.isDisabled = isDisabled
        self.emptyListTitle = emptyListTitle
        self.onSelectReasoningModel = onSelectReasoningModel
        self.onSelectReasoningEffort = onSelectReasoningEffort
    }

    public var showsConfigFallback: Bool { mainModel != "auto" && configWorkerSummary != nil }

    public var body: some View {
        let selectable = AgentDistillModelCatalog.concreteWorkerModels(reasoningModels)
        let eligible = selectable
        let trimmedQuery = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFiltering = !trimmedQuery.isEmpty
        let matches = AgentDistillModelCatalog.filtered(eligible, query: trimmedQuery)
        let displayed = isFiltering
            ? matches
            : eligible
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                AgentCompactMenuSection("Worker model")
                Text("Runs the tasks Main delegates.")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textSecondary)
            }
                .accessibilityIdentifier("agent.distill.reasoningModel.section")
            if mainModel == "auto" {
                Text("Worker follows the selected Auto profile option. Change its Main and Worker pair in Accounts.")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).frame(width: rowWidth, alignment: .leading)
            } else if let configWorkerSummary {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(configWorkerSummary)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.text)
                    Text("Update Distill to choose a Worker per conversation.")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                }
                .frame(width: rowWidth, alignment: .leading)
            } else {
            if let warning = reasoningWarning(in: selectable) {
                Text(warning)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: rowWidth, alignment: .leading)
                    .padding(.bottom, DS.Space.xs)
            }
            AgentCompactMenuRow("Off", detail: "Main does all the work", selected: reasoningModel == nil, width: rowWidth) {
                onSelectReasoningModel(nil)
            }
            .disabled(isDisabled)
            .help("Run without a separate reasoning model")
            if eligible.isEmpty {
                Text(emptyListTitle)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: rowWidth, alignment: .leading)
            } else {
                if eligible.count > AgentDistillModelCatalog.searchThreshold {
                    AgentModelSearchField(query: $filterQuery, width: rowWidth, accessibilityIdentifier: "agent.distill.reasoningModel.search")
                        .disabled(isDisabled)
                }
                if isFiltering && matches.isEmpty {
                    Text("No models match \"\(trimmedQuery)\".")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: rowWidth, alignment: .leading)
                }
                modelRows(displayed)
            }
            if reasoningModel != nil {
                AgentCompactMenuDivider(width: rowWidth)
                AgentCompactMenuSection("Worker effort")
                    .accessibilityIdentifier("agent.distill.reasoningEffort.section")
                if supportsReasoningModelEffort {
                    AgentEffortChipRow(selection: reasoningEffortSelection, efforts: reasoningEfforts, disabled: isDisabled, onSelect: onSelectReasoningEffort)
                    if let effort = reasoningEffortSelection.effort,
                       !reasoningEfforts.isEmpty,
                       !reasoningEfforts.contains(effort) {
                        Text("Selected Worker effort \(effort.displayName) is unavailable for this model. Choose Auto or a supported level.")
                            .font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: rowWidth, alignment: .leading)
                    }
                } else {
                    Text("Worker effort follows the model default in this Distill version.")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: rowWidth, alignment: .leading)
                }
            }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Worker model selection")
        .accessibilityIdentifier("agent.distill.reasoningModel")
    }

    private var rowWidth: CGFloat { width ?? AgentDistillModelCatalog.defaultWidth }

    private func reasoningWarning(in selectable: [AgentModelDescriptor]) -> String? {
        guard let reasoningModel else { return nil }
        if !selectable.contains(where: { $0.id == reasoningModel }) {
            return "Selected Worker model unavailable: \(reasoningModel). Choose Off or a model below."
        }
        return nil
    }

    @ViewBuilder
    private func modelRows(_ displayed: [AgentModelDescriptor]) -> some View {
        if !displayed.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AgentDistillModelCatalog.providerGroups(displayed), id: \.0) { provider, models in
                        Text(provider.uppercased()).font(DS.Font.caption2).foregroundColor(DS.Palette.textSecondary).padding(.horizontal, DS.Space.sm).padding(.top, DS.Space.xs)
                        ForEach(models, id: \.id) { modelRow($0) }
                    }
                }
            }
            .frame(width: rowWidth)
            .frame(maxHeight: 308)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AgentDistillModelCatalog.providerGroups(displayed), id: \.0) { provider, models in
                        Text(provider.uppercased()).font(DS.Font.caption2).foregroundColor(DS.Palette.textSecondary).padding(.horizontal, DS.Space.sm).padding(.top, DS.Space.xs)
                        ForEach(models, id: \.id) { modelRow($0) }
                    }
            }
        }
    }

    private func modelRow(_ model: AgentModelDescriptor) -> some View {
        AgentCompactMenuRow(
            AgentDistillModelCatalog.shortLabel(model.label),
            detail: model.contextWindowLabel,
            selected: model.id == reasoningModel,
            width: rowWidth
        ) {
            onSelectReasoningModel(model.id)
        }
        .disabled(isDisabled)
        .help("\(model.label)\n\(model.id)")
    }
}

public struct AgentDistillModelPills<StatusHeader: View, MainFooter: View>: View {
    public let mainModel: String
    public let mainModels: [AgentModelDescriptor]
    public let customMainModels: [String]
    public let reasoningModel: String?
    public let reasoningModels: [AgentModelDescriptor]
    public let mainEffortSelection: AgentEffortSelection
    public let mainEfforts: [AgentReasoningEffort]
    public let supportsMainEffortAuto: Bool
    public let reasoningEffortSelection: AgentEffortSelection
    public let reasoningEfforts: [AgentReasoningEffort]
    public let supportsReasoningModelEffort: Bool
    public let homePath: String?
    public let mainUnavailable: Bool
    public let serviceTierLabel: String?
    public let isRunning: Bool
    public let isDisabled: Bool
    public let emptyListTitle: String
    public let workerEmptyListTitle: String
    public let menuWidth: CGFloat
    public let mainIdentifier: String
    public let mainPopoverIdentifier: String
    public let workerIdentifier: String
    public let workerPopoverIdentifier: String
    public let onSelectMainModel: (String) -> Void
    public let onSelectCustomMainModel: (String) -> Void
    public let onSelectMainEffort: (AgentEffortSelection) -> Void
    public let onSelectWorkerModel: (String?) -> Void
    public let onSelectWorkerEffort: (AgentEffortSelection) -> Void
    public let onMainPopoverClosed: (() -> Void)?
    /// Lets a caller close the Main popover from its footer (e.g. after saving a custom model).
    private let mainIsPresented: Binding<Bool>?
    private let statusHeader: StatusHeader
    private let mainFooter: MainFooter
    @State private var showingMain = false
    @State private var showingWorker = false
    @State private var showingMainAutoGuide = false
    @State private var showingWorkerAutoGuide = false

    public init(
        mainModel: String,
        mainModels: [AgentModelDescriptor],
        customMainModels: [String] = [],
        reasoningModel: String?,
        reasoningModels: [AgentModelDescriptor],
        mainEffortSelection: AgentEffortSelection,
        mainEfforts: [AgentReasoningEffort],
        supportsMainEffortAuto: Bool,
        reasoningEffortSelection: AgentEffortSelection,
        reasoningEfforts: [AgentReasoningEffort],
        supportsReasoningModelEffort: Bool,
        homePath: String?,
        mainUnavailable: Bool,
        serviceTierLabel: String? = nil,
        isRunning: Bool,
        isDisabled: Bool,
        emptyListTitle: String,
        workerEmptyListTitle: String,
        menuWidth: CGFloat,
        mainIdentifier: String,
        mainPopoverIdentifier: String,
        workerIdentifier: String,
        workerPopoverIdentifier: String,
        onSelectMainModel: @escaping (String) -> Void,
        onSelectCustomMainModel: @escaping (String) -> Void,
        onSelectMainEffort: @escaping (AgentEffortSelection) -> Void,
        onSelectWorkerModel: @escaping (String?) -> Void,
        onSelectWorkerEffort: @escaping (AgentEffortSelection) -> Void,
        onMainPopoverClosed: (() -> Void)? = nil,
        mainIsPresented: Binding<Bool>? = nil,
        @ViewBuilder statusHeader: () -> StatusHeader,
        @ViewBuilder mainFooter: () -> MainFooter
    ) {
        self.mainModel = mainModel
        self.mainModels = mainModels
        self.customMainModels = customMainModels
        self.reasoningModel = reasoningModel
        self.reasoningModels = reasoningModels
        self.mainEffortSelection = mainEffortSelection
        self.mainEfforts = mainEfforts
        self.supportsMainEffortAuto = supportsMainEffortAuto
        self.reasoningEffortSelection = reasoningEffortSelection
        self.reasoningEfforts = reasoningEfforts
        self.supportsReasoningModelEffort = supportsReasoningModelEffort
        self.homePath = homePath
        self.mainUnavailable = mainUnavailable
        self.serviceTierLabel = serviceTierLabel
        self.isRunning = isRunning
        self.isDisabled = isDisabled
        self.emptyListTitle = emptyListTitle
        self.workerEmptyListTitle = workerEmptyListTitle
        self.menuWidth = menuWidth
        self.mainIdentifier = mainIdentifier
        self.mainPopoverIdentifier = mainPopoverIdentifier
        self.workerIdentifier = workerIdentifier
        self.workerPopoverIdentifier = workerPopoverIdentifier
        self.onSelectMainModel = onSelectMainModel
        self.onSelectCustomMainModel = onSelectCustomMainModel
        self.onSelectMainEffort = onSelectMainEffort
        self.onSelectWorkerModel = onSelectWorkerModel
        self.onSelectWorkerEffort = onSelectWorkerEffort
        self.onMainPopoverClosed = onMainPopoverClosed
        self.mainIsPresented = mainIsPresented
        self.statusHeader = statusHeader()
        self.mainFooter = mainFooter()
    }

    public var body: some View {
        HStack(spacing: DS.Space.sm) {
            mainPill
            workerPill
        }
    }

    private var mainPresentedBinding: Binding<Bool> { mainIsPresented ?? $showingMain }

    private var mainTitle: String {
        AgentDistillModelCatalog.mainPillTitle(model: mainModel, models: mainModels)
    }

    private var workerTitle: String {
        AgentDistillModelCatalog.workerPillTitle(
            reasoningModel: reasoningModel,
            models: reasoningModels,
            supportsSessionWorker: supportsReasoningModelEffort,
            homePath: homePath,
            mainModel: mainModel
        )
    }

    private var mainPresentation: AgentModelPillPresentation {
        AgentModelPillPresentation(
            title: mainTitle,
            effort: mainEffortSelection.pickerDisplayName,
            serviceTier: serviceTierLabel,
            prefix: "Main",
            warning: mainUnavailable && mainModel != "auto"
        )
    }

    private var workerPresentation: AgentModelPillPresentation {
        AgentModelPillPresentation(
            title: workerTitle,
            effort: mainModel != "auto" && supportsReasoningModelEffort && reasoningModel != nil
                ? reasoningEffortSelection.pickerDisplayName : nil,
            prefix: "Worker",
            warning: mainModel != "auto" && AgentDistillModelCatalog.workerUnavailable(reasoningModel: reasoningModel, models: reasoningModels)
        )
    }

    private var mainPill: some View {
        let label = (["Main", mainTitle, mainEffortSelection.pickerDisplayName] + [serviceTierLabel].compactMap { $0 })
            .joined(separator: " · ")
        return Button {
            mainPresentedBinding.wrappedValue.toggle()
        } label: {
            AgentModelPillLabel(presentation: mainPresentation, width: AgentDistillModelCatalog.pillWidth(label, cap: 220))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mainPresentation.accessibilityLabel)
        .accessibilityIdentifier(mainIdentifier)
        .help("Main model · main effort")
        .sheet(isPresented: mainPresentedBinding) {
            AgentDistillMainModelSheet(
                mainModel: mainModel,
                mainModels: mainModels,
                customMainModels: customMainModels,
                mainEffortSelection: mainEffortSelection,
                mainEfforts: mainEfforts,
                supportsMainEffortAuto: supportsMainEffortAuto,
                mainUnavailable: mainUnavailable,
                isRunning: isRunning,
                isDisabled: isDisabled,
                emptyListTitle: emptyListTitle,
                identifier: mainPopoverIdentifier,
                statusHeader: statusHeader,
                mainFooter: mainFooter,
                showingAutoGuide: $showingMainAutoGuide,
                onSelectMainModel: onSelectMainModel,
                onSelectCustomMainModel: onSelectCustomMainModel,
                onSelectMainEffort: onSelectMainEffort,
                close: { mainPresentedBinding.wrappedValue = false }
            )
        }
        .onChange(of: mainPresentedBinding.wrappedValue) { isShowing in
            if !isShowing {
                showingMainAutoGuide = false
                onMainPopoverClosed?()
            }
        }
    }

    private var workerPill: some View {
        Button {
            showingWorker.toggle()
        } label: {
            AgentModelPillLabel(
                presentation: workerPresentation,
                width: AgentDistillModelCatalog.pillWidth("Worker · \(workerTitle)", cap: 200)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workerPresentation.accessibilityLabel)
        .accessibilityIdentifier(workerIdentifier)
        .help("Worker model · Worker effort")
        .sheet(isPresented: $showingWorker) {
            AgentDistillWorkerModelSheet(
                mainModel: mainModel,
                reasoningModel: reasoningModel,
                reasoningModels: reasoningModels,
                reasoningEffortSelection: reasoningEffortSelection,
                reasoningEfforts: reasoningEfforts,
                supportsReasoningModelEffort: supportsReasoningModelEffort,
                configWorkerSummary: supportsReasoningModelEffort
                    ? nil : AgentDistillModelCatalog.configWorkerSummary(homePath: homePath),
                isRunning: isRunning,
                isDisabled: isDisabled,
                emptyListTitle: workerEmptyListTitle,
                identifier: workerPopoverIdentifier,
                statusHeader: statusHeader,
                showingAutoGuide: $showingWorkerAutoGuide,
                onSelectWorkerModel: onSelectWorkerModel,
                onSelectWorkerEffort: onSelectWorkerEffort,
                close: { showingWorker = false }
            )
        }
        .onChange(of: showingWorker) { isShowing in
            if !isShowing { showingWorkerAutoGuide = false }
        }
    }
}

private func agentDistillDisabledReason(_ isDisabled: Bool) -> String? {
    isDisabled ? "Unavailable right now." : nil
}

private func agentDistillProviderIcon(_ provider: String) -> String {
    switch provider {
    case "Grok": return "bolt.fill"
    case "ChatGPT": return "bubble.left.and.text.bubble.right.fill"
    case "Claude": return "asterisk"
    case "OpenRouter": return "point.3.connected.trianglepath.dotted"
    case "Custom": return "slider.horizontal.3"
    default: return "cpu"
    }
}

private func agentDistillEffortOptions(_ efforts: [AgentReasoningEffort], includesAuto: Bool = true) -> [(value: AgentEffortSelection, title: String, help: String?)] {
    (includesAuto ? [(value: AgentEffortSelection.automatic, title: "Auto", help: nil)] : []) + AgentEffortChipRow.ordered(efforts).map {
        (value: AgentEffortSelection.fixed($0), title: $0.displayName, help: $0.pickerHelpText)
    }
}

private func agentDistillDoneButton(_ close: @escaping () -> Void) -> some View {
    Button("Done", action: close)
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
}

private struct AgentDistillChoiceGrid: View {
    let models: [AgentModelDescriptor]
    let customModels: [String]
    let selectedId: String?
    let isDisabled: Bool
    let emptyTitle: String
    let searchIdentifier: String
    let onSelectModel: (String) -> Void
    let onSelectCustomModel: (String) -> Void
    @State private var query = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Space.md), count: 2)

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayed = AgentDistillModelCatalog.filtered(models, query: trimmed)
        let customMatches = trimmed.isEmpty
            ? customModels
            : customModels.filter { $0.lowercased().contains(trimmed.lowercased()) }
        let disabledReason = agentDistillDisabledReason(isDisabled)
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            if models.isEmpty && customModels.isEmpty {
                Text(emptyTitle)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            if models.count > AgentDistillModelCatalog.searchThreshold {
                AgentChoiceSearchField(query: $query, placeholder: "Search models", accessibilityIdentifier: searchIdentifier)
                    .disabled(isDisabled)
            }
            if !trimmed.isEmpty && displayed.isEmpty && customMatches.isEmpty {
                Text("No models match \"\(trimmed)\".")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            ForEach(AgentDistillModelCatalog.providerGroups(displayed), id: \.0) { provider, group in
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    AgentChoiceSectionHeader(provider)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.md) {
                        ForEach(group, id: \.id) { model in
                            AgentChoiceCard(
                                title: AgentDistillModelCatalog.shortLabel(model.label),
                                badge: model.contextWindowLabel,
                                selected: model.id == selectedId,
                                disabledReason: disabledReason,
                                action: { onSelectModel(model.id) }
                            ) {
                                AgentChoiceIconTile(systemName: agentDistillProviderIcon(provider), size: 30)
                            }
                            .help("\(model.label)\n\(model.id)")
                        }
                    }
                }
            }
            if !customMatches.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    AgentChoiceSectionHeader("Custom")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.md) {
                        ForEach(customMatches, id: \.self) { model in
                            AgentChoiceCard(
                                title: model,
                                subtitle: "Custom model",
                                selected: model == selectedId,
                                disabledReason: disabledReason,
                                action: { onSelectCustomModel(model) }
                            ) {
                                AgentChoiceIconTile(systemName: agentDistillProviderIcon("Custom"), size: 30)
                            }
                            .help(model)
                        }
                    }
                }
            }
        }
    }
}

/// Second step after picking a model: choose its effort, then the sheet closes.
private struct AgentDistillEffortStep: View {
    let efforts: [AgentReasoningEffort]
    let selection: AgentEffortSelection
    let isDisabled: Bool
    let identifierPrefix: String
    let includesAuto: Bool
    let onSelect: (AgentEffortSelection) -> Void

    /// Blue (lightest) to red (deepest) across whatever levels the model advertises.
    private func tint(_ effort: AgentReasoningEffort) -> Color {
        let ordered = AgentEffortChipRow.ordered(efforts)
        guard ordered.count > 1, let i = ordered.firstIndex(of: effort) else { return Color(hue: 0.6, saturation: 0.7, brightness: 0.95) }
        let t = Double(i) / Double(ordered.count - 1)
        return Color(hue: 0.6 * (1 - t), saturation: 0.75, brightness: 0.95)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            ForEach(agentDistillEffortOptions(efforts, includesAuto: includesAuto), id: \.title) { option in
                AgentChoiceCard(
                    title: option.title,
                    subtitle: option.value.isAutomatic ? "Let the model decide how long to think." : option.help,
                    selected: option.value == selection,
                    tint: option.value.effort.map(tint) ?? DS.Palette.ultracode,
                    disabledReason: agentDistillDisabledReason(isDisabled),
                    accessibilityIdentifier: "\(identifierPrefix).\(option.title.lowercased())",
                    action: { onSelect(option.value) }
                ) {
                    AgentChoiceIconTile(systemName: option.value.isAutomatic ? "wand.and.stars" : "speedometer",
                                        tint: option.value.effort.map(tint) ?? DS.Palette.ultracode, size: 30)
                }
            }
            if let effort = selection.effort, !efforts.isEmpty, !efforts.contains(effort) {
                AgentChoiceCallout(
                    icon: "exclamationmark.triangle.fill",
                    tint: DS.Palette.warning,
                    text: "Selected effort \(effort.displayName) is unavailable for this model. Choose Auto or a supported level."
                )
            }
        }
    }
}

private struct AgentDistillEffortTarget: Equatable {
    let modelTitle: String
    let efforts: [AgentReasoningEffort]
}

private func agentDistillBackToModels(_ action: @escaping () -> Void) -> some View {
    Button(action: action) { Label("Back to models", systemImage: "chevron.left") }
        .buttonStyle(.borderless)
}

private struct AgentDistillMainModelSheet<StatusHeader: View, MainFooter: View>: View {
    let mainModel: String
    let mainModels: [AgentModelDescriptor]
    let customMainModels: [String]
    let mainEffortSelection: AgentEffortSelection
    let mainEfforts: [AgentReasoningEffort]
    let supportsMainEffortAuto: Bool
    let mainUnavailable: Bool
    let isRunning: Bool
    let isDisabled: Bool
    let emptyListTitle: String
    let identifier: String
    let statusHeader: StatusHeader
    let mainFooter: MainFooter
    @Binding var showingAutoGuide: Bool
    let onSelectMainModel: (String) -> Void
    let onSelectCustomMainModel: (String) -> Void
    let onSelectMainEffort: (AgentEffortSelection) -> Void
    let close: () -> Void
    @State private var effortTarget: AgentDistillEffortTarget?

    private var models: [AgentModelDescriptor] {
        AgentDistillModelCatalog.selectableModels(mainModels).filter { $0.id != "auto" }
    }

    private var hasAutoOption: Bool {
        AgentDistillModelCatalog.shouldShowAutoOption(
            setupAvailable: AgentAutoGuide.makeGuide != nil,
            catalogHasAuto: mainModels.contains(where: { $0.id == "auto" }),
            selectedAuto: mainModel == "auto"
        )
    }

    private var catalogAdvertisesAuto: Bool {
        mainModels.contains(where: { $0.id == "auto" })
    }

    var body: some View {
        AgentChoiceSheet(
            icon: showingAutoGuide ? "sparkles" : (effortTarget != nil ? "speedometer" : "cpu"),
            tint: showingAutoGuide ? DS.Palette.ultracode : DS.Palette.accent,
            title: showingAutoGuide ? AgentAutoGuide.title : (effortTarget != nil ? "Main effort" : "Main model"),
            subtitle: showingAutoGuide ? AgentAutoGuide.subtitle
                : (effortTarget.map { "\($0.modelTitle) · how much it thinks before answering." } ?? "Leads the conversation: plans, reviews and answers."),
            width: 600,
            accessibilityIdentifier: identifier,
            onClose: close
        ) {
            if showingAutoGuide, let makeGuide = AgentAutoGuide.makeGuide {
                makeGuide(close)
            } else if let target = effortTarget {
                AgentDistillEffortStep(
                    efforts: target.efforts,
                    selection: mainEffortSelection,
                    isDisabled: isDisabled,
                    identifierPrefix: "agent.distill.mainEffort",
                    includesAuto: supportsMainEffortAuto,
                    onSelect: { selection in
                        onSelectMainEffort(selection)
                        close()
                    }
                )
            } else {
                if isRunning {
                    AgentChoiceCallout(icon: "info.circle", tint: DS.Palette.textSecondary, text: "Read-only while a run is active.")
                }
                statusHeader
                if hasAutoOption {
                    autoCard
                }
                if mainUnavailable && mainModel != "auto" {
                    AgentChoiceCallout(
                        icon: "exclamationmark.triangle.fill",
                        tint: DS.Palette.warning,
                        text: "Selected Main model unavailable: \(mainModel). Choose a model below or add it as Custom."
                    )
                }
                modelsSection
                if mainModel != "auto", !currentModelEfforts.isEmpty {
                    effortSummaryRow
                }
            }
        } footer: {
            if showingAutoGuide {
                agentDistillBackToModels { showingAutoGuide = false }
                Spacer()
            } else if effortTarget != nil {
                agentDistillBackToModels { effortTarget = nil }
                Spacer()
            }
            agentDistillDoneButton(close)
        }
    }

    @ViewBuilder
    private var autoCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            AgentChoiceCard(
                title: "Auto",
                subtitle: catalogAdvertisesAuto
                    ? "Picks the best account and model for each turn from your Auto profile."
                    : "Set up a profile before choosing Auto for this conversation.",
                badge: catalogAdvertisesAuto ? "Recommended" : "Set up",
                selected: mainModel == "auto",
                tint: DS.Palette.ultracode,
                disabledReason: agentDistillDisabledReason(isDisabled),
                action: { selectAuto() }
            ) {
                AgentChoiceIconTile(systemName: "sparkles", tint: DS.Palette.ultracode, size: 34)
            }
            if mainModel == "auto", AgentAutoGuide.makeGuide != nil {
                HStack {
                    Spacer()
                    Button("How Auto is set up →") { showingAutoGuide = true }
                        .buttonStyle(.plain)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.accent)
                }
            }
        }
    }

    @ViewBuilder
    private var modelsSection: some View {
        AgentChoiceSectionHeader("Models") {
            Text("\(models.count + customMainModels.count)")
                .font(DS.Font.caption2)
                .foregroundStyle(DS.Palette.textSecondary)
        }
        AgentDistillChoiceGrid(
            models: models,
            customModels: customMainModels,
            selectedId: mainModel,
            isDisabled: isDisabled,
            emptyTitle: emptyListTitle,
            searchIdentifier: "agent.distill.mainModel.search",
            onSelectModel: { id in
                let descriptor = models.first { $0.id == id }
                let efforts = descriptor?.supportedReasoningEfforts ?? []
                let normalizedSelection = mainEffortSelection.normalized(
                    for: efforts,
                    supportsAutomatic: supportsMainEffortAuto
                )
                if normalizedSelection != mainEffortSelection {
                    onSelectMainEffort(normalizedSelection)
                }
                onSelectMainModel(id)
                if efforts.isEmpty {
                    close()
                } else {
                    effortTarget = AgentDistillEffortTarget(
                        modelTitle: AgentDistillModelCatalog.shortLabel(descriptor?.label ?? id),
                        efforts: efforts
                    )
                }
            },
            onSelectCustomModel: { model in
                onSelectCustomMainModel(model)
                close()
            }
        )
        mainFooter
    }

    /// Efforts advertised by the selected model's own descriptor.
    private var currentModelEfforts: [AgentReasoningEffort] {
        mainModels.first { $0.id == mainModel }?.supportedReasoningEfforts ?? []
    }

    private var effortSummaryRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            AgentChoiceSectionHeader("Effort")
            AgentChoiceCard(
                title: "Main effort",
                subtitle: "Change how much the selected model thinks.",
                badge: mainEffortSelection.pickerDisplayName,
                selected: false,
                disabledReason: agentDistillDisabledReason(isDisabled),
                accessibilityIdentifier: "agent.distill.mainEffort.change",
                action: {
                    effortTarget = AgentDistillEffortTarget(
                        modelTitle: AgentDistillModelCatalog.shortLabel(
                            mainModels.first { $0.id == mainModel }?.label ?? mainModel
                        ),
                        efforts: currentModelEfforts
                    )
                }
            ) {
                AgentChoiceIconTile(systemName: "speedometer", size: 30)
            }
        }
    }

    /// Selecting Auto applies it at once and turns the shared profile on; the guide opens only when it still needs setup.
    private func selectAuto() {
        onSelectMainModel("auto")
        if catalogAdvertisesAuto {
            // The catalog can be stale after another client turned Auto off; re-enable without blocking.
            if let enableProfile = AgentAutoGuide.enableProfile { Task { @MainActor in _ = await enableProfile() } }
            close()
        } else if let enableProfile = AgentAutoGuide.enableProfile {
            Task { @MainActor in
                if await enableProfile() {
                    close()
                } else if AgentAutoGuide.makeGuide != nil {
                    showingAutoGuide = true
                }
            }
        } else if AgentAutoGuide.makeGuide != nil {
            showingAutoGuide = true
        } else {
            close()
        }
    }
}

private struct AgentDistillWorkerModelSheet<StatusHeader: View>: View {
    let mainModel: String
    let reasoningModel: String?
    let reasoningModels: [AgentModelDescriptor]
    let reasoningEffortSelection: AgentEffortSelection
    let reasoningEfforts: [AgentReasoningEffort]
    let supportsReasoningModelEffort: Bool
    let configWorkerSummary: String?
    let isRunning: Bool
    let isDisabled: Bool
    let emptyListTitle: String
    let identifier: String
    let statusHeader: StatusHeader
    @Binding var showingAutoGuide: Bool
    let onSelectWorkerModel: (String?) -> Void
    let onSelectWorkerEffort: (AgentEffortSelection) -> Void
    let close: () -> Void
    @State private var effortTarget: AgentDistillEffortTarget?

    private var models: [AgentModelDescriptor] {
        AgentDistillModelCatalog.concreteWorkerModels(reasoningModels)
    }

    private var reasoningUnavailable: Bool {
        AgentDistillModelCatalog.workerUnavailable(reasoningModel: reasoningModel, models: models)
    }

    var body: some View {
        AgentChoiceSheet(
            icon: showingAutoGuide ? "sparkles" : (effortTarget != nil ? "speedometer" : "person.2.wave.2"),
            tint: showingAutoGuide ? DS.Palette.ultracode : DS.Palette.accent,
            title: showingAutoGuide ? AgentAutoGuide.title : (effortTarget != nil ? "Worker effort" : "Worker model"),
            subtitle: showingAutoGuide ? AgentAutoGuide.subtitle
                : (effortTarget.map { "\($0.modelTitle) · how much it thinks before answering." } ?? "Runs the tasks Main delegates."),
            width: 600,
            accessibilityIdentifier: identifier,
            onClose: close
        ) {
            if showingAutoGuide, let makeGuide = AgentAutoGuide.makeGuide {
                makeGuide(close)
            } else if let target = effortTarget {
                AgentDistillEffortStep(
                    efforts: target.efforts,
                    selection: reasoningEffortSelection,
                    isDisabled: isDisabled,
                    identifierPrefix: "agent.distill.reasoningEffort",
                    includesAuto: true,
                    onSelect: { selection in
                        onSelectWorkerEffort(selection)
                        close()
                    }
                )
            } else {
                if isRunning {
                    AgentChoiceCallout(icon: "info.circle", tint: DS.Palette.textSecondary, text: "Read-only while a run is active.")
                }
                statusHeader
                if mainModel == "auto" {
                    autoContent
                } else if let configWorkerSummary {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(configWorkerSummary)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.text)
                        Text("Update Distill to choose a Worker per conversation.")
                            .font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textSecondary)
                    }
                } else {
                    workerContent
                }
            }
        } footer: {
            if showingAutoGuide {
                agentDistillBackToModels { showingAutoGuide = false }
                Spacer()
            } else if effortTarget != nil {
                agentDistillBackToModels { effortTarget = nil }
                Spacer()
            }
            agentDistillDoneButton(close)
        }
    }

    @ViewBuilder
    private var autoContent: some View {
        AgentChoiceCallout(
            icon: "sparkles",
            tint: DS.Palette.ultracode,
            text: "Worker follows your Auto profile. Each Auto option pairs a Main and a Worker model."
        )
        if AgentAutoGuide.makeGuide != nil {
            Button("Open Auto guide") { showingAutoGuide = true }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var workerContent: some View {
        if reasoningUnavailable, let reasoningModel {
            AgentChoiceCallout(
                icon: "exclamationmark.triangle.fill",
                tint: DS.Palette.warning,
                text: "Selected Worker model unavailable: \(reasoningModel). Choose Off or a model below."
            )
        }
        AgentChoiceCard(
            title: "Off",
            subtitle: "Main does all the work",
            selected: reasoningModel == nil,
            disabledReason: agentDistillDisabledReason(isDisabled),
            action: {
                onSelectWorkerModel(nil)
                close()
            }
        ) {
            AgentChoiceIconTile(systemName: "minus.circle", tint: DS.Palette.textSecondary, size: 34)
        }
        .help("Run without a separate reasoning model")
        AgentChoiceSectionHeader("Models") {
            Text("\(models.count)")
                .font(DS.Font.caption2)
                .foregroundStyle(DS.Palette.textSecondary)
        }
        AgentDistillChoiceGrid(
            models: models,
            customModels: [],
            selectedId: reasoningModel,
            isDisabled: isDisabled,
            emptyTitle: emptyListTitle,
            searchIdentifier: "agent.distill.reasoningModel.search",
            onSelectModel: { id in
                onSelectWorkerModel(id)
                let descriptor = models.first { $0.id == id }
                let efforts = descriptor?.supportedReasoningEfforts ?? []
                if !supportsReasoningModelEffort || efforts.isEmpty {
                    close()
                } else {
                    effortTarget = AgentDistillEffortTarget(
                        modelTitle: AgentDistillModelCatalog.shortLabel(descriptor?.label ?? id),
                        efforts: efforts
                    )
                }
            },
            onSelectCustomModel: { _ in }
        )
        if supportsReasoningModelEffort, let reasoningModel, !reasoningEfforts.isEmpty {
            AgentChoiceSectionHeader("Effort")
            AgentChoiceCard(
                title: "Worker effort",
                subtitle: "Change how much the selected Worker thinks.",
                badge: reasoningEffortSelection.pickerDisplayName,
                selected: false,
                disabledReason: agentDistillDisabledReason(isDisabled),
                accessibilityIdentifier: "agent.distill.reasoningEffort.change",
                action: {
                    effortTarget = AgentDistillEffortTarget(
                        modelTitle: AgentDistillModelCatalog.shortLabel(
                            models.first { $0.id == reasoningModel }?.label ?? reasoningModel
                        ),
                        efforts: reasoningEfforts
                    )
                }
            ) {
                AgentChoiceIconTile(systemName: "speedometer", size: 30)
            }
        }
    }
}

public struct AgentDistillModelSelectors<MainFooter: View>: View {
    public let mainModel: String
    public let mainModels: [AgentModelDescriptor]
    public let customMainModels: [String]
    public let reasoningModel: String?
    public let reasoningModels: [AgentModelDescriptor]
    public let mainEffortSelection: AgentEffortSelection
    public let mainEfforts: [AgentReasoningEffort]
    public let reasoningEffortSelection: AgentEffortSelection
    public let reasoningEfforts: [AgentReasoningEffort]
    public let supportsMainEffortAuto: Bool
    public let supportsReasoningModelEffort: Bool
    public let configWorkerSummary: String?
    public let width: CGFloat?
    public let isDisabled: Bool
    public let onSelectMainModel: (String) -> Void
    public let onSelectReasoningModel: (String?) -> Void
    public let onSelectMainEffort: (AgentEffortSelection) -> Void
    public let onSelectReasoningEffort: (AgentEffortSelection) -> Void
    private let mainFooter: MainFooter

    public init(
        mainModel: String,
        mainModels: [AgentModelDescriptor],
        customMainModels: [String] = [],
        reasoningModel: String?,
        reasoningModels: [AgentModelDescriptor],
        mainEffortSelection: AgentEffortSelection = .automatic,
        mainEfforts: [AgentReasoningEffort] = [],
        reasoningEffortSelection: AgentEffortSelection = .automatic,
        reasoningEfforts: [AgentReasoningEffort] = [],
        supportsMainEffortAuto: Bool = false,
        supportsReasoningModelEffort: Bool = false,
        configWorkerSummary: String? = nil,
        width: CGFloat? = nil,
        isDisabled: Bool,
        onSelectMainModel: @escaping (String) -> Void,
        onSelectCustomMainModel: @escaping (String) -> Void,
        onSelectReasoningModel: @escaping (String?) -> Void,
        onSelectMainEffort: @escaping (AgentEffortSelection) -> Void = { _ in },
        onSelectReasoningEffort: @escaping (AgentEffortSelection) -> Void = { _ in },
        @ViewBuilder mainFooter: () -> MainFooter
    ) {
        self.mainModel = mainModel
        self.mainModels = mainModels
        self.customMainModels = customMainModels
        self.reasoningModel = reasoningModel
        self.reasoningModels = reasoningModels
        self.mainEffortSelection = mainEffortSelection
        self.mainEfforts = mainEfforts
        self.reasoningEffortSelection = reasoningEffortSelection
        self.reasoningEfforts = reasoningEfforts
        self.supportsMainEffortAuto = supportsMainEffortAuto
        self.supportsReasoningModelEffort = supportsReasoningModelEffort
        self.configWorkerSummary = configWorkerSummary
        self.onSelectMainEffort = onSelectMainEffort
        self.onSelectReasoningEffort = onSelectReasoningEffort
        self.width = width
        self.isDisabled = isDisabled
        self.onSelectMainModel = onSelectMainModel
        self.onSelectReasoningModel = onSelectReasoningModel
        self.mainFooter = mainFooter()
        self.onSelectCustomMainModel = onSelectCustomMainModel
    }

    private let onSelectCustomMainModel: (String) -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentDistillMainModelSection(
                mainModel: mainModel,
                mainModels: mainModels,
                customMainModels: customMainModels,
                reasoningModel: reasoningModel,
                mainEffortSelection: mainEffortSelection,
                mainEfforts: mainEfforts,
                supportsMainEffortAuto: supportsMainEffortAuto,
                width: width,
                isDisabled: isDisabled,
                onSelectMainModel: onSelectMainModel,
                onSelectCustomMainModel: onSelectCustomMainModel,
                onSelectMainEffort: onSelectMainEffort,
                footer: { mainFooter }
            )
            AgentCompactMenuDivider(width: width)
            AgentDistillReasoningModelSection(
                mainModel: mainModel,
                reasoningModel: reasoningModel,
                reasoningModels: reasoningModels,
                reasoningEffortSelection: reasoningEffortSelection,
                reasoningEfforts: reasoningEfforts,
                supportsReasoningModelEffort: supportsReasoningModelEffort,
                configWorkerSummary: configWorkerSummary,
                width: width,
                isDisabled: isDisabled,
                onSelectReasoningModel: onSelectReasoningModel,
                onSelectReasoningEffort: onSelectReasoningEffort
            )
        }
    }
}

public struct AgentModelPopoverChrome<ManualContent: View>: View {
    let presentation: AgentModelPopoverPresentation
    let autoEnabled: Binding<Bool>
    let toggleDisabled: Bool
    let showsAutoRouting: Bool
    let title: String
    let manualContent: ManualContent

    public init(
        presentation: AgentModelPopoverPresentation,
        autoEnabled: Binding<Bool>,
        toggleDisabled: Bool,
        showsAutoRouting: Bool = true,
        title: String = "Model",
        @ViewBuilder manualContent: () -> ManualContent
    ) {
        self.presentation = presentation
        self.autoEnabled = autoEnabled
        self.toggleDisabled = toggleDisabled
        self.showsAutoRouting = showsAutoRouting
        self.title = title
        self.manualContent = manualContent()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if showsAutoRouting {
                header
                Divider()
                    .accessibilityIdentifier("agent.model.auto.divider")
            } else if !title.isEmpty {
                Text(title)
                    .font(DS.Font.caption.weight(.medium))
                    .foregroundColor(DS.Palette.text)
            }
            if showsAutoRouting && presentation.showsDisclaimer {
                AgentModelAutoRoutingCard(presentation: presentation)
                    .transition(presentation.transition == .fadeAndSlide
                        ? .opacity.combined(with: .move(edge: .top))
                        : .identity)
            } else {
                manualContent
            }
        }
        .animation(
            presentation.transition == .fadeAndSlide
                ? .easeInOut(duration: 0.2)
                : nil,
            value: presentation.mode
        )
        .padding(DS.Space.sm)
        .background(DS.Palette.surfaceOverlay)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var header: some View {
        HStack(spacing: DS.Space.md) {
            Text("Model")
                .font(DS.Font.caption.weight(.medium))
                .foregroundColor(DS.Palette.text)
            Spacer(minLength: DS.Space.xxl)
            Text("Auto")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.text)
            if presentation.showsAutoLoadingIndicator {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading automatic routing")
                    .accessibilityIdentifier("agent.model.auto.loading")
            }
            Toggle("", isOn: autoEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DS.Palette.success)
                .disabled(toggleDisabled)
                .accessibilityLabel(presentation.accessibilityLabel)
                .accessibilityValue(presentation.accessibilityValue)
                .accessibilityHint(presentation.accessibilityHint)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
        }
    }
}
