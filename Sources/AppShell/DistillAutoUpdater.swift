import Foundation
import os
import AgentRuntime
import SocketServer

private let distillUpdateLog = Logger(subsystem: "io.remotecode.agent", category: "distill.update")

/// Keeps the Mac's Distill on the latest release of its channel. RemoteCode
/// starts every Distill run with `--no-auto-update`, so without this Distill
/// only changes when the user presses the provider's update action.
///
/// A pass asks `distill update --check --json` and, when it reports an
/// update, installs it through the same path as that action. A pass never
/// surfaces an error and never fails an agent run: a failed or offline check
/// is logged and tried again at the next pass. Like every `distill update`,
/// an install asks a leader-mode Distill the user runs outside RemoteCode to
/// relaunch onto the new release after a 5 s grace, even mid-turn;
/// RemoteCode's own runs are `--no-leader` and keep the binary they started.
///
/// Whatever a pass found, the schedule then starts the bot VMs' download of
/// the latest release: they run it even when the Mac's Distill is a build
/// this updater never replaces.
actor DistillAutoUpdater {
    /// What `distill update --check --json` reports. Unknown keys are ignored.
    struct Check: Decodable, Equatable, Sendable {
        var currentVersion: String?
        var latestVersion: String?
        var updateAvailable: Bool
        /// Distill's own switch; false when the user turned its updater off.
        var autoUpdate: Bool?
        var error: String?
    }

    enum Install: Equatable, Sendable {
        case installed
        /// The user's update action holds the provider update lock.
        case alreadyRunning
        case failed(String)
    }

    enum Outcome: Equatable, Sendable {
        case upToDate
        /// Distill's installer does not manage this binary (a local build): it asked nothing.
        case notManaged(current: String?)
        case installed(latest: String?)
        /// Never read as "up to date": the next pass asks again.
        case couldNotCheck(String)
        case updateAlreadyRunning
        case installFailed(String)
        /// This release's install failed more than once; it waits some passes.
        case retryingLater(latest: String?)
        /// The update for this release was installed and the checked binary
        /// still reports it: a `cli.distill.path` pinned to a release file.
        /// Reported by the installing pass and by every later one.
        case installedBinaryNotInUse(latest: String)
        /// Another pass was running.
        case overlapped
        case cancelled
    }

    struct Dependencies: Sendable {
        /// Runs the check; nil when Distill is not installed or the command
        /// did not start or timed out.
        var check: @Sendable () async -> (status: Int32, stdout: String)?
        var install: @Sendable () async -> Install
        /// Starts the bot VMs' download of the latest release.
        var prefetchGuest: @Sendable () async -> Void
        var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        /// Launch restores workspaces and probes account usage (at 8 s) first.
        var launchDelay: TimeInterval = 30
        /// Hourly: Distill releases up to a few times a day, and a check is one
        /// short process with one request to GitHub's unauthenticated API
        /// (60 an hour per address, shared with everything else on the Mac).
        var interval: TimeInterval = 60 * 60
    }

    private let deps: Dependencies
    private var passRunning = false
    private var installedLatest: String?
    /// Failed installs of one release, and the passes left before it is tried again.
    private var failedInstall: (latest: String?, failures: Int, skip: Int)?

    init(_ dependencies: Dependencies) {
        self.deps = dependencies
    }

    /// One pass after `launchDelay`, then one every `interval`, until the
    /// calling task is cancelled. Each is followed by the bot VMs' prefetch.
    func runSchedule() async {
        var delay = deps.launchDelay
        while true {
            do { try await deps.sleep(delay) } catch { return }
            if Task.isCancelled { return }
            _ = await runPass()
            // Quit during the pass: do not start a download.
            if Task.isCancelled { return }
            await deps.prefetchGuest()
            delay = deps.interval
        }
    }

    /// Checks once and installs when an update is available. A pass that
    /// starts while another runs does nothing.
    @discardableResult
    func runPass() async -> Outcome {
        guard !passRunning else { return .overlapped }
        passRunning = true
        defer { passRunning = false }
        let outcome = await pass()
        Self.log(outcome)
        return outcome
    }

    private func pass() async -> Outcome {
        guard let output = await deps.check() else {
            return .couldNotCheck("the check did not run")
        }
        let check: Check
        switch Self.parse(status: output.status, stdout: output.stdout) {
        case .success(let parsed): check = parsed
        case .failure(let failure): return .couldNotCheck(failure.reason)
        }
        guard check.updateAvailable else {
            // No error and no latest version: Distill asked nothing, because its
            // installer does not manage this binary (a local build behind
            // `cli.distill.path`). It is never replaced, and never called current.
            return check.latestVersion == nil ? .notManaged(current: check.currentVersion) : .upToDate
        }
        if let latest = check.latestVersion, latest == installedLatest {
            return .installedBinaryNotInUse(latest: latest)
        }
        // A release whose install keeps failing (a bad checksum, a full disk,
        // a line too slow for the bound) is retried after 1, 2, 4, 8, 16 and
        // then every 24 passes, not with a ~194 MB download every hour.
        if let failed = failedInstall, failed.latest == check.latestVersion, failed.skip > 0 {
            failedInstall?.skip -= 1
            return .retryingLater(latest: check.latestVersion)
        }
        // Quit during the check: do not start a download.
        guard !Task.isCancelled else { return .cancelled }
        switch await deps.install() {
        case .installed:
            installedLatest = check.latestVersion
            failedInstall = nil
            // `distill update` compares the release behind bin/distill, not the
            // binary that was asked: with `cli.distill.path` on a release file it
            // exits 0 and RemoteCode still launches the old one.
            if let latest = check.latestVersion, await checkedBinaryUnchanged(since: check) {
                return .installedBinaryNotInUse(latest: latest)
            }
            return .installed(latest: check.latestVersion)
        case .alreadyRunning:
            return .updateAlreadyRunning
        case .failed(let reason):
            let failures = (failedInstall?.latest == check.latestVersion ? failedInstall?.failures ?? 0 : 0) + 1
            failedInstall = (check.latestVersion, failures, min(1 << min(failures - 1, 5), 24) - 1)
            return .installFailed(reason)
        }
    }

    /// Asks again after an install. A check that fails here leaves the
    /// install reported as installed; the next pass asks again.
    private func checkedBinaryUnchanged(since before: Check) async -> Bool {
        guard let output = await deps.check(),
              case .success(let after) = Self.parse(status: output.status, stdout: output.stdout)
        else { return false }
        return after.updateAvailable && after.currentVersion == before.currentVersion
    }

    struct CheckFailure: Error, Equatable {
        let reason: String
    }

    /// A non-zero exit, output that is not the check's JSON object, or a
    /// reported error (offline: exit 0 with `"error"` set) is a failed check.
    static func parse(status: Int32, stdout: String) -> Result<Check, CheckFailure> {
        guard status == 0 else { return .failure(CheckFailure(reason: "exit status \(status)")) }
        guard let check = try? JSONDecoder().decode(Check.self, from: Data(stdout.utf8)) else {
            return .failure(CheckFailure(reason: "unreadable output"))
        }
        if let error = check.error {
            return .failure(CheckFailure(reason: String(error.prefix(200))))
        }
        return .success(check)
    }

    private static func log(_ outcome: Outcome) {
        switch outcome {
        case .upToDate:
            distillUpdateLog.debug("distill.update up_to_date")
        case .notManaged(let current):
            distillUpdateLog.info(
                "distill.update skipped reason=not_managed_install version=\(current ?? "unknown", privacy: .public)"
            )
        case .installed(let latest):
            distillUpdateLog.info("distill.update installed version=\(latest ?? "unknown", privacy: .public)")
        case .couldNotCheck(let reason):
            distillUpdateLog.error("distill.update check_failed reason=\(reason, privacy: .public)")
        case .updateAlreadyRunning:
            distillUpdateLog.info("distill.update skipped reason=update_already_running")
        case .installFailed(let reason):
            distillUpdateLog.error("distill.update install_failed reason=\(reason, privacy: .public)")
        case .retryingLater(let latest):
            distillUpdateLog.info(
                "distill.update skipped reason=install_backoff version=\(latest ?? "unknown", privacy: .public)"
            )
        case .installedBinaryNotInUse(let latest):
            distillUpdateLog.info(
                "distill.update skipped reason=installed_binary_not_in_use version=\(latest, privacy: .public)"
            )
        case .overlapped, .cancelled:
            break
        }
    }
}

