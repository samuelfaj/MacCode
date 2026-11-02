import AppKit
import SwiftUI
import AgentRuntime
import CoreModel
import DesignSystemKit
import Surfaces

/// Accounts & Auto lives inline in Settings: a summary line over the full
/// accounts and Auto routing editor. The Agent App and Bot Studio point here
/// instead of carrying their own entry.
struct DistillAccountsSettingsSection: View {
    @ObservedObject var controller: DistillAccountsController
    let loadModels: () async -> [AgentModelDescriptor]
    var showsSummary = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if showsSummary {
                Text(Self.summary(statuses: controller.statuses, routing: controller.routing, loaded: controller.hasLoadedState))
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings.accounts.summary")
            }
            DistillAccountsPanelHost(controller: controller, loadModels: loadModels, embedded: true)
        }
    }

    static func summary(statuses: [DistillAccountStatus], routing: DistillAutoRouting, loaded: Bool) -> String {
        let connected = statuses.filter(\.connected).count
        let accounts: String
        if statuses.isEmpty {
            accounts = loaded ? "No accounts yet" : "Loading accounts…"
        } else {
            accounts = "\(connected) of \(statuses.count) account\(statuses.count == 1 ? "" : "s") connected"
        }
        guard loaded else { return accounts }
        return accounts + " · Auto " + (routing.enabled ? "on (\(routing.options.count) option\(routing.options.count == 1 ? "" : "s"))" : "off")
    }
}

/// Collapsible Accounts & Auto editor for the new-conversation empty state.
/// Open until Auto routing is set up; the user's choice is remembered.
struct DistillAccountsInlineDisclosure: View {
    @ObservedObject var controller: DistillAccountsController
    let loadModels: () async -> [AgentModelDescriptor]
    @AppStorage("agent.emptyState.accountsExpanded") private var storedExpanded: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func defaultExpanded(loaded: Bool, routing: DistillAutoRouting) -> Bool {
        guard loaded else { return false }
        return !(routing.enabled && !routing.options.isEmpty)
    }

    private var expanded: Bool {
        storedExpanded ?? Self.defaultExpanded(loaded: controller.hasLoadedState, routing: controller.routing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            header
            if expanded {
                DistillAccountsPanelHost(controller: controller, loadModels: loadModels, embedded: true)
                    .transition(.opacity)
            }
        }
        .task { if !controller.hasLoadedState { controller.refresh() } }
    }

    private var header: some View {
        Button {
            withAnimation(reduceMotion ? nil : DS.Motion.standard) {
                storedExpanded = !expanded
            }
        } label: {
            HStack(spacing: DS.Space.lg) {
                AgentChoiceIconTile(systemName: "person.2.badge.gearshape", tint: DS.Palette.accent, size: 28)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("Accounts & Auto routing")
                        .font(DS.Font.bodyStrong)
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Text(DistillAccountsSettingsSection.summary(
                        statuses: controller.statuses, routing: controller.routing, loaded: controller.hasLoadedState
                    ))
                    .font(DS.Font.bodyDense)
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                }
                Spacer(minLength: DS.Space.md)
                VStack(spacing: DS.Space.xxs) {
                    Image(systemName: "chevron.right")
                        .font(DS.Font.captionStrong)
                        .foregroundColor(DS.Palette.textSecondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(reduceMotion ? nil : DS.Motion.micro, value: expanded)
                    Text(expanded ? "Hide" : "Show")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                }
                .accessibilityHidden(true)
            }
            .padding(DS.Space.lg)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.line, lineWidth: 0.5))
        .accessibilityLabel("Accounts and Auto routing")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides accounts and Auto routing")
        .accessibilityIdentifier("agent.accounts.inline.toggle")
    }
}

struct DistillAccountsPanelHost: View {
    @ObservedObject var controller: DistillAccountsController
    let loadModels: () async -> [AgentModelDescriptor]
    var embedded = false

    var body: some View {
        DistillAccountsPanel(
            presentation: DistillAccountsPanelPresentation(
                statuses: controller.statuses,
                busyProvider: controller.busyProvider,
                signInURL: controller.signInURL,
                lastError: controller.lastError,
                installState: {
                    switch controller.installState {
                    case .unknown: return .unknown
                    case .installed: return .installed
                    case .installing: return .installing
                    case .failed(let message): return .failed(message)
                    }
                }(),
                busyAccountID: controller.busyAccountID,
                isBusy: controller.isBusy,
                routing: controller.routing,
                models: controller.models,
                routingLoaded: controller.hasLoadedState,
                isRefreshing: controller.isRefreshing || controller.isRefreshingUsage
            ),
            cancel: controller.cancel,
            openAgain: { NSWorkspace.shared.open($0) },
            dismissError: controller.dismissError,
            retryInstall: controller.retryDistillInstall,
            refreshAccounts: { Task { await controller.refreshAllUsage() } },
            add: { controller.add(provider: $0, label: $1) },
            rename: { controller.rename(accountID: $0, label: $1) },
            connectAccount: { controller.login(accountID: $0) },
            disconnectAccount: { controller.logout(accountID: $0) },
            remove: { controller.remove(accountID: $0) },
            refreshQuota: { controller.refreshUsage(accountID: $0) },
            saveRouting: controller.saveRouting,
            embedded: embedded
        )
        .onAppear { if !embedded || !controller.hasLoadedState { controller.refresh() } }
        .task(id: controller.statuses.filter(\.connected).map(\.id) + [controller.routing.enabled ? "auto-enabled" : "auto-disabled"]) {
            _ = await loadModels()
        }
    }
}
