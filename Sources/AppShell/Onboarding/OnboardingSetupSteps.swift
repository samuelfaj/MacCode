import AppKit
import SwiftUI
import DesignSystemKit

struct OnboardingDistillStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var setup: OnboardingSetupController

    var body: some View {
        OnboardingStepLayout(
            eyebrow: OnboardingStep.distill.eyebrow,
            title: "First, your AI engine.",
            subtitle: "MacCode installs Distill automatically, then checks that it can run. Keep this window open while it downloads."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                OnboardingToolRow(tool: .distill, state: setup.state(.distill)) {
                    Task { await setup.install(.distill) }
                }
                Text("You need an internet connection and space in your home folder. If a download fails, reconnect and try again. Your existing accounts are preserved.")
                    .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } illustration: {
            OnboardingPanel {
                VStack(spacing: DS.Space.xxl) {
                    OnboardingTitioImage(size: 160)
                    Text(setup.state(.distill).isReady ? "Ready for your accounts." : "Getting this Mac ready.")
                        .font(DS.Font.title2).foregroundColor(DS.Palette.text)
                    Text("ChatGPT · Claude · Grok · OpenRouter")
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                }.frame(maxWidth: .infinity)
            }
        } footer: {
            Spacer()
            Button("Skip for now") { vm.skip(.distill) }.buttonStyle(.link)
                .accessibilityHint("AI conversations need Distill. You can install it later from setup.")
            OnboardingPrimaryButton(title: "Continue", busy: setup.state(.distill).isBusy) {
                vm.advance(completing: .distill)
            }.disabled(!setup.state(.distill).isReady)
        }
        .onChange(of: setup.state(.distill).isReady) { _, ready in
            if ready { vm.accounts.ensureDistillInstalled() }
        }
        .task { await setup.prepareDistill() }
    }
}

struct OnboardingPermissionsStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @State private var permissions = ComputerUsePermissionBroker.snapshot()
    @State private var folderResults: [HostFileAccessProbeResult] = []
    @State private var checkingFolders = false

    var body: some View {
        OnboardingStepLayout(
            eyebrow: OnboardingStep.permissions.eyebrow,
            title: "Your Mac, your permissions.",
            subtitle: "macOS asks you to approve access. MacCode can open the right settings, but only you can grant permission."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                permission("Accessibility", detail: "Lets computer automation use apps and controls.", granted: permissions.accessibility) {
                    _ = ComputerUsePermissionBroker.Requesters.live.requestAccessibility()
                    openPrivacy("Privacy_Accessibility")
                }
                permission("Screen Recording", detail: "Lets computer automation see the screen.", granted: permissions.screenCapture) {
                    _ = ComputerUsePermissionBroker.Requesters.live.requestScreenCapture()
                    openPrivacy("Privacy_ScreenCapture")
                }
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    Text("Project folders & Full Disk Access").font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                    Text("Opening a project may ask for Desktop, Documents, Downloads or external volumes. Full Disk Access can reduce repeated prompts. A settings button does not grant access.")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(HostFileAccessCopy.openFullDiskAccessButton) {
                        NSWorkspace.shared.open(HostFileAccessSystemSettings.fullDiskAccessSettingsURL)
                    }.buttonStyle(DSSecondaryButtonStyle())
                    Button(checkingFolders ? "Checking…" : HostFileAccessCopy.requestAccessButton) {
                        checkingFolders = true
                        Task {
                            folderResults = await Task.detached { HostFileAccessProber.probeStandardTargets() }.value
                            checkingFolders = false
                        }
                    }.buttonStyle(.link).disabled(checkingFolders)
                    ForEach(folderResults, id: \.target) { result in
                        Text("\(result.target.title): \(result.outcome.rawValue)")
                            .font(DS.Font.caption).foregroundColor(result.outcome == .denied ? DS.Palette.warning : DS.Palette.textSecondary)
                    }
                }
            }
        } illustration: {
            OnboardingPanel {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    Image(systemName: "lock.shield").font(DS.Font.title).foregroundColor(DS.Palette.accent).accessibilityHidden(true)
                    Text("Approve only what you use.").font(DS.Font.title2).foregroundColor(DS.Palette.text)
                    Text("Allow Local Network when you connect your iPhone. Camera, microphone and Automation prompts appear only when a feature needs them. If macOS requests a restart, reopen MacCode to continue here.")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Text("Denied access can be changed later in System Settings → Privacy & Security.")
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            Button("Skip for now") { vm.skip(.permissions) }.buttonStyle(.link)
            OnboardingPrimaryButton(title: "Continue") { vm.advance(completing: .permissions) }
                .accessibilityHint("Continue after reviewing permissions. This does not grant access.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions = ComputerUsePermissionBroker.snapshot()
        }
    }

    private func permission(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                Text(title).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                Spacer()
                Label(granted ? "Allowed" : "Not allowed", systemImage: granted ? "checkmark.circle.fill" : "circle")
                    .font(DS.Font.caption).foregroundColor(granted ? DS.Palette.success : DS.Palette.warning)
            }
            Text(detail).font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
            Button(granted ? "Review settings" : "Open settings", action: action).buttonStyle(DSSecondaryButtonStyle())
                .accessibilityLabel("\(title) settings")
        }
    }

    private func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        permissions = ComputerUsePermissionBroker.snapshot()
    }
}

