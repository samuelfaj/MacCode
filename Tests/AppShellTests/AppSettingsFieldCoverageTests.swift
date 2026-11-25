import XCTest
import Persistence
@testable import AppShell

/// Coverage guard: every user-tunable AppSettings field must appear in
/// AppSettingsKeys.userTunableKeys so no field is silently omitted from
/// the Settings window.
///
/// Business rule: when a developer adds a new field to AppSettings they
/// must also add its key to AppSettingsKeys.userTunableKeys; this test
/// fails at that boundary, not silently at runtime.
///
/// @MainActor is required because SettingsViewModel is a @MainActor class
/// and the setter / reload tests call into it directly.
@MainActor
final class AppSettingsFieldCoverageTests: XCTestCase {

    // MARK: - Coverage guard (pure key-list assertions; no AppContext needed)

    /// Assert that every property declared on AppSettings has a matching
    /// entry in AppSettingsKeys.userTunableKeys.
    ///
    /// WHY: If a developer adds a field to AppSettings without adding it to
    /// the keys list, the Settings window will not surface the new field and
    /// users will have no UI to control it.
    func test_allAppSettingsFieldsCoveredByKeysList() {
        let expected: Set<String> = [
            "diffWordWrap",
            "diffIgnoreWhitespace",
            "sidebarSort",
            "insomniaEnabled",
            "notificationActionAlertsEnabled",
            "notificationCompletionAlertsEnabled",
            "notificationSoundEnabled",
            "notificationMutedWorkspaceIDs",
            "titioNotificationsEnabled",
            "titioLanguage",
            "insomniaAllowDisplaySleep",
            "insomniaAllowSystemSleepWhenDisplayClosed",
            "insomniaAllowScreenSaverAfter45MinutesOfInactivity",
            "terminalFontSize",
            "petEnabled",
            "petAnimationsEnabled",
            "petReadyCounterEnabled",
            "petPosition",
            "petSize",
            "petAttentionFilter",
            "petReduceMotion",
            "petSpeechEnabled",
            "botsControlPlaneEnabled",
            "botsMemoryEnabled",
            "botsEffectsEnabled",
            "botsAutonomyEnabled",
            "botsChannelsEnabled",
            "distillHighParallelism",
            "concurrentLeaseMode",
            "localRunConflictPolicy",
        ]
        let actual = Set(AppSettingsKeys.userTunableKeys)
        XCTAssertEqual(
            actual, expected,
            "AppSettingsKeys.userTunableKeys must list every user-tunable AppSettings field. " +
            "Missing: \(expected.subtracting(actual)), extra: \(actual.subtracting(expected))"
        )
    }

    /// Assert there are no duplicate keys (a duplicate signals a copy-paste error
    /// and would make the coverage check misleading).
    func test_userTunableKeysHasNoDuplicates() {
        let keys = AppSettingsKeys.userTunableKeys
        let unique = Set(keys)
        XCTAssertEqual(
            keys.count, unique.count,
            "AppSettingsKeys.userTunableKeys must not contain duplicates - duplicates make the coverage count misleading"
        )
    }

    // MARK: - SettingsViewModel setter round-trips (no AppContext / MainActor needed)

