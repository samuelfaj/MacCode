import SwiftUI
import AppKit
import CoreModel

// MARK: - Focus ring

public extension View {
    /// Renders the DS focus ring (DS.Palette.focusRing, 2pt, cornerRadius DS.Radius.control)
    /// around any interactive element that has keyboard focus.
    /// Usage: myControl.dsFocusRing(isFocused: focused)
    @ViewBuilder
    func dsFocusRing(isFocused: Bool, cornerRadius: CGFloat = DS.Radius.control) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(DS.Palette.focusRing, lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
        )
    }
}

// MARK: - Hover fill

/// Fill decision for `dsHoverFill` (pure, testable seam).
public enum DSHoverFill {
    /// - enabled: false => clear, so a selected row keeps its own fill
    /// - isHovering: true => DS.Palette.hover
    /// - otherwise => clear
    public static func fill(isHovering: Bool, enabled: Bool) -> Color {
        isHovering && enabled ? DS.Palette.hover : Color.clear
    }
}

private struct DSHoverFillModifier: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(DSHoverFill.fill(isHovering: hovering, enabled: enabled))
            )
            .onHover { hovering = $0 }
    }
}

public extension View {
    /// Paints DS.Palette.hover behind a clickable row while the pointer is over it.
    /// Instant on purpose: hover on the Mac does not fade.
    /// Usage: row.dsHoverFill(enabled: !selected)
    func dsHoverFill(enabled: Bool = true, cornerRadius: CGFloat = DS.Radius.control) -> some View {
        modifier(DSHoverFillModifier(enabled: enabled, cornerRadius: cornerRadius))
    }
}

// MARK: - Surface containers

public extension View {
    /// Panel: the dense card used for changed-files, plan, feed rows.
    /// Occupies the full proposed width (one complete line); content stays leading.
    func dsPanel(padding: CGFloat = DS.Space.lg, raised: Bool = false) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(raised ? DS.Palette.surfaceRaised : DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
    }

    /// Top/bottom bar background with a single hairline divider edge.
    func dsBar(edge: Edge = .bottom) -> some View {
        self
            .background(DS.Palette.surface)
            .overlay(alignment: edge == .bottom ? .bottom : .top) {
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            }
    }

}

// MARK: - Status pill

public struct DSPill: View {
    public enum Tone { case neutral, accent, success, warning, danger }
    let text: String
    let tone: Tone
    public init(_ text: String, tone: Tone = .neutral) { self.text = text; self.tone = tone }

    /// Maps each semantic tone to its SF Symbol name.
    /// Returns nil for tones that carry no distinct semantic state (neutral, accent).
    /// Used in body so the pill conveys state by icon+shape, not color alone (WCAG 1.4.1).
    public static func iconName(for tone: Tone) -> String? {
        switch tone {
        case .neutral: return nil
        case .accent:  return nil
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger:  return "xmark.octagon.fill"
        }
    }

    public var body: some View {
        HStack(spacing: DS.Space.xxs) {
            if let symbol = DSPill.iconName(for: tone) {
                Image(systemName: symbol)
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(fg)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(DS.Font.caption2.weight(.semibold))
                .foregroundColor(fg)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xxs)
        .background(bg)
        .clipShape(Capsule())
    }
    private var fg: Color {
        switch tone {
        case .neutral: return DS.Palette.textSecondary
        case .accent:  return DS.Palette.accent
        case .success: return DS.Palette.success
        case .warning: return DS.Palette.warning
        case .danger:  return DS.Palette.danger
        }
    }
    private var bg: Color {
        switch tone {
        case .neutral: return DS.Palette.surfaceOverlay
        case .accent:  return DS.Palette.accent.opacity(0.16)
        case .success: return DS.Palette.success.opacity(0.16)
        case .warning: return DS.Palette.warning.opacity(0.16)
        case .danger:  return DS.Palette.danger.opacity(0.16)
        }
    }
}

// MARK: - Icon button (compact visual; 26x22pt; 44x44pt hit target via contentShape)

public struct DSIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    /// Minimum hit-target dimension applied inside the component (HIG Adaptivity and Layout).
    nonisolated public static let hitTargetSize: CGFloat = 44
    /// Visual icon frame (narrower than hit target).
    nonisolated public static let visualSize: CGSize = CGSize(width: 26, height: 22)
    /// Inset that collapses the 44pt layout box to the glyph so HStack
    /// spacing is measured between icons, not hit boxes.
    nonisolated public static var visualPackInset: CGFloat {
        (hitTargetSize - visualSize.width) / 2
    }