extension AppContext {
    /// Starts the Distill update schedule. Behind the same gate as the managed
    /// integration: the isolated sandbox, the scheduled-task agent and unit
    /// tests never check or change the user's Distill. Call after the first
    /// frame; only the scheduling happens here.
    @discardableResult
    func startDistillAutoUpdates(
        dependencies: DistillAutoUpdater.Dependencies? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard distillAutoUpdates == nil,
              Self.shouldReconcileManagedDistillIntegration(
                  isRunningUnitTests: Self.isRunningUnitTests,
                  hasSkillsHomeOverride: agentSkillsHomeOverrideForTesting != nil,
                  environment: environment
              ) else { return false }
        let updater = DistillAutoUpdater(dependencies ?? distillAutoUpdaterDependencies())
        distillAutoUpdates = Task.detached(priority: .utility) { await updater.runSchedule() }
        return true
    }

    /// Quit: no further pass starts. A pass that is checking installs nothing.
    func stopDistillAutoUpdates() {
        distillAutoUpdates?.cancel()
        distillAutoUpdates = nil
    }

    func distillAutoUpdaterDependencies() -> DistillAutoUpdater.Dependencies {
        DistillAutoUpdater.Dependencies(
            check: { [weak self] in await self?.router?.distillUpdateCheck() },
            install: { [weak self] in
                await self?.router?.installDistillUpdate() ?? .failed("the app is closing")
            },
            prefetchGuest: { [weak self] in
                guard let prefetch = await self?.router?.guestDistillPrefetchLatest() else { return }
                await prefetch()
            }
        )
    }
}

