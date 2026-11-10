import AppKit
import CoreModel
import DesignSystemKit
import SwiftUI

/// Shared modal chrome for the composer controls (run as, models, permission,
/// execution). Every control opens one of these instead of a popover, so the
/// header, close behavior, option cards and spacing stay one component.

// MARK: - Sheet shell

public struct AgentChoiceSheet<Content: View, Footer: View>: View {
    public let icon: String
    public let tint: Color
    public let title: String
    public let subtitle: String?
    public let width: CGFloat
    public let accessibilityIdentifier: String
    public let onClose: () -> Void
    private let content: Content
    private let footer: Footer

    public init(
        icon: String,
        tint: Color = DS.Palette.accent,
        title: String,
        subtitle: String? = nil,
        width: CGFloat = 520,
        accessibilityIdentifier: String,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    content
                }
                .padding(DS.Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 560)
            footerArea
        }
        .frame(width: width)
        .background(DS.Palette.surface)
        .foregroundStyle(DS.Palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            AgentChoiceIconTile(systemName: icon, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .font(DS.Font.title3)
                    .foregroundColor(DS.Palette.text)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.lg)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(DS.Palette.surfaceRaised, in: Circle())
                    .overlay(Circle().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("\(accessibilityIdentifier).close")
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.vertical, DS.Space.xl)
    }

    @ViewBuilder
    private var footerArea: some View {
        if Footer.self != EmptyView.self {
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            HStack(spacing: DS.Space.md) { footer }
                .padding(.horizontal, DS.Space.xxl)
                .padding(.vertical, DS.Space.lg)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(DS.Palette.bg.opacity(0.35))
        }
    }
}

public extension AgentChoiceSheet where Footer == EmptyView {
    init(
        icon: String,
        tint: Color = DS.Palette.accent,
        title: String,
        subtitle: String? = nil,
        width: CGFloat = 520,
        accessibilityIdentifier: String,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            icon: icon, tint: tint, title: title, subtitle: subtitle, width: width,
            accessibilityIdentifier: accessibilityIdentifier, onClose: onClose,
            content: content, footer: { EmptyView() }
        )
    }
}

// MARK: - Building blocks

/// Rounded square with a tinted SF Symbol; the leading mark of headers and cards.
public struct AgentChoiceIconTile: View {
    public let systemName: String
    public let tint: Color
    public let size: CGFloat

    public init(systemName: String, tint: Color = DS.Palette.accent, size: CGFloat = 30) {
        self.systemName = systemName
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: DS.Border.hairline)
            )
            .accessibilityHidden(true)
    }
}

/// Uppercase group label with an optional trailing accessory (count, action).
public struct AgentChoiceSectionHeader<Accessory: View>: View {
    public let title: String
    private let accessory: Accessory

    public init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: DS.Space.sm) {
            Text(title.uppercased())
                .font(DS.Font.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundColor(DS.Palette.textTertiary)
            Spacer(minLength: 0)
            accessory
        }
        .accessibilityAddTraits(.isHeader)
    }
}

public extension AgentChoiceSectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title, accessory: { EmptyView() })
    }
}

/// One selectable option: leading mark, title, subtitle, trailing badge, and a
/// clear selected state (accent border + check). Disabled cards explain why.
public struct AgentChoiceCard<Leading: View>: View {
    public let title: String
    public let subtitle: String?
    public let badge: String?
    public let selected: Bool
    public let tint: Color
    public let disabledReason: String?
    public let accessibilityIdentifier: String?
    public let action: () -> Void
    private let leading: Leading
    @State private var hovering = false