    public init(_ systemName: String, help: String = "", action: @escaping () -> Void) {
        self.systemName = systemName; self.help = help; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(hovering ? DS.Palette.text : DS.Palette.textSecondary)
                .frame(width: 26, height: 22)
                .background(hovering ? DS.Palette.hover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                // Expand hit target to 44x44pt without changing the visual footprint.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Button opacity helper (pure, testable seam)

/// Computes the effective opacity for a DS button given its interaction state.
/// - isEnabled: false => DS.Alpha.disabled (hard floor, overrides hover)
/// - isHovering: true => 1.0 + DS.Alpha.hoverDelta (clamped to 1.0)
/// - normal     => 1.0
public enum DSButtonOpacity {
    public static func effectiveOpacity(isEnabled: Bool, isHovering: Bool) -> Double {
        guard isEnabled else { return DS.Alpha.disabled }
        return isHovering ? min(1.0, 1.0 + DS.Alpha.hoverDelta) : 1.0
    }
}

// MARK: - Primary / secondary button styles

public struct DSPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.body.weight(.semibold))
            .foregroundColor(DS.Palette.onAccent)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.md)
            .background(DS.Palette.accent.opacity(configuration.isPressed ? 0.82 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .opacity(DSButtonOpacity.effectiveOpacity(isEnabled: isEnabled, isHovering: hovering))
            .onHover { hovering = $0 }
    }
}

public struct DSSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let bg: Color = configuration.isPressed
            ? DS.Palette.pressed
            : (hovering ? DS.Palette.hover : DS.Palette.surfaceRaised)
        return configuration.label
            .font(DS.Font.body)
            .foregroundColor(DS.Palette.text)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
            .opacity(DSButtonOpacity.effectiveOpacity(isEnabled: isEnabled, isHovering: hovering))
            .onHover { hovering = $0 }
    }
}

// MARK: - Section header

public struct DSSectionHeader: View {
    let title: String
    let trailing: AnyView?
    public init(_ title: String, trailing: AnyView? = nil) {
        self.title = title; self.trailing = trailing
    }
    public var body: some View {
        HStack(spacing: DS.Space.md) {
            Text(title.uppercased())
                .font(DS.Font.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundColor(DS.Palette.textTertiary)
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }
}

/// Generic variant of DSSectionHeader that accepts a concrete @ViewBuilder trailing view,
/// preserving SwiftUI identity (no AnyView erasure). Prefer this over DSSectionHeader
/// on hot paths (lists, frequently-updating sections).
public struct DSSectionHeaderG<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: DS.Space.md) {
            Text(title.uppercased())
                .font(DS.Font.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundColor(DS.Palette.textTertiary)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }
}

/// Convenience init for the no-trailing case (trailing = EmptyView).
extension DSSectionHeaderG where Trailing == EmptyView {
    public init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

// MARK: - DSSectionHeaderG pure helpers (testable seam; no SwiftUI host required)

extension DSSectionHeaderG {
    /// Returns the display text exactly as rendered: uppercased, matching Text(title.uppercased()).
    /// Exists as a nonisolated static seam so tests can verify the transform without a View host.
    nonisolated public static func displayTitle(for rawTitle: String) -> String {
        rawTitle.uppercased()
    }
}

// MARK: - Empty state

public struct DSEmptyState<Action: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let background: Color
    let action: Action

    public init(
        icon: String,
        title: String,
        subtitle: String,
        background: Color = DS.Palette.bg,
        @ViewBuilder action: () -> Action
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.background = background
        self.action = action()
    }

    public var body: some View {
        VStack(spacing: DS.Space.lg) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            Text(title).font(DS.Font.title3).foregroundColor(DS.Palette.textSecondary)
            Text(subtitle)
                .font(DS.Font.bodyDense)
                .foregroundColor(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            action
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }
}

extension DSEmptyState where Action == EmptyView {
    public init(icon: String, title: String, subtitle: String, background: Color = DS.Palette.bg) {
        self.init(icon: icon, title: title, subtitle: subtitle, background: background) {
            EmptyView()
        }
    }
}

/// Trailing busy spinner used by Agentic workspace rows and dest dest roster.
public struct DSBusySpinner: View {
    public let label: String
    public var identifier: String?