extension AppCommandRouter {
    /// Asks the Distill that `updateAgentProvider` would update, with the same
    /// environment. The process runs off the main actor.
    func distillUpdateCheck() async -> (status: Int32, stdout: String)? {
        guard let target = providerUpdateTarget(provider: .distill, instanceId: nil) else { return nil }
        return await ProviderCLIProbe.runOffCooperativePool {
            ProviderCLIProbe.distillUpdateCheck(binaryPath: target.binaryPath, environment: target.environment)
        }
    }

    /// Distill's own bound for this download (`DOWNLOAD_REQUEST_TIMEOUT`, 20 min).
    /// It does not resume: killed sooner on a slow line, every pass restarts the
    /// ~194 MB download from zero and the update never lands.
    nonisolated static let distillInstallTimeoutSeconds: TimeInterval = 20 * 60

    /// Installs through the provider update action's path, so both share its
    /// lock and the probe-cache invalidation. A success publishes
    /// `agent.provider.updated`; a failure is only returned (and logged by the
    /// pass), because that event raises a failure alert on every retry.
    func installDistillUpdate(
        timeoutSeconds: TimeInterval = AppCommandRouter.distillInstallTimeoutSeconds
    ) async -> DistillAutoUpdater.Install {
        do {
            let response = try await updateAgentProvider(
                provider: .distill, providerInstanceId: nil, timeoutSeconds: timeoutSeconds, announcesFailure: false
            )
            if response.objectValue?["ok"]?.boolValue == true { return .installed }
            let status = response.objectValue?["status"]?.intValue.map(String.init) ?? "unknown"
            return .failed("distill update exited with status \(status)")
        } catch let error as JSONRPCError where error.code == Self.providerUpdateAlreadyRunningCode {
            return .alreadyRunning
        } catch {
            return .failed((error as? JSONRPCError)?.message ?? String(describing: error))
        }
    }
}
