import Foundation
import SwiftUI
import CoreModel
import AgentRuntime
import DesignSystemKit

/// One connected subscription account as a ring, so two
/// Claude logins show two rings.
public struct AccountUsageEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: DistillAccountProvider
    public let label: String
    public let email: String?
    public let usage: DistillAccountUsage?
    public let usageIsStale: Bool

    public init(id: String, provider: DistillAccountProvider, label: String, email: String? = nil, usage: DistillAccountUsage?, usageIsStale: Bool = false) {
        self.id = id; self.provider = provider; self.label = label; self.email = email; self.usage = usage
        self.usageIsStale = usageIsStale
    }

    /// Connected subscription accounts only, in the order Distill lists them.
    public static func entries(_ statuses: [DistillAccountStatus]) -> [AccountUsageEntry] {
        statuses.filter { $0.connected && $0.provider != .openrouter }.map {
            AccountUsageEntry(id: $0.id, provider: $0.provider, label: displayLabel($0), email: $0.email,
                              usage: DistillAccountUsage(quota: $0.quota),
                              usageIsStale: $0.quota?.status != "available")
        }
    }

    /// "claude (default)" reads as "Claude"; a named account keeps its name with the provider.
    static func displayLabel(_ status: DistillAccountStatus) -> String {
        let provider = status.provider.displayName
        let label = status.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.legacy || label.isEmpty || label.lowercased().hasPrefix(status.provider.rawValue) { return provider }
        return "\(provider) · \(label)"
    }
}

/// Pure copy for the sidebar's account-usage control. No UI state.
public enum AccountUsageDisplay {
    static let signedOutPrompt = "Sign in to track account usage"
    static let noAccountsPrompt = "Log in to an account in Settings › Accounts & Auto"

    /// Ring fill (0...1); nil means not loaded and must never draw as 0%.
    public static func ringProgress(_ entry: AccountUsageEntry) -> Double? {
        guard !entry.usageIsStale else { return nil }
        return entry.usage?.ringPercent.map { min(max($0 / 100.0, 0), 1) }
    }

    /// "Claude session 12%", "ChatGPT week 42%" or "Grok no usage data".
    static func ringCaption(_ entry: AccountUsageEntry) -> String {
        guard !entry.usageIsStale else { return "\(entry.label) usage unavailable" }
        if let weekly = entry.usage?.weeklyUsedPercent, weekly > (entry.usage?.sessionUsedPercent ?? -1) {
            return "\(entry.label) week \(formatPercent(weekly / 100))"
        }
        if let session = entry.usage?.sessionUsedPercent { return "\(entry.label) session \(formatPercent(session / 100))" }
        if let weekly = entry.usage?.weeklyUsedPercent { return "\(entry.label) week \(formatPercent(weekly / 100))" }
        return "\(entry.label) no usage data"
    }

    public static func ringsAccessibilityValue(signedIn: Bool, entries: [AccountUsageEntry]) -> String {
        guard signedIn else { return signedOutPrompt }
        guard !entries.isEmpty else { return noAccountsPrompt }
        return entries.map(ringCaption).joined(separator: ", ")
    }

    public static func ringsHelp(signedIn: Bool, entries: [AccountUsageEntry]) -> String {
        guard signedIn else { return signedOutPrompt }
        guard !entries.isEmpty else { return noAccountsPrompt }
        return (["Account usage"] + entries.map(ringCaption) + ["Click for details"]).joined(separator: "\n")
    }

    public static func sessionCaption(_ usage: DistillAccountUsage?) -> String {
        guard let session = usage?.sessionUsedPercent else { return "Session: no data" }
        return "Session used \(formatPercent(session / 100))"
    }

    public static func weeklyCaption(_ usage: DistillAccountUsage?) -> String {
        guard let weekly = usage?.weeklyUsedPercent else { return "Week: no data" }
        return "Week used \(formatPercent(weekly / 100))"
    }

    static func formatPercent(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }
}

/// Sidebar header control for account usage: one concentric ring per logged-in
/// account, left of the account avatar. Opening the details refreshes quotas.
struct AccountUsageSidebarControl: View {
    @ObservedObject var vm: SidebarViewModel
    let onOpenAccount: () -> Void
    let onOpenAccountsSettings: () -> Void
    @State private var showsDetails = false