    public init(
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        selected: Bool,
        tint: Color = DS.Palette.accent,
        disabledReason: String? = nil,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading
    ) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.selected = selected
        self.tint = tint
        self.disabledReason = disabledReason
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
        self.leading = leading()
    }

    private var disabled: Bool { disabledReason != nil }

    public var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                leading
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title)
                        .font(DS.Font.bodyStrong)
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    if let text = disabledReason ?? subtitle, !text.isEmpty {
                        Text(text)
                            .font(DS.Font.caption)
                            .foregroundColor(disabled ? DS.Palette.warning : DS.Palette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: DS.Space.sm)
                if let badge, !badge.isEmpty {
                    AgentChoiceBadge(badge)
                }
                checkmark
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
                    .fill(selected ? tint.opacity(0.10) : (hovering && !disabled ? DS.Palette.surfaceOverlay : DS.Palette.surfaceRaised))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.75) : DS.Palette.line, lineWidth: selected ? 1.5 : DS.Border.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
            .opacity(disabled ? DS.Alpha.disabled + 0.25 : 1)
        }
        .buttonStyle(AgentChoicePressStyle())
        .disabled(disabled)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .modifier(OptionalAccessibilityIdentifier(identifier: accessibilityIdentifier))
    }

    private var checkmark: some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? tint : DS.Palette.lineStrong, lineWidth: 1.5)
                .frame(width: 18, height: 18)
            if selected {
                Circle().fill(tint).frame(width: 18, height: 18)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Palette.onAccent)
            }
        }
        .accessibilityHidden(true)
    }
}

public extension AgentChoiceCard where Leading == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        selected: Bool,
        tint: Color = DS.Palette.accent,
        disabledReason: String? = nil,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title, subtitle: subtitle, badge: badge, selected: selected, tint: tint,
            disabledReason: disabledReason, accessibilityIdentifier: accessibilityIdentifier,
            action: action, leading: { EmptyView() }
        )
    }
}

/// Small rounded tag (Mac / VM, context window, "Recommended").
public struct AgentChoiceBadge: View {
    public let text: String
    public let tint: Color

