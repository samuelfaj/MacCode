import AppKit
import SwiftUI
import AgentRuntime
import CoreModel
import DesignSystemKit
import Surfaces

// MARK: 1 · Account

struct OnboardingAccountStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @FocusState private var focused: Field?
    private enum Field { case email, password }

    var body: some View {
        OnboardingStepLayout(
            eyebrow: "Step 1 of 7",
            title: vm.signedInEmail == nil ? (vm.creatingAccount ? "Create your account." : "Your next project starts here.") : "You're signed in.",
            subtitle: vm.signedInEmail == nil
                ? "One MacCode account links this Mac, your iPhone and your settings."
                : "Signed in as \(vm.signedInEmail ?? ""). Continue, or switch accounts in Settings later."
        ) {
            if vm.signedInEmail == nil { form }
        } illustration: {
            OnboardingWorkspacePreview(highlightSidebar: false)
        } footer: {
            Spacer()
            if vm.signedInEmail == nil {
                Button("Skip for now") { vm.skip(.account) }.buttonStyle(.link)
                    .accessibilityHint("Continue without an account. Remote access needs one later.")
            } else {
                OnboardingPrimaryButton(title: "Continue") { vm.advance(completing: .account) }
            }
        }
        .onAppear { if vm.signedInEmail == nil { focused = .email } }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            labeledField("Email") {
                TextField("you@example.com", text: $vm.email)
                    .textContentType(.username)
                    .focused($focused, equals: .email)
                    .onSubmit { focused = .password }
            }
            labeledField("Password") {
                SecureField(vm.creatingAccount ? "At least 8 characters" : "Password", text: $vm.password)
                    .textContentType(vm.creatingAccount ? .newPassword : .password)
                    .focused($focused, equals: .password)
                    .onSubmit { Task { await vm.submitAccount() } }
            }
            if let error = vm.accountError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Button {
                Task { await vm.submitAccount() }
            } label: {
                HStack(spacing: DS.Space.md) {
                    if vm.accountBusy { ProgressView().controlSize(.small) }
                    Text(vm.creatingAccount ? "Create account" : "Sign in")
                }
                .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(!vm.accountFormValid || vm.accountBusy)
            .keyboardShortcut(.defaultAction)
            Button(vm.creatingAccount ? "I already have an account" : "Create an account") {
                vm.creatingAccount.toggle()
            }
            .buttonStyle(.link)
            .frame(maxWidth: .infinity)
        }
    }

    private func labeledField<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(label).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
            field()
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, DS.Space.lg)
                .frame(height: 38)
                .background(DS.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Palette.lineStrong))
                .accessibilityLabel(label)
        }
    }
}

// MARK: 2 · Jev