    var body: some View {
        let signedIn = vm.privateAccountUser != nil
        let entries = vm.accountUsageEntries
        Button {
            guard signedIn else {
                onOpenAccount()
                return
            }
            if !showsDetails { vm.refreshAccountUsageForDetails() }
            showsDetails.toggle()
        } label: {
            AccountUsageRings(rings: signedIn ? entries.map { ($0.provider, AccountUsageDisplay.ringProgress($0)) } : [])
                .frame(width: 20, height: 20)
                .frame(width: 28, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(AccountUsageDisplay.ringsHelp(signedIn: signedIn, entries: entries))
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details }
        .accessibilityLabel("Account usage")
        .accessibilityValue(AccountUsageDisplay.ringsAccessibilityValue(signedIn: signedIn, entries: entries))
        .accessibilityHint(signedIn ? "Shows session and weekly limits for every subscription account" : "Opens your account")
        .accessibilityIdentifier("sidebar.accountUsage")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.xs) {
                Text("Account usage")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Spacer(minLength: 0)
                if vm.accountUsageIsRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                        .frame(width: 12, height: 12)
                        .accessibilityLabel("Refreshing usage data")
                        .accessibilityIdentifier("sidebar.accountUsage.refreshSpinner")
                }
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(vm.accountUsageRefreshError == nil
                         ? SidebarRootView.accountUsageLastUpdatedLabel(vm.accountUsageLastUpdated, now: timeline.date)
                         : "Usage refresh incomplete")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                .accessibilityIdentifier("sidebar.accountUsage.lastUpdated")
            }
            HStack(alignment: .top, spacing: DS.Space.xl) {
                VStack(alignment: .center, spacing: DS.Space.md) {
                    AccountUsageRings(rings: vm.accountUsageEntries.map { ($0.provider, AccountUsageDisplay.ringProgress($0)) })
                        .frame(width: 128, height: 128)
                    Text("One ring per subscription account, outer to inner in list order. Each ring shows the most-used limit. A faint ring means usage is unavailable.")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 148)
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    if vm.accountUsageEntries.isEmpty {
                        Text(AccountUsageDisplay.noAccountsPrompt)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(vm.accountUsageEntries.enumerated()), id: \.element.id) { index, entry in
                        accountRow(entry, index: index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = vm.accountUsageRefreshError {
                Text(error)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                showsDetails = false
                onOpenAccountsSettings()
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "person.2.badge.gearshape")
                        .accessibilityHidden(true)
                    Text("Accounts & Auto routing")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(DS.Font.caption2.weight(.semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(DSSecondaryButtonStyle())
            .accessibilityLabel("Accounts & Auto routing")
            .accessibilityIdentifier("sidebar.accountUsage.settings")
        }
        .padding(DS.Space.lg)
        .frame(width: 460, alignment: .leading)
        .background(DS.Palette.surface)
        .accessibilityIdentifier("sidebar.accountUsage.details")
    }

    private func accountRow(_ entry: AccountUsageEntry, index: Int) -> some View {
        let color = AccountUsageRings.color(for: entry.provider, index: index, in: vm.accountUsageEntries.map(\.provider))
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(entry.label)
                    .font(DS.Font.captionStrong)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let email = entry.email {
                Text(email).font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary).lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 12)
            }
            if entry.usageIsStale {
                Text(entry.usage == nil ? "Usage unavailable" : "Usage unavailable. Last known values:")
                    .font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary)
            }
            usageBar("Session", percent: entry.usage?.sessionUsedPercent, color: color, stale: entry.usageIsStale)
                .accessibilityLabel(AccountUsageDisplay.sessionCaption(entry.usage))
            usageBar("Week", percent: entry.usage?.weeklyUsedPercent, color: color, stale: entry.usageIsStale)
                .accessibilityLabel(AccountUsageDisplay.weeklyCaption(entry.usage))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.accountUsage.account.\(entry.id)")
    }

    /// "Session ▬▬▬── 75%"; a missing value shows "—" over an empty track, never 0%.
    private func usageBar(_ title: String, percent: Double?, color: Color, stale: Bool) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 48, alignment: .leading)
            Capsule()
                .fill(DS.Palette.line)
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    if let percent {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(stale ? color.opacity(0.35) : color)
                                .frame(width: proxy.size.width * min(max(percent / 100, 0), 1))
                        }
                    }
                }
            Text(percent.map { AccountUsageDisplay.formatPercent($0 / 100) } ?? "—")
                .font(DS.Font.caption)
                .foregroundColor(percent == nil ? DS.Palette.textTertiary : DS.Palette.textSecondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
    }
}

/// Concentric account rings, outer to inner in account order. Ring width shrinks
/// as accounts are added so every ring fits; same colors as the iOS rings.
struct AccountUsageRings: View {
    let rings: [(provider: DistillAccountProvider, progress: Double?)]

    static func baseColor(for provider: DistillAccountProvider) -> Color {
        switch provider {
        case .claude: return Color(nsColor: .systemOrange)
        case .chatgpt: return Color(nsColor: .systemBlue)
        case .grok: return Color(nsColor: .systemPurple)
        case .openrouter: return Color(nsColor: .systemTeal)
        }
    }

    /// A second account of the same provider gets a lighter shade so rings stay distinct.
    static func color(for provider: DistillAccountProvider, index: Int, in providers: [DistillAccountProvider]) -> Color {
        let repeatIndex = providers.prefix(index).filter { $0 == provider }.count
        return baseColor(for: provider).opacity(max(1 - Double(repeatIndex) * 0.3, 0.4))
    }

    var body: some View {
        GeometryReader { proxy in
            let side = max(min(proxy.size.width, proxy.size.height), 1)
            let count = max(rings.count, 1)
            let available = side / 2 - 1
            let lineWidth = max(min(available / CGFloat(count) * 0.62, side * 0.12), 1)
            let step = available / CGFloat(count)
            ZStack {
                if rings.isEmpty {
                    AccountUsageRing(progress: 0, color: DS.Palette.textTertiary, inset: 1 + lineWidth / 2, lineWidth: lineWidth, dimmed: true)
                }
                ForEach(Array(rings.enumerated()), id: \.offset) { index, ring in
                    AccountUsageRing(
                        progress: ring.progress ?? 0,
                        color: Self.color(for: ring.provider, index: index, in: rings.map(\.provider)),
                        inset: 1 + CGFloat(index) * step + lineWidth / 2,
                        lineWidth: lineWidth,
                        dimmed: ring.progress == nil
                    )
                }
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct AccountUsageRing: View {
    let progress: Double
    let color: Color
    let inset: CGFloat
    let lineWidth: CGFloat
    var dimmed: Bool = false

    var body: some View {
        ZStack {
            AccountUsageRingShape(progress: 1)
                .stroke(
                    color.opacity(dimmed ? 0.08 : 0.18),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            // Not loaded: faint track only — never paint a made-up fill.
            if !dimmed {
                AccountUsageRingShape(progress: progress)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
            }
        }
        .padding(inset)
    }
}

private struct AccountUsageRingShape: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bounded = min(max(progress, 0), 1)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(-88),
            endAngle: .degrees((360 * bounded) - 88),
            clockwise: false
        )
        return path
    }
}
