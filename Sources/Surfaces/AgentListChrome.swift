import CoreModel
import SwiftUI
import DesignSystemKit

/// Shared list / card / kill-switch chrome for dest and agentic overviews.
///
/// WHY: Schedule Tasks, Active Bots, and Active Threads painted the same
/// accent chips, search field, footer, 44pt icon cards, and travel-pause
/// switch in four files. One type owns the look.

// MARK: - Filter chip

public struct AgentListFilterChip: View {
    public let title: String
    public let count: Int
    public let selected: Bool
    public let identifier: String
    public let action: () -> Void

    public init(
        title: String,
        count: Int,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.count = count
        self.selected = selected
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Text(title)
                    .font(DS.Font.caption.weight(.semibold))
                Text(L("%1$@", count))
                    .font(DS.Font.caption2.weight(.bold))
                    .opacity(selected ? 0.9 : 0.7)
            }
            .foregroundColor(selected ? DS.Palette.onAccent : DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm)
            .background(selected ? DS.Palette.accent : DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(selected ? Color.clear : DS.Palette.line, lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(title), \(count)")
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Search

public struct AgentListSearchField: View {
    @Binding public var text: String
    public let placeholder: String
    public let identifier: String
    public let accessibilityLabel: String
    public let autofocus: Bool
    @FocusState private var focused: Bool

    public init(
        text: Binding<String>,
        placeholder: String,
        identifier: String,
        accessibilityLabel: String,
        autofocus: Bool = false
    ) {
        self._text = text
        self.placeholder = placeholder
        self.identifier = identifier
        self.accessibilityLabel = accessibilityLabel
        self.autofocus = autofocus
    }

    public var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .foregroundColor(DS.Palette.text)
                .focused($focused)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .onAppear {
            if autofocus { focused = true }
        }
    }
}

// MARK: - Footer

public struct AgentListFooterBar: View {
    public let caption: String
    public let pillTitle: String
    public let pillTone: DSPill.Tone

    public init(caption: String, pillTitle: String, pillTone: DSPill.Tone) {
        self.caption = caption
        self.pillTitle = pillTitle
        self.pillTone = pillTone
    }

    public var body: some View {
        HStack(spacing: DS.Space.md) {
            Text(caption)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
            DSPill(pillTitle, tone: pillTone)
                .accessibilityHidden(true)
            Spacer(minLength: DS.Space.md)
        }
        .padding(.horizontal, DS.Space.xxl)
        .frame(height: 40)
        .background(DS.Palette.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(caption)
    }
}

// MARK: - Kill switch

public struct AgentKillSwitchControl: View {
    public let isActive: Bool
    public let identifier: String
    public let accessibilityLabel: String
    public let onChange: (Bool) -> Void

    public init(
        isActive: Bool,
        identifier: String,
        accessibilityLabel: String,
        onChange: @escaping (Bool) -> Void
    ) {
        self.isActive = isActive
        self.identifier = identifier
        self.accessibilityLabel = accessibilityLabel
        self.onChange = onChange
    }

    public var body: some View {
        let tone = isActive ? DS.Palette.success : DS.Palette.warning
        return HStack(spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: isActive ? "bolt.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(tone)
                    .frame(width: 22, height: 22)
                    .background(tone.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(isActive ? L("Active") : L("Paused"))
                        .font(DS.Font.captionStrong)
                        .foregroundColor(DS.Palette.text)
                    Text(isActive ? L("Schedules on") : L("Travel pause"))
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                }
            }
            .accessibilityHidden(true)

            Toggle(isOn: Binding(
                get: { isActive },
                set: { onChange($0) }
            )) {
                Text(L("Active"))
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(DS.Palette.success)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isActive ? "On" : L("Off"))
            .accessibilityHint(L("Disables all automatic scheduled runs without deleting tasks"))
        }
        .padding(.leading, DS.Space.lg)
        .padding(.trailing, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(DS.Palette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(isActive ? tone.opacity(0.45) : DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .animation(DS.Motion.micro, value: isActive)
        .help(isActive
              ? L("Schedules are running. Turn off to pause all automatic runs (e.g. while traveling).")
              : L("All automatic runs are paused. Turn on when you return."))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
}

// MARK: - Overview card

public struct AgentOverviewMetaColumn: View {
    public let title: String
    public let value: String
    public let valueColor: Color
    public let width: CGFloat
    public let alignment: HorizontalAlignment
    public let multilineTextAlignment: TextAlignment
    /// When set, the value is a link that runs this instead of opening the card.
    public let action: (() -> Void)?
    public let actionHelp: String

    public init(
        title: String,
        value: String,
        valueColor: Color = DS.Palette.text,
        width: CGFloat = 140,
        alignment: HorizontalAlignment = .leading,
        multilineTextAlignment: TextAlignment = .leading,
        action: (() -> Void)? = nil,
        actionHelp: String = ""
    ) {
        self.title = title
        self.value = value
        self.valueColor = valueColor
        self.width = width
        self.alignment = alignment
        self.multilineTextAlignment = multilineTextAlignment
        self.action = action
        self.actionHelp = actionHelp
    }

    private var valueText: some View {
        Text(value)
            .font(DS.Font.caption.weight(.medium))
            .foregroundColor(action == nil ? valueColor : DS.Palette.accent)
            .lineLimit(2)
            .multilineTextAlignment(multilineTextAlignment)
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textTertiary)
            if let action {
                Button(action: action) { valueText.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help(actionHelp)
            } else {
                valueText
            }
        }
        .frame(width: width, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

public struct AgentOverviewCard<Badge: View, Meta: View, Trailing: View>: View {
    public let icon: String
    public let iconColor: Color
    public let title: String
    public let subtitle: String
    public let preview: String?
    public let identifier: String
    public let accessibilityValue: String?
    public let avatar: BotsAvatarView?
    public let onOpen: () -> Void
    public let badge: Badge
    public let meta: Meta
    public let trailing: Trailing

    public init(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        preview: String? = nil,
        identifier: String,
        accessibilityValue: String? = nil,
        avatar: BotsAvatarView? = nil,
        onOpen: @escaping () -> Void,
        @ViewBuilder badge: () -> Badge,
        @ViewBuilder meta: () -> Meta,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.preview = preview
        self.identifier = identifier
        self.accessibilityValue = accessibilityValue
        self.avatar = avatar
        self.onOpen = onOpen
        self.badge = badge()
        self.meta = meta()
        self.trailing = trailing()
    }

    public var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                if let avatar {
                    avatar.frame(width: 44, height: 44)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(iconColor)
                        .frame(width: 44, height: 44)
                        .background(DS.Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                        )
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(spacing: DS.Space.sm) {
                        Text(title)
                            .font(DS.Font.body.weight(.semibold))
                            .foregroundColor(DS.Palette.text)
                            .lineLimit(1)
                        badge
                    }
                    Text(subtitle)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                    if let preview, !preview.isEmpty {
                        Text(preview)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                meta
                trailing
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
        .accessibilityElement(children: .combine)
        .modifier(AgentOverviewCardValue(value: accessibilityValue))
    }
}

private struct AgentOverviewCardValue: ViewModifier {
    let value: String?

    func body(content: Content) -> some View {
        if let value {
            content.accessibilityValue(value)
        } else {
            content
        }
    }
}
