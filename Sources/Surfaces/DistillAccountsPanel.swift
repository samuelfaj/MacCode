import SwiftUI
import AgentRuntime
import CoreModel
import DesignSystemKit

public enum DistillAccountsInstallState: Equatable {
    case unknown, installed, installing, failed(String)
}

public enum DistillRoutingValidation {
    public static func models(for account: DistillAccountStatus?, catalog: [AgentModelDescriptor]) -> [AgentModelDescriptor] {
        guard let account else { return [] }
        return catalog.filter { $0.id != "auto" && $0.accountProvider == account.provider.rawValue }
    }

    public static func error(_ draft: DistillAutoRouting, saved: DistillAutoRouting,
                             accounts: [DistillAccountStatus], models: [AgentModelDescriptor]) -> String? {
        // Disabling an unchanged saved profile must work even when its catalog is no longer available.
        if !draft.enabled, draft.strategy == saved.strategy, draft.options == saved.options { return nil }
        if draft.enabled && draft.options.isEmpty { return "Add an option before enabling Auto." }
        var ids = Set<String>()
        for option in draft.options {
            guard !option.id.isEmpty, ids.insert(option.id).inserted else { return "Each Auto option needs a unique identity." }
            guard let account = accounts.first(where: { $0.id == option.accountID }) else { return "Choose an existing account for every option." }
            let eligible = Self.models(for: account, catalog: models)
            guard eligible.contains(where: { $0.id == option.mainModel }),
                  option.workerModel == nil || eligible.contains(where: { $0.id == option.workerModel }) else {
                return "Choose available Main and Worker models from the selected account’s provider."
            }
        }
        return nil
    }
}

public struct DistillAccountsPanelPresentation: Equatable {
    public let installState: DistillAccountsInstallState
    public let statuses: [DistillAccountStatus]
    public let busyProvider: DistillAccountProvider?
    public let signInURL: URL?
    public let lastError: String?
    public let busyAccountID: String?
    public let isBusy: Bool
    public let routing: DistillAutoRouting
    public let models: [AgentModelDescriptor]
    public let routingLoaded: Bool
    public let isRefreshing: Bool

    public init(statuses: [DistillAccountStatus], busyProvider: DistillAccountProvider?, signInURL: URL?, lastError: String?, installState: DistillAccountsInstallState = .unknown,
                busyAccountID: String? = nil, isBusy: Bool = false, routing: DistillAutoRouting = .init(), models: [AgentModelDescriptor] = [], routingLoaded: Bool = true, isRefreshing: Bool = false) {
        self.installState = installState
        self.statuses = statuses
        self.busyProvider = busyProvider
        self.signInURL = signInURL
        self.lastError = lastError
        self.busyAccountID = busyAccountID
        self.isBusy = isBusy || busyProvider != nil
        self.routing = routing
        self.models = models
        self.routingLoaded = routingLoaded
        self.isRefreshing = isRefreshing
    }

    public static func quotaText(_ quota: DistillAccountQuota?) -> String {
        quotaPresentation(quota, connected: true, connectionError: nil).text
    }

