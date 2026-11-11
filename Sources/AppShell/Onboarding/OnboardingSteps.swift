import AppKit
import SwiftUI
import AgentRuntime
import CoreModel
import DesignSystemKit
import Surfaces

// MARK: 1 · Sign in

/// MacCode requires an account; this step cannot be skipped.
struct OnboardingSignInStep: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        OnboardingStepLayout(
            eyebrow: OnboardingStep.signIn.eyebrow,
            title: L("Sign in to MacCode."),
            subtitle: L("A MacCode account links this Mac, your iPhone and your settings. You need one to use MacCode.")
        ) {
            OnboardingAccountSection(vm: vm)
        } illustration: {
            OnboardingPanel {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    OnboardingTitioImage(size: 140)
                    Text(L("One account, every device.")).font(DS.Font.title2).foregroundColor(DS.Palette.text)
                    Text(L("Your account keeps this Mac, your iPhone and your settings together, and lets you reach your projects remotely."))
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            Spacer()
            if vm.isSignedIn {
                OnboardingPrimaryButton(title: L("Continue")) { vm.advance(completing: .signIn) }
            } else {
                Text(L("Sign in or create an account to continue."))
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
            }
        }
    }
}

// MARK: 5 · AI accounts

/// The MacCode account form: links this Mac, the iPhone and settings.
struct OnboardingAccountSection: View {
    @ObservedObject var vm: OnboardingViewModel
    @FocusState private var focused: Field?
    private enum Field { case email, password }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if let email = vm.signedInEmail {
                    Text(L("Signed in as %1$@. Switch accounts in Settings later.", email))
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if vm.signedInEmail == nil { form }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            labeledField(L("Email")) {
                TextField(L("you@example.com"), text: $vm.email)
                    .textContentType(.username)
                    .focused($focused, equals: .email)
                    .onSubmit { focused = .password }
            }
            labeledField(L("Password")) {
                SecureField(vm.creatingAccount ? L("At least 8 characters") : L("Password"), text: $vm.password)
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
                    Text(vm.creatingAccount ? L("Create account") : L("Sign in"))
                }
                .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(!vm.accountFormValid || vm.accountBusy)
            Button(vm.creatingAccount ? L("I already have an account") : L("Create an account")) {
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

struct OnboardingAccountsStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var accounts: DistillAccountsController
    @State private var saving = false

    private let providers: [(DistillAccountProvider, String)] = [
        (.chatgpt, L("ChatGPT Plus, Pro or Team")),
        (.claude, L("Claude Pro or Max")),
        (.grok, L("SuperGrok or X Premium")),
    ]

    private var anyConnected: Bool {
        providers.contains { accounts.onboardingRowState($0.0) == .connected }
    }

    var body: some View {
        OnboardingStepLayout(
            eyebrow: OnboardingStep.accounts.eyebrow,
            title: L("Your AI subscriptions. One place."),
            subtitle: L("Connect the plans you already pay for. MacCode sets up Auto to pick a model from them; nothing is billed by MacCode.")
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    ForEach(providers, id: \.0) { provider, detail in
                        OnboardingProviderRow(provider: provider, detail: detail, state: accounts.onboardingRowState(provider)) {
                            accounts.onboardingConnect(provider)
                        }
                    }
                    OnboardingConnectionStatus(accounts: accounts)
                    Text(L("Sign-in happens in your browser. Fine-tune Auto or disconnect in Settings ▸ Accounts & Auto."))
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                }
            }
        } illustration: {
            OnboardingHubIllustration(connected: providers.map(\.0).filter { accounts.onboardingRowState($0) == .connected })
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            if let note = vm.routingNote {
                Text(note).font(DS.Font.caption).foregroundColor(DS.Palette.warning).lineLimit(2)
            }
            if anyConnected {
                OnboardingPrimaryButton(title: L("Continue"), busy: saving) {
                    saving = true
                    Task { await vm.finishAccounts(); saving = false }
                }
                .disabled(saving)
            } else {
                Button(L("Skip for now")) { vm.skip(.accounts) }.buttonStyle(.link)
                    .accessibilityHint(L("Connect AI accounts later in Settings."))
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
        .accessibilityLabel(L("%1$@ of 3 subscriptions connected.", connected.count))
    }
}

// MARK: 6 · Project

struct OnboardingProjectStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @State private var dropTargeted = false

