import AppKit
import SwiftUI
import AgentRuntime
import CoreModel
import DesignSystemKit
import Surfaces

/// First-run setup: six steps in one native window. Each step is one
/// decision on the left and a live illustration of its effect on the right.
struct OnboardingView: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var accounts: DistillAccountsController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(vm: OnboardingViewModel) {
        self.vm = vm
        self.accounts = vm.accounts
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStepper(current: vm.state.step, done: vm.state.completedSteps, reachable: vm.furthestReachable) { vm.jump(to: $0) }
                .padding(.horizontal, 40)
                .padding(.top, DS.Space.xxxl)
                .padding(.bottom, DS.Space.xl)
            Divider().overlay(DS.Palette.line)
            ZStack {
                stepContent
                    .id(vm.state.step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(reduceMotion ? .easeOut(duration: 0.16) : DS.Motion.standard, value: vm.state.step)
            if let error = vm.persistenceError {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
                    .padding(.bottom, DS.Space.md)
            }
        }
        .background(DS.Palette.bg)
        .preferredColorScheme(.dark)
        .onAppear { accounts.ensureDistillInstalled() }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        // The new step's parts stage themselves in; the old one leaves the
        // way the user is heading, faster than the entrance.
        let forward = vm.direction >= 0
        return .asymmetric(
            insertion: .opacity,
            removal: .opacity.combined(with: .offset(x: forward ? -16 : 16))
        )
    }

    @ViewBuilder private var stepContent: some View {
        switch vm.state.step {
        case .account: OnboardingAccountStep(vm: vm)
        case .jev: OnboardingJevStep(vm: vm, accounts: accounts)
        case .accounts: OnboardingProvidersStep(vm: vm, accounts: accounts)
        case .routing: OnboardingRoutingStep(vm: vm, accounts: accounts)
        case .bots: OnboardingBotsStep(vm: vm)
        case .workspace: OnboardingWorkspaceStep(vm: vm)
        }
    }
}

// MARK: - Shared layout

/// Decision column, illustration column, and a stable footer.
struct OnboardingStepLayout<Decision: View, Illustration: View, Footer: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder var decision: Decision
    @ViewBuilder var illustration: Illustration
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let wide = proxy.size.width >= 820
                ScrollView {
                    HStack(alignment: .center, spacing: 48) {
                        VStack(alignment: .leading, spacing: DS.Space.xxxl) {
                            VStack(alignment: .leading, spacing: DS.Space.lg) {
                                Text(eyebrow.uppercased())
                                    .font(DS.Font.captionStrong)
                                    .tracking(1.2)
                                    .foregroundColor(DS.Palette.accent)
                                    .onboardingReveal(0)
                                Text(title)
                                    .font(.system(size: 34, weight: .semibold))
                                    .tracking(-0.6)
                                    .foregroundColor(DS.Palette.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(.isHeader)
                                    .onboardingReveal(1)
                                Text(subtitle)
                                    .font(.system(size: 16))
                                    .foregroundColor(DS.Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .onboardingReveal(2)
                            }
                            decision
                                .onboardingReveal(3)
                        }
                        .frame(maxWidth: wide ? 440 : .infinity, alignment: .leading)
                        if wide {
                            illustration
                                .frame(maxWidth: .infinity)
                                .onboardingReveal(4, scale: true)
                        }
                    }
                    .padding(.horizontal, 48)
                    .padding(.vertical, 36)
                    .frame(minHeight: proxy.size.height)
                }
            }
            Divider().overlay(DS.Palette.line)
            HStack(spacing: DS.Space.lg) { footer }
                .padding(.horizontal, 32)
                .padding(.vertical, DS.Space.xl)
        }
    }
}

struct OnboardingBackButton: View {
    let vm: OnboardingViewModel
    var body: some View {
        if vm.state.step.previous != nil {
            Button { vm.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textSecondary)
                .keyboardShortcut("[", modifiers: .command)
        }
    }
}

struct OnboardingPrimaryButton: View {
    let title: String
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.md) {
                if busy { ProgressView().controlSize(.small) }
                Text(title)
            }
            .frame(minWidth: 140, minHeight: 22)
        }
        .buttonStyle(DSPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
    }
}

struct OnboardingStepper: View {
    let current: OnboardingStep
    let done: Set<OnboardingStep>
    let reachable: OnboardingStep
    let select: (OnboardingStep) -> Void

    var body: some View {
        HStack(spacing: DS.Space.md) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                let isDone = done.contains(step)
                let isCurrent = step == current
                Button { select(step) } label: {
                    HStack(spacing: DS.Space.sm) {
                        ZStack {
                            Circle()
                                .fill(isCurrent || isDone ? DS.Palette.accent : DS.Palette.surfaceRaised)
                                .overlay(Circle().strokeBorder(DS.Palette.lineStrong, lineWidth: isCurrent || isDone ? 0 : 1))
                            if isDone && !isCurrent {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            } else {
                                Text("\(step.index + 1)").font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .foregroundColor(isCurrent || isDone ? DS.Palette.onAccent : DS.Palette.textSecondary)
                        .frame(width: 20, height: 20)
                        Text(step.title)
                            .font(isCurrent ? DS.Font.bodyStrong : DS.Font.body)
                            .foregroundColor(isCurrent ? DS.Palette.text : DS.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .disabled(step.index > reachable.index)
                .accessibilityLabel("Step \(step.index + 1) of 6, \(step.title)\(isDone ? ", done" : "")")
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                if step != OnboardingStep.allCases.last {
                    Capsule()
                        .fill(isDone ? DS.Palette.accent.opacity(0.7) : DS.Palette.line)
                        .frame(height: 2)
                        .frame(minWidth: 12, maxWidth: .infinity)
                        .animation(DS.Motion.standard, value: isDone)
                }
            }
        }
    }
}

/// A raised panel used by the illustrations.
struct OnboardingPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(DS.Space.xxl)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous).strokeBorder(DS.Palette.line))
    }
}