struct OnboardingJevStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var accounts: DistillAccountsController

    private var connected: Bool { accounts.onboardingRowState(.openrouter) == .connected }

    var body: some View {
        OnboardingStepLayout(
            eyebrow: "Step 2 of 7 · Jev",
            title: "Less noise in every prompt.",
            subtitle: "Jev decides what each step needs to read and drops the rest, so agents spend fewer tokens on irrelevant context. Savings vary by task."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    bullet("line.3.horizontal.decrease", "Picks the relevant files, logs and tool output for each step.")
                    bullet("lock.shield", "It only advises. Permissions still decide what an agent may do.")
                    bullet("creditcard", "Jev runs through your OpenRouter key. OpenRouter bills those calls separately.")
                }
                OnboardingProviderRow(
                    provider: .openrouter,
                    detail: "Sign in with your browser. Your key stays on this Mac.",
                    state: accounts.onboardingRowState(.openrouter)
                ) { accounts.onboardingConnect(.openrouter) }
                OnboardingConnectionStatus(accounts: accounts)
            }
        } illustration: {
            OnboardingJevIllustration()
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            if connected {
                OnboardingPrimaryButton(title: "Continue") { vm.advance(completing: .jev) }
            } else {
                Button("Set up later") { vm.skip(.jev) }.buttonStyle(.link)
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            Image(systemName: symbol).foregroundColor(DS.Palette.accent).frame(width: 18).accessibilityHidden(true)
            Text(text).font(DS.Font.body).foregroundColor(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Tool output flows into Jev; only the relevant lanes reach the prompt.
struct OnboardingJevIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filtered = false

    private let lanes: [(String, String, Bool)] = [
        ("doc.text", "Build log · 4,812 lines", false),
        ("chevron.left.forwardslash.chevron.right", "Files you're changing", true),
        ("book", "Unrelated docs", false),
        ("checklist", "Failing test output", true),
        ("bubble.left", "Old chat history", false),
        ("gearshape", "Project config", true),
    ]

    var body: some View {
        OnboardingPanel {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                HStack {
                    Text("Tool output").font(DS.Font.captionStrong).foregroundColor(DS.Palette.textSecondary)
                    Spacer()
                    Text(filtered ? "Sent to the model" : "Before Jev")
                        .font(DS.Font.captionStrong)
                        .foregroundColor(filtered ? DS.Palette.accent : DS.Palette.textTertiary)
                        .contentTransition(.opacity)
                }
                ForEach(Array(lanes.enumerated()), id: \.offset) { index, lane in
                    HStack(spacing: DS.Space.lg) {
                        Image(systemName: lane.0).frame(width: 16)
                        Text(lane.1).font(DS.Font.body)
                        Spacer()
                        if filtered && lane.2 {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(DS.Palette.accent)
                        }
                    }
                    .foregroundColor(filtered && !lane.2 ? DS.Palette.textTertiary : DS.Palette.text)
                    .padding(.horizontal, DS.Space.lg)
                    .frame(height: 36)
                    .background(filtered && lane.2 ? DS.Palette.selection : DS.Palette.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .opacity(filtered && !lane.2 ? 0.45 : 1)
                    .offset(x: filtered && lane.2 && !reduceMotion ? 8 : 0)
                    .scaleEffect(filtered && !lane.2 && !reduceMotion ? 0.98 : 1, anchor: .leading)
                    .animation(reduceMotion ? OnboardingMotion.instant : DS.Motion.emphasized.delay(Double(index) * 0.05), value: filtered)
                    .onboardingReveal(5 + index)
                }
                Text("Illustration, not a measurement.").font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary)
            }
        }
        .frame(maxWidth: 380)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Illustration: of six kinds of tool output, Jev keeps the three relevant ones.")
        .task {
            // After the lanes have arrived, Jev filters once.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            filtered = true
        }
        .onTapGesture { filtered.toggle() }
    }
}

// MARK: 3 · AI accounts

struct OnboardingProvidersStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var accounts: DistillAccountsController

    private let providers: [(DistillAccountProvider, String)] = [
        (.chatgpt, "ChatGPT Plus, Pro or Team"),
        (.claude, "Claude Pro or Max"),
        (.grok, "SuperGrok or X Premium"),
    ]

    private var anyConnected: Bool {
        providers.contains { accounts.onboardingRowState($0.0) == .connected }
    }

    var body: some View {
        OnboardingStepLayout(
            eyebrow: "Step 3 of 7 · AI accounts",
            title: "Your AI subscriptions. One place.",
            subtitle: "Connect only the plans you already pay for. Agents use them directly; nothing is billed by MacCode."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                ForEach(providers, id: \.0) { provider, detail in
                    OnboardingProviderRow(provider: provider, detail: detail, state: accounts.onboardingRowState(provider)) {
                        accounts.onboardingConnect(provider)
                    }
                }
                OnboardingConnectionStatus(accounts: accounts)
                Text("Sign-in happens in your browser. Disconnect any account in Settings ▸ Accounts & Auto.")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
            }
        } illustration: {
            OnboardingHubIllustration(connected: providers.map(\.0).filter { accounts.onboardingRowState($0) == .connected })
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            if anyConnected {
                OnboardingPrimaryButton(title: "Continue") { vm.advance(completing: .accounts) }
            } else {
                Button("Do this later") { vm.skip(.accounts) }.buttonStyle(.link)
            }
        }
        .task { accounts.refresh() }
    }
}

struct OnboardingHubIllustration: View {
    let connected: [DistillAccountProvider]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let all: [DistillAccountProvider] = [.chatgpt, .claude, .grok]

