import XCTest
import CoreModel
import ServiceManagement
@testable import AppShell

final class ScheduledTaskRuntimeTests: XCTestCase {
    // Legacy-provider machinery is still exercised here; Distill-only rules run with the seam cleared.
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    func test_legacyProviderTaskRunsAsDistill_becauseRunsMustNeverStartOtherProviders() {
        AgentProvider.selectableForTesting = nil
        defer { AgentProvider.selectableForTesting = AgentProvider.allCases }
        var task = ScheduledTask(
            title: "Nightly", prompt: "Run tests", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp",
            runAsUser: "sam", runAsUID: 501, provider: .distill, providerInstanceID: "distill",
            model: "grok-4.6", reasoningEffort: .high,
            recurrence: .daily(at: ScheduledLocalTime(hour: 9, minute: 0)!), timeZoneIdentifier: "UTC"
        )
        task.provider = .codex
        task.providerInstanceID = "codex-cli"
        task.model = "gpt-5.6-sol"

        let resolved = ScheduledTaskExecutor.resolvingDistillDefaults(task)
        XCTAssertEqual(resolved.provider, .distill)
        XCTAssertEqual(resolved.providerInstanceID, "distill")
        XCTAssertFalse(resolved.model.isEmpty, "an unset model resolves to the Distill catalog default")
        XCTAssertNotEqual(resolved.model, "gpt-5.6-sol")
        XCTAssertEqual(resolved.prompt, "Run tests")
        XCTAssertTrue(resolved.validationErrors().isEmpty, "\(resolved.validationErrors())")
    }

    func test_reconciledDueDateLeavesPastDueUnchanged_becauseMissedFiresAreSkippedOnlyOnLaunch() {
        // WHY: while the app is open, claimDue must still see next_run_at <= now.
        // Catch-up compression of a multi-day backlog is intentionally gone.
        let now = Date(timeIntervalSince1970: 10 * 24 * 60 * 60)
        let past = Date(timeIntervalSince1970: 0)
        let task = makeHourly(nextRunAt: past)

        let reconciled = ScheduledTaskScheduler.reconciledDueDate(task: task, now: now)

        XCTAssertEqual(reconciled, past)
    }

    func test_reconciledDueDateFillsMissingNextRun_becauseEnabledTasksNeedASchedulePointer() {
        let now = Date(timeIntervalSince1970: 3 * 24 * 60 * 60)
        var task = makeHourly(nextRunAt: nil)
        task.recurrence = .once(at: Date(timeIntervalSince1970: 0))
        task.nextRunAt = nil

        // Once-in-the-past with nil next: calculatedNextRun returns nil.
        XCTAssertNil(ScheduledTaskScheduler.reconciledDueDate(task: task, now: now))
    }

    func test_catchUpWindowIsZero_becauseMissedFiresMustNotReplayOnRelaunch() {
        // WHY: product decision — schedules only run while RemoteCode is open;
        // reopening must not claim backlog within a 24h window.
        XCTAssertEqual(ScheduledTaskScheduler.catchUpWindow, 0)
    }

