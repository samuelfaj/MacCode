import XCTest
import AgentRuntime
import SocketServer
@testable import AppShell

/// WHY: RemoteCode starts Distill with `--no-auto-update`, so this updater is
/// the only thing that keeps the Mac's Distill current. It must install when
/// Distill says there is an update, and never on a guess: a check that failed
/// is not "up to date" and is not an update either.
final class DistillAutoUpdaterTests: XCTestCase {
    // Output of the real CLI (`distill update --check --json`, 2.0.40/2.0.41).
    private static let updateAvailable = #"{"currentVersion":"2.0.40","latestVersion":"2.0.41","updateAvailable":true,"installer":"gh-release","channel":"stable","autoUpdate":null,"error":null}"#
    private static let upToDate = #"{"currentVersion":"2.0.41","latestVersion":"2.0.41","updateAvailable":false,"installer":"gh-release","channel":"stable","autoUpdate":true,"error":null}"#
    private static let offline = #"{"currentVersion":"2.0.41","latestVersion":null,"updateAvailable":false,"installer":"gh-release","channel":"stable","autoUpdate":null,"error":"error sending request for url (https://api.github.com/repos/samuelfaj/distill/releases/latest)"}"#
    /// A local build, or any binary Distill's installer does not manage.
    private static let unmanagedBinary = #"{"currentVersion":"2.0.16+local.efficiency.1","latestVersion":null,"updateAvailable":false,"installer":null,"channel":"stable","autoUpdate":null,"error":null}"#

    /// Stands in for the check, the install and the guest prefetch, and
    /// records the order they ran in.
    private final class Fakes: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var output: (status: Int32, stdout: String)?
        private var outputAfterInstall: (status: Int32, stdout: String)? = (0, DistillAutoUpdaterTests.upToDate)
        private var installResult: DistillAutoUpdater.Install = .installed
        private var sleeps: [TimeInterval] = []
        private let (held, releaseHeld) = AsyncStream<Void>.makeStream()
        private var holdsCheck = false

        init(status: Int32 = 0, stdout: String?) {
            output = stdout.map { (status, $0) }
        }

        var events: [String] { lock.withLock { log } }
        var delays: [TimeInterval] { lock.withLock { sleeps } }
        func installs(_ result: DistillAutoUpdater.Install) { lock.withLock { installResult = result } }
        func checkReports(_ stdout: String) { lock.withLock { output = (0, stdout) } }
        /// What the check reports once an install succeeded (by default, up
        /// to date); nil is a check that did not run.
        func afterInstall(stdout: String?) { lock.withLock { outputAfterInstall = stdout.map { (0, $0) } } }
        /// Holds the next check only: a second one returns, so a lost
        /// single-flight guard fails the assertion instead of hanging the suite.
        func holdCheck() { lock.withLock { holdsCheck = true } }
        func releaseCheck() { releaseHeld.finish() }

        /// `sleep` nil keeps the real clock.
        func dependencies(
            launchDelay: TimeInterval? = nil,
            sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil
        ) -> DistillAutoUpdater.Dependencies {
            var deps = DistillAutoUpdater.Dependencies(
                check: {
                    let wait = self.lock.withLock { () -> Bool in
                        self.log.append("check")
                        defer { self.holdsCheck = false }
                        return self.holdsCheck
                    }
                    if wait { for await _ in self.held {} }
                    return self.lock.withLock { self.output }
                },
                install: {
                    self.lock.withLock { () -> DistillAutoUpdater.Install in
                        self.log.append("install")
                        if self.installResult == .installed { self.output = self.outputAfterInstall }
                        return self.installResult
                    }
                },
                prefetchGuest: { self.lock.withLock { self.log.append("prefetch") } }
            )
            if let launchDelay { deps.launchDelay = launchDelay }
            if let sleep { deps.sleep = sleep }
            return deps
        }