    static func quotaPresentation(_ quota: DistillAccountQuota?, connected: Bool, connectionError: String?,
                                  now: Date = Date()) -> (text: String, remainingPercent: Double?) {
        guard let quota else { return ("Quota unknown", nil) }
        func date(_ timestamp: String?) -> Date? {
            guard let timestamp else { return nil }
            // CLI/chrono RFC3339 includes fractional seconds; older snapshots may omit them.
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return parser.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        }
        let remaining = quota.remainingPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        let value = remaining.map { "\(Int($0.rounded()))% remaining" } ?? "Remaining quota unknown"
        let fetched = date(quota.fetchedAt)
        let age = fetched.map { now.timeIntervalSince($0) }
        let fresh = age.map { (0...300).contains($0) } ?? false
        let current = quota.status == "available" && fresh && connected && connectionError == nil
        let updated = fetched.map { "Updated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Update time unknown"
        let future = (age ?? 0) < 0
        let freshness = fetched == nil || future ? "Quota freshness unknown" : (current ? "Saved quota" : "Stale")
        switch quota.status {
        case "available", "stale":
            return ("\(freshness) · \(value) · \(updated)\(future ? " (future timestamp)" : "")", current ? remaining : nil)
        case "loading": return ("Refreshing quota…", nil)
        case "unsupported": return ("Quota unavailable for this provider", nil)
        default:
            if quota.fetchedAt != nil {
                return ("\(freshness) · \(value) · \(updated)\(future ? " (future timestamp)" : "") · Refresh unavailable", nil)
            }
            let checked = date(quota.checkedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
            return ("Quota unavailable · Checked \(checked)", nil)
        }
    }
}

public struct DistillAccountsPanel: View {
    public let presentation: DistillAccountsPanelPresentation
    public let cancel: () -> Void
    public let openAgain: (URL) -> Void
    public let dismissError: () -> Void
    public let retryInstall: () -> Void
    public let refreshAccounts: () -> Void
    public let add: (DistillAccountProvider, String) -> Void
    public let rename: (String, String) -> Void
    public let connectAccount: (String) -> Void
    public let disconnectAccount: (String) -> Void
    public let remove: (String) -> Void
    public let refreshQuota: (String) -> Void
    public let saveRouting: (DistillAutoRouting) -> Void
    public let embedded: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var newProvider = DistillAccountProvider.chatgpt
    @State private var newLabel = ""
    @State private var showingAddAccount = false
    @State private var showingRouting = false
    @State private var renameAccount: DistillAccountStatus?
    @State private var renamedLabel = ""
    @State private var confirmation: DistillAccountStatus?
    @State private var removing = false
    @State private var draft: DistillAutoRouting?
    @State private var confirmingDiscard = false

    public init(presentation: DistillAccountsPanelPresentation,
                cancel: @escaping () -> Void, openAgain: @escaping (URL) -> Void, dismissError: @escaping () -> Void,
                retryInstall: @escaping () -> Void, refreshAccounts: @escaping () -> Void,
                add: @escaping (DistillAccountProvider, String) -> Void,
                rename: @escaping (String, String) -> Void, connectAccount: @escaping (String) -> Void,
                disconnectAccount: @escaping (String) -> Void, remove: @escaping (String) -> Void,
                refreshQuota: @escaping (String) -> Void, saveRouting: @escaping (DistillAutoRouting) -> Void,
                embedded: Bool = false) {
        self.presentation = presentation
        self.cancel = cancel
        self.openAgain = openAgain
        self.dismissError = dismissError
        self.retryInstall = retryInstall
        self.refreshAccounts = refreshAccounts
        self.add = add
        self.rename = rename
        self.connectAccount = connectAccount
        self.disconnectAccount = disconnectAccount
        self.remove = remove
        self.refreshQuota = refreshQuota
        self.saveRouting = saveRouting
        self.embedded = embedded
    }

    private var currentDraft: DistillAutoRouting { draft ?? presentation.routing }
    private var hasChanges: Bool { currentDraft != presentation.routing }
    private var validationError: String? {
        DistillRoutingValidation.error(currentDraft, saved: presentation.routing, accounts: presentation.statuses, models: presentation.models)
    }
    private var unavailable: Bool {
        if case .failed = presentation.installState { return true }
        return presentation.isBusy || presentation.installState == .installing || !presentation.routingLoaded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if !embedded {
                HStack {
                    Text("Accounts & Auto").font(DS.Font.title2)
                    Spacer()
                    Button("Done") {
                        if hasChanges { confirmingDiscard = true } else { dismiss() }
                    }.keyboardShortcut(.cancelAction).frame(minHeight: 44).disabled(presentation.isBusy)
                }
                .confirmationDialog("Discard unsaved profile changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button("Discard changes", role: .destructive) { draft = nil; dismiss() }
                    Button("Keep editing", role: .cancel) {}
                }
            }
            if embedded {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DS.Space.xl) {
                        accountsCard.frame(minWidth: 340, maxWidth: .infinity, alignment: .top)
                        routingCard.frame(minWidth: 340, maxWidth: .infinity, alignment: .top)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.lg) {
                        accountsCard
                        routingCard
                    }
                }
            } else {
                GeometryReader { proxy in
                    if proxy.size.width >= 720 {
                        HStack(alignment: .top, spacing: DS.Space.xl) {
                            ScrollView { accountsCard }
                            ScrollView { routingCard }
                        }
                    } else {
                        VStack(spacing: DS.Space.lg) {
                            Picker("Settings section", selection: $showingRouting) {
                                Text("Accounts").tag(false)
                                Text("Auto routing").tag(true)
                            }.pickerStyle(.segmented).labelsHidden()
                            ScrollView {
                                if showingRouting { routingCard } else { accountsCard }
                            }
                        }
                    }
                }
            }
            if let error = presentation.lastError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.warning)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    VStack {
                        Button("Refresh accounts", action: refreshAccounts).frame(minHeight: 44)
                        Button("Dismiss", action: dismissError).frame(minWidth: 44, minHeight: 44)
                    }
                }.padding(DS.Space.sm)
            }
            routingFooter
        }
        .font(DS.Font.body)
        .foregroundStyle(DS.Palette.text)
        .interactiveDismissDisabled(hasChanges || presentation.isBusy)
        .sheet(isPresented: $showingAddAccount) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                Text("Add account").font(DS.Font.title3)
                AgentChoiceSelectField(
                    caption: "PROVIDER",
                    options: DistillAccountProvider.allCases.map { (value: $0, title: $0.displayName, subtitle: nil) },
                    selection: $newProvider,
                    identifier: "agent.accounts.add.provider"
                )
                TextField("Account label", text: $newLabel).frame(minHeight: 44)
                    .accessibilityLabel("Account label")
                Text("Give this account a name, then connect to sign in.")
                    .foregroundStyle(DS.Palette.textSecondary)
                HStack {
                    Button("Cancel") { showingAddAccount = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Add account") {
                        add(newProvider, newLabel.trimmingCharacters(in: .whitespacesAndNewlines))
                        showingAddAccount = false
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(unavailable || newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.frame(minHeight: 44)
            }.padding(DS.Space.xxl).frame(minWidth: 300, idealWidth: 360, maxWidth: 360)
                .font(DS.Font.body).foregroundStyle(DS.Palette.text)
                .background(DS.Palette.bg)
        }
        .sheet(isPresented: Binding(get: { renameAccount != nil }, set: { if !$0 { renameAccount = nil } })) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text("Rename \(renameAccount?.provider.displayName ?? "account")").font(DS.Font.body)
                TextField("Account label", text: $renamedLabel).frame(minHeight: 44)
                HStack {
                    Button("Cancel") { renameAccount = nil }.keyboardShortcut(.cancelAction).frame(minHeight: 44)
                    Button("Save") {
                        if let account = renameAccount { rename(account.id, renamedLabel.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        renameAccount = nil
                    }.keyboardShortcut(.defaultAction).frame(minHeight: 44).disabled(renamedLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(DS.Space.md).frame(minWidth: 300)
                .font(DS.Font.body).foregroundStyle(DS.Palette.text)
                .background(DS.Palette.bg)
        }
        .confirmationDialog("\(removing ? "Remove" : "Disconnect") \(confirmation?.label ?? "account")?",
                            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            Button(removing ? "Remove account" : "Disconnect account", role: .destructive) {
                if let account = confirmation { if removing { remove(account.id) } else { disconnectAccount(account.id) } }
                confirmation = nil
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text("\(confirmation?.provider.displayName ?? "") · \(confirmation?.label ?? "")\n\(confirmation?.email ?? confirmation?.id ?? "")\nOnly this account is affected. Other accounts stay connected.")
        }
        .onChange(of: presentation.routing) { saved in if draft == saved { draft = nil } }
    }

    private var accountsCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(spacing: DS.Space.sm) {
                Text("Accounts").font(DS.Font.title3)
                Text("\(presentation.statuses.filter(\.connected).count)/\(presentation.statuses.count)")
                    .font(DS.Font.caption).monospacedDigit().foregroundStyle(DS.Palette.textTertiary)
                Spacer()
                if presentation.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: refreshAccounts) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh accounts")
                    .accessibilityLabel("Refresh accounts")
                    .disabled(presentation.isBusy)
                }
                Button { newLabel = ""; showingAddAccount = true } label: {
                    Label("Add", systemImage: "plus")
                }.buttonStyle(DSSecondaryButtonStyle()).disabled(unavailable)
            }
            Text("Sign in to the accounts Distill can use.")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            installNotice
            if presentation.statuses.isEmpty {
                VStack(spacing: DS.Space.sm) {
                    AgentChoiceIconTile(systemName: "person.crop.circle.badge.plus", tint: DS.Palette.accent, size: 36)
                    Text("No accounts yet. Add one to get started.")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.xl)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(presentation.statuses.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider() }
                        accountRow(account)
                    }
                }
                .background(DS.Palette.bg.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Palette.line, lineWidth: 0.5))
            }
        }.padding(DS.Space.xl).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surfaceRaised).clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Palette.line, lineWidth: 0.5))
            .accessibilityIdentifier("agent.accounts.card")
    }

    private func providerIcon(_ provider: DistillAccountProvider) -> String {
        switch provider {
        case .grok: return "sparkle"
        case .chatgpt: return "bubble.left.and.bubble.right"
        case .claude: return "asterisk"
        case .openrouter: return "arrow.triangle.branch"
        }
    }

    @ViewBuilder private var installNotice: some View {
        switch presentation.installState {
        case .installing:
            HStack { ProgressView().controlSize(.small); Text("Installing Distill…") }.accessibilityIdentifier("agent.accounts.install.progress")
        case .failed(let message):
            Text(message).foregroundStyle(DS.Palette.warning).textSelection(.enabled).accessibilityIdentifier("agent.accounts.install.failed")
            Button("Retry", action: retryInstall).frame(minHeight: 44).accessibilityIdentifier("agent.accounts.install.retry")
        case .unknown, .installed: EmptyView()
        }
    }

    private func accountRow(_ account: DistillAccountStatus) -> some View {
        let quota = DistillAccountsPanelPresentation.quotaPresentation(
            account.quota, connected: account.connected, connectionError: account.connectionError
        )
        return HStack(alignment: .center, spacing: DS.Space.md) {
            AgentChoiceIconTile(systemName: providerIcon(account.provider),
                                tint: account.connected ? DS.Palette.accent : DS.Palette.textTertiary, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.label).font(DS.Font.bodyStrong).lineLimit(1).textSelection(.enabled)
                    Text(account.provider.displayName).font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Circle().fill(account.connected ? DS.Palette.success : DS.Palette.textTertiary).frame(width: 6, height: 6)
                    Text(account.connected ? (account.email ?? "Connected") : "Not connected")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if let error = account.connectionError {
                    Text(error).font(DS.Font.caption).foregroundStyle(DS.Palette.warning).lineLimit(2)
                }
                if let remaining = quota.remainingPercent {
                    HStack(spacing: 6) {
                        ProgressView(value: remaining, total: 100)
                            .tint(remaining < 20 ? DS.Palette.warning : DS.Palette.accent)
                            .frame(maxWidth: 160)
                            .accessibilityLabel("Saved remaining quota")
                            .accessibilityValue("\(Int(remaining.rounded())) percent")
                        Text("\(Int(remaining.rounded()))% left")
                            .font(DS.Font.caption2).monospacedDigit().foregroundStyle(DS.Palette.textTertiary)
                    }
                } else if account.connected, !quota.text.isEmpty {
                    Text(quota.text).font(DS.Font.caption2).foregroundStyle(DS.Palette.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.sm)
            if presentation.busyAccountID == account.id {
                HStack(spacing: DS.Space.sm) {
                    ProgressView().controlSize(.small).accessibilityLabel("Account operation in progress")
                    if let url = presentation.signInURL { Button("Open again") { openAgain(url) }.buttonStyle(.borderless) }
                    Button("Cancel", action: cancel).buttonStyle(.borderless)
                }
            } else {
                HStack(spacing: DS.Space.sm) {
                    if !account.connected {
                        Button("Connect") { connectAccount(account.id) }.buttonStyle(DSPrimaryButtonStyle())
                    }
                    Menu {
                        Button("Refresh quota") { refreshQuota(account.id) }.disabled(!account.connected)
                        Button("Rename") { renamedLabel = account.label; renameAccount = account }
                        if account.connected || !account.legacy { Divider() }
                        if account.connected {
                            Button("Disconnect…", role: .destructive) { removing = false; confirmation = account }
                        }
                        // Distill refuses to remove a provider's default (legacy) account; Disconnect covers it.
                        if !account.legacy {
                            Button("Remove…", role: .destructive) { removing = true; confirmation = account }
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Account actions for \(account.provider.displayName) · \(account.label)")
                    .help("Actions for \(account.provider.displayName) · \(account.label)")
                }.disabled(unavailable)
            }
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain).accessibilityIdentifier("agent.accounts.\(account.id)")
    }

    private var routingCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack { Text("Auto routing").font(DS.Font.title3); Spacer() }
            DistillAutoRoutingEditor(
                draft: Binding(get: { currentDraft }, set: { draft = $0 }),
                saved: presentation.routing,
                statuses: presentation.statuses,
                models: presentation.models,
                disabled: unavailable
            )
        }.padding(DS.Space.xl).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surfaceRaised).clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .accessibilityIdentifier("agent.accounts.routing")
    }

    private var routingFooter: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Divider()
            HStack(spacing: DS.Space.lg) {
                Text(!presentation.routingLoaded ? "Loading saved profile…" :
                     (hasChanges ? "Unsaved changes" : "Saved profile · \(presentation.routing.enabled ? "Enabled" : "Disabled")"))
                    .foregroundStyle(hasChanges ? DS.Palette.warning : DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if presentation.isBusy, presentation.busyAccountID == nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Saving accounts or routing")
                }
                if hasChanges {
                    Button("Cancel") { draft = nil }.frame(minHeight: 44).disabled(unavailable)
                    Button("Save profile") { saveRouting(currentDraft) }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .disabled(unavailable || validationError != nil)
                }
            }
        }.accessibilityIdentifier("agent.accounts.routing.footer")
    }
}
