import SwiftUI
import AppKit
import DesignSystemKit

/// Rotating purple gradient border + soft glow for the composer card while Ultracode is on.
/// `angleOverride` pins the gradient (render tests); otherwise it rotates one lap per
/// `AgentUltracodeBorderPresentation.lapSeconds`, or stays static under Reduce Motion.
/// The rotation holds its angle while the window is not key or the composer is hidden
/// (background tab, closed window).
/// Core Animation turns the gradient: a SwiftUI timeline redrew the conic gradient and its
/// blurred glow on the CPU 30 times a second (most of a core while the composer was visible).
public struct UltracodeBorder: ViewModifier {
    public var active: Bool
    public var angleOverride: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var onScreen = true

    public init(active: Bool, angleOverride: Double? = nil) {
        self.active = active
        self.angleOverride = angleOverride
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                if active { border.transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.2), value: active)
    }

    private var border: some View {
        let animated = angleOverride == nil
            && AgentUltracodeBorderPresentation.isAnimated(reduceMotion: reduceMotion)
        let ticking = animated && AgentUltracodeBorderPresentation.isTicking(
            reduceMotion: reduceMotion,
            windowIsKey: controlActiveState == .key,
            onScreen: onScreen
        )
        return UltracodeBorderLayer(angle: angleOverride ?? 0, rotating: animated, paused: !ticking)
            .background(UltracodeBorderVisibilityProbe(onScreen: $onScreen))
            .allowsHitTesting(false)
    }
}

private struct UltracodeBorderLayer: NSViewRepresentable {
    var angle: Double
    var rotating: Bool
    var paused: Bool

    func makeNSView(context: Context) -> UltracodeBorderLayerView { UltracodeBorderLayerView() }

    func updateNSView(_ nsView: UltracodeBorderLayerView, context: Context) {
        nsView.update(angle: angle, rotating: rotating, paused: paused)
    }
}

/// The border as layers: a conic gradient spun by a repeating Core Animation rotation,
/// masked to the rounded stroke, with the glow as a shadow on the layer that holds it.
final class UltracodeBorderLayerView: NSView {
    static let spinKey = "ultracode.spin"
    let gradient = CAGradientLayer()
    private let glow = CALayer()
    private let ring = CALayer()
    private let stroke = CAShapeLayer()
    private let lineWidth: CGFloat = 1.5
    private var requested: (angle: Double, rotating: Bool, paused: Bool) = (0, false, true)

    /// True while the rotation is attached and its clock runs.
    var isSpinning: Bool { gradient.animation(forKey: Self.spinKey) != nil && gradient.speed != 0 }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        let tint = NSColor(DS.Palette.ultracode)
        gradient.type = .conic
        gradient.colors = [tint, NSColor(DS.Palette.ultracodeDeep), tint.withAlphaComponent(0.35), tint].map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        stroke.fillColor = nil
        stroke.strokeColor = NSColor.black.cgColor
        stroke.lineWidth = lineWidth
        ring.mask = stroke
        ring.addSublayer(gradient)
        glow.shadowColor = tint.cgColor
        glow.shadowOpacity = 0.35
        glow.shadowRadius = 6
        glow.shadowOffset = .zero
        glow.addSublayer(ring)
        layer?.addSublayer(glow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Added sublayers keep scale 1 unless told; a 1.5 pt stroke would blur on Retina.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for sublayer in [glow, ring, stroke, gradient] { sublayer.contentsScale = scale }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        ring.frame = bounds
        stroke.frame = bounds
        stroke.path = RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .inset(by: lineWidth / 2)
            .path(in: bounds)
            .cgPath
        // A square of the diagonal keeps the stroke covered at every rotation.
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    /// A detached view gets no SwiftUI update, so leaving the window pauses here too.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func update(angle: Double, rotating: Bool, paused: Bool) {
        requested = (angle, rotating, paused)
        apply()
    }

    private func apply() {
        let paused = requested.paused || window == nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard requested.rotating else {
            gradient.removeAnimation(forKey: Self.spinKey)
            resetClock()
            gradient.setAffineTransform(CGAffineTransform(rotationAngle: requested.angle * .pi / 180))
            return
        }
        gradient.setAffineTransform(.identity)
        if gradient.animation(forKey: Self.spinKey) == nil {
            resetClock()
            let lap = AgentUltracodeBorderPresentation.lapSeconds
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = lap
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            // Same phase as every other border on screen.
            spin.beginTime = gradient.convertTime(CACurrentMediaTime(), from: nil)
                - Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: lap)
            gradient.add(spin, forKey: Self.spinKey)
        }
        if paused, gradient.speed != 0 {
            let now = gradient.convertTime(CACurrentMediaTime(), from: nil)
            gradient.speed = 0
            gradient.timeOffset = now
        } else if !paused, gradient.speed == 0 {
            let pausedAt = gradient.timeOffset
            resetClock()
            gradient.beginTime = gradient.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        }
    }

    private func resetClock() {
        gradient.speed = 1
        gradient.timeOffset = 0
        gradient.beginTime = 0
    }
}

/// Reports whether the border's AppKit host is in a window and not hidden by an
/// ancestor (`isHidden` tab caches keep SwiftUI timelines running).
private struct UltracodeBorderVisibilityProbe: NSViewRepresentable {
    @Binding var onScreen: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { onScreen = $0 }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = { onScreen = $0 }
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var reported: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func viewDidHide() { super.viewDidHide(); report() }
        override func viewDidUnhide() { super.viewDidUnhide(); report() }

        private func report() {
            let visible = window != nil && !isHiddenOrHasHiddenAncestor
            guard visible != reported else { return }
            reported = visible
            // AppKit calls these mid-update; never write SwiftUI state synchronously.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reported == visible else { return }
                self.onChange?(visible)
            }
        }
    }
}
