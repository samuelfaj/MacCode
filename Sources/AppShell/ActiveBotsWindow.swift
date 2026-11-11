import CoreModel
import DesignSystemKit
import Surfaces
import SwiftUI

public enum ActiveBotsTab: String, CaseIterable, Identifiable {
    case active
    case lastFinished

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .active: return L("Active")
        case .lastFinished: return L("Last Finished")
        }
    }
}

public struct ActiveBotScreenItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let botID: BotID
    public let title: String
    public let handle: String
    public let detail: String
    public let preview: String?
    public let symbol: String?
    public let startedAt: Date?

    public init(bot: BotDefinition, preview: String, providerName: String, startedAt: Date? = nil) {
        self.id = "active:\(bot.id.value.uuidString.lowercased())"
        self.botID = bot.id
        self.title = bot.name
        self.handle = bot.handle
        let job = bot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let handleLine = "@\(bot.handle)"
        if job.isEmpty {
            self.detail = "\(handleLine) · \(providerName)"
        } else {
            self.detail = "\(handleLine) · \(job) · \(providerName)"
        }
        let clean = MarkdownPlainText.firstLine(AgentReplyQuote.strippingQuote(preview))
        self.preview = clean.isEmpty || clean == L("No job yet") ? nil : clean
        self.symbol = bot.avatarSymbol
        self.startedAt = startedAt
    }

    public var lastTriggeredLabel: String {
        Self.timestampLabel(startedAt)
    }

    public var nextRunLabel: String { L("Running now") }

    static func timestampLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

public struct FinishedBotScreenItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let runID: AgentRunID
    public let botID: BotID
    public let title: String
    public let detail: String
    public let status: AgentRunStatus
    public let finishedAt: Date?
    public let startedAt: Date

    public init(run: AgentRun, bot: BotDefinition, conversationTitle: String) {
        self.id = "finished:\(run.id.value.uuidString.lowercased())"
        self.runID = run.id
        self.botID = bot.id
        let safeTitle = bot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = safeTitle.isEmpty ? L("Bot") : safeTitle
        let provider = PetActiveThreadProjector.providerLabel(run.provider)
        let model = run.model.isEmpty ? provider : "\(provider) · \(run.model)"
        let convo = conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = convo.isEmpty ? "@\(bot.handle) · \(model)" : "@\(bot.handle) · \(convo) · \(model)"
        self.status = run.status
        self.finishedAt = run.finishedAt
        self.startedAt = run.startedAt
    }

    public var lastTriggeredLabel: String {
        ActiveBotScreenItem.timestampLabel(finishedAt ?? startedAt)
    }

    public var nextRunLabel: String { "—" }
}

public struct ActiveBotsRootView: View {
    @ObservedObject private var vm: BotsViewModel