    public init(_ text: String, tint: Color = DS.Palette.textSecondary) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(DS.Font.caption2.weight(.semibold).monospacedDigit())
            .foregroundColor(tint)
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xxs)
            .background(tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// Large search field used at the top of long option lists.
public struct AgentChoiceSearchField: View {
    @Binding public var query: String
    public let placeholder: String
    public let accessibilityIdentifier: String
    @FocusState private var focused: Bool

    public init(query: Binding<String>, placeholder: String, accessibilityIdentifier: String) {
        self._query = query
        self.placeholder = placeholder
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .focused($focused)
                .accessibilityIdentifier(accessibilityIdentifier)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(height: 34)
        .background(DS.Palette.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(focused ? DS.Palette.focusRing : DS.Palette.line, lineWidth: focused ? 1.5 : DS.Border.hairline)
        )
    }
}

/// Inline callout for warnings and guidance inside a sheet.
public struct AgentChoiceCallout: View {
    public let icon: String
    public let tint: Color
    public let text: String

    public init(icon: String, tint: Color, text: String) {
        self.icon = icon
        self.tint = tint
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.lg)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: DS.Border.hairline)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Segmented effort chooser sized for sheets (Auto · Low · Medium · …).
public struct AgentChoiceSegmented<Value: Hashable>: View {
    public let options: [(value: Value, title: String, help: String?)]
    public let selection: Value
    public let disabled: Bool
    public let onSelect: (Value) -> Void
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(options: [(value: Value, title: String, help: String?)], selection: Value, disabled: Bool = false, onSelect: @escaping (Value) -> Void) {
        self.options = options
        self.selection = selection
        self.disabled = disabled
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: DS.Space.xxs) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    onSelect(option.value)
                } label: {
                    Text(option.title)
                        .font(DS.Font.caption.weight(isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? DS.Palette.onAccent : DS.Palette.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                                    .fill(DS.Palette.accent)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.help ?? option.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(DS.Space.xxs)
        .background(DS.Palette.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .animation(reduceMotion ? nil : DS.Motion.emphasized, value: selection)
        .disabled(disabled)
        .opacity(disabled ? DS.Alpha.disabled + 0.25 : 1)
    }
}

/// Subtle press feedback (scale 0.98) for cards; instant release.
public struct AgentChoicePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : DS.Motion.micro, value: configuration.isPressed)
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// Presentation for one Distill execution mode: the tint and symbol shared by the composer
/// capsule and its choice sheet, so a mode looks the same everywhere it appears.
public extension DistillExecutionMode {
    var capsuleTint: Color {
        switch self {
        case .auto: return DS.Palette.accent
        case .normal: return DS.Palette.textSecondary
        case .ultrafast: return DS.Palette.warning
        case .ultracode: return DS.Palette.ultracode
        case .ultrasave: return DS.Palette.success
        }
    }

    var capsuleIcon: String {
        switch self {
        case .auto: return "sparkles"
        case .normal: return "circle.dotted"
        case .ultrafast: return "bolt.fill"
        case .ultracode: return "wand.and.stars"
        case .ultrasave: return "leaf.fill"
        }
    }
}

/// Composer capsule for Distill's one exclusive execution mode. Opens `AgentChoiceSheet`.
public struct AgentExecutionModeCapsule: View {
    public let selected: DistillExecutionMode
    public let disabled: Bool
    public let accessibilityIdentifier: String
    public let onSelect: (DistillExecutionMode) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false

    public init(
        selected: DistillExecutionMode,
        disabled: Bool = false,
        accessibilityIdentifier: String,
        onSelect: @escaping (DistillExecutionMode) -> Void
    ) {
        self.selected = selected
        self.disabled = disabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onSelect = onSelect
    }

    public var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: selected.capsuleIcon)
                    .font(.system(size: 10))
                    .foregroundColor(selected == .normal ? DS.Palette.textSecondary : selected.capsuleTint)
                Text(L("Mode"))
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                Text(selected.displayName)
                    .font(DS.Font.caption.weight(.medium))
                    .foregroundColor(selected == .normal ? DS.Palette.textSecondary : DS.Palette.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(DS.Palette.textSecondary)
            }
            .fixedSize()
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xs)
            .background(background)
            .clipShape(Capsule())
            .overlay(stroke)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
        .help("Execution mode: \(selected.pickerHelpText)")
        .animation(reduceMotion ? nil : DS.Motion.micro, value: selected)
        .accessibilityLabel("Mode \(selected.displayName)")
        .accessibilityIdentifier(accessibilityIdentifier)
        .sheet(isPresented: $isPresented) { sheet }
    }

    private var background: some View {
        ZStack {
            Capsule().fill(DS.Palette.surfaceRaised)
            if selected == .ultracode {
                Capsule()
                    .fill(LinearGradient(
                        colors: [DS.Palette.ultracode, DS.Palette.ultracodeDeep],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .opacity(0.22)
            } else if selected != .normal {
                Capsule().fill(selected.capsuleTint.opacity(0.13))
            }
        }
    }

    private var stroke: some View {
        Capsule().strokeBorder(
            selected == .normal ? DS.Palette.line : selected.capsuleTint.opacity(0.6),
            lineWidth: DS.Border.hairline
        )
    }

    private var sheet: some View {
        AgentChoiceSheet(
            icon: "slider.horizontal.3",
            tint: selected.capsuleTint,
            title: "Execution mode",
            subtitle: "How Distill works on this conversation. One mode is active at a time.",
            width: 460,
            accessibilityIdentifier: "agent.mode.sheet",
            onClose: { isPresented = false }
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                ForEach(DistillExecutionMode.allCases, id: \.self) { mode in
                    AgentChoiceCard(
                        title: mode.displayName,
                        subtitle: mode.pickerHelpText,
                        selected: mode == selected,
                        tint: mode.capsuleTint,
                        accessibilityIdentifier: "agent.mode.sheet.\(mode.rawValue)",
                        action: {
                            onSelect(mode)
                            isPresented = false
                        }
                    ) {
                        AgentChoiceIconTile(systemName: mode.capsuleIcon, tint: mode.capsuleTint)
                    }
                }
            }
        }
    }
}
