import SwiftUI
import CoreModel
import DesignSystemKit

/// Shared chrome of a Bot chat header. The Bots Desk and an Agent App tab on a
/// Bot thread mount the same identity, context and icon spacing.
public enum BotChatHeader {
    /// Toolbar-sized strip: Desk and Agent App are chat, not a page hero.
    public static let height: CGFloat = 44

    /// Visual gap between header glyphs. DSIconButton lays out at 44pt so the
    /// 26pt icon keeps a 44pt hit box; subtract that extra so the glyphs sit
    /// `DS.Space.xs` apart like workspace header icons.
    public static var iconSpacing: CGFloat {
        DS.Space.xs - (DSIconButton.hitTargetSize - DSIconButton.visualSize.width)
    }

    /// A Bot with no name still needs a label in the roster, the header and
    /// VoiceOver. Same fallback as iOS.
    public static func displayName(_ name: String) -> String {
        name.isEmpty ? L("Untitled") : name
    }
}

/// Avatar, name, job, @handle and permission of the Bot that runs the chat.
/// With `onOpen` the whole block is one button that opens the Bot's Studio.
public struct BotChatHeaderIdentity: View {
    let bot: BotDefinition
    let permission: String
    let attention: BotAttentionState
    let identifierPrefix: String
    let status: AnyView?
    let onOpen: (() -> Void)?

    public init(
        bot: BotDefinition,
        permission: String,
        attention: BotAttentionState,
        identifierPrefix: String,
        status: AnyView? = nil,
        onOpen: (() -> Void)?
    ) {
        self.bot = bot
        self.permission = permission
        self.attention = attention
        self.identifierPrefix = identifierPrefix
        self.status = status
        self.onOpen = onOpen
    }

    public var body: some View {
        if let onOpen {
            Button(action: onOpen) {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Open Studio for %1$@", BotChatHeader.displayName(bot.name)))
            .accessibilityIdentifier("\(identifierPrefix).identity")
        } else {
            label
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(identifierPrefix).identity")
        }
    }

    private var label: some View {
        HStack(spacing: DS.Space.sm) {
            BotsAvatarView(
                name: bot.name,
                handle: bot.handle,
                symbol: bot.avatarSymbol,
                size: 22,
                attention: attention
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Space.sm) {
                    // One line: the bar is a fixed 44pt strip, so a long name
                    // must truncate, not wrap over the chat.
                    Text(BotChatHeader.displayName(bot.name))
                        .font(DS.Font.bodyStrong)
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(BotChatHeader.displayName(bot.name))
                        .accessibilityIdentifier("\(identifierPrefix).name")
                    if let status {
                        // The status keeps its place when the name truncates.
                        status.layoutPriority(1)
                    }
                }
                // textSecondary: 10pt information text needs 4.5:1; textTertiary is 3.72:1.
                HStack(spacing: DS.Space.sm) {
                    Text(bot.title.isEmpty ? L("No job yet") : bot.title)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                        .accessibilityIdentifier("\(identifierPrefix).job")
                    Text(L("@%1$@", bot.handle))
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                        .accessibilityIdentifier("\(identifierPrefix).handle")
                    Text(permission)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                        .accessibilityIdentifier("\(identifierPrefix).permission")
                }
                .lineLimit(1)
            }
        }
    }
}

/// Branch and context usage of the thread, beside the Bot identity.
public struct BotChatHeaderContext: View {
    @ObservedObject var vm: AgentAppViewModel
    let identifierPrefix: String

    public init(vm: AgentAppViewModel, identifierPrefix: String) {
        self.vm = vm
        self.identifierPrefix = identifierPrefix
    }

    public var body: some View {
        HStack(spacing: DS.Space.sm) {
            if let branch = vm.gitBranch {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                Text(branch)
                    .font(DS.Font.caption2.monospaced())
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(branch)
            }
            if let context = vm.contextHealthMessage {
                if vm.gitBranch != nil { Text("·").foregroundColor(DS.Palette.textTertiary) }
                Text(context)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .layoutPriority(-1)
        .accessibilityIdentifier("\(identifierPrefix).context")
    }
}