    var body: some View {
        OnboardingPanel {
            HStack(spacing: 28) {
                RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
                    .fill(DS.Palette.surfaceRaised)
                    .frame(width: 64, height: 64)
                    .overlay(Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 22, weight: .semibold)).foregroundColor(DS.Palette.accent))
                VStack(spacing: DS.Space.lg) {
                    ForEach(Array(all.enumerated()), id: \.element) { index, provider in
                        let on = connected.contains(provider)
                        HStack(spacing: DS.Space.md) {
                            ZStack(alignment: .leading) {
                                Capsule().fill(DS.Palette.line).frame(width: 36, height: 2)
                                Capsule().fill(DS.Palette.accent).frame(width: 36, height: 2)
                                    .scaleEffect(x: on ? 1 : 0.001, anchor: .leading)
                            }
                            Image(systemName: provider.onboardingSymbol)
                            Text(provider.displayName).font(DS.Font.bodyStrong)
                            Spacer()
                            Circle().fill(on ? DS.Palette.success : DS.Palette.lineStrong).frame(width: 7, height: 7)
                        }
                        .foregroundColor(on ? DS.Palette.text : DS.Palette.textSecondary)
                        .padding(.horizontal, DS.Space.lg)
                        .frame(width: 210, height: 44)
                        .background(DS.Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                            .strokeBorder(on ? DS.Palette.accent.opacity(0.6) : DS.Palette.line))
                        .scaleEffect(on && !reduceMotion ? 1.02 : 1)
                        .animation(reduceMotion ? OnboardingMotion.instant : DS.Motion.emphasized, value: on)
                        .onboardingReveal(5 + index)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(connected.count) of 3 subscriptions connected.")
    }
}

// MARK: 4 · Auto

struct OnboardingRoutingStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var accounts: DistillAccountsController
    @State private var saving = false
    @State private var loaded = false

    var body: some View {
        OnboardingStepLayout(
            eyebrow: "Step 4 of 7 · Auto",
            title: "The right model, without choosing every time.",
            subtitle: "Auto picks a model from the accounts you connected. It applies to new conversations and Bots set to Auto."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                strategyCard(.orderedFirst, title: "Follow my order", detail: "Uses the first available option in the order below.", recommended: true)
                strategyCard(.highestRemaining, title: "Prefer remaining quota", detail: "Picks the account with the most known quota left.", recommended: false)
                if !loaded {
                    HStack(spacing: DS.Space.md) { ProgressView().controlSize(.small); Text("Reading your accounts and models…").font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary) }
                } else if let note = vm.routingNote {
                    Label(note, systemImage: "info.circle").font(DS.Font.body).foregroundColor(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    optionList
                }
                Text("Fine-tune accounts, models and order anytime in Settings ▸ Accounts & Auto.")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
            }
        } illustration: {
            OnboardingRoutingIllustration(options: vm.routingDraft.options, strategy: vm.routingDraft.strategy, accounts: accounts.statuses, models: accounts.models)
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            Button("Choose models myself") { vm.skip(.routing) }.buttonStyle(.link)
            if !vm.routingDraft.options.isEmpty {
                OnboardingPrimaryButton(title: "Use Auto", busy: saving) {
                    saving = true
                    Task { await vm.saveRouting(); saving = false }
                }
                .disabled(saving)
            }
        }
        .task {
            await vm.prepareRouting()
            loaded = true
        }
    }

    private func strategyCard(_ strategy: DistillAutoStrategy, title: String, detail: String, recommended: Bool) -> some View {
        let selected = vm.routingDraft.strategy == strategy
        return Button { vm.setStrategy(strategy) } label: {
            HStack(alignment: .top, spacing: DS.Space.lg) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? DS.Palette.accent : DS.Palette.textSecondary)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(spacing: DS.Space.md) {
                        Text(title).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                        if recommended {
                            Text("Recommended").font(DS.Font.caption2.weight(.semibold))
                                .padding(.horizontal, DS.Space.sm).padding(.vertical, 2)
                                .background(DS.Palette.selection).foregroundColor(DS.Palette.accent)
                                .clipShape(Capsule())
                        }
                    }
                    Text(detail).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                }
                Spacer()
            }
            .padding(DS.Space.lg)
            .contentShape(Rectangle())
            .background(selected ? DS.Palette.selection.opacity(0.6) : DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(selected ? DS.Palette.accent.opacity(0.7) : DS.Palette.line))
            .animation(DS.Motion.micro, value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var optionList: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("YOUR ORDER").font(DS.Font.captionStrong).tracking(1).foregroundColor(DS.Palette.textSecondary)
            ForEach(Array(vm.routingDraft.options.enumerated()), id: \.element.id) { index, option in
                let account = accounts.statuses.first { $0.id == option.accountID }
                HStack(spacing: DS.Space.lg) {
                    Text("\(index + 1)").font(DS.Font.monoStrong).foregroundColor(DS.Palette.textSecondary).frame(width: 14)
                    Text(account?.label ?? "Account").font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                    Spacer()
                    Text(accounts.models.first { $0.id == option.mainModel }?.label ?? option.mainModel)
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).lineLimit(1)
                }
                .padding(.horizontal, DS.Space.lg)
                .frame(height: 34)
                .background(DS.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            }
        }
    }
}