        func recordSleep(_ seconds: TimeInterval) -> Int {
            lock.withLock { sleeps.append(seconds); return sleeps.count }
        }
    }

    private func outcome(_ fakes: Fakes) async -> DistillAutoUpdater.Outcome {
        await DistillAutoUpdater(fakes.dependencies()).runPass()
    }

    // MARK: One pass

    /// The owner's rule: an available update is installed, once.
    func test_updateAvailable_installsOnce() async {
        let fakes = Fakes(stdout: Self.updateAvailable)
        let result = await outcome(fakes)
        XCTAssertEqual(result, .installed(latest: "2.0.41"))
        XCTAssertEqual(fakes.events, ["check", "install", "check"])
    }

    func test_upToDate_installsNothing() async {
        let fakes = Fakes(stdout: Self.upToDate)
        let result = await outcome(fakes)
        XCTAssertEqual(result, .upToDate)
        XCTAssertEqual(fakes.events, ["check"])
    }

    /// Offline, GitHub rate-limited, a Distill too old for `--json`, a check
    /// that timed out: none of them says there is an update, so nothing is
    /// installed, and none of them says there is not, so it is not "up to date".
    func test_failedCheck_installsNothingAndIsReportedAsCouldNotCheck() async {
        let cases: [(String, Fakes)] = [
            ("reported error", Fakes(stdout: Self.offline)),
            ("invalid JSON", Fakes(stdout: "error: unexpected argument '--json' found")),
            ("empty output", Fakes(stdout: "")),
            ("missing updateAvailable", Fakes(stdout: #"{"currentVersion":"2.0.41","error":null}"#)),
            ("non-zero exit", Fakes(status: 2, stdout: Self.updateAvailable)),
            ("did not run", Fakes(stdout: nil))
        ]
        for (name, fakes) in cases {
            let result = await outcome(fakes)
            guard case .couldNotCheck = result else {
                XCTFail("\(name): expected couldNotCheck, got \(result)")
                continue
            }
            XCTAssertEqual(fakes.events, ["check"], name)
        }
    }

    /// A release may add fields; that must not stop updates.
    func test_unknownKeysInTheCheckAreIgnored() {
        let json = #"{"updateAvailable":true,"latestVersion":"3.0.0","releaseNotes":{"url":"x"},"error":null}"#
        XCTAssertEqual(
            try? DistillAutoUpdater.parse(status: 0, stdout: json + "\n").get(),
            DistillAutoUpdater.Check(latestVersion: "3.0.0", updateAvailable: true)
        )
    }

    /// MacCode keeps Distill current on every launch, whatever Distill's own
    /// `auto_update` says: Distill is MacCode's only dependency.
    func test_autoUpdateOffInDistill_stillInstalls() async {
        let off = Fakes(stdout: #"{"latestVersion":"2.0.41","updateAvailable":true,"autoUpdate":false,"error":null}"#)
        let result = await outcome(off)
        XCTAssertEqual(off.events.first, "check")
        XCTAssertTrue(off.events.contains("install"), "\(result)")
    }

    /// A local build behind `cli.distill.path` must never be replaced by
    /// surprise: Distill reports no update for a binary its installer does
    /// not manage, and the updater installs only what the check reports. A
    /// binary Distill never checked must not be logged as current either, or
    /// a stale install looks healthy.
    func test_binaryNotManagedByTheInstaller_isLeftAlone() async {
        let fakes = Fakes(stdout: Self.unmanagedBinary)
        let result = await outcome(fakes)
        XCTAssertEqual(result, .notManaged(current: "2.0.16+local.efficiency.1"))
        XCTAssertEqual(fakes.events, ["check"])
    }

    /// `cli.distill.path` pinned to one release file: `distill update` exits
    /// 0 and the app keeps launching the old file. The app must not claim an
    /// install RemoteCode does not use, and must not run the installer again
    /// for that release.
    func test_updateInstalledButCheckedBinaryUnchanged_isNotInstalledAgain() async {
        let fakes = Fakes(stdout: Self.updateAvailable)
        fakes.afterInstall(stdout: Self.updateAvailable)
        let updater = DistillAutoUpdater(fakes.dependencies())
        let first = await updater.runPass()
        XCTAssertEqual(first, .installedBinaryNotInUse(latest: "2.0.41"))
        let second = await updater.runPass()
        XCTAssertEqual(second, .installedBinaryNotInUse(latest: "2.0.41"))
        XCTAssertEqual(fakes.events, ["check", "install", "check", "check"])
    }

    /// A network blip right after a real install must not hide it: only a
    /// check that answers can say the binary is unchanged.
    func test_checkFailingAfterTheInstall_stillReportsIt() async {
        for after in [nil, Self.offline] {
            let fakes = Fakes(stdout: Self.updateAvailable)
            fakes.afterInstall(stdout: after)
            let result = await outcome(fakes)
            XCTAssertEqual(result, .installed(latest: "2.0.41"))
            XCTAssertEqual(fakes.events, ["check", "install", "check"])
        }
    }

    /// The user pressed Update at the same moment: their update is the one
    /// running, which is not a failure.
    func test_manualUpdateAlreadyRunning_isNotAnError() async {
        let fakes = Fakes(stdout: Self.updateAvailable)
        fakes.installs(.alreadyRunning)
        let result = await outcome(fakes)
        XCTAssertEqual(result, .updateAlreadyRunning)
        XCTAssertEqual(fakes.events, ["check", "install"])
    }

    /// A failed install is retried by a later pass, not remembered as done.
    func test_failedInstall_isRetriedByTheNextPass() async {
        let fakes = Fakes(stdout: Self.updateAvailable)
        fakes.installs(.failed("exit status 1"))
        let updater = DistillAutoUpdater(fakes.dependencies())
        let first = await updater.runPass()
        XCTAssertEqual(first, .installFailed("exit status 1"))
        fakes.installs(.installed)
        let second = await updater.runPass()
        XCTAssertEqual(second, .installed(latest: "2.0.41"))
        XCTAssertEqual(fakes.events, ["check", "install", "check", "install", "check"])
    }

    /// A release that cannot install (a bad checksum, a full disk, a line too
    /// slow for the bound) must not cost a ~194 MB download every hour, and a
    /// newer release must not wait behind the old one's backoff.
    func test_repeatedlyFailingInstall_backsOffUntilANewerRelease() async {
        let fakes = Fakes(stdout: Self.updateAvailable)
        fakes.installs(.failed("exit status 1"))
        let updater = DistillAutoUpdater(fakes.dependencies())
        var outcomes: [DistillAutoUpdater.Outcome] = []
        for _ in 0..<4 { outcomes.append(await updater.runPass()) }
        XCTAssertEqual(outcomes, [
            .installFailed("exit status 1"), .installFailed("exit status 1"),
            .retryingLater(latest: "2.0.41"), .installFailed("exit status 1")
        ])
        XCTAssertEqual(fakes.events, ["check", "install", "check", "install", "check", "check", "install"])

        // Three failures: 2.0.41 now waits three passes. 2.0.42 does not.
        fakes.checkReports(Self.updateAvailable.replacingOccurrences(of: "2.0.41", with: "2.0.42"))
        fakes.installs(.installed)
        let newer = await updater.runPass()
        XCTAssertEqual(newer, .installed(latest: "2.0.42"))
    }

    /// Two installers of the same release must never run together.
    func test_overlappingPass_doesNotRunASecondCheck() async throws {
        let fakes = Fakes(stdout: Self.updateAvailable)
        fakes.holdCheck()
        let updater = DistillAutoUpdater(fakes.dependencies())
        let first = Task { await updater.runPass() }
        try await waitUntil { fakes.events == ["check"] }
        let second = await updater.runPass()
        XCTAssertEqual(second, .overlapped)
        fakes.releaseCheck()
        let finished = await first.value
        XCTAssertEqual(finished, .installed(latest: "2.0.41"))
        XCTAssertEqual(fakes.events, ["check", "install", "check"])
    }

    // MARK: Schedule

    /// WHY: bot VMs run the latest Distill release whatever the Mac's Distill
    /// is. A Mac on a local build is never updated by a pass, and its bots
    /// were once left on an old guest build with no Auto routing: every pass,
    /// whatever it found, is followed by the bot VMs' prefetch.
    func test_schedule_prefetchesTheLatestGuestReleaseAfterEveryPass() async throws {
        for stdout in [Self.unmanagedBinary, Self.upToDate, Self.offline] {
            let fakes = Fakes(stdout: stdout)
            let updater = DistillAutoUpdater(fakes.dependencies(sleep: { seconds in
                // The second wait is the one quit interrupts.
                if fakes.recordSleep(seconds) == 2 { try await Task.sleep(nanoseconds: 30_000_000_000) }
            }))
            let schedule = Task { await updater.runSchedule() }
            try await waitUntil { fakes.delays.count == 2 }
            XCTAssertEqual(fakes.events, ["check", "prefetch"], stdout)
            schedule.cancel()
            await schedule.value
        }
    }

    /// The first check waits for launch to settle, then repeats hourly, and
    /// quit (task cancellation) ends the schedule without another pass.
    func test_schedule_waitsForLaunchThenRepeatsHourlyUntilCancelled() async throws {
        let fakes = Fakes(stdout: Self.upToDate)
        let updater = DistillAutoUpdater(fakes.dependencies(sleep: { seconds in
            // The third wait is the one quit interrupts.
            if fakes.recordSleep(seconds) == 3 { try await Task.sleep(nanoseconds: 30_000_000_000) }
        }))
        let schedule = Task { await updater.runSchedule() }
        try await waitUntil { fakes.delays.count == 3 }
        XCTAssertEqual(fakes.delays, [30, 3600, 3600])
        XCTAssertEqual(fakes.events, ["check", "prefetch", "check", "prefetch"])
        schedule.cancel()
        await schedule.value
        XCTAssertEqual(fakes.events, ["check", "prefetch", "check", "prefetch"])
    }

    /// Quit while the check is running must not start a download.
    func test_cancelledDuringTheCheck_installsNothing() async throws {
        let fakes = Fakes(stdout: Self.updateAvailable)
        fakes.holdCheck()
        let updater = DistillAutoUpdater(fakes.dependencies(launchDelay: 0))
        let schedule = Task { await updater.runSchedule() }
        try await waitUntil { fakes.events == ["check"] }
        schedule.cancel()
        fakes.releaseCheck()
        await schedule.value
        XCTAssertEqual(fakes.events, ["check"])
    }

    // MARK: Gate

    /// The isolated sandbox, the scheduled-task agent and unit tests share the
    /// user's home: there the updater must not even check, let alone install.
    @MainActor
    func test_gateClosed_noPassEverRuns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2DistillAutoUpdate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakes = Fakes(stdout: Self.updateAvailable)

        // A unit test without a sandboxed home would act on the developer's.
        let plain = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("plain").path)
        XCTAssertFalse(plain.startDistillAutoUpdates(dependencies: fakes.dependencies(launchDelay: 0), environment: [:]))
        XCTAssertNil(plain.distillAutoUpdates)

        let sandboxed = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("sandboxed").path,
            agentSkillsHomeOverrideForTesting: root.appendingPathComponent("home", isDirectory: true)
        )
        await sandboxed.legacyTokenSaverPurgeTask?.value
        XCTAssertFalse(sandboxed.startDistillAutoUpdates(
            dependencies: fakes.dependencies(launchDelay: 0),
            environment: ["RC2_DISABLE_MANAGED_DISTILL_RECONCILE": "1"]
        ))
        XCTAssertNil(sandboxed.distillAutoUpdates)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fakes.events, [])

        // The same context with the gate open does run, so it was the gate.
        XCTAssertTrue(sandboxed.startDistillAutoUpdates(dependencies: fakes.dependencies(launchDelay: 0), environment: [:]))
        try await waitUntil { fakes.events == ["check", "install", "check", "prefetch"] }
        // Quit must end the schedule, not only forget it: a pass still checking
        // would otherwise start a download in a process that is exiting.
        let schedule = try XCTUnwrap(sandboxed.distillAutoUpdates)
        sandboxed.stopDistillAutoUpdates()
        XCTAssertNil(sandboxed.distillAutoUpdates)
        XCTAssertTrue(schedule.isCancelled, "stopping must cancel the schedule's task")
    }

    // MARK: Shared update path

    /// A router whose Distill is a script, not Distill: it records how it was
    /// called, reports 2.0.41 as available until an `update` succeeded, and
    /// its `update` takes 0.3 s, or exits 1 while `fail` exists.
    private struct FakeDistill {
        let root: URL
        let binary: URL
        let fail: URL
        let updated: URL
        let calls: URL
        let ctx: AppContext
        let router: AppCommandRouter
        var recorded: [String] {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    @MainActor
    private func fakeDistill() throws -> FakeDistill {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2DistillAutoUpdate-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let calls = root.appendingPathComponent("calls.log")
        let fail = root.appendingPathComponent("fail")
        let updated = root.appendingPathComponent("updated")
        let binary = root.appendingPathComponent("fake-distill")
        try """
        #!/bin/sh
        printf '%s|%s\\n' "$*" "$REMOTE_CODE_AGENT_PROVIDER" >> "\(calls.path)"
        if [ "$*" = "update --check --json" ]; then
          if [ -e "\(updated.path)" ]; then printf '%s\\n' '\(Self.upToDate)'; else printf '%s\\n' '\(Self.updateAvailable)'; fi
          exit 0
        fi
        if [ -e "\(fail.path)" ]; then exit 1; fi
        sleep 0.3
        : > "\(updated.path)"
        exit 0
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("cli.distill.path", binary.path)
        return FakeDistill(root: root, binary: binary, fail: fail, updated: updated, calls: calls, ctx: ctx, router: router)
    }

    /// The automatic install and the user's Update action must be one path:
    /// the same binary, the same lock (never two installers at once), and a
    /// failed `distill update` reported as failed.
    @MainActor
    func test_install_sharesTheProviderUpdateActionAndItsLock() async throws {
        let f = try fakeDistill()
        let router = f.router

        let ran = await router.distillUpdateCheck()
        let check = try XCTUnwrap(ran)
        XCTAssertEqual(try DistillAutoUpdater.parse(status: check.status, stdout: check.stdout).get().latestVersion, "2.0.41")
        XCTAssertEqual(f.recorded, ["update --check --json|distill"], "the check asks with the Distill provider environment")

        let manual = Task { try await router.updateAgentProvider(provider: .distill, providerInstanceId: nil) }
        try await waitUntil { f.recorded.count == 2 }
        let duringManual = await router.installDistillUpdate()
        XCTAssertEqual(duringManual, .alreadyRunning)
        _ = try await manual.value

        let automatic = await router.installDistillUpdate()
        XCTAssertEqual(automatic, .installed)
        XCTAssertEqual(f.recorded.filter { $0 == "update|distill" }.count, 2, "one manual install and one automatic one")

        try Data().write(to: f.fail)
        let failed = await router.installDistillUpdate()
        XCTAssertEqual(failed, .failed("distill update exited with status 1"))
    }

    /// Distill cannot resume a download, so a bound shorter than its own 20
    /// minutes means a Mac on a slow line re-downloads ~194 MB every hour and
    /// never updates. The automatic install is governed by its own bound, not
    /// by the 120 s of the user's Update action.
    @MainActor
    func test_install_hasItsOwnTimeout() async throws {
        let f = try fakeDistill()
        XCTAssertGreaterThanOrEqual(AppCommandRouter.distillInstallTimeoutSeconds, 20 * 60)
        let killed = await f.router.installDistillUpdate(timeoutSeconds: 0.05)
        XCTAssertEqual(killed, .failed("distill update exited with status -1"), "the bound must reach the process")
        let installed = await f.router.installDistillUpdate()
        XCTAssertEqual(installed, .installed)
    }

    /// A background install the user never started must not put "Provider
    /// update failed" in Activity and on the pet at every retry: a failed
    /// `agent.provider.updated` becomes a persisted failure notification.
    /// A successful one still tells paired clients the provider changed, and
    /// the user's own Update action still reports its failure.
    @MainActor
    func test_failedAutomaticInstall_isNotAnnounced() async throws {
        let f = try fakeDistill()
        let outcomes = Recorded<Bool>()
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            // Distill's account controller publishes this kind too, without `ok`.
            guard event.kind == "agent.provider.updated",
                  event.payload.objectValue?["provider"] == .string("distill"),
                  let ok = event.payload.objectValue?["ok"]?.boolValue else { return }
            outcomes.append(ok)
        }
        defer { EventBus.shared.unsubscribe(token) }

        let installed = await f.router.installDistillUpdate()
        XCTAssertEqual(installed, .installed)
        try await waitUntil { outcomes.values == [true] }

        try Data().write(to: f.fail)
        let failed = await f.router.installDistillUpdate()
        XCTAssertEqual(failed, .failed("distill update exited with status 1"))
        let manual = try await f.router.updateAgentProvider(provider: .distill, providerInstanceId: nil)
        XCTAssertEqual(manual.objectValue?["ok"], .bool(false))
        try await waitUntil { outcomes.values.count >= 2 }
        XCTAssertEqual(outcomes.values, [true, false], "only the user's own failed update is announced")
    }

    /// A background install that is succeeding must never be reported to the
    /// user as a failed update: pressing Update while it holds the lock says
    /// an update is running.
    @MainActor
    func test_updatePressedDuringTheAutomaticInstall_isNotShownAsAFailure() async throws {
        let f = try fakeDistill()
        let settings = SettingsViewModel(context: f.ctx, loadImmediately: false)
        let automatic = Task { await f.router.installDistillUpdate() }
        try await waitUntil { f.recorded == ["update|distill"] }
        await settings.updateProvider(.distill)
        let message = try XCTUnwrap(settings.providerUpdateMessages[.distill])
        XCTAssertEqual(message, "Distill is already updating.")
        // The provider row paints a message with this prefix as an error.
        XCTAssertFalse(message.hasPrefix("Update failed"))
        let finished = await automatic.value
        XCTAssertEqual(finished, .installed)
        XCTAssertEqual(f.recorded, ["update|distill"])
    }

    /// The check, the install and the bot VMs' prefetch are joined only by
    /// the updater's production dependencies. Mis-wired, the app would check
    /// or install nothing, or the bot VMs would not get the latest release,
    /// and nothing would tell the user.
    @MainActor
    func test_productionDependencies_checkInstallAndPrefetchTheGuestBuild() async throws {
        let f = try fakeDistill()
        let guestTools = f.root.appendingPathComponent("guest-tools", isDirectory: true)
        let cached = guestTools.appendingPathComponent("distill/2.0.40", isDirectory: true)
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
        try Data("v40".utf8).write(to: cached.appendingPathComponent("distill-linux-aarch64"))
        let requested = Recorded<URL>()
        f.ctx.distillGuestBinaries = DistillGuestBinaryProvisioner(
            guestToolsRoot: guestTools,
            fetch: { url, _ in
                requested.append(url)
                throw DistillGuestBinaryError.downloadFailed(url: url.absoluteString, status: 404)
            },
            latestRelease: { DistillVersion(2, 0, 42) }
        )
        let dependencies = f.ctx.distillAutoUpdaterDependencies()
        let pass = await DistillAutoUpdater(dependencies).runPass()
        XCTAssertEqual(pass, .installed(latest: "2.0.41"))
        XCTAssertEqual(f.recorded, ["update --check --json|distill", "update|distill", "update --check --json|distill"])
        // The latest release, not the version the Mac's Distill just installed.
        await dependencies.prefetchGuest()
        try await waitUntil { !requested.values.isEmpty }
        XCTAssertEqual(
            requested.values.first?.absoluteString,
            "https://github.com/samuelfaj/distill/releases/download/v2.0.42/SHA256SUMS"
        )
    }

    private final class Recorded<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Value] = []
        var values: [Value] { lock.withLock { stored } }
        func append(_ value: Value) { lock.withLock { stored.append(value) } }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met in \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
