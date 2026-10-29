import XCTest
import AppKit
import SwiftUI
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence

@MainActor
final class InsomniaSidebarTests: XCTestCase {
    private final class FakeInsomniaPowerManager: InsomniaPowerManaging {
        var activateReasons: [String] = []
        var activateOptions: [InsomniaPowerOptions] = []
        var deactivateCount = 0
        var shouldActivate = true

        func activate(reason: String, options: InsomniaPowerOptions) -> Bool {
            activateReasons.append(reason)
            activateOptions.append(options)
            return shouldActivate
        }

        func deactivate() {
            deactivateCount += 1
        }

        func releaseProcessAssertions() {}
    }

    private final class FakeExternalPowerMonitor: ExternalPowerMonitoring {
        var currentPowerState: ExternalPowerState
        var onPowerStateChanged: (@MainActor (ExternalPowerState) -> Void)?
        var startCount = 0
        var stopCount = 0

        init(powerState: ExternalPowerState = .externalPower) {
            self.currentPowerState = powerState
        }

        func start() {
            startCount += 1
        }

        func stop() {
            stopCount += 1
        }

        @MainActor
        func send(_ state: ExternalPowerState) {
            currentPowerState = state
            onPowerStateChanged?(state)
        }
    }

    private func make(
        dir: String = NSTemporaryDirectory() + "RC2Insomnia-" + UUID().uuidString,
        seedSettings: AppSettings? = nil,
        power: FakeInsomniaPowerManager = FakeInsomniaPowerManager(),
        powerMonitor: ExternalPowerMonitoring = FakeExternalPowerMonitor(),
        insomniaBatteryPrompt: @escaping SidebarViewModel.InsomniaBatteryPrompt = { $0(.keepEnabled) },
        operationErrorPresenter: @escaping SidebarViewModel.OperationErrorPresenter = { _, _ in }
    ) throws -> (AppContext, AppCommandRouter, SidebarViewModel, FakeInsomniaPowerManager) {
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        if let seedSettings {
            SettingsStore(db: ctx.db).save(seedSettings)
        }
        let vm = SidebarViewModel(
            context: ctx,
            router: router,
            insomniaPower: power,
            powerMonitor: powerMonitor,
            insomniaBatteryPrompt: insomniaBatteryPrompt,
            operationErrorPresenter: operationErrorPresenter
        )
        return (ctx, router, vm, power)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func test_defaultInactiveWhenUserHasNotChangedToggle() throws {
        let (ctx, _, vm, power) = try make()

        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(SettingsStore(db: ctx.db).load().insomniaEnabled,
                       "a user with no saved Insomnia choice must launch macOS without asking for an admin password")
        XCTAssertTrue(power.activateReasons.isEmpty,
                      "default inactive Insomnia must not acquire macOS keep-awake assertions on launch")
    }

    func test_accountUsageRefreshesFromProviderTokenUsageEvents() async throws {
        let (ctx, router, vm, _) = try make()
        let workspaceDir = NSTemporaryDirectory() + "RC2AccountUsageWorkspace-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workspaceDir, withIntermediateDirectories: true)
        let workspace = try router.createWorkspace(name: "usage", cwd: workspaceDir)
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "usage",
            provider: .codex,
            model: "gpt-test"
        )
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-test",
            status: .running,
            startedAt: Date()
        )
        try ctx.runRepo.upsert(run)