struct OnboardingRoutingIllustration: View {
    let options: [DistillAutoOption]
    let strategy: DistillAutoStrategy
    let accounts: [DistillAccountStatus]
    let models: [AgentModelDescriptor]

    var body: some View {
        OnboardingPanel {
            VStack(spacing: DS.Space.xl) {
                Label("Your task", systemImage: "text.cursor")
                    .font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                    .padding(.horizontal, DS.Space.xl).frame(height: 40)
                    .background(DS.Palette.surfaceRaised).clipShape(Capsule())
                Image(systemName: "arrow.down").foregroundColor(DS.Palette.textTertiary)
                    .onboardingReveal(6)
                Text(strategy == .orderedFirst ? "Auto · follow my order" : "Auto · most quota left")
                    .font(DS.Font.captionStrong).foregroundColor(DS.Palette.accent)
                    .id(strategy)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .animation(DS.Motion.standard, value: strategy)
                    .onboardingReveal(7)
                if options.isEmpty {
                    Text("Connect an account to see Auto choose.").font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                        .onboardingReveal(8)
                } else {
                    VStack(spacing: DS.Space.md) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            let chosen = index == 0
                            HStack {
                                Text(accounts.first { $0.id == option.accountID }?.label ?? "Account").font(DS.Font.bodyStrong)
                                Spacer()
                                if chosen { Image(systemName: "checkmark.circle.fill").foregroundColor(DS.Palette.accent) }
                            }
                            .foregroundColor(chosen ? DS.Palette.text : DS.Palette.textSecondary)
                            .padding(.horizontal, DS.Space.lg).frame(width: 240, height: 40)
                            .background(chosen ? DS.Palette.selection : DS.Palette.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                            .onboardingReveal(8 + index)
                        }
                    }
                    .animation(DS.Motion.standard, value: strategy)
                }
                Text("Preview. Auto checks availability on every run.").font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(options.isEmpty ? "Auto preview: no connected account yet." : "Auto preview: \(options.count) option\(options.count == 1 ? "" : "s"); the first available is used.")
    }
}

// MARK: 5 · Bots

struct OnboardingBotsStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        OnboardingStepLayout(
            eyebrow: "Step 5 of 7 · Bots",
            title: "You have a team. And Titio.",
            subtitle: "Bots are agents with a role, memory and their own conversations. Titio is your general assistant: it knows MacCode and can coordinate the others."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                Toggle(isOn: Binding(get: { vm.state.createDeveloper }, set: { vm.setCreateDeveloper($0) })) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Add a Developer Bot to my first project").font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                        Text("Reads code, plans changes and reviews. Only works in the project you pick next.")
                            .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityLabel("Add a Developer Bot to my first project")
                if vm.state.createDeveloper {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        Text("Name").font(DS.Font.captionStrong).foregroundColor(DS.Palette.textSecondary)
                        TextField("Developer", text: Binding(get: { vm.state.developerName }, set: { vm.setDeveloperName($0) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .accessibilityLabel("Developer Bot name")
                    }
                    .transition(.opacity)
                }
                Label("Runs on this Mac with your permissions. A project folder is context, not a sandbox.", systemImage: "info.circle")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .animation(reduceMotion ? nil : DS.Motion.standard, value: vm.state.createDeveloper)
        } illustration: {
            HStack(alignment: .center, spacing: DS.Space.xxxl) {
                botCard(avatar: AnyView(OnboardingTitioImage(size: 44)), name: "Titio", role: "General assistant", delay: 0.35)
                if vm.state.createDeveloper {
                    botCard(avatar: AnyView(Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 22, weight: .semibold)).foregroundColor(DS.Palette.accent)),
                            name: vm.state.developerName.isEmpty ? "Developer" : vm.state.developerName,
                            role: "Your project", delay: 0.5)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(reduceMotion ? nil : DS.Motion.emphasized, value: vm.state.createDeveloper)
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            OnboardingPrimaryButton(title: "Continue") { vm.advance(completing: .bots) }
        }
        .onAppear { arrived = true }
    }

    private func botCard(avatar: AnyView, name: String, role: String, delay: Double) -> some View {
        VStack(spacing: DS.Space.lg) {
            avatar.frame(width: 64, height: 64)
                .background(DS.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
            Text(name).font(DS.Font.title3).foregroundColor(DS.Palette.text).lineLimit(1)
            Text(role).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
        }
        .frame(width: 170, height: 170)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous).strokeBorder(DS.Palette.line))
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived || reduceMotion ? 0 : 14)
        .rotation3DEffect(.degrees(arrived || reduceMotion ? 0 : 8), axis: (x: 1, y: 0, z: 0), anchor: .bottom)
        .animation(reduceMotion ? OnboardingMotion.instant : DS.Motion.emphasized.delay(delay), value: arrived)
        .accessibilityElement(children: .combine)
    }
}

