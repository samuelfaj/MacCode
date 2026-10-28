import Foundation
import os
import AgentRuntime
import CoreModel
import Persistence
import SocketServer

private let guestResolverLog = Logger(subsystem: "io.remotecode.agent", category: "bot.guest")

/// The bot container a guest run executes in, once it is current, running and
/// has the run's workspace mounted.
struct BotGuestVM: Equatable, Sendable {
    var container: String
    /// `docker info` Architecture (picks the guest Distill asset).
    var dockerArch: String
    /// Host paths bound at the same path inside the guest.
    var mountedWorkspaces: [String]
}

/// Brings a bot's container up for a guest run. Blocking (Docker CLI); the
/// resolver calls it on a dispatch queue, never on the cooperative pool.
protocol BotGuestVMPreparing: Sendable {
    /// `workspace` nil: a workspace-less (desk) thread, provision only.
    func prepare(
        botID: BotID,
        threadID: AgentThreadID,
        workspace: String?,
        registeredWorkspaces: Set<String>
    ) throws -> BotGuestVM
}

/// Decides and prepares, per Distill run, whether it runs inside its bot's
/// Linux guest (plan A).
///
/// Only threads carrying the durable guest marker (`BotGuestRuntime`) on a
/// `.vm` target go to the guest; legacy `.vm` threads keep their Mac sessions.
/// A guest thread never falls back to the Mac: every failure throws.
///
/// Conversations run on one bot VM in parallel. The registry claim
/// (`tryBegin`) is taken here, at the spawn point every send path goes
/// through, and is refused only while a rebuild or stop holds the VM ("The
/// VM is busy"); the coordinator's run-finished callback frees it. A
/// contextual run shares its identity's VM like an ordinary run (delegated
/// runs stay exclusive); its lease is per run, so a retry of the same run
/// waits for that run's teardown without blocking other conversations.
///
/// Stop while a run is still preparing (an image build can take minutes)
/// invalidates the run's acceptance permit; preparation then stops at its
/// next step and undoes what it did, so nothing is provisioned, copied or
/// spawned for a run the user already stopped.
final class BotGuestRunResolver: DistillGuestLaunchResolving, @unchecked Sendable {
    struct Dependencies: @unchecked Sendable {
        var threadRepo: AgentThreadRepository
        var botStore: BotStore
        var appSupport: URL
        var registry: BotVMRunRegistry = .shared
        var isDelegatedRun: @Sendable (AgentRunID, AgentThreadID) -> Bool = { _, _ in false }
        var onVMAvailable: @Sendable (BotID, AgentThreadID) -> Void = { _, _ in }
        var leases = DistillGuestLeases()
        var barrier: DistillGuestLaunchBarrier
        var gateway: BotGuestMCPGateway
        var vm: any BotGuestVMPreparing
        /// In-guest path of the verified Distill binary for a Docker architecture.
        var binaryGuestPath: @Sendable (_ hostBinary: String?, _ dockerArch: String) async throws -> String
        /// Renews the Mac sign-in a run's model uses when it expires soon.
        var refresh: @Sendable (_ hostHome: URL, _ provider: DistillAccountProvider?) async throws -> Void
        var dockerExecutable: @Sendable () throws -> String
        /// Registered workspace roots by id (MainActor state in the app).
        var workspaces: @Sendable () async -> [WorkspaceID: String]
        var prepareContextRuntime: (@Sendable (AgentRunRequest, AgentRunID?, String, Bool) async throws -> BotContextGuestResources)? = nil
        var contextualAdmissions: BotContextRunAdmissions? = nil
        var contextDockerArchitecture: (@Sendable () throws -> String)? = nil
        /// The Mac distill binary, for its version (nil: not installed).
        var hostBinary: @Sendable (_ request: AgentRunRequest) -> String?
        /// Reads the Mac distill binary's version ahead of `binaryGuestPath`,
        /// which reuses a version that was read (one that could not be read
        /// is asked for again). It does not depend on the VM, so it runs
        /// while the VM comes up.
        var probeHostVersion: @Sendable (_ hostBinary: String?) async -> Void = { _ in }
        /// The Codex client version the Mac's Distill would name to ChatGPT
        /// for a run with this host environment (`DistillCodexClientVersion`);
        /// nil when it would use its built-in default. Runs while the VM
        /// comes up, like `probeHostVersion`.
        var codexClientVersion: @Sendable (_ hostEnvironment: [String: String]) async -> String? = { _ in nil }
        var gitIdentity: @Sendable () -> GitIdentity?
        /// The app's own environment, under the run's (DISTILL_HOME, model keys).
        var processEnvironment: [String: String] = ProcessInfo.processInfo.environment
        var heartbeatInterval: TimeInterval = BotGuestLeaseHeartbeat.interval
        /// How long a run start waits for the other sign-ins to be renewed.
        var otherSignInWait: TimeInterval = 3
        /// False in a process that does not own the app's bot guests (the
        /// scheduled-task agent): its guest threads fail instead of racing
        /// the app for the same bot.
        var hostsGuestRuns = true
    }

    private let deps: Dependencies
    private let lock = NSLock()
    private var mirrors: [String: DistillGuestCredentialMirror] = [:]
    /// Plans handed out and not yet torn down, by run id.
    private var livePlans: [String: (plan: DistillGuestLaunchPlan, retainsVMClaim: Bool)] = [:]

    init(_ dependencies: Dependencies) {
        self.deps = dependencies
    }

    func retainsExclusiveVMClaim(runID: AgentRunID) -> Bool {
        lock.withLock { livePlans[runID.value.uuidString.lowercased()]?.retainsVMClaim == true }
    }

    // MARK: - DistillGuestLaunchResolving


    func isGuestThread(_ threadId: AgentThreadID) -> Bool {
        (try? deps.threadRepo.guestPlacement(of: threadId))??.runsInGuest == true
    }

    func preservesSessionIdentity(_ threadId: AgentThreadID) -> Bool {
        guard deps.contextualAdmissions?.hasAdmission(threadID: threadId) == true else { return false }
        do { return try deps.botStore.conversationContextPin(linkedTo: threadId) != nil }
        catch { return true }
    }

    var supportsGuestRecovery: Bool { deps.hostsGuestRuns }

    func resynchronizeGuest(_ request: AgentRunRequest) async throws -> Bool {
        try Task.checkCancellation()
        guard deps.hostsGuestRuns,
              request.runAsUser.map({ $0.uid == getuid() }) ?? true,
              deps.contextualAdmissions?.hasAdmission(for: request.runId) != true,
              deps.contextualAdmissions?.hasAdmission(threadID: request.threadId) != true,
              try deps.botStore.conversationContextPin(linkedTo: request.threadId) == nil,
              let placement = try deps.threadRepo.guestPlacement(of: request.threadId), placement.runsInGuest,
              let thread = try deps.threadRepo.get(id: request.threadId) else { return false }
        let botID = try dockerBot(of: thread)
        let destination = try deps.botStore.threadExecutionDestination(thread.id)
            ?? deps.botStore.executionDestination(botID: botID)
        guard destination.target == .vm else { return false }
        try deps.botStore.validateExecutionDestination(destination, botID: botID, workspaceID: thread.workspaceId, contextPin: nil)
        let resourceID = try deps.botStore.guestResourceID(botID: botID, threadID: thread.id)
        guard !BotComputerControl.shared.isControlledByUser(botID, resourceID: resourceID),
              deps.registry.claim(botID: botID, threadID: thread.id, resourceID: resourceID)?.runID == request.runId else { return false }
        let environment = deps.processEnvironment.merging(request.environment) { _, run in run }
        let hostHome = DistillProvisioner.homeURL(environment: environment)
        let runID = request.runId.value.uuidString.lowercased()
        // Only re-copy current credentials; token renewal remains owned by normal preflight.
        return try lock.withLock {
            guard let plan = livePlans[runID]?.plan, plan.container == BotComputerGuestSpec.containerName(botID: resourceID),
                  let mirror = mirrors[hostHome.path] else { return false }
            try Task.checkCancellation()
            return try mirror.resynchronize(runID: runID)
        }
    }