        ctx.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 120, outputTokens: 80, totalTokens: 200)),
            thread.id,
            run.id
        )

        // Delivery is debounced twice (provider-usage flush, then the usage-changed post),
        // so the deadline covers both windows plus scheduling slack under a loaded run.
        let refreshed = await waitUntil(
            timeout: AppContext.providerUsageDebounceInterval + AppContext.usageNotificationMinimumInterval + 3
        ) { vm.accountUsageSnapshot.usedTokens == 200 }
        XCTAssertTrue(refreshed,
                      "sidebar account-usage figure must refresh when Claude/Codex provider usage is recorded")
        // Provider token-usage events record REAL provider spend only. Savings
        // are measured at compression time and live in the DB ledger — they are
        // never synthesised here from a fixed ratio (the old behavior reported a
        // fabricated 276). usage.json must therefore show zero "saved".
        XCTAssertEqual(vm.accountUsageSnapshot.measuredSavedTokens, 0,
                       "token-usage events must not fabricate savings from an assumed compression ratio")
    }

    func test_toggleOffPersistsAndReloadsOff() throws {
        let dir = NSTemporaryDirectory() + "RC2InsomniaOff-" + UUID().uuidString
        let (ctx, _, vm, power) = try make(dir: dir, seedSettings: AppSettings(insomniaEnabled: true))

        vm.setInsomniaEnabled(false)

        let disabled = SettingsStore(db: ctx.db).load()
        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(disabled.insomniaEnabled, "turning Insomnia off must persist the inactive session")
        XCTAssertGreaterThan(power.deactivateCount, 0,
                             "turning Insomnia off must release the macOS keep-awake assertion")

        let (_, _, reloaded, reloadedPower) = try make(dir: dir)
        XCTAssertFalse(reloaded.insomniaEnabled)
        XCTAssertTrue(reloadedPower.activateReasons.isEmpty,
                      "a saved off choice must survive relaunch and must not reacquire keep-awake")
    }

    func test_toggleOnPersistsAndReloadsOn() throws {
        let dir = NSTemporaryDirectory() + "RC2InsomniaOn-" + UUID().uuidString
        let (ctx, _, vm, power) = try make(dir: dir, seedSettings: AppSettings(insomniaEnabled: false))

        vm.setInsomniaEnabled(true)

        XCTAssertTrue(vm.insomniaEnabled)
        XCTAssertTrue(SettingsStore(db: ctx.db).load().insomniaEnabled,
                      "turning Insomnia on must persist the active session")
        XCTAssertEqual(power.activateReasons, ["MacCode Insomnia"],
                       "turning Insomnia on must acquire the macOS keep-awake assertion")

        let (_, _, reloaded, reloadedPower) = try make(dir: dir)
        XCTAssertTrue(reloaded.insomniaEnabled)
        XCTAssertEqual(reloadedPower.activateReasons, ["MacCode Insomnia"],
                       "a saved on choice must survive relaunch and reacquire keep-awake")
    }

    func test_appCloseDisablesInsomniaAndPreventsRelaunchReactivation() throws {
        let dir = NSTemporaryDirectory() + "RC2InsomniaClose-" + UUID().uuidString
        let (ctx, _, vm, power) = try make(dir: dir, seedSettings: AppSettings(insomniaEnabled: false))

        vm.setInsomniaEnabled(true)
        vm.disableInsomniaForAppClose()

        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(SettingsStore(db: ctx.db).load().insomniaEnabled,
                       "closing the macOS app must persist Insomnia off so keep-awake cannot outlive the app session")
        XCTAssertGreaterThan(power.deactivateCount, 0,
                             "closing the macOS app must release all Insomnia power assertions")

        let (_, _, reloaded, reloadedPower) = try make(dir: dir)
        XCTAssertFalse(reloaded.insomniaEnabled)
        XCTAssertTrue(reloadedPower.activateReasons.isEmpty,
                      "reopening the app after a normal close must not silently restart Insomnia")
    }

    func test_unpluggingMacBookWhileInsomniaEnabledPromptsAndCanDisable() throws {
        let monitor = FakeExternalPowerMonitor(powerState: .externalPower)
        var promptCount = 0
        let (ctx, _, vm, power) = try make(
            seedSettings: AppSettings(insomniaEnabled: false),
            powerMonitor: monitor,
            insomniaBatteryPrompt: { completion in
                promptCount += 1
                completion(.disable)
            }
        )

        vm.setInsomniaEnabled(true)
        monitor.send(.battery)

        XCTAssertEqual(promptCount, 1,
                       "unplugging while Insomnia is active must ask before letting a keep-awake session drain battery")
        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(SettingsStore(db: ctx.db).load().insomniaEnabled,
                       "choosing Disable Insomnia from the battery warning must persist the safer off state")
        XCTAssertGreaterThan(power.deactivateCount, 0,
                             "choosing Disable Insomnia from the battery warning must release keep-awake assertions")
    }

    func test_unpluggingMacBookWhileInsomniaEnabledCanKeepSession() throws {
        let monitor = FakeExternalPowerMonitor(powerState: .externalPower)
        var promptCount = 0
        let (ctx, _, vm, power) = try make(
            seedSettings: AppSettings(insomniaEnabled: false),
            powerMonitor: monitor,
            insomniaBatteryPrompt: { completion in
                promptCount += 1
                completion(.keepEnabled)
            }
        )

        vm.setInsomniaEnabled(true)
        let deactivateCountBeforeWarning = power.deactivateCount
        monitor.send(.battery)

        XCTAssertEqual(promptCount, 1,
                       "unplugging while Insomnia is active must let the user intentionally keep the session on")
        XCTAssertTrue(vm.insomniaEnabled)
        XCTAssertTrue(SettingsStore(db: ctx.db).load().insomniaEnabled,
                      "choosing Keep Insomnia On must not silently turn off a requested keep-awake session")
        XCTAssertEqual(power.deactivateCount, deactivateCountBeforeWarning,
                       "choosing Keep Insomnia On must not release the active keep-awake assertion")
    }

    /// WHY: on 2026-10-29 the battery warning was a blocking modal on the main
    /// actor; every remote RPC waited behind it and the iPhone could not
    /// connect for 84 minutes. The warning must return at once, ask only once
    /// while open, and apply the answer whenever the user gives it.
    func test_batteryWarningDoesNotBlockWhileUnanswered() throws {
        let monitor = FakeExternalPowerMonitor(powerState: .externalPower)
        var pending: [@MainActor (SidebarViewModel.InsomniaBatteryDecision) -> Void] = []
        let (_, _, vm, _) = try make(
            seedSettings: AppSettings(insomniaEnabled: false),
            powerMonitor: monitor,
            insomniaBatteryPrompt: { completion in pending.append(completion) }
        )

        vm.setInsomniaEnabled(true)
        monitor.send(.battery)
        XCTAssertEqual(pending.count, 1, "the warning is shown")
        XCTAssertTrue(vm.insomniaEnabled, "nothing changes until the user answers")

        monitor.send(.externalPower)
        monitor.send(.battery)
        XCTAssertEqual(pending.count, 1, "an unplug while the warning is open does not stack a second one")

        pending[0](.disable)
        XCTAssertFalse(vm.insomniaEnabled, "a late answer still applies")

        vm.setInsomniaEnabled(true)
        monitor.send(.externalPower)
        monitor.send(.battery)
        XCTAssertEqual(pending.count, 2, "after the answer the next unplug warns again")
    }

    func test_batteryNotificationWhileInsomniaOffDoesNotPrompt() throws {
        let monitor = FakeExternalPowerMonitor(powerState: .externalPower)
        var promptCount = 0
        let (_, _, vm, _) = try make(
            seedSettings: AppSettings(insomniaEnabled: false),
            powerMonitor: monitor,
            insomniaBatteryPrompt: { completion in
                promptCount += 1
                completion(.disable)
            }
        )

        monitor.send(.battery)

        XCTAssertEqual(promptCount, 0,
                       "battery warnings must not interrupt users when Insomnia is already off")
        XCTAssertFalse(vm.insomniaEnabled)
    }

    func test_launchingAlreadyOnBatteryDoesNotPromptWithoutUnplugTransition() throws {
        let monitor = FakeExternalPowerMonitor(powerState: .battery)
        var promptCount = 0
        let (_, _, vm, _) = try make(
            seedSettings: AppSettings(insomniaEnabled: false),
            powerMonitor: monitor,
            insomniaBatteryPrompt: { completion in
                promptCount += 1
                completion(.disable)
            }
        )

        vm.setInsomniaEnabled(true)
        monitor.send(.battery)

        XCTAssertEqual(promptCount, 0,
                       "the warning is for an unplug event, not for every refresh while already on battery")
        XCTAssertTrue(vm.insomniaEnabled)
    }

    func test_optionsPersistAndUpdateActiveSession() throws {
        let (ctx, _, vm, power) = try make(seedSettings: AppSettings(insomniaEnabled: false))

        vm.setInsomniaAllowDisplaySleep(false)
        vm.setInsomniaAllowSystemSleepWhenDisplayClosed(true)
        vm.setInsomniaAllowScreenSaverAfter45MinutesOfInactivity(false)
        var settings = SettingsStore(db: ctx.db).load()
        XCTAssertFalse(settings.insomniaAllowDisplaySleep)
        XCTAssertTrue(settings.insomniaAllowSystemSleepWhenDisplayClosed)
        XCTAssertFalse(settings.insomniaAllowScreenSaverAfter45MinutesOfInactivity)
        XCTAssertTrue(power.activateOptions.isEmpty,
                      "changing Insomnia options while inactive must persist preferences without starting a session")

        vm.setInsomniaEnabled(true)
        settings = SettingsStore(db: ctx.db).load()
        XCTAssertTrue(settings.insomniaEnabled)
        XCTAssertEqual(power.activateOptions.last, InsomniaPowerOptions(
            allowDisplaySleep: false,
            allowSystemSleepWhenDisplayClosed: true,
            allowScreenSaverAfter45MinutesOfInactivity: false
        ))

        vm.setInsomniaAllowDisplaySleep(true)
        XCTAssertEqual(power.activateOptions.last, InsomniaPowerOptions(
            allowDisplaySleep: true,
            allowSystemSleepWhenDisplayClosed: true,
            allowScreenSaverAfter45MinutesOfInactivity: false
        ), "adjusting options while active must immediately restart the active keep-awake assertion")
    }

    func test_powerAssertionFailurePersistsOff() throws {
        let power = FakeInsomniaPowerManager()
        power.shouldActivate = false
        let (ctx, _, vm, _) = try make(seedSettings: AppSettings(insomniaEnabled: false), power: power)

        vm.setInsomniaEnabled(true)

        let settings = SettingsStore(db: ctx.db).load()
        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(settings.insomniaEnabled,
                       "if macOS refuses the keep-awake assertion, the sidebar must fail loud by returning to off state")
        XCTAssertEqual(power.activateReasons, ["MacCode Insomnia"])
    }
}
