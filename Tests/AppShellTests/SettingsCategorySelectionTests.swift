import XCTest
@testable import AppShell
import CoreModel
import Persistence

/// WHY: Settings lives in the main window now, so the selected category is the
/// only place that remembers which destination the user left open. It must
/// survive a reopen of MacCode, or the Settings destination silently resets.
final class SettingsGeneralCategoryTests: XCTestCase {
    // WHY: the interface language lives under Settings > General, so that row
    // must exist, come first, and stay reachable from every other group.
    func testGeneralIsTheFirstSettingsRow() {
        XCTAssertEqual(SettingsCategory.allCases.first, .general)
        XCTAssertEqual(SettingsCategory.groups.first, [.general])
        XCTAssertEqual(SettingsCategory.general.title, L("General"))
        XCTAssertEqual(SettingsCategory.general.group, 0)
        XCTAssertEqual(SettingsCategory.general.symbol, "globe")
    }
}

@MainActor
final class SettingsCategorySelectionTests: XCTestCase {
    func testNotificationsCategoryPersistsAcrossViewModels() throws {
        let dir = NSTemporaryDirectory() + "RC2SettingsCategory-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let viewModel = SettingsViewModel(context: context)
        viewModel.selectedCategory = .notifications
        XCTAssertEqual(SettingsViewModel(context: context).selectedCategory, .notifications)
    }

    func test_selectRouteAccountsSelectsAccountsAndPersistsAcrossViewModels() throws {
        let dir = NSTemporaryDirectory() + "RC2SettingsCategory-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let vm = SettingsViewModel(context: ctx)
        XCTAssertEqual(vm.selectedCategory, .remoteAccess)

        vm.select(route: .accounts)

        XCTAssertEqual(vm.selectedCategory, .accounts)
        XCTAssertEqual(SettingsViewModel(context: ctx).selectedCategory, .accounts)
    }
}
