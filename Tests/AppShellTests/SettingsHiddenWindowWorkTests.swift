import AppKit
import XCTest
@testable import AppShell

/// AppDelegate builds the stand-alone Settings window at launch, and the user
/// usually opens Settings inside the main window instead, so that stand-alone
/// window is often never shown. While its SwiftUI content was attached, every
/// published change re-ran the selected section's layout on the main thread
/// (hang 2026-11-18T01:55Z: ~420 of 881 main-thread samples laying out the
/// Accounts & Auto section of a Settings window the user never opened). An
/// unshown window must do no Settings work; showing it must still work.
@MainActor
final class SettingsHiddenWindowWorkTests: XCTestCase {
    func test_unshownSettingsWindowHostsNoSwiftUIUntilShown() throws {
        let directory = NSTemporaryDirectory() + "RC2SettingsHidden-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        try context.settingsRepo.set(SettingsViewModel.selectedCategoryKey, SettingsCategory.accounts.rawValue)

        let controller = SettingsWindowController(context: context)
        controller.window.animationBehavior = .none
        defer {
            controller.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(
            hostsSwiftUI(controller.window.contentView),
            "a Settings window nobody opened must not keep a live SwiftUI graph that relayouts on every change"
        )

        XCTAssertTrue(controller.show(route: .accounts), "showing Settings must still render the Accounts section")
        XCTAssertTrue(controller.window.isVisible)
        XCTAssertTrue(hostsSwiftUI(controller.window.contentView))
        XCTAssertEqual(controller.window.contentLayoutRect.width, 880, accuracy: 1, "first show keeps the designed size")
    }

    private func hostsSwiftUI(_ view: NSView?) -> Bool {
        guard let view else { return false }
        if String(describing: type(of: view)).contains("NSHostingView") { return true }
        return view.subviews.contains { hostsSwiftUI($0) }
    }
}