    func prepare(
        _ request: AgentRunRequest,
        progress: @escaping @Sendable (DistillGuestStage) -> Void
    ) async throws -> DistillGuestLaunchPlan? {
        if deps.contextualAdmissions?.hasAdmission(for: request.runId) == true,
           try deps.botStore.conversationContextPin(linkedTo: request.threadId) != nil {
            let work = Task {
                try await self.preparePinnedContextRuntime(request, progress: progress)
            }
            request.acceptancePermit?.onInvalidate { work.cancel() }
            return try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        }
        guard let placement = try deps.threadRepo.guestPlacement(of: request.threadId),
              placement.runsInGuest else { return nil }
        let stamps = BotGuestPrepareIntervals()
        let work = Task {
            // Covers the launch barrier and the run claim, until the first
            // stage is reported.
            stamps.begin(.starting)
            defer { stamps.end() }
            return try await self.prepareGuestRun(request, placement: placement) { stage in
                stamps.begin(stage)
                progress(stage)
            }
        }
        request.acceptancePermit?.onInvalidate { work.cancel() }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func preparePinnedContextRuntime(
        _ request: AgentRunRequest,
        progress: @escaping @Sendable (DistillGuestStage) -> Void
    ) async throws -> DistillGuestLaunchPlan {
        let unavailable = DistillGuestLaunchError.unavailable(
            "Contextual execution is unavailable until runtime isolation is verified."
        )
        guard deps.hostsGuestRuns else { throw unavailable }
        try await deps.barrier.wait()
        try Task.checkCancellation()
        guard let prepareContextRuntime = deps.prepareContextRuntime else { throw unavailable }
        guard let admissions = deps.contextualAdmissions else {
            let resources = try await prepareContextRuntime(request, nil, "", false)
            if resources.hasCredentialMaterial { progress(.preparingAgent) }
            try await Self.blocking { try resources.cancel() }
            throw unavailable
        }
        guard let admission = try admissions.consume(request) else {
            let resources = try await prepareContextRuntime(request, nil, "", false)
            if resources.hasCredentialMaterial { progress(.preparingAgent) }
            try await Self.blocking { try resources.cancel() }
            throw unavailable
        }
        let identity = try deps.botStore.contextRuntimeIdentity(pin: admission.pin, threadID: request.threadId)
        guard !BotComputerControl.shared.isControlledByUser(admission.pin.botID, resourceID: identity.storageBotID) else {
            throw DistillGuestLaunchError.unavailable("You are controlling this VM. Return control before starting a conversation.")
        }
        let claim = BotVMRunRegistry.Entry(threadID: request.threadId, runID: request.runId,
            title: (try deps.threadRepo.get(id: request.threadId))?.title ?? "Conversation", workspace: request.cwd,
            exclusive: deps.isDelegatedRun(request.runId, request.threadId))
        if let holder = deps.registry.tryBegin(botID: admission.pin.botID, entry: claim, resourceID: identity.storageBotID,
                                              allowsSameThreadExclusive: false) {
            throw DistillGuestLaunchError.busy("The VM is busy in \(holder.title)")
        }
        let lease = try await deps.leases.acquire(Self.contextLeaseKey(identity: identity, runID: request.runId))
        var resources: BotContextGuestResources?
        var heartbeat: BotGuestLeaseHeartbeat?
        do {
            func validate() throws {
                try Task.checkCancellation()
                guard admission.validates() else { throw unavailable }
            }
            try validate()
            guard request.providerBinary == nil,
                  request.extraArgs.isEmpty, request.providerThreadId == admission.resumeCursor,
                  !admission.model.isEmpty, request.model == admission.model,
                  let architecture = deps.contextDockerArchitecture else { throw unavailable }
            progress(.preparingAgent)
            let hostBinary = deps.hostBinary(request)
            await deps.probeHostVersion(hostBinary)
            try validate()
            let dockerArch = try architecture()
            let binaryPath = try await deps.binaryGuestPath(hostBinary, dockerArch)
            try validate()
            let dockerExecutable = try deps.dockerExecutable()
            progress(.startingVM)
            let prepared = try await prepareContextRuntime(request, admission.parentRunID, admission.providerConfiguration, true)
            resources = prepared
            try validate()
            guard let envFile = prepared.envFileURL else { throw unavailable }
            let runID = request.runId.value.uuidString.lowercased()
            let guestHome = BotComputerGuestSpec.guestHomeURL(appSupport: deps.appSupport, botID: prepared.identity.storageBotID)
            let leaseHeartbeat = try BotGuestLeaseHeartbeat(guestHome: guestHome, runID: runID, interval: deps.heartbeatInterval)
            heartbeat = leaseHeartbeat
            let computedGuestCwd: String
            switch admission.pin.context {
            case .general: computedGuestCwd = BotComputerGuestSpec.guestUserHome
            case .workspace: computedGuestCwd = request.cwd
            }
            let guestCwd = Self.guestResumeCwd(request, guestHome: guestHome, computed: computedGuestCwd, mounted: [])
            let guestCommand = try DistillGuestLaunchPlan.guestCommand(binaryPath: binaryPath, for: request)
            try validate()
            progress(.launching)
            try validate()
            let plan = DistillGuestLaunchPlan(
                runID: runID, dockerExecutable: dockerExecutable, container: prepared.container,
                guestCwd: guestCwd, guestCommand: guestCommand, envFileURL: envFile, lease: lease,
                teardown: { [weak self] _ in
                    leaseHeartbeat.stop()
                    do { try await Self.blocking { try prepared.cancel() } }
                    catch { guestResolverLog.error("bot.context.finish_failed run=\(runID, privacy: .public)") }
                    self?.forgetPlan(runID: runID)
                },
                onSessionOpened: admission.recordOpened
            )
            lock.withLock { livePlans[runID] = (plan, false) }
            return plan
        } catch {
            heartbeat?.stop()
            if let resources {
                do { try await Self.blocking { try resources.cancel() } }
                catch { guestResolverLog.error("bot.context.prepare_cleanup_failed run=\(request.runId.value.uuidString.lowercased(), privacy: .public)") }
            }
            await lease.release()
            throw Self.launchError(error)
        }
    }

    static func contextLeaseKey(identity: BotContextRuntimeIdentity, runID: AgentRunID) -> String {
        "\(identity.storageBotID.value.uuidString.lowercased()):\(runID.value.uuidString.lowercased())"
    }

    private func prepareGuestRun(
        _ request: AgentRunRequest,
        placement: AgentThreadGuestPlacement,
        progress: @escaping @Sendable (DistillGuestStage) -> Void
    ) async throws -> DistillGuestLaunchPlan {
        guard placement.guestRuntime == BotGuestRuntime.distillV1 else {
            throw DistillGuestLaunchError.unavailable(
                "this conversation was set up by a newer MacCode; update MacCode to run it."
            )
        }
        guard deps.hostsGuestRuns else {
            throw DistillGuestLaunchError.unavailable("bot Linux VM runs only start from the MacCode app.")
        }
        // The guest gets the app user's own sign-ins; a run meant for another
        // macOS user must not run with them.
        if let runAsUser = request.runAsUser, runAsUser.uid != getuid() {
            throw DistillGuestLaunchError.unavailable(
                "this conversation runs as the macOS user \(runAsUser.shortName); bot Linux VM runs use only your own accounts."
            )
        }
        guard let thread = try deps.threadRepo.get(id: request.threadId) else {
            throw DistillGuestLaunchError.unavailable("the conversation no longer exists.")
        }
        let botID = try dockerBot(of: thread)
        let destination = try deps.botStore.threadExecutionDestination(thread.id)
            ?? deps.botStore.executionDestination(botID: botID)
        try deps.botStore.validateExecutionDestination(
            destination, botID: botID, workspaceID: thread.workspaceId,
            contextPin: deps.botStore.conversationContextPin(linkedTo: thread.id)
        )
        let machine = try destination.virtualMachineID.flatMap { try deps.botStore.virtualMachine(id: $0) }
        if let workspaceID = machine?.workspaceID, await deps.workspaces()[workspaceID] == nil {
            throw DistillGuestLaunchError.unavailable("This VM's workspace is no longer available.")
        }
        let resourceID = try deps.botStore.guestResourceID(botID: botID, threadID: thread.id)
        guard !BotComputerControl.shared.isControlledByUser(botID, resourceID: resourceID) else {
            throw DistillGuestLaunchError.unavailable("You are controlling this VM. Return control before starting a conversation.")
        }
        try await deps.barrier.wait()

        let claim = BotVMRunRegistry.Entry(
            threadID: request.threadId, runID: request.runId, title: thread.title, workspace: request.cwd,
            exclusive: deps.isDelegatedRun(request.runId, request.threadId)
        )
        if let holder = deps.registry.tryBegin(botID: botID, entry: claim, resourceID: resourceID,
                                              allowsSameThreadExclusive: false) {
            throw DistillGuestLaunchError.busy("The VM is busy in \(holder.title)")
        }
        // Failed preparation leaves release to the coordinator. A prepared
        // delegated run keeps its exclusive claim until guest termination
        // is confirmed; ordinary runs continue sharing the VM.
        let leaseKey = resourceID.value.uuidString.lowercased()
        let runID = request.runId.value.uuidString.lowercased()
        var undo: [() -> Void] = []
        do {
            // A lease handed over just before a Stop is this run's to free.
            try Task.checkCancellation()
            progress(.startingVM)
            var workspace = try await workspaceRoot(of: thread)
            if workspace == nil, let workspaceID = machine?.workspaceID {
                workspace = await deps.workspaces()[workspaceID]
            }
            let mount = workspace
            let registered = Set(await deps.workspaces().values)
            let vmPreparer = deps.vm
            // Runs while the VM comes up: it needs nothing from the VM. Not
            // awaited when the VM fails or the send is stopped, so neither
            // waits on a distill binary that hangs. The sign-in renewal
            // stays after the VM: a stopped or failed start renews nothing.
            let hostBinary = deps.hostBinary(request)
            let probeHostVersion = deps.probeHostVersion
            let hostVersionProbe = Task { await probeHostVersion(hostBinary) }
            // The same holds for the Codex version the guest asks ChatGPT as.
            let hostEnvironment = deps.processEnvironment.merging(request.environment) { _, run in run }
            let resolveCodexClientVersion = deps.codexClientVersion
            let codexClientVersionProbe = Task { await resolveCodexClientVersion(hostEnvironment) }
            let vm = try await Self.blocking {
                try vmPreparer.prepare(
                    botID: resourceID, threadID: request.threadId,
                    workspace: mount, registeredWorkspaces: registered
                )
            }
            try Task.checkCancellation()
            // A workspace-pinned Bot conversation runs in the Bot's Mac home like a
            // desk one; that path is never mounted, so it runs in the guest home.
            let guestHome = BotComputerGuestSpec.guestHomeURL(appSupport: deps.appSupport, botID: resourceID)
            let computedGuestCwd = try Self.guestCwd(
                requestCwd: thread.workspaceId == nil ? (workspace ?? request.cwd) : request.cwd,
                workspace: Self.isBotHome(request.cwd, appSupport: deps.appSupport) ? nil : workspace,
                mounted: vm.mountedWorkspaces
            )
            let guestCwd = Self.guestResumeCwd(
                request, guestHome: guestHome, computed: computedGuestCwd, mounted: vm.mountedWorkspaces
            )

            progress(.preparingAgent)
            await hostVersionProbe.value
            let binaryPath = try await deps.binaryGuestPath(hostBinary, vm.dockerArch)
            let dockerExecutable = try deps.dockerExecutable()
            try Task.checkCancellation()

            progress(.signingIn)
            let hostHome = DistillProvisioner.homeURL(environment: hostEnvironment)
            let hostConfig = (try? String(
                contentsOf: hostHome.appendingPathComponent("config.toml"), encoding: .utf8
            )) ?? ""
            let provider = DistillGuestCredentials.accountProvider(model: request.model, hostConfig: hostConfig)
            let accounts = try DistillGuestCredentials.accountsForRun(
                model: request.model, hostConfig: hostConfig, hostHome: hostHome)
            if accounts.isEmpty { try await deps.refresh(hostHome, provider) }
            else {
                var prepared = false
                var lastError: Error?
                for account in accounts {
                    // A token request is not cut by Stop, so it returns normally.
                    try Task.checkCancellation()
                    do {
                        try await Self.prepareAccount(account, hostHome: hostHome, binary: hostBinary,
                            environment: hostEnvironment, refresh: deps.refresh)
                        prepared = true
                    } catch is CancellationError { throw CancellationError() }
                    catch { lastError = error }
                }
                if !prepared, let lastError { throw lastError }
            }
            // Best effort: the run's own sign-in is ready, so another one
            // that cannot be renewed now must not stop it, and a slow one
            // must not hold it. Waited for briefly, because the guest loads
            // each account's models once, when it starts. Never cancelled,
            // by Stop or by the wait ending: a renewal that is cut may
            // already have spent the refresh token. A late renewal reaches
            // the guest through the mirror's watcher.
            let used = Set(accounts.map(\.provider) + [provider].compactMap { $0 })
            let others = DistillHostCredentialRefresher.otherSignIns(hostHome: hostHome, excluding: used)
            if !others.isEmpty {
                let refresh = deps.refresh
                let wait = deps.otherSignInWait
                let (renewed, signal) = AsyncStream<Void>.makeStream()
                Task {
                    for other in others {
                        do { try await refresh(hostHome, other) } catch {
                            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                            guestResolverLog.error(
                                "bot.guest.credentials.other_refresh_failed provider=\(other.rawValue, privacy: .public) error=\(reason, privacy: .public)"
                            )
                        }
                    }
                    signal.finish()
                }
                let deadline = Task {
                    try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
                    signal.finish()
                }
                // Ends when the renewals do, at the deadline, or on Stop.
                for await _ in renewed {}
                deadline.cancel()
            }
            try Task.checkCancellation()
            let guestDistillHome = DistillGuestCredentials.distillHome(guestHome: guestHome)
            let mirror = mirror(hostHome: hostHome, binary: hostBinary, environment: hostEnvironment)
            try mirror.begin(runID: runID, guestDistillHome: guestDistillHome, provider: provider, accounts: accounts)
            undo.append { mirror.end(runID: runID) }

            let gateway = deps.gateway
            let issued = try gateway.issue(BotGuestMCPGateway.Binding(
                runID: runID,
                hostEnvironment: BotGuestMCPGateway.Binding.hostEnvironment(fromRunEnvironment: request.environment)
            ))
            undo.append { gateway.revoke(runID: runID) }
            let rendered = DistillGuestConfig.render(
                hostConfig: hostConfig, gatewayPort: issued.port, hostEnvironment: hostEnvironment
            )
            if let reason = rendered.droppedModels[request.model] {
                throw DistillGuestLaunchError.unavailable(
                    "the model \(request.model) cannot run in the bot's Linux VM: \(reason)"
                )
            }
            let envFile = try DistillGuestEnvironment.writeRunFiles(
                rendered: rendered,
                configDirectory: guestDistillHome,
                guestDistillHome: DistillGuestEnvironment.distillHome,
                providerEnvironment: request.environment,
                runID: runID,
                gatewayToken: issued.token,
                gitIdentity: deps.gitIdentity(),
                codexClientVersion: await codexClientVersionProbe.value,
                runsDirectory: DistillGuestEnvironment.runsDirectory(appSupport: deps.appSupport)
            )
            undo.append { unlink(envFile.path) }
            // Before the agent starts: its reaper ends a run with no lease.
            let heartbeat = try BotGuestLeaseHeartbeat(
                guestHome: guestHome, runID: runID, interval: deps.heartbeatInterval
            )
            undo.append { heartbeat.stop() }
            let guestCommand = try DistillGuestLaunchPlan.guestCommand(binaryPath: binaryPath, for: request)
            try Task.checkCancellation()

            progress(.launching)
            guestResolverLog.info(
                "bot.guest.prepared run=\(runID, privacy: .public) bot=\(leaseKey, privacy: .public) binary=\(binaryPath, privacy: .public)"
            )
            let onTerminationConfirmed: (@Sendable () -> Void)?
            if claim.exclusive {
                onTerminationConfirmed = { [weak self, registry = deps.registry, onVMAvailable = deps.onVMAvailable] in
                    let next = registry.releaseAndNextWaiter(runID: request.runId)
                    self?.forgetPlan(runID: runID)
                    if let next { onVMAvailable(next.botID, next.threadID) }
                }
            } else {
                onTerminationConfirmed = nil
            }
            let plan = DistillGuestLaunchPlan(
                runID: runID,
                dockerExecutable: dockerExecutable,
                container: vm.container,
                guestCwd: guestCwd,
                guestCommand: guestCommand,
                envFileURL: envFile,
                lease: nil,
                teardown: { [weak self] _ in
                    heartbeat.stop()
                    if !claim.exclusive { self?.forgetPlan(runID: runID) }
                    mirror.end(runID: runID)
                    gateway.revoke(runID: runID)
                },
                onTerminationConfirmed: onTerminationConfirmed
            )
            lock.withLock { livePlans[runID] = (plan, claim.exclusive) }
            return plan
        } catch {
            undo.reversed().forEach { $0() }
            if error is CancellationError {
                guestResolverLog.info(
                    "bot.guest.prepare_stopped run=\(runID, privacy: .public) bot=\(leaseKey, privacy: .public)"
                )
            } else {
                guestResolverLog.error(
                    "bot.guest.prepare_failed run=\(runID, privacy: .public) bot=\(leaseKey, privacy: .public)"
                )
            }
            throw Self.launchError(error)
        }
    }

    // MARK: - App termination

    /// App quit, synchronous: ends every guest run this app still owns
    /// (including one whose turn is still ending, which the adapter no longer
    /// tracks) with a fire-and-forget `kill-agent`, stops renewing their
    /// sign-in copies, and deletes every copy, env file and lease, as the
    /// next launch would. A run whose kill does not land is ended by its
    /// guest reaper once its lease stops changing. A process that does not
    /// host guest runs (the scheduled-task agent) leaves the app's alone.
    func endRunsForAppTermination() {
        guard deps.hostsGuestRuns else { return }
        let (plans, mirrors) = lock.withLock { (livePlans.values.map(\.plan), Array(self.mirrors.values)) }
        plans.forEach { $0.killGuestDetached() }
        mirrors.forEach { $0.endAll() }
        BotGuestLaunchSweep.removeLeftovers(appSupport: deps.appSupport)
        guestResolverLog.info("bot.guest.app_termination runs=\(plans.count, privacy: .public)")
    }

    private func forgetPlan(runID: String) {
        lock.withLock { _ = livePlans.removeValue(forKey: runID) }
    }

    // MARK: - Rules

    /// The bot whose Docker desktop runs this thread.
    private func dockerBot(of thread: AgentThread) throws -> BotID {
        let linked = thread.actor.botID ?? (try? deps.botStore.conversationLinked(to: thread.id))??.botID
        guard let botID = linked,
              let bot = try deps.botStore.get(id: botID), bot.deletedAt == nil else {
            throw DistillGuestLaunchError.unavailable("the bot of this conversation no longer exists.")
        }
        let revision = try bot.currentRevisionID.flatMap { try deps.botStore.getRevision(id: $0) }
        let pinned = try deps.botStore.threadExecutionDestination(thread.id)
        guard pinned?.target == .vm || revision?.desktopKind == .dockerDesktop else {
            throw DistillGuestLaunchError.unavailable("this bot no longer has a Docker desktop.")
        }
        return botID
    }

    /// The registered workspace root a workspace thread mounts; nil for a
    /// workspace-less (desk) thread.
    private func workspaceRoot(of thread: AgentThread) async throws -> String? {
        guard let workspaceID = thread.workspaceId else { return nil }
        guard let root = await deps.workspaces()[workspaceID] else {
            throw DistillGuestLaunchError.unavailable("this conversation's workspace is no longer open in MacCode.")
        }
        return root
    }

    /// Where the agent runs inside the guest. A desk thread runs in the guest
    /// user's home. A workspace thread runs at its own path, which must be
    /// the mounted workspace or inside it; anything else fails rather than
    /// silently running somewhere else. A linked git worktree also needs the
    /// repository its `.git` file points at to be mounted, or git fails inside.
    static func guestCwd(requestCwd: String, workspace: String?, mounted: [String]) throws -> String {
        guard workspace != nil else { return BotComputerGuestSpec.guestUserHome }
        let cwd = URL(fileURLWithPath: requestCwd).resolvingSymlinksInPath().standardizedFileURL.path
        guard let mount = mountContaining(cwd, mounted) else {
            throw DistillGuestLaunchError.unavailable(
                "this conversation's folder \(cwd) is not inside a folder mounted in the bot's Linux VM."
            )
        }
        if let gitDir = linkedGitDir(from: cwd, upTo: mount), mountContaining(gitDir, mounted) == nil {
            throw DistillGuestLaunchError.unavailable(
                "this conversation's git worktree belongs to a repository at \(gitDir), which is not mounted in the bot's Linux VM."
            )
        }
        return cwd
    }

    /// A resumed guest session must run in the cwd Distill stored it under:
    /// `session/load` fails when the cwd differs. Keep the stored cwd only when
    /// it is the guest home or inside a mounted workspace; otherwise keep `computed`.
    static func resumeGuestCwd(computed: String, stored: String?, mounted: [String]) -> String {
        guard let stored, stored != computed else { return computed }
        if stored == BotComputerGuestSpec.guestUserHome || mountContaining(stored, mounted) != nil {
            return stored
        }
        return computed
    }

    /// `resumeGuestCwd` for a run; reads the stored session from the guest's `.distill`.
    static func guestResumeCwd(
        _ request: AgentRunRequest, guestHome: URL, computed: String, mounted: [String]
    ) -> String {
        guard let sessionId = request.providerThreadId, !sessionId.isEmpty else { return computed }
        let sessionsRoot = DistillGuestCredentials.distillHome(guestHome: guestHome)
            .appendingPathComponent("sessions", isDirectory: true)
        let stored = DistillACPAdapter.storedSessionCwd(sessionsRoot: sessionsRoot, sessionId: sessionId)
        let resumed = resumeGuestCwd(computed: computed, stored: stored, mounted: mounted)
        if resumed != computed {
            guestResolverLog.info(
                "bot.guest.resume_cwd_switched run=\(request.runId.value.uuidString.lowercased(), privacy: .public) thread=\(request.threadId.description, privacy: .public)"
            )
        }
        return resumed
    }

    /// A Bot home: under the running app's bots root, or at
    /// `…/RemoteCode*/bots/<uuid>/e<N>` from another channel's or an override's
    /// Application Support.
    static func isBotHome(_ cwd: String, appSupport: URL) -> Bool {
        let root = BotHome.botsRootURL(appSupportDirectory: appSupport).resolvingSymlinksInPath().standardizedFileURL.path
        let path = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        return mountContaining(path, [root]) != nil || hasBotHomeLayout(path)
    }

    static func hasBotHomeLayout(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard parts.count >= 4 else { return false }
        return (1..<(parts.count - 2)).contains { index in
            parts[index] == "bots"
                && parts[index - 1].hasPrefix("RemoteCode")
                && UUID(uuidString: parts[index + 1]) != nil
                && parts[index + 2].range(of: #"^e\d+$"#, options: .regularExpression) != nil
        }
    }


    private static func mountContaining(_ path: String, _ mounted: [String]) -> String? {
        mounted.first { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// The git directory a `.git` file (`gitdir: <path>`) between `path` and
    /// `root` points at; nil when the nearest `.git` is a directory or absent.
    static func linkedGitDir(from path: String, upTo root: String) -> String? {
        var directory = URL(fileURLWithPath: path, isDirectory: true)
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue,
                      let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(whereSeparator: \.isNewline).first,
                      line.hasPrefix("gitdir:") else { return nil }
                let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let url = target.hasPrefix("/")
                    ? URL(fileURLWithPath: target)
                    : directory.appendingPathComponent(target)
                return url.resolvingSymlinksInPath().standardizedFileURL.path
            }
            if directory.path == root || directory.path == "/" { return nil }
            directory.deleteLastPathComponent()
        }
    }

    // MARK: - Helpers

    /// Grok's scoped CLI owns its OIDC refresh chain; do not duplicate that transport in Swift.
    private static func prepareAccount(
        _ account: DistillAccountStatus, hostHome: URL, binary: String?, environment: [String: String],
        refresh: @Sendable (URL, DistillAccountProvider?) async throws -> Void
    ) async throws {
        let credentialHome = try DistillAccounts.credentialHome(account: account, home: hostHome)
        do { try await refresh(credentialHome, account.provider) }
        catch DistillGuestCredentialError.grokLoginExpiring where !account.legacy {
            guard let binary else { throw DistillGuestCredentialError.notSignedIn(.grok) }
            let accounts = DistillAccounts(home: hostHome, binaryPath: binary, environment: environment, openURL: { _ in })
            _ = try await accounts.refreshUsage(id: account.id)
            // The CLI may retain a still-valid token outside its renewal window. Keep preflight honest.
            try await refresh(credentialHome, account.provider)
        }
    }

    private func mirror(hostHome: URL, binary: String?, environment: [String: String]) -> DistillGuestCredentialMirror {
        lock.withLock {
            if let mirror = mirrors[hostHome.path] { return mirror }
            let refresh = deps.refresh
            let mirror = DistillGuestCredentialMirror(
                hostHome: hostHome,
                refresh: { provider in try await refresh(hostHome, provider) },
                refreshAccount: { account in
                    try await Self.prepareAccount(account, hostHome: hostHome, binary: binary,
                        environment: environment, refresh: refresh)
                },
                onRefreshFailure: { runIDs, _ in
                    guestResolverLog.error("bot.guest.credentials.refresh_failed runs=\(runIDs.count, privacy: .public)")
                }
            )
            mirrors[hostHome.path] = mirror
            return mirror
        }
    }

    static func launchError(_ error: Error) -> Error {
        if error is DistillAutoRoutingError || error is DistillGuestLaunchError || error is CancellationError { return error }
        let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return DistillGuestLaunchError.unavailable(reason)
    }

    /// Runs Docker and file work on a dispatch queue: it blocks for seconds,
    /// which would starve Swift's cooperative pool.
    static func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

/// `bot_guest_prepare` signpost intervals on `io.remotecode.perf`, one per
/// preparation stage and named by it: a stage ends where the next one begins,
/// or where preparation returns or throws.
private final class BotGuestPrepareIntervals: @unchecked Sendable {
    private let lock = NSLock()
    private var open: OSSignpostIntervalState?

    func begin(_ stage: DistillGuestStage) {
        end()
        let signposter = PerfSwitchMetrics.signposter
        let interval = signposter.beginInterval(
            "bot_guest_prepare",
            id: signposter.makeSignpostID(),
            "\(stage.rawValue, privacy: .public)"
        )
        lock.withLock { open = interval }
    }

    func end() {
        let interval = lock.withLock { () -> OSSignpostIntervalState? in
            defer { open = nil }
            return open
        }
        if let interval { PerfSwitchMetrics.signposter.endInterval("bot_guest_prepare", interval) }
    }
}

/// Renews `<guest home>/.rc-runs/<runId>.lease` while the Mac owns a guest
/// run. The guest's reaper (run-agent) ends a run whose lease has not changed
/// for 45 s, which is what stops it after the app crashes or is killed. Each
/// renewal re-creates the file (temp + rename): the agent can delete it.
/// The agent owns `.rc-runs` too and can swap it for a symlink to a Mac
/// folder, so every write and delete goes through a no-follow descriptor
/// reopened each time; a swapped `.rc-runs` makes renewals fail (and the
/// reaper end the run), never write into the Mac folder.
final class BotGuestLeaseHeartbeat: @unchecked Sendable {
    static let interval: TimeInterval = 10

    let fileURL: URL
    private let directoryURL: URL
    private let queue = DispatchQueue(label: "io.remotecode.bot-guest.lease", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var renewals = 0
    private var activity: NSObjectProtocol?

    /// Writes the lease once before returning; throws when it cannot.
    init(guestHome: URL, runID: String, interval: TimeInterval = BotGuestLeaseHeartbeat.interval) throws {
        directoryURL = guestHome.appendingPathComponent(".rc-runs", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("\(runID).lease")
        try queue.sync { try renew() }
        // This lease is a correctness deadline, not discretionary background work.
        // App Nap must not defer it past the guest reaper's 45-second bound.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep the active bot VM run lease current"
        )
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            do {
                try self.renew()
            } catch {
                guestResolverLog.error("bot.guest.lease.renew_failed file=\(self.fileURL.lastPathComponent, privacy: .public)")
            }
        }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    /// Idempotent. Removes the lease so a leftover agent is reaped.
    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            timer = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
            guard let directory = try? PrivateDirectory(directoryURL, create: false) else { return }
            directory.remove(fileURL.lastPathComponent)
            directory.close()
        }
    }

    private func renew() throws {
        renewals += 1
        let directory = try PrivateDirectory(directoryURL, create: true)
        defer { directory.close() }
        // The guest reads the live bind mount. Persisting a heartbeat through
        // a host power loss is useless, and fsync can stall past its deadline
        // while the Mac is paging or busy with other disk writes.
        try directory.writeAtomically(Data("\(renewals)\n".utf8), to: fileURL.lastPathComponent, synchronize: false)
    }
}

/// The production `BotGuestVMPreparing`: Docker up, container current and
/// running (an outdated one is replaced: this run is the bot's only one),
/// workspace mounted, and the agent's tools present.
final class BotGuestDockerVM: BotGuestVMPreparing, @unchecked Sendable {
    /// What the in-guest agent and its MCP servers execute (run-agent's
    /// reaper needs setsid; linux-use needs the X11 tools and ImageMagick).
    static let requiredTools = ["setsid", "git", "python3", "xdotool", "wmctrl", "xwd", "playwright-mcp"]

    private let appSupport: URL
    private let docker: any BotComputerDockerClienting
    private let service: BotComputerGuestService
    private let lock = NSLock()
    /// Container name → image whose tools passed the probe. Tools come from
    /// the image, so a container keeps its result until it is recreated.
    private var probedImages: [String: String] = [:]
    private let resolveExecutable: (@Sendable () throws -> String)?
    init(
        appSupport: URL,
        docker: any BotComputerDockerClienting,
        service: BotComputerGuestService,
        resolveExecutable: (@Sendable () throws -> String)? = nil
    ) {
        self.appSupport = appSupport
        self.docker = docker
        self.service = service
        self.resolveExecutable = resolveExecutable
    }

    func prepare(
        botID: BotID,
        threadID: AgentThreadID,
        workspace: String?,
        registeredWorkspaces: Set<String>
    ) throws -> BotGuestVM {
        _ = try resolveExecutable?()
        let arch = try dockerArchitecture()
        let container: String
        let image: String
        let recreated: Bool
        if let running = try? service.runningCurrentContainer(
            botID: botID, workspace: workspace,
            registered: registeredWorkspaces, requestingThreadID: threadID, contextualNetworkPolicy: false
        ) {
            container = BotComputerGuestSpec.containerName(botID: botID)
            image = running.imageID
            recreated = false
        } else {
            // Anything but running and current takes the path every send took
            // before. It starts with `docker info`, which is what names a
            // daemon that is down.
            if let workspace {
                try service.ensureWorkspaceMounted(
                    botID: botID, workspace: workspace,
                    registered: registeredWorkspaces, requestingThreadID: threadID
                )
            }
            let ready = try service.provision(botID: botID, requestingThreadID: threadID)
            container = ready.containerID
            image = ready.imageReference
            recreated = !ready.resumed
        }
        try checkTools(container: container, image: image, recreated: recreated)
        let manifest = BotComputerGuestSpec.workspacesURL(appSupport: appSupport, botID: botID)
        let mounted = (try? Data(contentsOf: manifest))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return BotGuestVM(container: container, dockerArch: arch, mountedWorkspaces: mounted)
    }

    private func dockerArchitecture() throws -> String {
        let info = try docker.info()
        guard let arch = DistillGuestBinaryProvisioner.dockerArchitecture(fromInfo: info) else {
            throw DistillGuestLaunchError.unavailable("Docker did not report its CPU architecture.")
        }
        return arch
    }

    static let toolsProbeScript =
        "for t in " + requiredTools.joined(separator: " ")
        + "; do command -v \"$t\" >/dev/null 2>&1 || printf '%s ' \"$t\"; done; "
        + "command -v convert >/dev/null 2>&1 || command -v magick >/dev/null 2>&1 || printf 'convert '"

    private func checkTools(container: String, image: String, recreated: Bool) throws {
        let cached = lock.withLock { () -> Bool in
            if recreated { probedImages[container] = nil }
            return probedImages[container] == image
        }
        if cached { return }
        let output = try docker.exec(
            name: container,
            command: ["sh", "-c", Self.toolsProbeScript],
            user: BotComputerGuestSpec.agentUser,
            detach: false
        )
        let missing = (String(data: output, encoding: .utf8) ?? "")
            .split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard missing.isEmpty else {
            throw DistillGuestLaunchError.unavailable(
                "the bot's Linux image lacks \(missing.joined(separator: ", ")). "
                    + "Add them to the bot's Dockerfile, or restore the default one, and rebuild."
            )
        }
        lock.withLock { probedImages[container] = image }
    }
}

extension AppContext {
    /// The app's guest resolver. In the app (`hostsGuestRuns`), launch
    /// cleanup runs off the main thread and then opens the barrier guest runs
    /// wait on; elsewhere guest threads fail.
    func makeBotGuestRunResolver(hostsGuestRuns: Bool) -> BotGuestRunResolver {
        let appSupport = appSupportDirectory
        let docker = guestDocker
        let guestService = BotComputerGuestService(
            appSupport: appSupport,
            docker: docker,
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL()
        )
        let binaries = distillGuestBinaries
        let distillOverride = (try? settingsRepo.get("cli.distill.path")) ?? nil
        let barrier = botGuestLaunchBarrier
        if hostsGuestRuns {
            // A guest run reads the Mac's `codex` version through the
            // login-shell PATH, and nothing else starts that capture before
            // the first agent turn. Unit tests never start the user's shell.
            if !AppContext.isRunningUnitTests,
               ProcessInfo.processInfo.environment["RC_LOGIN_SHELL_ENV_IMPORT"] != "0" {
                LoginShellEnvironment.prewarm()
            }
            // Unit tests never reach the user's Docker daemon.
            let sweepDocker: (any BotComputerDockerClienting)? = AppContext.isRunningUnitTests ? nil : docker
            let store = botStore
            // Unit tests never run the user's Distill.
            let trimGuestCache: @Sendable () async -> Void = AppContext.isRunningUnitTests ? {} : {
                guard let host = DistillProvisioner.resolveInstalledBinary(override: distillOverride) else { return }
                await binaries.collectGarbage(hostBinary: host)
            }
            DispatchQueue.global(qos: .utility).async {
                var botIDs: [BotID] = []
                if sweepDocker != nil {
                    do {
                        botIDs = try store.list(includeHidden: true, includeDeleted: true).map(\.id)
                            + store.listVirtualMachines().map(\.storageID)
                    } catch {
                        // Fail open: the barrier still opens; a leftover
                        // agent then ends only by its lease reaper (~50 s).
                        guestResolverLog.error(
                            "bot.guest.launch_sweep skipped=bot_list_failed error=\(String(describing: error), privacy: .public)"
                        )
                    }
                }
                BotGuestLaunchSweep.run(
                    docker: sweepDocker, appSupport: appSupport, botIDs: botIDs, barrier: barrier,
                    contextStore: store, beforeOpening: trimGuestCache
                )
                if let sweepDocker {
                    BotGuestLaunchSweep.startStoppedDesktops(docker: sweepDocker, store: store)
                }
            }
            if !AppContext.isRunningUnitTests, distillHostWatch == nil {
                distillHostWatch = Self.watchHostDistill(binaries: binaries, override: distillOverride)
            }
        }
        let contextStore = botStore
        let contextThreadRepo = threadRepo
        let contextHostID = liveActivityHostIdentity.serverId
        return BotGuestRunResolver(BotGuestRunResolver.Dependencies(
            threadRepo: threadRepo,
            botStore: botStore,
            appSupport: appSupport,
            isDelegatedRun: { [weak coordinator = coordinator] runID, threadID in
                coordinator?.isDelegatedRun(runID, threadId: threadID) == true
            },
            onVMAvailable: { [weak self] botID, threadID in
                Task { @MainActor [weak self] in
                    await self?.router?.handOffBotVM(botID: botID, to: threadID)
                }
            },
            barrier: barrier,
            gateway: botGuestMCPGateway,
            vm: BotGuestDockerVM(
                appSupport: appSupport,
                docker: docker,
                service: guestService,
                resolveExecutable: { try BotComputerDockerResolver.shared.resolveHealthyExecutable() }
            ),
            binaryGuestPath: { hostBinary, arch in
                try await binaries.resolve(hostBinary: hostBinary, dockerArch: arch).guestPath
            },
            refresh: { hostHome, provider in
                try await DistillHostCredentialRefresher(hostHome: hostHome).prepare(provider: provider)
            },
            dockerExecutable: { try BotComputerDockerResolver.shared.resolveHealthyExecutable() },
            workspaces: { [weak self] in
                await MainActor.run {
                    self?.state.workspaces.mapValues(\.cwd) ?? [:]
                }
            },
            prepareContextRuntime: { [weak self] request, parentRunID, providerConfiguration, persistentSession in
                guard let context = self else {
                    throw DistillGuestLaunchError.unavailable(
                        "Contextual execution is unavailable until runtime isolation is verified."
                    )
                }
                let pin = try await BotGuestRunResolver.blocking {
                    try contextStore.conversationContextPin(linkedTo: request.threadId)
                }
                let (workspace, registeredWorkspaces) = await MainActor.run { () -> (Workspace?, Set<String>) in
                    let workspaces = context.state.workspaces
                    let workspace: Workspace?
                    if let pin, case .workspace(let workspaceID) = pin.context {
                        workspace = workspaces[workspaceID]
                    } else {
                        workspace = nil
                    }
                    return (workspace, Set(workspaces.values.map(\.cwd)))
                }
                return try await BotGuestRunResolver.blocking {
                    try BotContextGuestResources.prepare(
                        request: request,
                        hostID: contextHostID,
                        store: contextStore,
                        threadRepo: contextThreadRepo,
                        service: guestService,
                        appSupport: appSupport,
                        workspace: workspace,
                        registeredWorkspaces: registeredWorkspaces,
                        secretStore: context.contextualSecretStore,
                        parentRunID: parentRunID,
                        providerConfiguration: providerConfiguration,
                        persistentSession: persistentSession
                    )
                }
            },
            contextualAdmissions: contextualRunAdmissions,
            contextDockerArchitecture: {
                let info = try docker.info()
                guard let architecture = DistillGuestBinaryProvisioner.dockerArchitecture(fromInfo: info) else {
                    throw DistillGuestLaunchError.unavailable("Docker did not report its CPU architecture.")
                }
                return architecture
            },
            hostBinary: { request in
                DistillProvisioner.resolveInstalledBinary(override: request.providerBinary ?? distillOverride)
            },
            probeHostVersion: { hostBinary in
                if let hostBinary { _ = await binaries.hostVersion(binary: hostBinary) }
            },
            codexClientVersion: { hostEnvironment in
                // What the Mac's Distill is started with (ProviderSubprocessLauncher):
                // the login-shell PATH is where `codex` usually is, a GUI app's has none.
                await DistillCodexClientVersion.resolve(environment: CodexRunner.processEnvironment(
                    overrides: hostEnvironment, purpose: .agentTurn(.distill)
                ))
            },
            gitIdentity: { BotComputerGuestService.gitIdentity() },
            hostsGuestRuns: hostsGuestRuns
        ))
    }
}

extension AppContext {
    /// Distill (its own updater or `distill update`) swaps the bin symlink
    /// when it installs a release. Each change starts the guest download for
    /// every architecture already cached; repeats share one download.
    static func watchHostDistill(
        binaries: DistillGuestBinaryProvisioner, override: String?
    ) -> DispatchSourceFileSystemObject? {
        guard let host = DistillProvisioner.resolveInstalledBinary(override: override) else { return nil }
        let directory = URL(fileURLWithPath: host).deletingLastPathComponent().path
        let descriptor = open(directory, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .global(qos: .utility)
        )
        source.setEventHandler {
            Task {
                for arch in await binaries.cachedArchitectures() {
                    binaries.prefetch(hostBinary: host, dockerArch: arch)
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}

/// App launch: no guest run survives a quit, so nothing a previous run left
/// is live. Quit runs `removeLeftovers` too.
enum BotGuestLaunchSweep {
    /// The launch cleanup, blocking: ends leftover in-guest agents and stray
    /// `bash -lc` shells, then deletes the Mac-side leftovers (sign-in
    /// copies, env files, leases), then opens `barrier`, so no guest run
    /// starts before its bot's leftovers are gone and the cleanup never
    /// touches a new run (whose tools run under `bash -lc` too).
    /// `docker` nil skips the in-guest step. `beforeOpening` trims the guest
    /// distill cache after the leftovers are ended and before `barrier`
    /// opens, the only moment no guest executes a cached build.
    @discardableResult
    static func run(
        docker: (any BotComputerDockerClienting)?,
        appSupport: URL,
        botIDs: [BotID],
        barrier: DistillGuestLaunchBarrier,
        contextStore: BotStore? = nil,
        beforeOpening: @escaping @Sendable () async -> Void = {}
    ) -> BotContextGuestRecovery.Report {
        let recovery = BotContextGuestRecovery.reconcile(docker: docker, appSupport: appSupport)
        guestResolverLog.info("bot.context.launch_recovery reconciled=\(recovery.reconciled.count, privacy: .public) uncertain=\(recovery.failures.count, privacy: .public)")
        var report = recovery
        if recovery.failures.isEmpty, let contextStore {
            do {
                let roots = Set(try contextStore.contextDelegations().map(\.parentRunID))
                for runID in roots {
                    _ = try contextStore.closeContextDelegationTree(runID: runID)
                }
            } catch {
                var failures = report.failures
                failures["context-lineage"] = String(describing: error)
                report = BotContextGuestRecovery.Report(reconciled: report.reconciled, failures: failures)
            }
        }
        if let docker { endLeftoverRuns(docker: docker, appSupport: appSupport, botIDs: botIDs) }
        removeLeftovers(appSupport: appSupport)
        Task {
            await beforeOpening()
            await barrier.open()
        }
        return report
    }

    /// Ends what a previous session of this app left running in the
    /// containers of this database's bots, whatever their desktop kind is
    /// now: in-guest agents (`kill-agent --all` as the guest user, only where
    /// a run's lease survived, i.e. the app crashed or was killed; quit and
    /// the previous launch delete them), then `bash -lc` shells whose
    /// `docker exec` client died with the app (`BotVMOrphanScan`, as root).
    /// Another app sharing the Docker daemon (the installed app beside a
    /// debug sandbox) has its own bots and its own Application Support, so a
    /// container counts only when this app has a guest home for its bot, its
    /// name and bot label match one of `botIDs`, and its home is bound from
    /// that guest home. Docker down: no container runs, so there is nothing
    /// to end. Blocking; returns the containers whose agents were ended.
    @discardableResult
    static func endLeftoverRuns(
        docker: any BotComputerDockerClienting,
        appSupport: URL,
        botIDs: [BotID]
    ) -> [String] {
        // No guest home here: no container of this app is bound from it, so
        // bots that never had a Docker desktop cost no Docker call.
        let candidates = botIDs.filter {
            FileManager.default.fileExists(atPath: BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: $0).path)
        }
        guard !candidates.isEmpty else { return [] }
        guard (try? docker.info()) != nil else {
            guestResolverLog.info("bot.guest.launch_sweep skipped=docker_unavailable")
            return []
        }
        var swept: [String] = []
        var reaped = 0
        var inspectFailures = 0
        for botID in candidates {
            let name = BotComputerGuestSpec.containerName(botID: botID)
            let container: BotComputerContainerInspect
            do {
                container = try docker.inspect(name: name)
            } catch {
                // Usually a removed container; counted so a failing Docker shows.
                inspectFailures += 1
                continue
            }
            guard container.running,
                  container.labels[BotComputerGuestSpec.botIDLabelKey] == botID.value.uuidString.lowercased(),
                  let source = container.homeSource,
                  samePath(source, BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: botID).path)
            else { continue }
            if mayHaveLeftoverRuns(appSupport: appSupport, botID: botID) {
                do {
                    _ = try docker.exec(
                        name: name,
                        command: [BotComputerGuestSpec.killAgentPath, "--all"],
                        user: BotComputerGuestSpec.agentUser,
                        detach: false
                    )
                    swept.append(name)
                } catch {
                    // A run that survived KILL is left to its reaper, which
                    // ends it once its lease stops changing.
                    guestResolverLog.error("bot.guest.launch_sweep.kill_failed container=\(name, privacy: .public)")
                }
            }
            reaped += BotVMOrphanScan.reap(docker: docker, names: [name]).count
        }
        guestResolverLog.info(
            "bot.guest.launch_sweep containers=\(swept.count, privacy: .public) orphan_shells=\(reaped, privacy: .public) inspect_failed=\(inspectFailures, privacy: .public)"
        )
        return swept
    }

    /// Whether an agent a previous session started may still run in
    /// `botID`'s guest: a lease outlives its run only when the app did not
    /// end it. A `.rc-runs` that is not a plain folder (the guest owns it and
    /// may swap it for a symlink) cannot be read safely, so it counts.
    static func mayHaveLeftoverRuns(appSupport: URL, botID: BotID) -> Bool {
        let leases = BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: botID)
            .appendingPathComponent(".rc-runs", isDirectory: true)
        do {
            let directory = try PrivateDirectory(leases, create: false)
            defer { directory.close() }
            return directory.entries().contains { $0.hasSuffix(".lease") }
        } catch DistillGuestCredentialError.writeFailed(_, let code) where code == ENOENT {
            return false
        } catch {
            return true
        }
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return canonical(a) == canonical(b)
    }

    /// Starts the Docker desktop of each live bot whose container exists but is
    /// stopped, so the bot's desktop is up without a run. Creates nothing;
    /// best-effort, a failure is logged and skipped.
    static func startStoppedDesktops(docker: any BotComputerDockerClienting, store: BotStore) {
        let bots: [BotDefinition]
        do {
            bots = try store.list(includeHidden: true)
        } catch {
            guestResolverLog.error("bot.guest.desktop_start skipped=bot_list_failed error=\(String(describing: error), privacy: .public)")
            return
        }
        for bot in bots {
            guard let revisionID = bot.currentRevisionID,
                  (try? store.getRevision(id: revisionID))??.desktopKind == .dockerDesktop else { continue }
            let name = BotComputerGuestSpec.containerName(botID: bot.id)
            guard let container = try? docker.inspect(name: name), !container.running else { continue }
            do {
                try docker.start(name: name)
            } catch {
                guestResolverLog.error("bot.guest.desktop_start_failed container=\(name, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    static func removeLeftovers(appSupport: URL, fileManager: FileManager = .default) {
        let guestHomes = BotComputerGuestSpec.guestHomeRoot(appSupport: appSupport)
        DistillGuestCredentials.removeAllCopies(guestHomeRoot: guestHomes)
        let runs = DistillGuestEnvironment.runsDirectory(appSupport: appSupport)
        for name in (try? fileManager.contentsOfDirectory(atPath: runs.path)) ?? [] where name.hasSuffix(".env") {
            unlink(runs.appendingPathComponent(name).path)
        }
        // A lease nobody renews makes the guest reaper end a leftover agent
        // `endLeftoverRuns` could not reach (up to ~50 s later). The guest
        // owns `.rc-runs`: a symlinked one is skipped, never followed.
        for bot in (try? fileManager.contentsOfDirectory(atPath: guestHomes.path)) ?? [] {
            let leases = guestHomes.appendingPathComponent(bot, isDirectory: true)
                .appendingPathComponent("home/.rc-runs", isDirectory: true)
            guard let directory = try? PrivateDirectory(leases, create: false) else { continue }
            for name in directory.entries() where name.hasSuffix(".lease") {
                directory.remove(name)
            }
            directory.close()
        }
    }
}