struct OnboardingToolsStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var setup: OnboardingSetupController

    var body: some View {
        OnboardingStepLayout(
            eyebrow: OnboardingStep.tools.eyebrow,
            title: "The tools behind your project.",
            subtitle: "MacCode prepares Git, Node.js and computer automation. Add Chrome or Docker if you use their features. You can return to setup at any time."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                ForEach(OnboardingTool.allCases.filter { $0 != .distill }, id: \.self) { tool in
                    OnboardingToolRow(tool: tool, state: setup.state(tool)) {
                        Task { await setup.install(tool) }
                    }
                }
                Button("Check again") {
                    Task { for tool in OnboardingTool.allCases where tool != .distill { await setup.refresh(tool) } }
                }.buttonStyle(.link)
                if setup.state(.chrome).isReady { ChromeExtensionSettingsSection() }
            }
        } illustration: {
            OnboardingPanel {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    OnboardingTitioImage(size: 140)
                    Text("No Terminal setup required.").font(DS.Font.title2).foregroundColor(DS.Palette.text)
                    Text("Downloads come from the official releases. MacCode checks checksums or macOS signatures before installing. Existing Chrome, Docker, OrbStack and Node installations are reused when compatible.")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Text("Linux packages, the Bot desktop and its browser are prepared automatically on first use. That first start needs internet access and extra disk space.")
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            Button("Skip for now") { vm.skip(.tools) }.buttonStyle(.link)
            OnboardingPrimaryButton(title: "Continue") {
                vm.advance(completing: .tools)
            }.disabled(!setup.requiredToolsReady)
        }
        .task { await setup.prepareTools() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { for tool in OnboardingTool.allCases where tool != .distill { await setup.refresh(tool) } }
        }
    }
}

struct OnboardingToolRow: View {
    let tool: OnboardingTool
    let state: OnboardingToolState
    let install: () -> Void

    private var tone: Color {
        switch state {
        case .ready: return DS.Palette.success
        case .failed: return DS.Palette.danger
        case .needsAction: return DS.Palette.warning
        default: return DS.Palette.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.lg) {
                Text(tool.title).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                Spacer(minLength: DS.Space.md)
                if state.isBusy { ProgressView().controlSize(.small) }
                else if state.isReady {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(DS.Palette.success).accessibilityLabel("Ready")
                } else {
                    Button(state == .missing ? "Install" : "Try again", action: install)
                        .buttonStyle(DSSecondaryButtonStyle()).accessibilityLabel("Install or retry \(tool.title)")
                }
            }
            Text(tool.detail).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(state.message).font(DS.Font.caption)
                .foregroundColor(tone)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityLabel(tool.title)
                .accessibilityValue(state.message)
                .accessibilityIdentifier("onboarding.tool.\(tool.rawValue).status")
        }
        .padding(DS.Space.xl)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(DS.Palette.line))
    }
}
