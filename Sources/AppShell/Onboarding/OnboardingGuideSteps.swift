import SwiftUI
import DesignSystemKit

struct OnboardingBasicsStep: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        OnboardingStepLayout(
            eyebrow: OnboardingStep.basics.eyebrow,
            title: "Meet your new workspace.",
            subtitle: "MacCode brings your project, AI agents and tools together. This Mac runs the work; your iPhone can follow when connected."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                lesson("folder", title: "Start with a project", detail: "Open a folder to keep files, terminals, browser tabs and agent conversations together.")
                lesson("bubble.left.and.bubble.right", title: "Give an agent a goal", detail: "Describe what you need in Agent App. Choose a Bot for a role, then follow its progress and review the changes.")
                lesson("lock.shield", title: "Choose how it can act", detail: "Review the permissions before sending a task. The first project opens with a draft you can read and edit before sending.")
            }
        } illustration: {
            OnboardingPanel {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    OnboardingTitioImage(size: 140)
                    Text("Try one small task.")
                        .font(DS.Font.title2).foregroundColor(DS.Palette.text)
                    Text(OnboardingDeveloperTemplate.firstPrompt)
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Review the plan before asking for changes.", systemImage: "checklist")
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                }
            }
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            OnboardingPrimaryButton(title: "Continue") { vm.advance(completing: .basics) }
                .accessibilityIdentifier("onboarding.basics.continue")
        }
    }

    private func lesson(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            Image(systemName: symbol).foregroundColor(DS.Palette.accent)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(title).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                Text(detail).font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct OnboardingChromeStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var setup: OnboardingSetupController
    @StateObject private var connection = ChromeExtensionSetup()

    var body: some View {
        OnboardingStepLayout(
            eyebrow: OnboardingStep.chrome.eyebrow,
            title: "Connect the browser you already use.",
            subtitle: "Install the Chrome extension once to let agents work in background tabs using the profile you choose."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                if setup.state(.chrome).isReady {
                    Label("Google Chrome is installed", systemImage: "checkmark.circle.fill")
                        .font(DS.Font.captionStrong).foregroundColor(DS.Palette.success)
                } else {
                    OnboardingToolRow(tool: .chrome, state: setup.state(.chrome)) {
                        Task { await setup.install(.chrome) }
                    }
                }
                ChromeExtensionSettingsSection(setup: connection, showGuide: true)
                    .disabled(!setup.state(.chrome).isReady)
                if !setup.state(.chrome).isReady {
                    Text("Install Google Chrome above to begin extension setup.")
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                }
            }
        } illustration: {
            OnboardingPanel {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    OnboardingTitioImage(size: 140)
                    Text("Your profile. Your choice.")
                        .font(DS.Font.title2).foregroundColor(DS.Palette.text)
                    Text("Choose the Chrome profile with the website logins you want agents to use. Review Chrome's permission prompts before enabling the extension.")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Selecting an automated tab gives control back to you. You can disable the extension later in Chrome.")
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            Button("Skip for now") { vm.skip(.chrome) }.buttonStyle(.link)
                .accessibilityHint("Continue without Chrome automation. Set it up later in Settings.")
            OnboardingPrimaryButton(title: "Continue") { vm.advance(completing: .chrome) }
                .disabled(connection.state != .connected)
                .accessibilityHint("Available after Check Connection confirms Chrome is connected.")
                .accessibilityIdentifier("onboarding.chrome.continue")
        }
        .task { await setup.refresh(.chrome) }
    }
}
