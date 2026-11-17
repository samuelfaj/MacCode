import AppKit

@MainActor
final class AgentCursorOverlay {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class CursorView: NSView {
        var theme = "default"
        var session = ""
        var cursorColor = NSColor(red: 66 / 255, green: 165 / 255, blue: 245 / 255, alpha: 1)

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)

            switch theme {
            case "dot":
                let dot = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12))
                dot.lineWidth = 1.5
                shadow.set()
                cursorColor.setFill()
                dot.fill()
                NSColor.white.setStroke()
                dot.stroke()
                NSShadow().set()
            case "crosshair":
                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: 0, y: 8))
                path.line(to: NSPoint(x: 16, y: 8))
                path.move(to: NSPoint(x: 8, y: 0))
                path.line(to: NSPoint(x: 8, y: 16))
                shadow.set()
                cursorColor.setStroke()
                path.stroke()
                NSShadow().set()
            default:
                let scale: CGFloat = 1.2
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 1 * scale, y: 1 * scale))
                path.line(to: NSPoint(x: 1 * scale, y: 17.5 * scale))
                path.line(to: NSPoint(x: 5 * scale, y: 13.7 * scale))
                path.line(to: NSPoint(x: 7.8 * scale, y: 20.3 * scale))
                path.line(to: NSPoint(x: 10.8 * scale, y: 19 * scale))
                path.line(to: NSPoint(x: 8.1 * scale, y: 12.6 * scale))
                path.line(to: NSPoint(x: 13.3 * scale, y: 12.6 * scale))
                path.close()
                path.lineWidth = 1.5
                path.lineJoinStyle = .round
                shadow.set()
                cursorColor.setFill()
                path.fill()
                NSColor.white.setStroke()
                path.stroke()
                NSShadow().set()

                guard !session.isEmpty else { return }
                let text = session as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
                let textSize = text.size(withAttributes: attributes)
                let pill = NSRect(x: 22, y: 24, width: textSize.width + 12, height: 20)
                let label = NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7)
                cursorColor.setFill()
                label.fill()
                text.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + (pill.height - textSize.height) / 2), withAttributes: attributes)
            }
        }
    }

    private static var configured = false
    private var panels: [String: NSPanel] = [:]
    private var cursorViews: [String: CursorView] = [:]
    private var hides: [String: Task<Void, Never>] = [:]

    func remove(_ session: String) {
        hides.removeValue(forKey: session)?.cancel()
        panels.removeValue(forKey: session)?.orderOut(nil)
        cursorViews.removeValue(forKey: session)
    }

    func move(session: String, point: CGPoint, theme: String, color: String, duration: Double, hideAfter: Double) async {
        if !Self.configured {
            NSApplication.shared.setActivationPolicy(.accessory)
            // The stdio server runs a bare RunLoop, not NSApp.run(); without this the
            // window server never shows the panel.
            NSApplication.shared.finishLaunching()
            Self.configured = true
        }
        let panel: NSPanel
        let cursorView: CursorView
        if let existing = panels[session], let existingView = cursorViews[session] {
            panel = existing
            cursorView = existingView
        } else {
            panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            cursorView = CursorView(frame: NSRect(x: 0, y: 0, width: 200, height: 48))
            panel.contentView = cursorView
            panels[session] = panel
            cursorViews[session] = cursorView
        }
        cursorView.theme = theme
        cursorView.session = session
        cursorView.cursorColor = Self.color(color)
        cursorView.needsDisplay = true
        hides.removeValue(forKey: session)?.cancel()
        // Hotspot inside the flipped view: arrow tip, dot center, or crosshair center.
        let hotspot: CGFloat = ["dot": 6, "crosshair": 8][theme] ?? 1.2
        let origin = NSPoint(x: point.x - hotspot, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y - 48 + hotspot)
        if !panel.isVisible { panel.setFrameOrigin(origin) }
        panel.orderFrontRegardless()
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration / 1000
                panel.animator().setFrameOrigin(origin)
            } completionHandler: { continuation.resume() }
        }
        if hideAfter > 0 {
            hides[session] = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(hideAfter * 1_000_000)) } catch { return }
                self?.panels[session]?.orderOut(nil)
            }
        }
    }

    static func color(_ value: String) -> NSColor {
        let hex = UInt32(value.dropFirst(), radix: 16) ?? 0x42A5F5
        return NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
