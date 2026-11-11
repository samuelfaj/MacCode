import AppKit
import SwiftUI
import XCTest
import DesignSystemKit
@testable import AppShell

/// Every scene of the Chrome walkthrough must render a non-empty frame, and
/// the loop must cover the five setup actions in order.
@MainActor
final class OnboardingChromeGuideSnapshotTests: XCTestCase {
    func test_everyGuideSceneRendersAndTheLoopFollowsTheSetupOrder() throws {
        XCTAssertEqual(OnboardingChromeGuideAnimation.Scene.allCases,
                       [.openExtensions, .developerMode, .loadUnpacked, .chooseFolder, .enabled])
        let outDir = ProcessInfo.processInfo.environment["RC_ONBOARDING_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        for scene in OnboardingChromeGuideAnimation.Scene.allCases {
            let host = NSHostingView(rootView: OnboardingChromeGuideAnimation(still: scene)
                .frame(width: 440).background(DS.Palette.bg).preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: 440, height: 420)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 5_000, "\(scene) rendered an empty frame")
            XCTAssertFalse(scene.caption.isEmpty)
            if let outDir { try png.write(to: outDir.appendingPathComponent("chrome-guide-\(scene.rawValue).png")) }
        }
    }
}