    public init(vm: BotsViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            overviewScreen
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.bg)
        .accessibilityIdentifier("bots.activeScreen")
        .onAppear { vm.scheduleActiveBotsFreshness() }
        .onChange(of: vm.activeBotsTab) { _ in
            vm.scheduleActiveBotsFreshness()
        }
    }

    private var overviewScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(L("Active Bots"))
                        .font(DS.Font.title.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    Text(vm.activeBotsSubtitle)
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.textSecondary)
                }
                Spacer(minLength: DS.Space.lg)
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

            content
        }
    }

    private var filterChips: some View {
        HStack(spacing: DS.Space.sm) {
            AgentListFilterChip(
                title: ActiveBotsTab.active.title,
                count: vm.filteredActiveBotItems().count,
                selected: vm.activeBotsTab == .active,
                identifier: "activeBots.tab.active"
            ) { vm.activeBotsTab = .active }
            AgentListFilterChip(
                title: ActiveBotsTab.lastFinished.title,
                count: vm.filteredFinishedBotItems().count,
                selected: vm.activeBotsTab == .lastFinished,
                identifier: "activeBots.tab.lastFinished"
            ) { vm.activeBotsTab = .lastFinished }
        }
        .accessibilityIdentifier("activeBots.statusFilter")
    }

    private var searchField: some View {
        AgentListSearchField(
            text: $vm.activeBotsSearchText,
            placeholder: L("Search bots"),
            identifier: "activeBots.search",
            accessibilityLabel: L("Search bots")
        )
        .accessibilityLabel(L("Search bots"))
    }

    @ViewBuilder
    private var content: some View {
        switch vm.activeBotsTab {
        case .active:
            activeList
        case .lastFinished:
            finishedList
        }
    }

    private var activeList: some View {
        let items = vm.filteredActiveBotItems()
        return Group {
            if items.isEmpty {
                DSEmptyState(
                    icon: "bolt.horizontal.circle",
                    title: vm.activeBotsSearchText.isEmpty ? L("No active bots") : L("No matching bots"),
                    subtitle: vm.activeBotsSearchText.isEmpty
                        ? L("Bot runs in progress will show up here with name and provider context.")
                        : L("Try another search or clear the status filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(items) { item in
                            ActiveBotCard(item: item) {
                                vm.openActiveBotItem(item)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
                .accessibilityIdentifier("activeBots.activeList")
            }
        }
    }

    private var finishedList: some View {
        let items = vm.filteredFinishedBotItems()
        return Group {
            if items.isEmpty {
                DSEmptyState(
                    icon: "checkmark.circle",
                    title: vm.activeBotsSearchText.isEmpty ? L("No recent finished runs") : L("No matching bots"),
                    subtitle: vm.activeBotsSearchText.isEmpty
                        ? L("Completed, failed, cancelled, and interrupted bot runs appear here.")
                        : L("Try another search or clear the status filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(items) { item in
                            FinishedBotCard(item: item) {
                                vm.openFinishedBotItem(item)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
                .accessibilityIdentifier("activeBots.finishedList")
            }
        }
    }

    private var footerBar: some View {
        AgentListFooterBar(
            caption: vm.activeBotsFooterLine,
            pillTitle: vm.activeBotCount > 0 ? L("Live") : L("Idle"),
            pillTone: vm.activeBotCount > 0 ? .warning : .neutral
        )
        .accessibilityLabel(vm.activeBotsFooterLine)
    }
}

struct ActiveBotCard: View {
    let item: ActiveBotScreenItem
    let onOpen: () -> Void

    var body: some View {
        AgentOverviewCard(
            icon: "bolt.fill",
            iconColor: DS.Palette.accent,
            title: item.title,
            subtitle: item.detail,
            identifier: "activeBots.active.\(item.botID.value.uuidString.lowercased())",
            onOpen: onOpen
        ) {
            DSPill(L("Running"), tone: .success)
        } meta: {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                AgentOverviewMetaColumn(title: L("Last Triggered"), value: item.lastTriggeredLabel)
                AgentOverviewMetaColumn(
                    title: L("Next Run"),
                    value: item.nextRunLabel,
                    valueColor: DS.Palette.warning
                )
            }
        } trailing: {
            Menu {
                Button(L("Open Desk"), action: onOpen)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(L("Bot actions"))
        }
    }
}

private struct FinishedBotCard: View {
    let item: FinishedBotScreenItem
    let onOpen: () -> Void

    var body: some View {
        AgentOverviewCard(
            icon: statusIcon,
            iconColor: statusColor,
            title: item.title,
            subtitle: item.detail,
            identifier: "activeBots.finished.\(item.runID.value.uuidString.lowercased())",
            onOpen: onOpen
        ) {
            statusPill
        } meta: {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                AgentOverviewMetaColumn(title: L("Last Triggered"), value: item.lastTriggeredLabel)
                AgentOverviewMetaColumn(title: L("Next Run"), value: item.nextRunLabel)
            }
        } trailing: {
            Menu {
                Button(L("Open Desk"), action: onOpen)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(L("Bot actions"))
        }
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
        case .completed: DSPill(L("Completed"), tone: .success)
        case .failed: DSPill(L("Failed"), tone: .danger)
        case .cancelled: DSPill(L("Cancelled"), tone: .neutral)
        case .interrupted: DSPill(L("Interrupted"), tone: .warning)
        case .pending: DSPill(L("Pending"), tone: .warning)
        case .running: DSPill(L("Running"), tone: .warning)
        }
    }
}

