import AppKit
import XCTest
@testable import AppShell

/// Settings/Account first-frame contract (AGENTS.md loading rule): show()
/// presents the window on the interaction turn using the VM's cached state,
/// and the SQLite/disk freshness pass runs only after the first frame commits
/// (committed-frame barrier). Rapid show() calls must coalesce into exactly
/// one reload (latest-wins), matching the shell-wide freshness pattern.
@MainActor
final class SettingsFirstFrameTests: XCTestCase {
    func test_showPaintsWindowBeforeFreshnessReload() async throws {
        let (controller, context) = try makeController()
        defer { close(controller) }
        // DB is newer than the VM cache captured at init.
        try context.settingsRepo.set("remote_access_enabled", "1")
        XCTAssertFalse(controller.viewModel.remoteAccessEnabled)

        controller.show()

        XCTAssertTrue(controller.window.isVisible, "window must present on the interaction turn")
        XCTAssertFalse(controller.viewModel.remoteAccessEnabled, "reload must not run synchronously in show()")

        let fresh = await drainUntil(controller.viewModel.remoteAccessEnabled)
        XCTAssertTrue(fresh, "deferred freshness pass must still complete exactly")
    }

    func test_showAttachedPresentsSheetBeforeFreshnessReload() async throws {
        let (controller, context) = try makeController()
        let parent = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        parent.animationBehavior = .none
        defer {
            close(controller)
            parent.orderOut(nil)
        }
        try context.settingsRepo.set("remote_access_enabled", "1")

        controller.show(attachedTo: parent)

        XCTAssertTrue(parent.attachedSheet === controller.window, "sheet must attach on the interaction turn")
        XCTAssertFalse(controller.viewModel.remoteAccessEnabled, "reload must not run synchronously in show(attachedTo:)")

        let fresh = await drainUntil(controller.viewModel.remoteAccessEnabled)
        XCTAssertTrue(fresh, "deferred freshness pass must still complete exactly")
    }

    func test_rapidShowCallsCoalesceIntoOneReload() async throws {
        let (controller, _) = try makeController()
        defer { close(controller) }
        XCTAssertEqual(controller.viewModel.reloadCountForTesting, 1, "init hydration counts once")

        controller.show()
        controller.show()

        let coalesced = await drainUntil(controller.viewModel.reloadCountForTesting == 2)
        XCTAssertTrue(
            coalesced,
            "A→B rapid shows must coalesce into exactly one freshness pass"
        )
        // Give a (regressed) second pass time to sneak in before locking the count.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.viewModel.reloadCountForTesting, 2)
    }

    func test_deferredConstructionHydratesOnFirstShow() async throws {
        let directory = NSTemporaryDirectory() + "RC2SettingsFirstFrame-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        // SidebarView constructs controllers with loadImmediately: false so the
        // first click turn does no SQLite/disk work; show() owns hydration.
        let controller = SettingsWindowController(
            context: context,
            loadImmediately: false
        )
        controller.window.animationBehavior = .none
        defer { close(controller) }
        try context.settingsRepo.set("remote_access_enabled", "1")
        XCTAssertEqual(controller.viewModel.reloadCountForTesting, 0)

        controller.show()

        XCTAssertTrue(controller.window.isVisible, "first frame must not wait for hydration")
        let fresh = await drainUntil(controller.viewModel.remoteAccessEnabled)
        XCTAssertTrue(fresh, "first freshness pass must hydrate the deferred VM")
        XCTAssertEqual(controller.viewModel.reloadCountForTesting, 1)
    }

    func test_accountWindowPaintsBeforeFreshnessReload() async throws {
        let directory = NSTemporaryDirectory() + "RC2AccountFirstFrame-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let controller = AccountWindowController(context: context)
        defer { close(controller) }
        try context.settingsRepo.set("remote_access_enabled", "1")
        XCTAssertFalse(controller.viewModel.remoteAccessEnabled)

        controller.show()

        XCTAssertTrue(controller.window.isVisible, "window must present on the interaction turn")
        XCTAssertFalse(controller.viewModel.remoteAccessEnabled, "reload must not run synchronously in show()")

        let fresh = await drainUntil(controller.viewModel.remoteAccessEnabled)
        XCTAssertTrue(fresh, "deferred freshness pass must still complete exactly")
    }

    // MARK: - Helpers

    private func makeController() throws -> (SettingsWindowController, AppContext) {
        let directory = NSTemporaryDirectory() + "RC2SettingsFirstFrame-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let controller = SettingsWindowController(
            context: context
        )
        controller.window.animationBehavior = .none
        return (controller, context)
    }

    private func close(_ controller: SettingsWindowController) {
        controller.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func close(_ controller: AccountWindowController) {
        controller.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Pumps the main queue until `condition` holds (committed-frame barrier
    /// plus task body need a few main-queue turns), bounded by `timeout`.
    @discardableResult
    private func drainUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return condition()
    }

    func test_cliPathDraftsSurviveSectionSwitch() throws {
        // WHY: switching Settings sections re-runs onAppear; unsaved CLI path typing must not be overwritten.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AppShell/SettingsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("if draft.isEmpty || draft == stored { draft = stored }"))
        XCTAssertFalse(source.contains("codexPathDraft = vm.codexPath"))
    }
}