    func test_executeAdvancesWithSpentOccurrenceHelper_becauseTruncationMustNotRestall() throws {
        // WHY: source contract — after claim, next pointer must use afterSpent
        // (+1s), not bare calculatedNextRun(after: scheduledAt).
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("calculatedNextRunAfterSpent"))
        XCTAssertFalse(
            source.contains("calculatedNextRun(after: claim.run.scheduledAt)"),
            "execute must not advance with the raw spent scheduledAt"
        )
    }

    func test_eligibleUsersIncludesCurrentNonRootUser_becauseEditorMustOfferRunnableIdentity() throws {
        let user = try XCTUnwrap(ScheduledSystemUserCatalog.user(named: NSUserName()))
        XCTAssertNotEqual(user.uid, 0)
        XCTAssertTrue(ScheduledSystemUserCatalog.eligibleUsers().contains(user))
    }

    func test_isolatedE2EDisablesManagedDistillReconcile_becauseItMustNotMutateRunningAppTools() {
        XCTAssertFalse(AppContext.shouldReconcileManagedDistillIntegration(
            isRunningUnitTests: false,
            hasSkillsHomeOverride: false,
            environment: ["RC2_DISABLE_MANAGED_DISTILL_RECONCILE": "1"]
        ))
        XCTAssertTrue(AppContext.shouldReconcileManagedDistillIntegration(
            isRunningUnitTests: false,
            hasSkillsHomeOverride: false,
            environment: [:]
        ))
    }

    @MainActor
    func test_notFoundStillRegisters_becausePackagedAgentsCanReportItBeforeFirstRegistration() {
        XCTAssertTrue(ScheduledTaskAgentServiceManager.registrationIsRequired(for: .notFound))
        XCTAssertTrue(ScheduledTaskAgentServiceManager.registrationIsRequired(for: .notRegistered))
        XCTAssertFalse(ScheduledTaskAgentServiceManager.registrationIsRequired(for: .enabled))
        XCTAssertFalse(ScheduledTaskAgentServiceManager.registrationIsRequired(for: .requiresApproval))
    }

    func test_headlessAgentUsesDurableProviderOwnershipStore_becauseProviderSpawnMustBeCrashSafe() {
        let root = URL(fileURLWithPath: "/tmp/remote-code-scheduled-test", isDirectory: true)
        XCTAssertEqual(
            ScheduledTaskAgentAppDelegate.providerOwnershipFile(in: root).path,
            "/tmp/remote-code-scheduled-test/diagnostics/provider-process-ownership.json"
        )
    }

    func test_crossUserScheduledLaunchUsesTheSharedHelper_becauseNoShellWrapperMayEscalate() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("RunAsUserProcessBootstrap.ensureHelperInstalled()"))
        XCTAssertTrue(source.contains("runAsUser: runAsForProbe"))
        XCTAssertFalse(source.contains("/usr/bin/sudo"))
        XCTAssertFalse(source.contains("scheduled-task-runners"))
    }

    func test_manualDistillPreflightResolvesLegacyInstanceId_becauseLaunchMustUseConnectedAccount() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("snapshots.resolvedSnapshot(provider: task.provider, instanceID: task.providerInstanceID)"))
        XCTAssertTrue(source.contains("task.providerInstanceID = snapshot.id"))
        XCTAssertTrue(source.contains("instanceId: snapshot.id"))
        XCTAssertTrue(source.contains("providerInstanceId: task.providerInstanceID"))
    }

    func test_runtimePreservesFrozenProviderAndReportsManualClaimFailures_becauseRunNowMustNotSilentlyChangeOrDrop() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"))

        XCTAssertFalse(source.contains("?? snapshots.first(where: { $0.provider == task.provider })"))
        XCTAssertTrue(source.contains("completion(.failure(error))"))
        XCTAssertTrue(source.contains("scheduler.runNow(taskID: id) { result in"))
        XCTAssertTrue(source.contains("store.listActiveRuns()"))
    }

    func test_preflightErrorLocalizedDescriptionPreservesMessage_becauseRunNowAlertMustNotShowError0() {
        // WHY: without LocalizedError, NSError bridging surfaces
        // "AppShell.ScheduledTaskPreflightError error 0" and hides the payload.
        let cases: [ScheduledTaskPreflightError] = [
            .invalidTask("This scheduled task already has an active run."),
            .missingWorkspace,
            .inaccessibleWorkspace("/tmp/ws"),
            .ineligibleUser("nobody"),
            .helperUnavailable("guest"),
            .providerUnavailable("Provider not signed in."),
            .unsupportedModel("gpt-x"),
            .unsupportedReasoning("High"),
        ]
        for error in cases {
            XCTAssertEqual(error.localizedDescription, error.description, String(describing: error))
            XCTAssertFalse(
                error.localizedDescription.contains("error 0")
                    || error.localizedDescription.contains("ScheduledTaskPreflightError error"),
                "localizedDescription leaked NSError bridge: \(error.localizedDescription)"
            )
        }
        let asError: Error = ScheduledTaskPreflightError.invalidTask("Scheduler version mismatch. Retry.")
        XCTAssertEqual(asError.localizedDescription, "Scheduler version mismatch. Retry.")
    }

    @MainActor
    func test_distillScheduleValidationAllowsDuplicateModelsAndRejectsUnsupportedEffortBeforeExecution() throws {
        // WHY: equal Main and Worker models are valid, but unsupported efforts must fail before execution.
        let snapshot = AgentProviderSnapshot(
            id: "distill",
            provider: .distill,
            driverKind: .distillACP,
            displayName: "Distill",
            accentColor: "#6E56CF",
            continuationGroup: "distill",
            interactionModes: [.default],
            permissionModes: [.fullAccess],
            enabled: true,
            installed: true,
            status: .available,
            authenticated: true,
            models: [
                AgentModelDescriptor(id: "main", label: "Main", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: [.high]),
                AgentModelDescriptor(id: "reason", label: "Reason", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: [.high]),
            ],
            slashCommands: [],
            capabilities: AgentProviderCapabilities(
                supportsDistillMainEffortAuto: true,
                supportsDistillReasoningModelEffort: true
            )
        )
        var task = makeHourly(nextRunAt: nil)
        task.provider = .distill
        task.model = "main"
        task.distillMainEffortSelection = .fixed(.high)
        task.reasoningModel = "main"
        task.distillReasoningEffortSelection = .fixed(.high)
        let selection = ScheduledTaskExecutor.modelSelection(for: task)
        XCTAssertEqual(selection.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(selection.distillReasoningEffortSelection, .fixed(.high))
        XCTAssertNoThrow(try ScheduledTaskExecutor.validateModelConfiguration(task, snapshot: snapshot))

        task.distillMainEffortSelection = .fixed(.high)
        task.distillReasoningEffortSelection = .fixed(.low)
        XCTAssertThrowsError(try ScheduledTaskExecutor.validateModelConfiguration(task, snapshot: snapshot)) {
            XCTAssertEqual(($0 as? ScheduledTaskPreflightError)?.description,
                           ScheduledTaskPreflightError.unsupportedReasoning("Low").description)
        }

        task.model = "  "
        task.reasoningModel = nil
        XCTAssertThrowsError(try ScheduledTaskExecutor.validateModelConfiguration(task, snapshot: snapshot)) {
            XCTAssertEqual(
                ($0 as? ScheduledTaskPreflightError)?.description,
                ScheduledTaskPreflightError.invalidTask("Select an explicit Distill Main model.").description
            )
        }

        task.model = "reason"
        task.reasoningModel = "reason"
        task.distillReasoningEffortSelection = .fixed(.high)
        XCTAssertNoThrow(try ScheduledTaskExecutor.validateModelConfiguration(task, snapshot: snapshot))
    }

    @MainActor
    func test_deepseekAutomaticMainEffortIgnoresStaleLegacyEffort_becauseScheduleEditorPersistsBothFields() throws {
        let snapshot = AgentProviderSnapshot(
            id: "distill",
            provider: .distill,
            driverKind: .distillACP,
            displayName: "Distill",
            accentColor: "#6E56CF",
            continuationGroup: "distill",
            interactionModes: [.default],
            permissionModes: [.fullAccess],
            enabled: true,
            installed: true,
            status: .available,
            authenticated: true,
            models: [
                AgentModelDescriptor(id: "nativeDistillDeepseek", label: "DeepSeek", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: [.low, .high, .max]),
            ],
            slashCommands: [],
            capabilities: AgentProviderCapabilities(supportsDistillMainEffortAuto: true)
        )
        var task = makeHourly(nextRunAt: nil)
        task.provider = .distill
        task.model = "nativeDistillDeepseek"
        task.reasoningEffort = .medium
        task.distillMainEffortSelection = .automatic
        XCTAssertNoThrow(try ScheduledTaskExecutor.validateModelConfiguration(task, snapshot: snapshot))

        task.distillMainEffortSelection = .fixed(.medium)
        XCTAssertThrowsError(try ScheduledTaskExecutor.validateModelConfiguration(task, snapshot: snapshot))
        task.distillMainEffortSelection = nil
        XCTAssertThrowsError(try ScheduledTaskExecutor.validateModelConfiguration(task, snapshot: snapshot))

        task.distillMainEffortSelection = .fixed(.high)
        XCTAssertNoThrow(try ScheduledTaskExecutor.validateModelConfiguration(task, snapshot: snapshot))

        task.provider = .codex
        task.distillMainEffortSelection = nil
        XCTAssertThrowsError(try ScheduledTaskExecutor.validateModelConfiguration(task, snapshot: snapshot))
    }

    func test_ultracodeReachesTheRunSelectionOnlyForDistill_becauseScheduledRunsMustMatchTheComposer() {
        var task = makeHourly(nextRunAt: nil)
        task.provider = .distill
        task.model = "auto"
        task.distillExecutionMode = .ultrafast
        XCTAssertEqual(ScheduledTaskExecutor.modelSelection(for: task).distillExecutionMode, .ultrafast)
        task.distillExecutionMode = .normal
        XCTAssertEqual(ScheduledTaskExecutor.modelSelection(for: task).distillExecutionMode, .normal)
    }

    @MainActor
    func test_botScheduleCarriesUltracodeAndPermission_becauseBotRunsMustMatchTheComposer() {
        var spec = BotScheduleSpec(provider: .distill, providerInstanceID: "distill", model: "auto")
        spec.distillExecutionMode = .ultrasave
        spec.permissionMode = .supervised
        let routing = BotsViewModel.routineRouting(spec, base: BotDeskRouting())
        XCTAssertEqual(routing.distillExecutionMode, .ultrasave)
        XCTAssertEqual(routing.permissionMode, .supervised)

        let legacy = BotsViewModel.routineRouting(BotScheduleSpec(provider: .distill), base: BotDeskRouting())
        XCTAssertEqual(legacy.distillExecutionMode, .auto, "a spec that never chose a mode gets the Auto default")
        XCTAssertEqual(legacy.permissionMode, BotDeskRouting().permissionMode, "Old specs keep the Bot default")
    }

    func test_autoRoutingConfigurationCarriesScheduledFallbackAndEligibleProviders() {
        var task = makeHourly(nextRunAt: nil)
        task.routingMode = .auto

        let configuration = ScheduledTaskExecutor.routingConfiguration(
            for: task,
            policyDigest: String(repeating: "a", count: 64),
            eligibleProviders: [.codex, .grok]
        )

        XCTAssertEqual(configuration.mode, .auto)
        XCTAssertEqual(configuration.manualSelection.provider, task.provider)
        XCTAssertEqual(configuration.manualSelection.effectiveModel, task.model)
        XCTAssertEqual(configuration.manualProviderInstanceId, task.providerInstanceID)
        XCTAssertEqual(configuration.eligibleProviders, [.codex, .grok])
        XCTAssertEqual(configuration.revision, 1)
    }

    func test_rejectUIOnlySchedulePrompt_blocksLocalAgentCommands_becauseScheduleIsPasteAndPlay() {
        // WHY: Agent App intercepts /clear /status etc. without a provider turn —
        // including argument-bearing forms like `/clear foo`.
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/clear"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/clear history"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("$status"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/model gpt-5"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/fork"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/plan"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/plan implement the feature"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/default"))
        XCTAssertNoThrow(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/default Ship the deploy pipeline"))
        XCTAssertNoThrow(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("Ship the deploy pipeline"))
        XCTAssertNoThrow(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("$sam-work DEV-1"))
        XCTAssertNoThrow(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/goal reduce latency"))
    }

    func test_executeRunsHeadlessWithoutUIFocus_becauseSchedulesMustNotHijackTheUser() throws {
        // Source contract: scheduled fires create a durable thread + start via
        // sendAgentMessage. They must not activate the app, switch workspaces,
        // focus Agent App, write the composer, or depend on viewModel.send().
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("router.createAgentThread("))
        XCTAssertTrue(source.contains("router.sendAgentMessage("))
        XCTAssertTrue(source.contains("surfaceID: nil"))
        XCTAssertTrue(source.contains("quiet: true"))
        XCTAssertTrue(source.contains("permissionMode: .fullAccess"))
        XCTAssertTrue(source.contains("interactionMode: .default"))
        XCTAssertTrue(source.contains("orchestrationRoutingSnapshot: prepared.routingSnapshot"))
        XCTAssertTrue(source.contains("scheduleDispatchPrompt"))
        XCTAssertTrue(source.contains("skipMissedOccurrencesOnLaunch"))
        XCTAssertTrue(source.contains("reclaimOrphanedActiveRuns"))
        XCTAssertFalse(source.contains("openAgentAppForSchedule"))
        XCTAssertFalse(source.contains("await vm.send()"))
        XCTAssertFalse(source.contains("createThread(title: \"New thread\")"))
        XCTAssertFalse(source.contains("NSApplication.shared.activate"))
        XCTAssertFalse(source.contains("selectWorkspace("))
        XCTAssertFalse(
            source.contains("modelDiscoverySource == .live"),
            "Auto preflight must not be stricter than Agent App (requireLiveCatalog false)"
        )
        // Foreign-user Auto must not put the scheduled .sh wrapper in launch configs.
        XCTAssertTrue(source.contains("launchProviderBinary"))
        XCTAssertTrue(source.contains("allowlisted provider binary"))
        // Snapshot discovery must probe as the scheduled run-as user, not app owner.
        XCTAssertTrue(source.contains("listAgentProviderSnapshots(runAsUser:"))
    }

    func test_scheduleDispatchPrompt_matchesAgentAppFirstTokenNormalization() {
        // WHY: headless send must not regress `/sam-work`→`$sam-work`, `$goal`→`/goal`,
        // or `/default body`→`body` that AgentAppViewModel.send applied.
        let skillSnapshot = AgentProviderSnapshot(
            id: "codex",
            provider: .codex,
            driverKind: .codexCLI,
            displayName: "Codex",
            accentColor: "#2F80ED",
            continuationGroup: "codex",
            interactionModes: [.default],
            permissionModes: [.fullAccess],
            enabled: true,
            installed: true,
            status: .available,
            authenticated: true,
            binaryPath: "/usr/local/bin/codex",
            models: [AgentModelDescriptor(id: "m", label: "M", provider: .codex)],
            slashCommands: ["/goal"],
            skills: ["sam-work"],
            capabilities: .conservative
        )
        XCTAssertEqual(
            ScheduledTaskExecutor.scheduleDispatchPrompt("/sam-work DEV-1", providerSnapshot: skillSnapshot),
            "$sam-work DEV-1"
        )
        XCTAssertEqual(
            ScheduledTaskExecutor.scheduleDispatchPrompt("$goal ship it", providerSnapshot: skillSnapshot),
            "/goal ship it"
        )
        XCTAssertEqual(
            ScheduledTaskExecutor.scheduleDispatchPrompt("/default Ship the pipeline", providerSnapshot: nil),
            "Ship the pipeline"
        )
        XCTAssertEqual(
            ScheduledTaskExecutor.scheduleDispatchPrompt("$sam-work DEV-1", providerSnapshot: skillSnapshot),
            "$sam-work DEV-1"
        )
        XCTAssertEqual(
            ScheduledTaskExecutor.scheduleDispatchPrompt("plain prompt", providerSnapshot: nil),
            "plain prompt"
        )
    }

    func test_mainAppOwnsScheduler_becauseLaunchAgentMustNotDualClaim() throws {
        let main = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/Main.swift"),
            encoding: .utf8
        )
        let delegate = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/AppDelegate.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(main.contains("background agent unregistered"))
        XCTAssertFalse(main.contains("ScheduledTaskAgentAppDelegate("))
        XCTAssertTrue(delegate.contains("startInProcessScheduledTaskScheduler"))
        XCTAssertTrue(delegate.contains("ScheduledTaskAgentServiceManager().unregister()"))
        XCTAssertTrue(delegate.contains("router.scheduledTaskScheduler = scheduler"))
    }

    /// WHY: `SMAppService.unregister()` is a synchronous XPC to the background
    /// task service, and the manager is @MainActor, so the launch path paid it
    /// on main before the first window. It is a best-effort migration whose
    /// result is discarded (Main.swift already unregisters a leftover agent),
    /// so it must run from a detached task through the nonisolated entry.
    func test_launchUnregistersLegacyAgentOffMain_becauseTheXPCMustNotDelayTheFirstWindow() throws {
        let delegate = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/AppDelegate.swift"),
            encoding: .utf8
        )
        let runtime = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(delegate.contains(
            "Task.detached(priority: .utility) { try? ScheduledTaskAgentServiceManager().unregister() }"
        ))
        XCTAssertTrue(runtime.contains("public nonisolated func unregister() throws {"))
        XCTAssertTrue(runtime.contains("public nonisolated init() {}"))
    }

    func test_runNowUsesInProcessScheduler_becauseXPCIsRetired() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTasksWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("router.scheduledTaskScheduler"))
        XCTAssertTrue(source.contains("scheduler.runNow(taskID:"))
        XCTAssertFalse(source.contains("service.wake(taskID:"))
        XCTAssertFalse(source.contains("try service.register()"))
    }

    func test_autoRoutingIsBoundToSavedProviderAccount_becauseScheduledRunsMustNotSubstituteSource() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"), encoding: .utf8)

        // Auto may only admit the exact saved provider + instance (SCHED-005).
        XCTAssertTrue(source.contains("$0.id == task.providerInstanceID"))
        XCTAssertTrue(source.contains("eligibleProviders: [task.provider]"))
        XCTAssertTrue(source.contains("is unavailable for Auto model routing"))
    }

    func test_preflightProbesAuthenticationInSelectedUserContext_becauseAccountsMustNotLeakAcrossHomes() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"))

        XCTAssertTrue(source.contains("ProviderCLIProbe.authStatus("))
        XCTAssertTrue(source.contains("runAsUser: runAsForProbe"))
        XCTAssertTrue(source.contains("probeEnvironment = user.name == NSUserName()"))
        XCTAssertTrue(source.contains("The selected provider is unavailable for system user"))
    }

    func test_helperPostsFailureNotifications_becauseUnattendedErrorsMustBeVisible() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"))

        XCTAssertTrue(source.contains("SystemNotifier.shared.bootstrap()"))
        XCTAssertTrue(source.contains("title: \"Scheduled task failed\""))
    }

    private func makeHourly(nextRunAt: Date?) -> ScheduledTask {
        ScheduledTask(
            title: "Hourly", prompt: "Run", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp",
            runAsUser: NSUserName(), runAsUID: ScheduledSystemUserCatalog.user(named: NSUserName())?.uid ?? 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC", nextRunAt: nextRunAt
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func test_authCacheHitSkipsProbe_becauseBackToBackRunsMustNotRespawnTheProviderCLI() async {
        let binary = "/tmp/rc-auth-cache-hit-\(UUID().uuidString)"
        var probes = 0
        let first = await ScheduledProviderAuthCache.authenticated(provider: .codex, binaryPath: binary, runAsUser: nil) {
            probes += 1
            return true
        }
        let second = await ScheduledProviderAuthCache.authenticated(provider: .codex, binaryPath: binary, runAsUser: nil) {
            probes += 1
            return true
        }
        XCTAssertEqual(first, true)
        XCTAssertEqual(second, true)
        XCTAssertEqual(probes, 1, "a successful probe inside the TTL must be reused")
    }

    func test_authCacheNeverCachesFailureOrUnknown_becauseAFixedLoginMustBeSeenOnTheNextRun() async {
        let binary = "/tmp/rc-auth-cache-fail-\(UUID().uuidString)"
        var probes = 0
        for result: Bool? in [false, nil, false] {
            let value = await ScheduledProviderAuthCache.authenticated(provider: .codex, binaryPath: binary, runAsUser: nil) {
                probes += 1
                return result
            }
            XCTAssertEqual(value, result)
        }
        XCTAssertEqual(probes, 3, "failed or unknown probes must run again every time")
    }

    func test_authCacheKeyIncludesRunAsUser_becauseAnotherAccountsLoginIsDifferent() async {
        let binary = "/tmp/rc-auth-cache-user-\(UUID().uuidString)"
        let alice = AgentRunAsUser(generatedUID: "a", shortName: "alice", uid: 501, gid: 20, homePath: "/Users/alice")
        let bob = AgentRunAsUser(generatedUID: "b", shortName: "bob", uid: 502, gid: 20, homePath: "/Users/bob")
        var probes = 0
        _ = await ScheduledProviderAuthCache.authenticated(provider: .codex, binaryPath: binary, runAsUser: alice) {
            probes += 1; return true
        }
        _ = await ScheduledProviderAuthCache.authenticated(provider: .codex, binaryPath: binary, runAsUser: bob) {
            probes += 1; return true
        }
        XCTAssertEqual(probes, 2)
    }
}
