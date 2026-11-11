import CoreModel
import SwiftUI
import DesignSystemKit

struct OnboardingChromeStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var setup: OnboardingSetupController
    @StateObject private var connection = ChromeExtensionSetup()

    var body: some View {
        OnboardingStepLayout(
            eyebrow: OnboardingStep.chrome.eyebrow,
            title: L("Connect the browser you already use."),
            subtitle: L("Install the Chrome extension once to let agents work in background tabs using the profile you choose.")
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                OnboardingToolRow(tool: .chrome, state: setup.state(.chrome)) {
                    Task { await setup.install(.chrome) }
                }
                ChromeExtensionSettingsSection(setup: connection, showGuide: true)
                    .disabled(!setup.state(.chrome).isReady)
                if !setup.state(.chrome).isReady {
                    Text(L("Install Google Chrome above to begin extension setup."))
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                }
            }
        } illustration: {
            OnboardingChromeGuideAnimation()
        } footer: {
            OnboardingBackButton(vm: vm)
            Spacer()
            if connection.state != .connected {
                Text(L("Continue unlocks once Chrome is connected."))
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
            }
            Button(L("Skip for now")) { vm.skip(.chrome) }.buttonStyle(.link)
                .accessibilityHint(L("Continue without Chrome automation. Set it up later in Settings."))
            OnboardingPrimaryButton(title: L("Continue")) { vm.advance(completing: .chrome) }
                .disabled(connection.state != .connected)
                .accessibilityHint(L("Available after Check Connection confirms Chrome is connected."))
                .accessibilityIdentifier("onboarding.chrome.continue")
        }
        .task { await setup.refresh(.chrome) }
    }
}