    /// Each setter must both mutate appSettings in-memory and persist via
    /// settingsStore.update so a subsequent reload() reflects the change.
    ///
    /// WHY: A setter that only updates the @Published property without calling
    /// settingsStore.update would silently lose the value on the next reload.
    func test_settersPersistToSettingsStore() throws {
        let dir = NSTemporaryDirectory() + "RC2AppSettingsFieldCoverage-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)

        let vm = SettingsViewModel(context: ctx)

        // Sidebar sort
        vm.setSidebarSort("created")
        XCTAssertEqual(vm.appSettings.sidebarSort, "created",
                       "setSidebarSort must update appSettings immediately")
        XCTAssertEqual(SettingsStore(db: ctx.db).load().sidebarSort, "created",
                       "setSidebarSort must persist the value so reload() sees it")

        vm.setNotificationActionAlertsEnabled(false)
        vm.setNotificationCompletionAlertsEnabled(false)
        vm.setNotificationSoundEnabled(true)
        vm.setNotificationWorkspaceMuted("workspace-a", muted: true)
        let notifications = SettingsStore(db: ctx.db).load()
        XCTAssertFalse(notifications.notificationActionAlertsEnabled)
        XCTAssertFalse(notifications.notificationCompletionAlertsEnabled)
        XCTAssertTrue(notifications.notificationSoundEnabled)
        XCTAssertEqual(notifications.notificationMutedWorkspaceIDs, ["workspace-a"])

        // Terminal base font
        vm.setTerminalFontSize(16)
        XCTAssertEqual(vm.appSettings.terminalFontSize, 16,
                       "setTerminalFontSize must update appSettings immediately")
        XCTAssertEqual(SettingsStore(db: ctx.db).load().terminalFontSize, 16,
                       "setTerminalFontSize must persist so new terminal surfaces use the selected base size")

        // Insomnia enabled flag
        vm.setInsomniaEnabled(true)
        XCTAssertTrue(vm.appSettings.insomniaEnabled)
        XCTAssertTrue(SettingsStore(db: ctx.db).load().insomniaEnabled,
                      "setInsomniaEnabled must persist so InsomniaPowerManager sees it on next launch")

        // Insomnia sub-options
        vm.setInsomniaAllowDisplaySleep(false)
        XCTAssertFalse(vm.appSettings.insomniaAllowDisplaySleep)
        XCTAssertFalse(SettingsStore(db: ctx.db).load().insomniaAllowDisplaySleep)

        vm.setInsomniaAllowSystemSleepWhenDisplayClosed(true)
        XCTAssertTrue(vm.appSettings.insomniaAllowSystemSleepWhenDisplayClosed)
        XCTAssertTrue(SettingsStore(db: ctx.db).load().insomniaAllowSystemSleepWhenDisplayClosed)

        vm.setInsomniaAllowScreenSaverAfter45MinutesOfInactivity(false)
        XCTAssertFalse(vm.appSettings.insomniaAllowScreenSaverAfter45MinutesOfInactivity)
        XCTAssertFalse(SettingsStore(db: ctx.db).load().insomniaAllowScreenSaverAfter45MinutesOfInactivity)

        vm.setPetEnabled(true)
        vm.setPetAnimationsEnabled(false)
        vm.setPetReadyCounterEnabled(false)
        vm.setPetPosition("free")
        vm.setPetSize(1.5)
        vm.setPetAttentionFilter("needsYou")
        vm.setPetReduceMotion(true)
        let pet = SettingsStore(db: ctx.db).load()
        XCTAssertTrue(pet.petEnabled, "show-pet changes must survive Settings relaunch")
        XCTAssertFalse(pet.petAnimationsEnabled)
        XCTAssertFalse(pet.petReadyCounterEnabled)
        XCTAssertEqual(pet.petPosition, "free")
        XCTAssertEqual(pet.petSize, 1.5)
        XCTAssertEqual(pet.petAttentionFilter, "needsYou")
        XCTAssertTrue(pet.petReduceMotion)

        // Control plane defaults on; persist the off flip so Settings reload matches store.
        vm.setBotsControlPlaneEnabled(false)
        XCTAssertFalse(vm.appSettings.botsControlPlaneEnabled,
                       "setBotsControlPlaneEnabled(false) must update appSettings immediately")
        XCTAssertFalse(SettingsStore(db: ctx.db).load().botsControlPlaneEnabled,
                       "setBotsControlPlaneEnabled must persist so a Bot cannot be created after the user turns the plane off")

        // The Distill nesting setting starts off and must survive a reload.
        XCTAssertFalse(vm.appSettings.distillHighParallelism, "high parallelism must default off")
        vm.setDistillHighParallelism(true)
        XCTAssertTrue(vm.appSettings.distillHighParallelism)
        XCTAssertTrue(SettingsStore(db: ctx.db).load().distillHighParallelism,
                      "setDistillHighParallelism must persist so every Distill run sees it")
    }

    /// reload() must reflect the last-persisted value, not a stale in-memory value.
    ///
    /// WHY: If setters persist correctly but reload() skips certain keys, the
    /// Settings window would silently show the wrong toggle state after re-opening.
    func test_reloadRestoresPersistedValues() throws {
        let dir = NSTemporaryDirectory() + "RC2AppSettingsReload-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let store = SettingsStore(db: ctx.db)
        store.save(AppSettings(
            diffWordWrap: true,
            sidebarSort: "manual",
            terminalFontSize: 18,
            petReduceMotion: true
        ))

        let vm = SettingsViewModel(context: ctx)
        vm.reload()

        XCTAssertEqual(vm.appSettings.sidebarSort, "manual",
                       "reload() must restore sidebarSort from the persisted store")
        XCTAssertTrue(vm.appSettings.diffWordWrap,
                      "reload() must restore diffWordWrap from the persisted store")
        XCTAssertTrue(vm.appSettings.petReduceMotion,
                      "reload() must restore petReduceMotion from the persisted store")
        XCTAssertEqual(vm.appSettings.terminalFontSize, 18,
                       "reload() must restore terminalFontSize from the persisted store")
    }
}