struct OnboardingProviderRow: View {
    let provider: DistillAccountProvider
    let detail: String
    let state: OnboardingProviderRowState
    var connect: () -> Void = {}

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Palette.surfaceOverlay)
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: provider.onboardingSymbol).font(.system(size: 15, weight: .medium)).foregroundColor(DS.Palette.text))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(provider.displayName).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                Text(detail).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).lineLimit(2)
            }
            Spacer(minLength: DS.Space.md)
            switch state {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(DS.Font.captionStrong)
                    .foregroundColor(DS.Palette.success)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            case .waiting:
                HStack(spacing: DS.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for browser").font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                }
            case .available(let enabled):
                Button("Connect", action: connect)
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(!enabled)
                    .accessibilityLabel("Connect \(provider.displayName)")
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.lg)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(state == .connected ? DS.Palette.success.opacity(0.35) : DS.Palette.line)
        )
        .animation(DS.Motion.micro, value: state)
        .accessibilityElement(children: .contain)
    }
}

enum OnboardingProviderRowState: Equatable {
    case connected, waiting, available(Bool)
}

extension DistillAccountProvider {
    var onboardingSymbol: String {
        switch self {
        case .chatgpt: return "sparkles"
        case .claude: return "asterisk"
        case .grok: return "bolt.horizontal"
        case .openrouter: return "arrow.triangle.branch"
        }
    }
}

extension DistillAccountsController {
    func onboardingRowState(_ provider: DistillAccountProvider) -> OnboardingProviderRowState {
        let entries = statuses.filter { $0.provider == provider }
        if entries.contains(where: \.connected) { return .connected }
        if isBusy, let busy = busyAccountID, entries.contains(where: { $0.id == busy }) { return .waiting }
        return .available(!isBusy && installState == .installed)
    }

    /// Signs in the provider's first account, adding one when none exists.
    func onboardingConnect(_ provider: DistillAccountProvider) {
        if let entry = statuses.first(where: { $0.provider == provider }) {
            login(accountID: entry.id)
        } else {
            add(provider: provider, label: provider.displayName)
        }
    }
}

/// Browser sign-in in progress: reopen or cancel, plus the installer state.
struct OnboardingConnectionStatus: View {
    @ObservedObject var accounts: DistillAccountsController

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            switch accounts.installState {
            case .installing:
                Label("Installing Distill, the engine that runs your AI accounts…", systemImage: "arrow.down.circle")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
            case .failed(let message):
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Text(message).font(DS.Font.caption).foregroundColor(DS.Palette.danger).textSelection(.enabled)
                    Button("Try again") { accounts.retryDistillInstall() }.buttonStyle(DSSecondaryButtonStyle())
                }
            default: EmptyView()
            }
            if accounts.isBusy, accounts.busyAccountID != nil {
                HStack(spacing: DS.Space.md) {
                    Text("Finish signing in in your browser, then come back.")
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    Spacer()
                    if let url = accounts.signInURL {
                        Button("Open again") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                    }
                    Button("Cancel") { accounts.cancel() }.buttonStyle(.link)
                }
            }
            if let error = accounts.lastError {
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(DS.Palette.warning)
                    Text(error).font(DS.Font.caption).foregroundColor(DS.Palette.text).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { accounts.dismissError() }.buttonStyle(.link)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Titio's still frame. Setup avoids the animated pet: it would redraw
/// continuously behind a form the user is reading.
struct OnboardingTitioImage: View {
    let size: CGFloat
    var body: some View {
        Group {
            if let image = TitioBot.avatarImage {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
            } else {
                Image(systemName: "cat.fill").resizable().scaledToFit().foregroundColor(DS.Palette.text)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Motion

/// Rare, first-run motion: each step enters once in reading order
/// (eyebrow, title, text, choices, illustration). Footers never move.
enum OnboardingMotion {
    static func reveal(_ index: Int) -> Double { 0.06 + Double(index) * 0.07 }
    static let instant = Animation.easeOut(duration: 0.16)
}

struct OnboardingReveal: ViewModifier {
    let index: Int
    var scale = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .scaleEffect(shown || reduceMotion || !scale ? 1 : 0.97)
            .onAppear {
                withAnimation(reduceMotion ? OnboardingMotion.instant : DS.Motion.emphasized.delay(OnboardingMotion.reveal(index))) {
                    shown = true
                }
            }
    }
}

extension View {
    func onboardingReveal(_ index: Int, scale: Bool = false) -> some View {
        modifier(OnboardingReveal(index: index, scale: scale))
    }
}