    public init(label: String, identifier: String? = nil) {
        self.label = label
        self.identifier = identifier
    }

    public var body: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.7)
            .frame(width: 16, height: 16)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier ?? "ds.busy.spinner")
    }
}

// MARK: - Resize dividers

public enum DSResizeAxis {
    /// A vertical divider between left/right panes. Drag delta is horizontal.
    case vertical
    /// A horizontal divider between top/bottom panes. Drag delta is vertical.
    case horizontal

    var cursor: NSCursor {
        switch self {
        case .vertical: return .resizeLeftRight
        case .horizontal: return .resizeUpDown
        }
    }
}

public struct DSResizeDivider: View {
    private let axis: DSResizeAxis
    private let help: String
    private let onDrag: ((CGFloat) -> Void)?
    @State private var lastTranslation: CGFloat = 0

    /// Step applied per arrow-key press via accessibilityAdjustableAction (20pt = ~2 text rows).
    static let keyStep: CGFloat = 20

    public init(axis: DSResizeAxis, help: String = "", onDrag: ((CGFloat) -> Void)? = nil) {
        self.axis = axis
        self.help = help
        self.onDrag = onDrag
    }

    // Returns a non-empty accessible label: the caller-supplied help string, or a
    // direction-aware fallback so VoiceOver users always hear a meaningful name.
    var accessibleLabel: String {
        help.isEmpty ? (axis == .vertical ? L("Resize horizontally") : L("Resize vertically")) : help
    }

    public var body: some View {
        Rectangle()
            .fill(DS.Palette.line.opacity(0.78))
            .overlay {
                Capsule()
                    .fill(DS.Palette.lineStrong.opacity(0.92))
                    .frame(width: axis == .vertical ? DS.ResizeDivider.gripThickness : DS.ResizeDivider.gripLength,
                           height: axis == .vertical ? DS.ResizeDivider.gripLength : DS.ResizeDivider.gripThickness)
            }
            .frame(width: axis == .vertical ? DS.ResizeDivider.thickness : nil,
                   height: axis == .horizontal ? DS.ResizeDivider.thickness : nil)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard let onDrag else { return }
                        let current = axis == .vertical ? value.translation.width : value.translation.height
                        onDrag(current - lastTranslation)
                        lastTranslation = current
                    }
                    .onEnded { _ in lastTranslation = 0 }
            )
            .help(accessibleLabel)
            .accessibilityLabel(accessibleLabel)
            .accessibilityAdjustableAction { direction in
                guard let onDrag else { return }
                switch direction {
                case .increment: onDrag(+DSResizeDivider.keyStep)
                case .decrement: onDrag(-DSResizeDivider.keyStep)
                @unknown default: break
                }
            }
    }
}

public final class DSResizeHandleView: NSView {
    public var onDrag: ((CGFloat, Bool) -> Void)?
    public let axis: DSResizeAxis
    private let grip = NSView()

    public init(axis: DSResizeAxis) {
        self.axis = axis
        super.init(frame: .zero)
        configure()
    }

    public required init?(coder: NSCoder) {
        self.axis = .vertical
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = DS.NS.line.cgColor
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.wantsLayer = true
        grip.layer?.backgroundColor = DS.NS.lineStrong.cgColor
        grip.layer?.cornerRadius = DS.ResizeDivider.gripThickness / 2
        addSubview(grip)
        NSLayoutConstraint.activate([
            grip.centerXAnchor.constraint(equalTo: centerXAnchor),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: axis == .vertical ? DS.ResizeDivider.gripThickness : DS.ResizeDivider.gripLength),
            grip.heightAnchor.constraint(equalToConstant: axis == .vertical ? DS.ResizeDivider.gripLength : DS.ResizeDivider.gripThickness)
        ])
        addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis.cursor)
    }

    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        let delta = axis == .vertical ? translation.x : translation.y
        onDrag?(delta, recognizer.state == .ended || recognizer.state == .cancelled)
    }
}
