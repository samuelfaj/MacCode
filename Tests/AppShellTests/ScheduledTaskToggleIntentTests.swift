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
        /// Created by the sign-in probe when it starts.
        let probeStarted: URL
        /// The probe reports a login once this exists (or after 5 s).
        let probeRelease: URL
    }

    /// A paused codex task whose preflight passes when the test releases it:
    /// the sign-in probe runs a stand-in `codex` that signals its start,
    /// waits for the release file, then reports a login.
    private func makePausedTask() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ScheduleToggle-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let slowCodex = root.appendingPathComponent("codex")
        let probeStarted = root.appendingPathComponent("probe-started")
        let probeRelease = root.appendingPathComponent("probe-release")
        try """
        #!/bin/sh
        touch '\(probeStarted.path)'
        i=0
        while [ ! -f '\(probeRelease.path)' ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
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
        return Fixture(context: context, router: router, store: store, task: task,
                       probeStarted: probeStarted, probeRelease: probeRelease)
    }

    private func waitForProbeStart(_ fixture: Fixture) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: fixture.probeStarted.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.probeStarted.path), "Resume must be checking the provider")
    }

    private func releaseProbe(_ fixture: Fixture) {
        FileManager.default.createFile(atPath: fixture.probeRelease.path, contents: Data())
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
}
