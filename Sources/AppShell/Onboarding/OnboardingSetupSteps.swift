import CoreModel
import AppKit
import SwiftUI
import DesignSystemKit

struct OnboardingSetupStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var setup: OnboardingSetupController

    private let required: [OnboardingTool] = [.distill, .git, .node, .automation]
    private let optional: [OnboardingTool] = [.docker, .helper]
    private var ready: Bool { setup.state(.distill).isReady && setup.requiredToolsReady }

    var body: some View {
        OnboardingStepLayout(
            eyebrow: OnboardingStep.setup.eyebrow,
            title: L("Getting your Mac ready."),
            subtitle: L("MacCode installs what it needs in your home folder, with no Terminal. Keep this window open while it downloads.")
        ) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                ForEach(required, id: \.self) { tool in
                    OnboardingToolRow(tool: tool, state: setup.state(tool)) { Task { await setup.install(tool) } }
                }
                Text(L("OPTIONAL")).font(DS.Font.captionStrong).tracking(1).foregroundColor(DS.Palette.textSecondary)
                    .padding(.top, DS.Space.md)
                ForEach(optional, id: \.self) { tool in
                    OnboardingToolRow(tool: tool, state: setup.state(tool)) { Task { await setup.install(tool) } }
                }
                Button(L("Check again")) {
                    Task { for tool in OnboardingTool.allCases { await setup.refresh(tool) } }
                }.buttonStyle(.link)
            }
        } illustration: {
            OnboardingPanel {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    OnboardingTitioImage(size: 140)
                    Text(ready ? L("Your Mac is ready.") : L("Getting this Mac ready."))
                        .font(DS.Font.title2).foregroundColor(DS.Palette.text)
                    Text(L("Downloads come from the official releases. MacCode checks checksums or macOS signatures before installing. Existing Chrome, Docker, OrbStack and Node installations are reused when compatible."))
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Text(L("You need an internet connection and space in your home folder. If a download fails, reconnect and retry. Your existing accounts are preserved."))
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            Spacer()
            Button(L("Skip for now")) { vm.skip(.setup) }.buttonStyle(.link)
                .accessibilityHint(L("AI conversations need Distill. You can install it later from setup."))
            OnboardingPrimaryButton(title: L("Continue"), busy: !ready && (setup.state(.distill).isBusy || setup.states.values.contains { $0.isBusy })) {
                vm.advance(completing: .setup)
            }.disabled(!ready)
        }
        .onChange(of: setup.state(.distill).isReady) { _, ready in
            if ready { vm.accounts.ensureDistillInstalled() }
        }
        .task {
            await setup.prepareDistill()
            await setup.prepareTools()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { for tool in OnboardingTool.allCases { await setup.refresh(tool) } }
        }
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
            title: L("Your Mac, your permissions."),
            subtitle: L("macOS asks you to approve access. MacCode can open the right settings, but only you can grant permission.")
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                permission(L("Accessibility"), detail: L("Lets computer automation use apps and controls."), granted: permissions.accessibility) {
                    _ = ComputerUsePermissionBroker.Requesters.live.requestAccessibility()
                    openPrivacy("Privacy_Accessibility")
                }
                permission(L("Screen Recording"), detail: L("Lets computer automation see the screen."), granted: permissions.screenCapture) {
                    _ = ComputerUsePermissionBroker.Requesters.live.requestScreenCapture()
                    openPrivacy("Privacy_ScreenCapture")
                }
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    Text(L("Project folders & Full Disk Access")).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                    Text(L("Opening a project may ask for Desktop, Documents, Downloads or external volumes. Full Disk Access can reduce repeated prompts. A settings button does not grant access."))
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
                        Text(L("%1$@: %2$@", result.target.title, result.outcome.rawValue))
                            .font(DS.Font.caption).foregroundColor(result.outcome == .denied ? DS.Palette.warning : DS.Palette.textSecondary)
                    }
                }
            }
        } illustration: {
            OnboardingPanel {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    Image(systemName: "lock.shield").font(DS.Font.title).foregroundColor(DS.Palette.accent).accessibilityHidden(true)
                    Text(L("Approve only what you use.")).font(DS.Font.title2).foregroundColor(DS.Palette.text)
                    Text(L("Allow Local Network when you connect your iPhone. Camera, microphone and Automation prompts appear only when a feature needs them. If macOS requests a restart, reopen MacCode to continue here."))
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Text(L("Denied access can be changed later in System Settings → Privacy & Security."))
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            Button(L("Skip for now")) { vm.skip(.permissions) }.buttonStyle(.link)
            OnboardingPrimaryButton(title: L("Continue")) { vm.advance(completing: .permissions) }
                .accessibilityHint(L("Continue after reviewing permissions. This does not grant access."))
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
            Button(granted ? L("Review settings") : L("Open settings"), action: action).buttonStyle(DSSecondaryButtonStyle())
                .accessibilityLabel(L("%1$@ settings", title))
        }
    }

    private func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        permissions = ComputerUsePermissionBroker.snapshot()
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

    private var symbol: String {
        switch tool {
        case .distill: return "cpu"
        case .git: return "arrow.triangle.branch"
        case .node: return "shippingbox"
        case .automation: return "cursorarrow.motionlines"
        case .chrome: return "globe"
        case .docker: return "cube.transparent"
        case .helper: return "person.2"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.xl) {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Palette.surfaceOverlay)
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundColor(DS.Palette.text))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(tool.title).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                Text(tool.detail).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(state.message).font(DS.Font.caption)
                    .foregroundColor(tone)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityLabel(tool.title)
                    .accessibilityValue(state.message)
                    .accessibilityIdentifier("onboarding.tool.\(tool.rawValue).status")
            }
            Spacer(minLength: DS.Space.md)
            if state.isBusy { ProgressView().controlSize(.small).padding(.top, DS.Space.xs) }
            else if state.isReady {
                Image(systemName: "checkmark.circle.fill").foregroundColor(DS.Palette.success)
                    .padding(.top, DS.Space.xs).accessibilityLabel(L("Ready"))
            } else {
                Button(state == .missing ? L("Install") : L("Try again"), action: install)
                    .buttonStyle(DSSecondaryButtonStyle()).accessibilityLabel(L("Install or retry %1$@", tool.title))
            }
        }
        .padding(DS.Space.xl)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .strokeBorder(state.isReady ? DS.Palette.success.opacity(0.3) : DS.Palette.line))
    }
}