// MARK: 6 · Project

struct OnboardingWorkspaceStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @State private var dropTargeted = false

    var body: some View {
        OnboardingStepLayout(
            eyebrow: "Step 6 of 7 · Project",
            title: "Open something of yours.",
            subtitle: "Pick a project folder. MacCode opens it as a workspace\(vm.state.createDeveloper ? " with \(vm.state.developerName) ready" : "")."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                Button(action: pickFolder) {
                    VStack(spacing: DS.Space.lg) {
                        Image(systemName: vm.folder == nil ? "folder.badge.plus" : "folder.fill")
                            .font(.system(size: 30)).foregroundColor(DS.Palette.accent)
                        Text(vm.folder?.lastPathComponent ?? "Choose project folder")
                            .font(DS.Font.title3).foregroundColor(DS.Palette.text).lineLimit(1).truncationMode(.middle)
                        Text(vm.folder.map { ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath } ?? "or drop a folder here")
                            .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                    .contentShape(Rectangle())
                    .background(dropTargeted ? DS.Palette.selection : DS.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
                        .strokeBorder(dropTargeted || vm.folder != nil ? DS.Palette.accent : DS.Palette.lineStrong,
                                      style: StrokeStyle(lineWidth: 1, dash: vm.folder == nil ? [5, 4] : [])))
                    .animation(DS.Motion.micro, value: dropTargeted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(vm.folder.map { "Project folder \($0.lastPathComponent). Choose another." } ?? "Choose project folder")
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
                if vm.state.createDeveloper {
                    Label("The first message is a draft. Nothing runs until you send it.", systemImage: "paperplane")
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                }
                if let error = vm.finishError {
                    Label(error, systemImage: "exclamationmark.circle.fill").font(DS.Font.body).foregroundColor(DS.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } illustration: {
            OnboardingWorkspacePreview(highlightSidebar: vm.folder != nil, folderName: vm.folder?.lastPathComponent,
                                       botName: vm.state.createDeveloper ? vm.state.developerName : nil)
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            if vm.folder == nil {
                OnboardingPrimaryButton(title: "Choose folder", action: pickFolder)
            } else {
                OnboardingPrimaryButton(title: "Create workspace", busy: vm.finishing) { vm.finish() }
                    .disabled(vm.finishing)
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder to open as a workspace."
        // begin, not runModal: a modal loop would hold every main-actor RPC.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            vm.chooseFolder(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
            DispatchQueue.main.async { vm.chooseFolder(url) }
        }
        return true
    }
}

/// A miniature of the main window: sidebar with Titio and the project, and a
/// composer holding the first, unsent message.
struct OnboardingWorkspacePreview: View {
    var highlightSidebar: Bool
    var folderName: String? = nil
    var botName: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Characters of the first prompt shown; types in once, then stays.
    @State private var typed = 0

    private var prompt: String { OnboardingDeveloperTemplate.firstPrompt }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: DS.Space.sm) { Circle().fill(Color(hex: 0xFF5F57)); Circle().fill(Color(hex: 0xFEBC2E)); Circle().fill(Color(hex: 0x28C840)) }
                    .frame(height: 8).padding(.bottom, DS.Space.md)
                HStack(spacing: DS.Space.sm) {
                    OnboardingTitioImage(size: 16)
                    Text("Titio").font(DS.Font.caption)
                }
                .foregroundColor(DS.Palette.textSecondary)
                .onboardingReveal(6)
                Text("WORKSPACES").font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary).padding(.top, DS.Space.md)
                    .onboardingReveal(7)
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "folder.fill").font(.system(size: 10))
                    Text(folderName ?? "my-project").font(DS.Font.caption).lineLimit(1).truncationMode(.middle)
                }
                .foregroundColor(highlightSidebar ? DS.Palette.text : DS.Palette.textSecondary)
                .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
                .background(highlightSidebar ? DS.Palette.selection : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control))
                .scaleEffect(highlightSidebar && !reduceMotion ? 1.04 : 1, anchor: .leading)
                .animation(reduceMotion ? OnboardingMotion.instant : DS.Motion.emphasized, value: folderName)
                .onboardingReveal(8)
                Spacer()
            }
            .padding(DS.Space.lg)
            .frame(width: 130)
            .background(DS.Palette.surface)
            VStack(alignment: .leading, spacing: DS.Space.md) {
                ForEach(0..<4, id: \.self) { row in
                    Capsule().fill(DS.Palette.line).frame(width: CGFloat([170, 120, 150, 90][row]), height: 6)
                        .onboardingReveal(6 + row)
                }
                Spacer()
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Text(botName.map { "@\($0)  " } ?? "")
                        .font(DS.Font.caption2.weight(.semibold)).foregroundColor(DS.Palette.accent)
                    + Text(String(prompt.prefix(typed))).font(DS.Font.caption2).foregroundColor(DS.Palette.textSecondary)
                    + Text(String(prompt.dropFirst(typed))).font(DS.Font.caption2).foregroundColor(.clear)
                }
                .lineLimit(3)
                .padding(DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            }
            .padding(DS.Space.lg)
            .background(DS.Palette.bg)
        }
        .frame(width: 400, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous).strokeBorder(DS.Palette.lineStrong))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the MacCode window with your project and Titio in the sidebar.")
        .task {
            // One pass of typing, after the window has assembled. Hidden text
            // keeps the bubble's size fixed, so nothing reflows while typing.
            guard !reduceMotion else { typed = prompt.count; return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            while typed < prompt.count, !Task.isCancelled {
                typed = min(prompt.count, typed + 2)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }
}

// MARK: 7 · Follow

struct OnboardingFollowStep: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        OnboardingStepLayout(
            eyebrow: "Step 7 of 7 · Follow",
            title: "You're all set.",
            subtitle: "MacCode is built in the open. Follow along on X for releases, tips and what's coming next."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                Button { NSWorkspace.shared.open(OnboardingFollow.url) } label: {
                    HStack(spacing: DS.Space.md) {
                        Text("𝕏").font(.system(size: 20, weight: .bold)).foregroundColor(DS.Palette.text)
                            .frame(width: 40, height: 40)
                            .background(DS.Palette.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Samuel Fajreldines").font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                            Text(OnboardingFollow.handle).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                        }
                        Spacer()
                        Text("Open again").font(DS.Font.bodyStrong).foregroundColor(DS.Palette.accent)
                        Image(systemName: "arrow.up.right").foregroundColor(DS.Palette.accent).accessibilityHidden(true)
                    }
                    .padding(DS.Space.lg)
                    .background(DS.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Follow \(OnboardingFollow.handle) on X. Opens in your browser.")
                Label("Your project opens when you finish.", systemImage: "folder")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
            }
        } illustration: {
            OnboardingFollowIllustration(done: vm.state.completedSteps)
        } footer: {
            Spacer()
            OnboardingPrimaryButton(title: "Open my project") { vm.done() }
        }
    }
}

/// The finished setup: every step checked off, one after the other.
struct OnboardingFollowIllustration: View {
    let done: Set<OnboardingStep>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checked = 0
    private let steps = OnboardingStep.allCases.filter { $0 != .follow }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: DS.Space.md) {
                    let shown = index < checked, ok = done.contains(step)
                    Image(systemName: shown ? (ok ? "checkmark.circle.fill" : "minus.circle") : "circle")
                        .foregroundColor(shown && ok ? DS.Palette.accent : DS.Palette.textTertiary)
                        .scaleEffect(index < checked || reduceMotion ? 1 : 0.85)
                    Text(step.title).font(DS.Font.body)
                        .foregroundColor(index < checked ? DS.Palette.text : DS.Palette.textSecondary)
                    Spacer()
                    if index < checked && !done.contains(step) {
                        Text("Later").font(DS.Font.caption).foregroundColor(DS.Palette.textTertiary)
                    }
                }
                .animation(reduceMotion ? OnboardingMotion.instant : DS.Motion.emphasized, value: checked)
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: 300)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup checklist: \(done.count) done, the rest can be set up later in Settings.")
        .task {
            guard !reduceMotion else { checked = steps.count; return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            for index in steps.indices {
                checked = index + 1
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
        }
    }
}
