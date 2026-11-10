import CoreModel
import DesignSystemKit
import SwiftUI

private struct BotVMBannerRow<Buttons: View>: View {
    let icon: String
    let text: String
    let identifier: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 14, height: 14, alignment: .center)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// The bot asked to run on the Mac; only the user's click approves it.
struct BotMacExecutionBanner: View {
    @ObservedObject var vm: AgentAppViewModel

    var body: some View {
        BotVMBannerRow(
            icon: "desktopcomputer",
            text: "The bot asked to run on the Mac: \(vm.pendingMacExecutionReason ?? "")",
            identifier: "agent.macExecution.banner"
        ) {
            Button(L("Decline")) { vm.resolveMacExecution(approve: false) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("agent.macExecution.decline")
            Button(L("Approve")) { vm.resolveMacExecution(approve: true) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("agent.macExecution.approve")
        }
    }
}

/// The bot VM failed preflight; the thread stays on the VM unless the user picks the Mac.
struct BotVMUnavailableBanner: View {
    @ObservedObject var vm: AgentAppViewModel

    var body: some View {
        BotVMBannerRow(
            icon: "exclamationmark.triangle",
            text: "The bot's VM is not available.",
            identifier: "agent.vmUnavailable.banner"
        ) {
            Button(L("Start VM")) { vm.startUnavailableBotVM() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("agent.vmUnavailable.start")
            Button(L("Run this thread on the Mac")) { vm.runSelectedThreadOnMac() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("agent.vmUnavailable.runOnMac")
        }
    }
}