    var body: some View {
        OnboardingStepLayout(
            eyebrow: OnboardingStep.project.eyebrow,
            title: L("Open something of yours."),
            subtitle: L("Pick a project folder. MacCode opens it as a workspace%1$@.", vm.state.createDeveloper ? L(" with %1$@ ready", vm.state.developerName) : "")
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                Button(action: pickFolder) {
                    VStack(spacing: DS.Space.lg) {
                        Image(systemName: vm.folder == nil ? "folder.badge.plus" : "folder.fill")
                            .font(.system(size: 30)).foregroundColor(DS.Palette.accent)
                        Text(vm.folder?.lastPathComponent ?? L("Choose project folder"))
                            .font(DS.Font.title3).foregroundColor(DS.Palette.text).lineLimit(1).truncationMode(.middle)
                        Text(vm.folder.map { ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath } ?? L("or drop a folder here"))
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
                .accessibilityLabel(vm.folder.map { L("Project folder %1$@. Choose another.", $0.lastPathComponent) } ?? L("Choose project folder"))
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
                Toggle(isOn: Binding(get: { vm.state.createDeveloper }, set: { vm.setCreateDeveloper($0) })) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(L("Add a Developer Bot to this project")).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                        Text(L("Reads code, plans changes and reviews. Works only in this project."))
                            .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityLabel(L("Add a Developer Bot to this project"))
                if vm.state.createDeveloper {
                    TextField(L("Developer"), text: Binding(get: { vm.state.developerName }, set: { vm.setDeveloperName($0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .accessibilityLabel(L("Developer Bot name"))
                    Label(L("The first message is a draft. Nothing runs until you send it."), systemImage: "paperplane")
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                }
                if let error = vm.finishError {
                    Label(error, systemImage: "exclamationmark.circle.fill").font(DS.Font.body).foregroundColor(DS.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } illustration: {
            VStack(spacing: DS.Space.xxxl) {
                OnboardingWorkspacePreview(highlightSidebar: vm.folder != nil, folderName: vm.folder?.lastPathComponent,
                                           botName: vm.state.createDeveloper ? vm.state.developerName : nil)
                tour
            }
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            Button(L("Follow %1$@ on X", OnboardingFollow.handle)) { NSWorkspace.shared.open(OnboardingFollow.url) }
                .buttonStyle(.link)
            if vm.state.completedSteps.contains(.project) {
                OnboardingPrimaryButton(title: L("Done")) { vm.close() }
            } else if vm.folder == nil {
                OnboardingPrimaryButton(title: L("Choose folder"), action: pickFolder)
            } else {
                OnboardingPrimaryButton(title: L("Create workspace"), busy: vm.finishing) { vm.finish() }
                    .disabled(vm.finishing)
            }
        }
    }

    private var tour: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            Text(L("WHAT YOU GET")).font(DS.Font.captionStrong).tracking(1).foregroundColor(DS.Palette.textSecondary)
            lesson("folder", title: L("A project, all in one place"), detail: L("Files, terminals, browser tabs and agent conversations stay together."))
            lesson("bubble.left.and.bubble.right", title: L("Titio and your Bots"), detail: L("Describe a goal in Agent App. Titio is your general assistant; Bots take a role."))
            lesson("lock.shield", title: L("You stay in control"), detail: L("Review permissions before sending. The first message opens as a draft you can edit."))
        }
        .frame(maxWidth: 400, alignment: .leading)
    }

    private func lesson(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            Image(systemName: symbol).foregroundColor(DS.Palette.accent)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                Text(detail).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        panel.message = L("Choose the project folder to open as a workspace.")
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
                    Text(L("Titio")).font(DS.Font.caption)
                }
                .foregroundColor(DS.Palette.textSecondary)
                .onboardingReveal(6)
                Text(L("WORKSPACES")).font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary).padding(.top, DS.Space.md)
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
        .accessibilityLabel(L("Preview of the MacCode window with your project and Titio in the sidebar."))
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
