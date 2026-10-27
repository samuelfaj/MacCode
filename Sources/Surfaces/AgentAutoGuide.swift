import DesignSystemKit
import SwiftUI

/// Entry point for the Auto model guide. The guide edits the Distill Auto
/// profile, which lives behind `DistillAccountsController` in AppShell, so
/// AppShell installs the factory at launch and Surfaces only presents it.
public enum AgentAutoGuide {
    /// Builds the guide sheet body. `onClose` dismisses the hosting sheet.
    public static let title = "Auto profile"
    public static let subtitle = "The global Auto profile affects all Auto conversations, Bots, and scheduled Auto runs."

    @MainActor public static var makeGuide: ((_ onClose: @escaping () -> Void) -> AnyView)?
    /// Turns the shared Auto profile on; false when it still needs setup in the guide.
    @MainActor public static var enableProfile: (@MainActor () async -> Bool)?
}

/// Inline Accounts & Auto editor shown in a Distill conversation's empty state.
/// AppShell installs the factory (the controller lives there); Surfaces only mounts it.
public enum AgentAccountsInline {
    @MainActor public static var make: (() -> AnyView)?
}

/// New-conversation empty state: title, subtitle and, when the host installed
/// it, the Accounts & Auto editor. Shared by the Agent App and Bot Desk.
public struct AgentNewConversationEmptyState: View {
    public let title: String
    public let subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        if let makeAccounts = AgentAccountsInline.make {
            VStack(spacing: DS.Space.xl) {
                VStack(spacing: DS.Space.md) {
                    AgentChoiceIconTile(systemName: "sparkles", tint: DS.Palette.ultracode, size: 40)
                    Text(title).font(DS.Font.title3).foregroundColor(DS.Palette.text)
                    Text(subtitle)
                        .font(DS.Font.bodyDense)
                        .foregroundColor(DS.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                makeAccounts()
                    .frame(maxWidth: 880)
                    .accessibilityIdentifier("agent.accounts.inline")
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.vertical, DS.Space.xl)
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            DSEmptyState(icon: "sparkles", title: title, subtitle: subtitle)
        }
    }
}
