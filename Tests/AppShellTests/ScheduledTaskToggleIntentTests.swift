import XCTest
import CoreModel
@testable import AppShell
@testable import Persistence

/// WHY: Resume checks the provider before it enables a task, and that check
/// takes real time (a provider CLI sign-in probe). A Pause the user sends
/// while it runs is the newer intent. Before, the Resume finished afterwards
/// and wrote enabled = true over the Pause, so the scheduler went on running
/// a task the user had just paused (Mac window and iPhone alike).
@MainActor
final class ScheduledTaskToggleIntentTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    private struct Fixture {
        let context: AppContext
        let router: AppCommandRouter
        let store: ScheduledTaskStore
        let task: ScheduledTask
        /// Holds `probe-started-N` / `probe-release-N`, one pair per probe in start order.
        let probes: URL
    }

    /// A paused codex task whose preflight passes when the test releases it:
    /// the sign-in probe runs a stand-in `codex`. The Nth probe to start touches
    /// `probe-started-N`, waits for `probe-release-N` (or 5 s), then reports a
    /// login, so a test decides which preflight finishes first.
    private func makePausedTask() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ScheduleToggle-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let slowCodex = root.appendingPathComponent("codex")
        let probes = root.appendingPathComponent("probes", isDirectory: true)
        try FileManager.default.createDirectory(at: probes, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        cd '\(probes.path)'
        n=0
        while [ -f "probe-started-$n" ]; do n=$((n+1)); done
        touch "probe-started-$n"
        i=0
        while [ ! -f "probe-release-$n" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
        echo 'Logged in using ChatGPT'

        """.write(to: slowCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowCodex.path)

        let context = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "schedule", cwd: workspaceDir.path)
        router.providerSnapshotsOverrideForTesting = [AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5", label: "GPT-5", provider: .codex)],
            binaryPath: slowCodex.path,
            authenticated: true,
            id: "codex"
        )]

        var draft = ScheduledTaskEditorDraft(now: Date())
        draft.title = "Nightly"
        draft.prompt = "Check the build"
        draft.workspaceID = workspace.id
        draft.workspacePathSnapshot = workspaceDir.path
        draft.runAsUser = NSUserName()
        draft.runAsUID = try XCTUnwrap(ScheduledSystemUserCatalog.user(named: NSUserName())).uid
        draft.provider = .codex
        draft.providerInstanceID = "codex"
        draft.model = "gpt-5"
        draft.routingMode = .manual
        draft.isEnabled = false
        draft.frequencyRules[0].frequency = .hourly
        draft.frequencyRules[0].intervalHours = 1
        let task = try draft.makeTask()
        let store = ScheduledTaskStore(db: context.db)
        try store.save(task)
        return Fixture(context: context, router: router, store: store, task: task, probes: probes)
    }

    private func waitForProbeStart(_ fixture: Fixture, _ index: Int = 0) async throws {
        let started = fixture.probes.appendingPathComponent("probe-started-\(index)").path
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: started), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started), "Resume must be checking the provider")
    }

    private func releaseProbe(_ fixture: Fixture, _ index: Int = 0) {
        FileManager.default.createFile(atPath: fixture.probes.appendingPathComponent("probe-release-\(index)").path, contents: Data())
    }

    /// Waits up to `seconds` for the window row to read `enabled`.
    private func waitForRow(_ vm: ScheduledTasksViewModel, _ fixture: Fixture, enabled: Bool, seconds: Double) async throws -> Bool? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if vm.tasks.first(where: { $0.id == fixture.task.id })?.isEnabled == enabled { return enabled }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return vm.tasks.first { $0.id == fixture.task.id }?.isEnabled
    }

    private func storedEnabled(_ fixture: Fixture) throws -> Bool {
        try XCTUnwrap(fixture.store.get(id: fixture.task.id)).isEnabled
    }

    /// Waits up to `seconds` for the stored flag to become `true`.
    private func waitForStoredEnable(_ fixture: Fixture, seconds: Double) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try storedEnabled(fixture) { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try storedEnabled(fixture)
    }

    func test_resumeAloneStillEnablesTheTask() async throws {
        // Control: the fixture's preflight really passes, so the race test
        // below is not green just because Resume always fails.
        let fixture = try await makePausedTask()
        releaseProbe(fixture)
        let vm = ScheduledTasksViewModel(context: fixture.context, router: fixture.router)
        vm.toggle(try XCTUnwrap(vm.tasks.first { $0.id == fixture.task.id }))
        let enabled = try await waitForStoredEnable(fixture, seconds: 5)
        XCTAssertTrue(enabled, "Resume must enable the task once its preflight passes; error: \(vm.errorMessage ?? "none")")
    }

    func test_pauseWhileResumeIsCheckingTheProviderKeepsTheTaskPaused() async throws {
        let fixture = try await makePausedTask()
        let vm = ScheduledTasksViewModel(context: fixture.context, router: fixture.router)
        vm.toggle(try XCTUnwrap(vm.tasks.first { $0.id == fixture.task.id }))
        try await waitForProbeStart(fixture)
        let resumedRow = try XCTUnwrap(vm.tasks.first { $0.id == fixture.task.id })
        XCTAssertTrue(resumedRow.isEnabled, "Resume flips the row at once")
        XCTAssertFalse(try storedEnabled(fixture), "the Pause lands while Resume is still checking")
        vm.toggle(resumedRow)
        releaseProbe(fixture)

        let enabled = try await waitForStoredEnable(fixture, seconds: 1.5)
        XCTAssertFalse(enabled, "the earlier Resume must not enable a task the user paused after it")
        XCTAssertEqual(vm.tasks.first { $0.id == fixture.task.id }?.isEnabled, false)
        XCTAssertNil(vm.errorMessage)
    }

    func test_remotePauseWhileRemoteResumeIsCheckingTheProviderKeepsTheTaskPaused() async throws {
        let fixture = try await makePausedTask()
        let resume = Task { @MainActor in
            try await fixture.router.enableScheduledTaskRemote(id: fixture.task.id, enabled: true)
        }
        try await waitForProbeStart(fixture)
        _ = try await fixture.router.enableScheduledTaskRemote(id: fixture.task.id, enabled: false)
        releaseProbe(fixture)
        let resumeResult = try await resume.value

        XCTAssertFalse(try storedEnabled(fixture), "the iPhone's later Pause must win over its earlier Resume")
        XCTAssertEqual(resumeResult.objectValue?["enabled"]?.boolValue, false,
                       "the superseded Resume reports the state that was kept")
    }

    func test_iPhonePauseWhileTheWindowResumesLeavesTheRowPaused() async throws {
        // The window flips the row to Active on Resume; when the iPhone's
        // Pause supersedes it, the row must show the stored Paused state, not
        // stay Active over a paused task.
        let fixture = try await makePausedTask()
        let vm = ScheduledTasksViewModel(context: fixture.context, router: fixture.router)
        vm.toggle(try XCTUnwrap(vm.tasks.first { $0.id == fixture.task.id }))
        try await waitForProbeStart(fixture)
        _ = try await fixture.router.enableScheduledTaskRemote(id: fixture.task.id, enabled: false)
        releaseProbe(fixture)

        let row = try await waitForRow(vm, fixture, enabled: false, seconds: 3)
        XCTAssertEqual(row, false, "the row must follow the iPhone's Pause")
        XCTAssertFalse(try storedEnabled(fixture))
        XCTAssertNil(vm.errorMessage)
    }

    func test_iPhoneResumeWhileTheWindowResumesLeavesTheRowActive() async throws {
        // The window's Resume is superseded by the iPhone's Resume. The window's
        // check finishes first and shows the stored Paused state; the iPhone's
        // Resume writes afterwards. The row must end Active like the store.
        let fixture = try await makePausedTask()
        let vm = ScheduledTasksViewModel(context: fixture.context, router: fixture.router)
        vm.toggle(try XCTUnwrap(vm.tasks.first { $0.id == fixture.task.id }))
        try await waitForProbeStart(fixture, 0)
        let remoteResume = Task { @MainActor in
            try await fixture.router.enableScheduledTaskRemote(id: fixture.task.id, enabled: true)
        }
        try await waitForProbeStart(fixture, 1)
        releaseProbe(fixture, 0)
        let superseded = try await waitForRow(vm, fixture, enabled: false, seconds: 3)
        XCTAssertEqual(superseded, false, "the superseded window Resume shows what is stored")
        releaseProbe(fixture, 1)
        _ = try await remoteResume.value

        XCTAssertTrue(try storedEnabled(fixture), "the iPhone's Resume is the latest intent")
        let row = try await waitForRow(vm, fixture, enabled: true, seconds: 3)
        XCTAssertEqual(row, true, "the row must show the task the iPhone resumed as Active")
        XCTAssertNil(vm.errorMessage)
    }

    func test_openWindowShowsATaskTheiPhoneResumed() async throws {
        // An idle, visible window must follow a Resume sent from the iPhone.
        let fixture = try await makePausedTask()
        releaseProbe(fixture, 0)
        let vm = ScheduledTasksViewModel(context: fixture.context, router: fixture.router)
        XCTAssertEqual(vm.tasks.first { $0.id == fixture.task.id }?.isEnabled, false)
        _ = try await fixture.router.enableScheduledTaskRemote(id: fixture.task.id, enabled: true)
        XCTAssertTrue(try storedEnabled(fixture))
        let row = try await waitForRow(vm, fixture, enabled: true, seconds: 3)
        XCTAssertEqual(row, true, "the open window must show the iPhone's Resume")
    }

    func test_storeChangeElsewhereKeepsAPendingResumeRowActive() async throws {
        // While the window's own Resume is still checking the provider, a store
        // change from elsewhere (another task saved on the iPhone) reloads the
        // rows. The pending Resume must keep its Active row, not flash Paused.
        let fixture = try await makePausedTask()
        let vm = ScheduledTasksViewModel(context: fixture.context, router: fixture.router)
        vm.toggle(try XCTUnwrap(vm.tasks.first { $0.id == fixture.task.id }))
        try await waitForProbeStart(fixture, 0)
        let reloads = vm.storeChangeReloadCountForTesting
        ScheduledTaskCrossProcess.notifyStoreChanged(reason: "remote_save")
        let deadline = Date().addingTimeInterval(3)
        while vm.storeChangeReloadCountForTesting == reloads, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(vm.storeChangeReloadCountForTesting, reloads, "the window reloaded for the change")
        XCTAssertEqual(vm.tasks.first { $0.id == fixture.task.id }?.isEnabled, true,
                       "a Resume still checking the provider keeps its Active row")
        XCTAssertFalse(try storedEnabled(fixture), "nothing is stored before the check passes")
        releaseProbe(fixture, 0)
        let enabled = try await waitForStoredEnable(fixture, seconds: 5)
        XCTAssertTrue(enabled)
        XCTAssertEqual(vm.tasks.first { $0.id == fixture.task.id }?.isEnabled, true)
    }
}
