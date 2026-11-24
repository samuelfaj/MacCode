import XCTest
import SwiftUI
import CoreModel
@testable import Surfaces

@MainActor
final class UltracodeBorderTests: XCTestCase {
    func test_ultracodeBorder_showsOnlyForDistillWithUltracodeOn() {
        XCTAssertTrue(AgentUltracodeBorderPresentation.shows(provider: .distill, ultracode: true))
        XCTAssertFalse(AgentUltracodeBorderPresentation.shows(provider: .distill, ultracode: false))
        XCTAssertFalse(AgentUltracodeBorderPresentation.shows(provider: .claude, ultracode: true))
    }

    func test_ultracodeBorder_reduceMotionStopsAnimation() {
        XCTAssertFalse(AgentUltracodeBorderPresentation.isAnimated(reduceMotion: true))
        XCTAssertTrue(AgentUltracodeBorderPresentation.isAnimated(reduceMotion: false))
        XCTAssertEqual(AgentUltracodeBorderPresentation.lapSeconds, 4)
    }

    /// WHY: the 30 Hz rotation (gradient + blurred glow rebuilt every tick) only
    /// earns its cost where someone sees it. A non-key window or a hidden
    /// composer must hold still; Reduce Motion still wins everywhere.
    func test_ultracodeBorder_ticksOnlyInKeyWindowWhileOnScreen() {
        XCTAssertTrue(AgentUltracodeBorderPresentation.isTicking(reduceMotion: false, windowIsKey: true, onScreen: true))
        XCTAssertFalse(AgentUltracodeBorderPresentation.isTicking(reduceMotion: false, windowIsKey: false, onScreen: true))
        XCTAssertFalse(AgentUltracodeBorderPresentation.isTicking(reduceMotion: false, windowIsKey: true, onScreen: false))
        XCTAssertFalse(AgentUltracodeBorderPresentation.isTicking(reduceMotion: true, windowIsKey: true, onScreen: true))
    }

    /// The border's Core Animation view inside `root`, if mounted.
    private func borderLayerView(in root: NSView) -> UltracodeBorderLayerView? {
        if let view = root as? UltracodeBorderLayerView { return view }
        for child in root.subviews {
            if let found = borderLayerView(in: child) { return found }
        }
        return nil
    }

    /// Whether a mounted border is turning after the probe and SwiftUI settle.
    /// `state` nil leaves the control state to the real (never key) test window.
    private func borderSpins(state: ControlActiveState?, hideHost: Bool = false) throws -> Bool {
        let border = RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.black)
            .frame(width: 420, height: 90)
            .modifier(UltracodeBorder(active: true))
            .padding(24)
        let view = Group {
            if let state { border.environment(\.controlActiveState, state) } else { border }
        }
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 500, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if hideHost {
            // How cached Agent App tabs are parked: hidden, still in the window.
            host.isHidden = true
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        return try XCTUnwrap(borderLayerView(in: host), "border view mounted").isSpinning
    }

    /// WHY: before the timeline paused, the rotation ran at ~30 frames/s in every
    /// case below; it must only turn where someone can see it.
    func test_ultracodeBorder_holdsStillWhenWindowNotKeyOrHostHidden() throws {
        XCTAssertTrue(try borderSpins(state: .key), "a key, visible composer must keep rotating (the look stays)")
        XCTAssertFalse(try borderSpins(state: nil), "real non-key window: holds still")
        XCTAssertFalse(try borderSpins(state: .inactive), "not key / app in background: holds still")
        XCTAssertFalse(try borderSpins(state: .key, hideHost: true), "hidden tab host: holds still")
    }

    /// WHY: tabs are parked by hiding an AppKit ancestor and shown again by
    /// unhiding it. Pausing there must not freeze the border for good: once the
    /// tab is back on screen in the key window, the rotation resumes. While parked
    /// it holds its angle instead of snapping back.
    func test_ultracodeBorder_resumesWhenHiddenAncestorIsShownAgain() throws {
        let view = RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.black)
            .frame(width: 420, height: 90)
            .modifier(UltracodeBorder(active: true))
            .padding(24)
            .environment(\.controlActiveState, .key)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 500, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tab = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
        let host = NSHostingView(rootView: view)
        host.frame = tab.bounds
        tab.addSubview(host)
        window.contentView = tab
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        func settle(_ change: () -> Void = {}) {
            change()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        func angle(_ border: UltracodeBorderLayerView) -> Double {
            border.gradient.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double ?? .nan
        }
        settle()
        let border = try XCTUnwrap(borderLayerView(in: host))
        XCTAssertTrue(border.isSpinning, "precondition: visible in a key window rotates")
        settle { tab.isHidden = true }
        XCTAssertFalse(border.isSpinning, "parked tab holds still")
        let parked = angle(border)
        settle()
        XCTAssertEqual(angle(border), parked, accuracy: 0.0001, "a parked border keeps its angle")
        settle { tab.isHidden = false }
        XCTAssertTrue(border.isSpinning, "shown again: rotation resumes")
        settle { host.removeFromSuperview() }
        XCTAssertFalse(border.isSpinning, "detached host holds still")
        settle { tab.addSubview(host) }
        XCTAssertTrue(border.isSpinning, "re-attached host rotates again")
    }

    /// WHY: the border turns for as long as an Ultracode composer sits in the key
    /// window, often for hours while a run streams. Redrawing its conic gradient and
    /// blurred glow through a SwiftUI timeline cost ~760 ms of CPU per second for a
    /// composer-sized card (the live app showed ~35% of a core on the main thread).
    /// The rotation must run in Core Animation, leaving the app near idle.
    func test_ultracodeBorder_rotatesWithoutSpendingAppCPUEveryFrame() {
        let view = RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.black)
            .frame(width: 760, height: 120)
            .modifier(UltracodeBorder(active: true))
            .padding(24)
            .environment(\.controlActiveState, .key)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 820, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func cpuMs() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
        }
        let start = cpuMs()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertLessThan(cpuMs() - start, 150, "a rotating border must not redraw on the app's CPU every frame")
    }

    /// Render evidence; writes PNGs only when ULTRACODE_RENDER_DIR is set.
    func test_ultracodeBorder_rendersPNGs() throws {
        guard let dir = ProcessInfo.processInfo.environment["ULTRACODE_RENDER_DIR"] else {
            throw XCTSkip("ULTRACODE_RENDER_DIR not set")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for angle in [0.0, 120.0] {
            let view = RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.black)
                .frame(width: 420, height: 90)
                .modifier(UltracodeBorder(active: true, angleOverride: angle))
                .padding(24)
                .background(Color(red: 0.06, green: 0.08, blue: 0.1))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ultracode-border-\(Int(angle)).png"))
        }
    }
}
