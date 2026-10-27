import SwiftUI
import CoreModel
import DesignSystemKit

/// Blobatar renderer. Picker tiles stay `.frozen` (bloub BotTile).
public struct BotBlobatarView: View {
    public var name: String
    public var spec: BotBlobatarSpec
    public var size: CGFloat
    public var motion: BotBlobatarMotionMode
    public var handle: String
    public var tintHex: UInt32? = nil
    /// Renders one fixed frame of the motion (snapshots and tests).
    var fixedTime: TimeInterval? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    public init(
        name: String,
        spec: BotBlobatarSpec,
        size: CGFloat,
        motion: BotBlobatarMotionMode = .frozen,
        handle: String = "",
        tintHex: UInt32? = nil
    ) {
        self.name = name
        self.spec = spec
        self.size = size
        self.motion = motion
        self.handle = handle
        self.tintHex = tintHex
    }

    public var body: some View {
        let figure = BotBlobatar.figure(name: name, spec: spec, handle: handle, tintHex: tintHex)
        let motionSeed = spec.renderSeed(liveName: name, handle: handle)
        Group {
            if let fixedTime {
                canvas(figure, Self.pose(motion: motion, seed: motionSeed, time: fixedTime, expression: spec.expression))
            } else if reduceMotion || motion == .frozen || (motion == .hover && !hovering) {
                // Still avatars draw once; only moving ones pay for a timeline.
                canvas(figure, .still)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    canvas(figure, Self.pose(motion: motion, seed: motionSeed, time: timeline.date.timeIntervalSinceReferenceDate, expression: spec.expression))
                }
            }
        }
        .frame(width: size, height: size)
        .onHover { hovering = $0 }
        .accessibilityHidden(true)
    }

    /// Pose for one frame: `.working` hops, every other moving mode breathes.
    static func pose(motion: BotBlobatarMotionMode, seed: String, time: TimeInterval, expression: BotBlobatarExpression) -> BotBlobatarMotion {
        switch motion {
        case .frozen: return .still
        case .working: return BotBlobatarMotion.sampleWorking(name: seed, time: time)
        case .always, .hover: return BotBlobatar.motion(name: seed, time: time, expression: expression, amplitude: 1)
        }
    }

    private func canvas(_ figure: BotBlobatarFigure, _ pose: BotBlobatarMotion) -> some View {
        Canvas { context, canvasSize in
            draw(figure: figure, motion: pose, in: context, canvasSize: canvasSize)
        }
    }

    private func draw(
        figure: BotBlobatarFigure,
        motion: BotBlobatarMotion,
        in context: GraphicsContext,
        canvasSize: CGSize
    ) {
        let scale = min(canvasSize.width, canvasSize.height) / 100
        let scaleOnly = CGAffineTransform(scaleX: scale, y: scale)
        var body = scaleOnly
        if figure.bodyOffsetY != 0 {
            body = body.translatedBy(x: 0, y: figure.bodyOffsetY)
        }
        body = body
            .translatedBy(x: 50 + motion.shakeX, y: 50 + motion.bobY + motion.shakeY)
            .scaledBy(x: motion.breatheX, y: motion.breatheY)
            .translatedBy(x: -50, y: -50)
        let head = color(figure.palette.head)
        for petal in figure.petals {
            let rect = CGRect(x: petal.cx - petal.r, y: petal.cy - petal.r, width: petal.r * 2, height: petal.r * 2)
            context.fill(Path(ellipseIn: rect).applying(body), with: .color(head))
        }
        context.fill(bodyPath(figure).applying(body), with: .color(head))
        let ink = color(figure.palette.eye)
        let glance = size >= 40 ? motion : BotBlobatarMotion(
            breatheX: motion.breatheX,
            breatheY: motion.breatheY,
            bobY: motion.bobY,
            blink: motion.blink,
            glanceX: 0,
            glanceY: 0,
            shakeX: motion.shakeX,
            shakeY: motion.shakeY
        )
        for capsule in figure.eyes {
            var eye = body.translatedBy(x: glance.glanceX, y: glance.glanceY)
            eye = eye.translatedBy(x: capsule.cx, y: capsule.cy)
                .scaledBy(x: 1, y: glance.blink)
                .translatedBy(x: -capsule.cx, y: -capsule.cy)
            context.fill(superellipse(capsule).applying(eye), with: .color(ink))
        }
    }

    private func bodyPath(_ figure: BotBlobatarFigure) -> Path {
        if figure.resolvedShape == .organic || figure.resolvedShape == .cloud {
            return blobPath(
                cx: figure.body.cx,
                cy: figure.body.cy,
                rx: figure.body.rx,
                ry: figure.body.ry,
                radii: figure.radii,
                rot: figure.resolvedShape == .cloud ? 0 : figure.body.rot
            )
        }
        return superellipse(figure.body)
    }

    private func superellipse(_ e: BotBlobatarEllipse) -> Path {
        let n = max(1.2, e.n)
        let k = min(1, (8 * pow(2, -1 / n) - 4) / 3)
        let a = e.rx
        let b = e.ry
        let ak = a * k
        let bk = b * k
        let pts: [(Double, Double)] = [
            (a, 0),
            (a, bk), (ak, b), (0, b),
            (-ak, b), (-a, bk), (-a, 0),
            (-a, -bk), (-ak, -b), (0, -b),
            (ak, -b), (a, -bk), (a, 0),
        ]
        let t = e.rot * .pi / 180
        let cosT = cos(t)
        let sinT = sin(t)
        func map(_ p: (Double, Double)) -> CGPoint {
            CGPoint(
                x: e.cx + p.0 * cosT - p.1 * sinT,
                y: e.cy + p.0 * sinT + p.1 * cosT
            )
        }
        var path = Path()
        path.move(to: map(pts[0]))
        var i = 1
        while i + 2 < pts.count {
            path.addCurve(to: map(pts[i + 2]), control1: map(pts[i]), control2: map(pts[i + 1]))
            i += 3
        }
        path.closeSubpath()
        return path
    }

    private func blobPath(cx: Double, cy: Double, rx: Double, ry: Double, radii: [Double], rot: Double) -> Path {
        let count = radii.count
        guard count >= 3 else {
            return superellipse(BotBlobatarEllipse(cx: cx, cy: cy, rx: rx, ry: ry, n: 2, rot: rot))
        }
        let t0 = rot * .pi / 180
        let points: [CGPoint] = radii.enumerated().map { i, m in
            let a = t0 + (2 * .pi * Double(i)) / Double(count)
            return CGPoint(x: cx + rx * m * cos(a), y: cy + ry * m * sin(a))
        }
        func at(_ i: Int) -> CGPoint {
            points[((i % count) + count) % count]
        }
        var path = Path()
        path.move(to: at(0))
        for i in 0..<count {
            let p0 = at(i - 1)
            let p1 = at(i)
            let p2 = at(i + 1)
            let p3 = at(i + 2)
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            )
        }
        path.closeSubpath()
        return path
    }

    private func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
