import Foundation
import AppKit
import CoreModel
import Persistence
import AgentRuntime
import Surfaces
import ServiceManagement
import Darwin
import os

private let scheduledTaskLog = Logger(subsystem: "io.remotecode.appshell", category: "scheduled-tasks")

public struct ScheduledSystemUser: Sendable, Equatable, Identifiable {
    public let name: String
    public let uid: uid_t
    public let gid: gid_t
    public let homeDirectory: String
    public var id: String { name }
}

public enum ScheduledSystemUserCatalog {
    public static func eligibleUsers() -> [ScheduledSystemUser] {
        var users: [ScheduledSystemUser] = []
        setpwent()
        defer { endpwent() }
        while let entry = getpwent()?.pointee {
            let uid = entry.pw_uid
            guard uid >= 500, uid < UInt32.max - 1,
                  let namePointer = entry.pw_name,
                  let homePointer = entry.pw_dir,
                  let shellPointer = entry.pw_shell else { continue }
            let name = String(cString: namePointer)
            let home = String(cString: homePointer)
            let shell = String(cString: shellPointer)
            guard !name.hasPrefix("_"), shell != "/usr/bin/false", shell != "/bin/false", shell != "/usr/bin/nologin" else { continue }
            users.append(ScheduledSystemUser(name: name, uid: uid, gid: entry.pw_gid, homeDirectory: home))
        }
        return users.sorted { lhs, rhs in
            if lhs.name == NSUserName() { return true }
            if rhs.name == NSUserName() { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public static func user(named name: String) -> ScheduledSystemUser? {
        guard let pointer = getpwnam(name) else { return nil }
        let entry = pointer.pointee
        guard entry.pw_uid >= 500, entry.pw_uid < UInt32.max - 1,
              let namePointer = entry.pw_name, let homePointer = entry.pw_dir,
              let shellPointer = entry.pw_shell else { return nil }
        let shell = String(cString: shellPointer)
        guard shell != "/usr/bin/false", shell != "/bin/false", shell != "/usr/bin/nologin" else { return nil }
        return ScheduledSystemUser(
            name: String(cString: namePointer),
            uid: entry.pw_uid,
            gid: entry.pw_gid,
            homeDirectory: String(cString: homePointer)
        )
    }
}

public enum ScheduledTaskPreflightError: Error, CustomStringConvertible, LocalizedError, Equatable {
    case invalidTask(String)
    case missingWorkspace
    case inaccessibleWorkspace(String)
    case ineligibleUser(String)
    case helperUnavailable(String)
    case providerUnavailable(String)
    case unsupportedModel(String)
    case unsupportedReasoning(String)

    public var description: String {
        switch self {
        case .invalidTask(let value): return value
        case .missingWorkspace: return "The selected workspace no longer exists."
        case .inaccessibleWorkspace(let path): return "The workspace is not readable and writable: \(path)"
        case .ineligibleUser(let user): return "The system user is not eligible: \(user)"
        case .helperUnavailable(let user): return "MacCode's privileged helper is unavailable for user \(user). Authorize its one-time installation, then retry."
        case .providerUnavailable(let reason): return reason
        case .unsupportedModel(let model): return "The selected provider does not expose model \(model)."
        case .unsupportedReasoning(let effort): return "The selected model does not support \(effort) reasoning."
        }
    }

    /// WHY: Run Now / XPC failure paths use `error.localizedDescription`. Without
    /// LocalizedError, Foundation bridges to NSError and drops the human message
    /// ("AppShell.ScheduledTaskPreflightError error 0.").
    public var errorDescription: String? { description }
}

/// In-memory phase of a run that is queued or starting. Read by the window's
/// active-run poll; never persisted.
nonisolated enum ScheduledTaskRunPhases {
    private static let lock = NSLock()
    private static var phases: [UUID: String] = [:]

    static func set(_ phase: String, taskID: UUID) {
        lock.lock()
        phases[taskID] = phase
        lock.unlock()
    }

    static func clear(taskID: UUID) {
        lock.lock()
        phases.removeValue(forKey: taskID)
        lock.unlock()
    }

    static func snapshot() -> [UUID: String] {
        lock.lock()
        defer { lock.unlock() }
        return phases
    }
}

/// In-memory memo of a successful provider auth probe, so back-to-back runs
/// do not respawn the CLI. Failures and unknown results are never cached.
nonisolated enum ScheduledProviderAuthCache {
    private struct Key: Hashable {
        let provider: AgentProvider
        let binaryPath: String
        let runAsUser: AgentRunAsUser?
    }

    static let ttl: TimeInterval = 60
    private static let lock = NSLock()
    private static var verifiedAt: [Key: Date] = [:]

    /// Re-runs the probe only while it returns nil (timed out or unknown). A
    /// `false` is a real sign-out and returns at once.
    static func probeRetryingUnknown(
        delays: [TimeInterval] = [0.5, 1],
        _ probe: () async -> Bool?
    ) async -> Bool? {
        var result = await probe()
        for delay in delays where result == nil {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            result = await probe()
        }
        return result
    }

    static func authenticated(
        provider: AgentProvider,
        binaryPath: String,
        runAsUser: AgentRunAsUser?,
        now: Date = Date(),
        probe: () async -> Bool?
    ) async -> Bool? {
        let key = Key(provider: provider, binaryPath: binaryPath, runAsUser: runAsUser)
        if isFresh(key, now: now) { return true }
        let result = await probe()
        if result == true { remember(key, at: now) }
        return result
    }

    private static func isFresh(_ key: Key, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = verifiedAt[key] else { return false }
        return now.timeIntervalSince(at) < ttl
    }

    private static func remember(_ key: Key, at: Date) {
        lock.lock()
        verifiedAt[key] = at
        lock.unlock()
    }
}

@MainActor
public final class ScheduledTaskExecutor {
    private let context: AppContext
    private let router: AppCommandRouter
    private let orchestrationRuntime: AgentOrchestrationRuntime

    public init(
        context: AppContext,
        router: AppCommandRouter,
        orchestrationRuntime: AgentOrchestrationRuntime = AgentOrchestrationRuntime()
    ) {
        self.context = context
        self.router = router
        self.orchestrationRuntime = orchestrationRuntime
    }

    /// A run must never start Codex/Claude/Grok: legacy routes map to Distill and an
    /// unset Distill model resolves to the first Distill catalog model.
    nonisolated static func resolvingDistillDefaults(_ task: ScheduledTask) -> ScheduledTask {
        var task = task
        task.migrateLegacyProvider()
        if task.provider == .distill,
           task.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let model = DistillRunner.listModels(installedVersion: nil).first?.id {
            task.model = model
        }
        return task
    }

    public func preflight(_ task: ScheduledTask) async throws -> Workspace {
        try await prepareExecution(Self.resolvingDistillDefaults(task)).workspace
    }

    /// Headless in-process run: create a durable agent thread and start the
    /// provider through the shared coordinator (`sendAgentMessage`), without
    /// activating RemoteCode, switching workspaces, focusing Agent App tabs,
    /// writing the composer textarea, or depending on a UI "play" click.
    ///
    /// Ownership stays in the interactive app process (local coordinator). No
    /// LaunchAgent foreign ownership or XPC stop path. Rails refresh when a
    /// surface already shows the workspace; the user's current focus is not
    /// stolen.
    /// - Parameter onThreadCreated: called after the thread row exists so the
    ///   scheduler can link `scheduled_task_runs.thread_id` before provider start.
    public func execute(
        _ task: ScheduledTask,
        onThreadCreated: ((AgentThreadID) throws -> Void)? = nil
    ) async throws -> (threadID: AgentThreadID, runID: AgentRunID) {
        var task = Self.resolvingDistillDefaults(task)
        ScheduledTaskRunPhases.set("Checking provider…", taskID: task.id)
        let prepared = try await prepareExecution(task)
        if task.effectiveRoutingMode != .auto, let snapshot = prepared.providerSnapshot {
            task.providerInstanceID = snapshot.id
        }
        try Self.rejectUIOnlySchedulePrompt(task.prompt)
        // Match AgentAppViewModel.send: $goal→/goal, /sam-work→$sam-work, /default body→body.
        let dispatchPrompt = Self.scheduleDispatchPrompt(
            task.prompt,
            providerSnapshot: prepared.providerSnapshot
        )

        let runAs = Self.resolveRunAsUser(task: task)
        let modelSelection = Self.modelSelection(for: task)
        let routingConfiguration: AgentRoutingConfiguration?
        if task.effectiveRoutingMode == .auto {
            routingConfiguration = prepared.routingSnapshot?.configuration
                ?? Self.routingConfiguration(
                    for: task,
                    policyDigest: orchestrationRuntime.policyDigest,
                    eligibleProviders: [task.provider]
                )
        } else {
            routingConfiguration = nil
        }

        // surfaceID: nil + quiet: create durable row without selecting tabs or
        // rebuilding workspace UI (no focus/workspace yank).
        let thread = try router.createAgentThread(
            workspace: task.workspaceID,
            title: task.title,
            provider: task.provider,
            model: task.model.isEmpty ? modelSelection.effectiveModel : task.model,
            permissionMode: task.permissionMode,
            reasoningEffort: task.reasoningEffort,
            reasoningModel: task.provider == .distill ? task.reasoningModel : nil,
            modelSelection: modelSelection,
            providerInstanceId: task.providerInstanceID,
            runAsUser: runAs,
            surfaceID: nil,
            routingConfiguration: routingConfiguration,
            quiet: true
        )
        try onThreadCreated?(thread.id)
        ScheduledTaskRunPhases.set("Starting…", taskID: task.id)
        if task.executionMode != .local {
            _ = try router.configureAgentThreadExecution(
                thread: thread.id,
                executionMode: task.executionMode,
                baseBranch: task.baseBranch
            )
        }

        let sendResult = try await router.sendAgentMessage(
            thread: thread.id,
            text: dispatchPrompt,
            provider: task.provider,
            model: task.model.isEmpty ? nil : task.model,
            permissionMode: task.permissionMode,
            reasoningEffort: task.reasoningEffort,
            interactionMode: task.interactionMode,
            modelSelection: modelSelection,
            providerInstanceId: task.providerInstanceID,
            attachments: [],
            orchestrationRoutingSnapshot: prepared.routingSnapshot
        )

        switch sendResult.status {
        case .started:
            guard let runID = sendResult.runId else {
                throw ScheduledTaskPreflightError.invalidTask(
                    "Scheduled task send did not return a provider run id."
                )
            }
            return (thread.id, runID)
        case .queued:
            // Brand-new thread must never queue behind another run.
            throw ScheduledTaskPreflightError.invalidTask(
                "Scheduled task was queued instead of started. Retry when no other run is active on the thread."
            )
        }
    }

    /// Local Agent App commands that never start a provider turn. Scheduled
    /// prompts must not silently no-op or create empty threads for these.
    ///
    /// nonisolated: pure string classification; catalog mirrors
    /// `AgentAppViewModel.localSlashCommands` without MainActor hop.
    nonisolated static func rejectUIOnlySchedulePrompt(_ text: String) throws {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = line.first, first == "/" || first == "$" else { return }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        let command = (parts.first ?? "").lowercased()
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        // Agent App handles these locally regardless of arguments (except
        // `/default body` / `/plan body` which switch mode then may send body).
        // Schedules require a real provider turn.
        let alwaysUIOnly = Set(["clear", "fork", "model", "status"])
        if alwaysUIOnly.contains(command) {
            throw ScheduledTaskPreflightError.invalidTask(
                "Scheduled tasks cannot run the local Agent App command /\(command). Use a full prompt or skill ($name)."
            )
        }
        if command == "plan" {
            throw ScheduledTaskPreflightError.invalidTask(
                "Scheduled tasks run in Default interaction mode. Remove /plan and put the work in the prompt (or use a skill like $sam-work)."
            )
        }
        if command == "default", argument.isEmpty {
            throw ScheduledTaskPreflightError.invalidTask(
                "Scheduled tasks cannot run the local Agent App command /default. Use a full prompt or skill ($name)."
            )
        }
        // `/default body` is allowed — scheduleDispatchPrompt strips the command.
        _ = argument
    }

    /// Same first-token rewrite Agent App applies before provider dispatch.
    /// - `$goal` / `/goal` → command form `/goal`
    /// - `/sam-work` / `$sam-work` → skill form `$sam-work` when registered as skill
    /// - `/default body` → `body` (schedules already run in Default mode)
    /// Mirrors `AgentAppViewModel.localSlashCommands` without MainActor hop.
    nonisolated private static let scheduleLocalSlashCommands = [
        "/clear", "/default", "/fork", "/model", "/plan", "/status"
    ]

    nonisolated static func scheduleDispatchPrompt(
        _ raw: String,
        providerSnapshot: AgentProviderSnapshot?
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = AgentComposerSuggestions.normalizingComposerTriggerPrefix(
            trimmed,
            localSlashCommands: scheduleLocalSlashCommands,
            providerSlashCommands: Array(Set(
                (providerSnapshot?.slashCommands ?? [])
                    + AgentComposerSuggestions.passThroughSlashCommands
            )),
            skills: providerSnapshot?.skills ?? []
        )
        // Agent App switches to Default then sends body; headless is already Default.
        if let first = normalized.first, first == "/" || first == "$" {
            let parts = normalized.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            let command = (parts.first ?? "").lowercased()
            let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if command == "default", !argument.isEmpty {
                return argument
            }
        }
        return normalized
    }

    private static func resolveRunAsUser(task: ScheduledTask) -> AgentRunAsUser? {
        guard let user = ScheduledSystemUserCatalog.user(named: task.runAsUser) else {
            return AgentRunAsUser.current()
        }
        return AgentRunAsUser(
            generatedUID: "",
            shortName: user.name,
            uid: user.uid,
            gid: user.gid,
            homePath: user.homeDirectory
        )
    }

    private struct PreparedExecution {
        let workspace: Workspace
        let manualLaunch: AgentOrchestrationLaunchConfiguration?
        let routingSnapshot: AgentOrchestrationRoutingSnapshot?
        /// Snapshot for the scheduled provider instance — composer normalization.
        let providerSnapshot: AgentProviderSnapshot?
    }

    private func prepareExecution(_ task: ScheduledTask) async throws -> PreparedExecution {
        let validation = task.validationErrors()
        guard validation.isEmpty else { throw ScheduledTaskPreflightError.invalidTask(validation.joined(separator: " ")) }
        guard let workspace = try router.listWorkspaces().first(where: { $0.id == task.workspaceID }) else {
            throw ScheduledTaskPreflightError.missingWorkspace
        }
        guard URL(fileURLWithPath: workspace.cwd).standardizedFileURL.path
                == URL(fileURLWithPath: task.workspacePathSnapshot).standardizedFileURL.path else {
            throw ScheduledTaskPreflightError.inaccessibleWorkspace("The selected workspace path changed after this task was saved.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.cwd, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: workspace.cwd),
              FileManager.default.isWritableFile(atPath: workspace.cwd) else {
            throw ScheduledTaskPreflightError.inaccessibleWorkspace(workspace.cwd)
        }
        guard let user = ScheduledSystemUserCatalog.user(named: task.runAsUser) else {
            throw ScheduledTaskPreflightError.ineligibleUser(task.runAsUser)
        }
        guard user.uid == task.runAsUID else {
            throw ScheduledTaskPreflightError.ineligibleUser("\(task.runAsUser) changed identity since this task was saved")
        }
        if user.name != NSUserName() {
            do {
                try RunAsUserProcessBootstrap.ensureHelperInstalled()
            } catch {
                throw ScheduledTaskPreflightError.helperUnavailable(user.name)
            }
        }

        // Discover install/auth/binary as the account that will actually run the
        // provider through the shared helper. App-owner snapshots reject valid
        // foreign-user CLIs.
        let runAsForProbe = Self.resolveRunAsUser(task: task)
        let snapshots = await router.listAgentProviderSnapshots(runAsUser: runAsForProbe)
        if task.effectiveRoutingMode == .auto {
            let autoSnapshot = try await autoRoutingSnapshot(
                task: task,
                user: user,
                snapshots: snapshots
            )
            return PreparedExecution(
                workspace: workspace,
                manualLaunch: nil,
                routingSnapshot: autoSnapshot,
                providerSnapshot: autoSnapshot.providerSnapshots.first {
                    $0.id == task.providerInstanceID && $0.provider == task.provider
                } ?? autoSnapshot.providerSnapshots.first
            )
        }

        let snapshot = snapshots.resolvedSnapshot(provider: task.provider, instanceID: task.providerInstanceID)
        do {
            try AgentProviderRunPreflight.validate(
                snapshot: snapshot,
                interactionMode: .default,
                permissionMode: .fullAccess,
                attachments: []
            )
        } catch {
            throw ScheduledTaskPreflightError.providerUnavailable(String(describing: error))
        }
        guard let snapshot else { throw ScheduledTaskPreflightError.providerUnavailable("Provider capabilities are not loaded yet.") }
        let descriptor = snapshot.models.first { $0.id == task.model }
        guard descriptor != nil || snapshot.models.isEmpty || snapshot.models.contains(where: \.supportsCustomModel) else {
            throw ScheduledTaskPreflightError.unsupportedModel(task.model)
        }
        try Self.validateModelConfiguration(task, snapshot: snapshot)
        let binary = snapshot.binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseBinary = binary?.isEmpty == false ? binary! : task.provider.rawValue
        let probeEnvironment = user.name == NSUserName()
            ? router.providerEnvironment(provider: task.provider, instanceId: snapshot.id)
            : [:]
        let authenticated = await ScheduledProviderAuthCache.authenticated(
            provider: task.provider,
            binaryPath: baseBinary,
            runAsUser: runAsForProbe
        ) {
            await ScheduledProviderAuthCache.probeRetryingUnknown {
                await ProviderCLIProbe.runOffCooperativePool {
                    ProviderCLIProbe.authStatus(
                        provider: task.provider,
                        binaryPath: baseBinary,
                        environment: probeEnvironment,
                        runAsUser: runAsForProbe
                    ).authenticated
                }
            }
        }
        guard authenticated == true || (task.provider == .distill && user.name != NSUserName() && authenticated == nil) else {
            throw ScheduledTaskPreflightError.providerUnavailable(
                Self.signInUnavailableMessage(provider: task.provider, userName: user.name, authenticated: authenticated)
            )
        }
        return PreparedExecution(
            workspace: workspace,
            manualLaunch: AgentOrchestrationLaunchConfiguration(
                binary: baseBinary,
                environment: probeEnvironment
            ),
            routingSnapshot: nil,
            providerSnapshot: snapshot
        )
    }

    /// `nil` means the sign-in check could not answer; it is not a sign-out.
    nonisolated static func signInUnavailableMessage(
        provider: AgentProvider,
        userName: String,
        authenticated: Bool?
    ) -> String {
        guard authenticated == nil else {
            return "The selected provider is unavailable for system user \(userName). Sign in as that user and retry."
        }
        return "Could not verify the \(provider.rawValue.capitalized) sign-in for system user \(userName) (the check timed out). Try again."
    }

    nonisolated static func modelSelection(for task: ScheduledTask) -> AgentModelSelection {
        AgentModelSelection(
            provider: task.provider,
            modelId: task.model,
            reasoningEffort: task.reasoningEffort,
            distillMainEffortSelection: task.provider == .distill
                ? (task.distillMainEffortSelection ?? .fixed(task.reasoningEffort)) : nil,
            distillReasoningEffortSelection: task.provider == .distill
                ? (task.distillReasoningEffortSelection ?? .automatic) : nil,
            distillExecutionMode: task.provider == .distill ? task.distillExecutionMode : .normal
        )
    }

    static func validateModelConfiguration(
        _ task: ScheduledTask,
        snapshot: AgentProviderSnapshot
    ) throws {
        guard task.provider == .distill else {
            let descriptor = snapshot.models.first { $0.id == task.model }
            if let descriptor, descriptor.supportsReasoning,
               !descriptor.supportedReasoningEfforts.isEmpty,
               !descriptor.supportedReasoningEfforts.contains(task.reasoningEffort) {
                throw ScheduledTaskPreflightError.unsupportedReasoning(task.reasoningEffort.displayName)
            }
            return
        }
        let mainModel = task.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoningModel = task.reasoningModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mainModel.isEmpty else {
            throw ScheduledTaskPreflightError.invalidTask("Select an explicit Distill Main model.")
        }
        let mainEffortSelection = task.distillMainEffortSelection ?? .fixed(task.reasoningEffort)
        let mainDescriptor = snapshot.models.first(where: { $0.id == mainModel })
        if let effort = mainEffortSelection.effort,
           let supported = mainDescriptor?.supportedReasoningEfforts,
           !supported.isEmpty,
           !supported.contains(effort) {
            throw ScheduledTaskPreflightError.unsupportedReasoning(effort.displayName)
        }
        guard let reasoningModel, !reasoningModel.isEmpty else { return }
        let reasoningDescriptor = snapshot.models.first(where: { $0.id == reasoningModel })
        if reasoningDescriptor == nil, !snapshot.models.isEmpty {
            throw ScheduledTaskPreflightError.unsupportedModel(reasoningModel)
        }
        if snapshot.effectiveCapabilities.supportsDistillReasoningModelEffort,
           let selection = task.distillReasoningEffortSelection {
            if let effort = selection.effort,
               let supported = reasoningDescriptor?.supportedReasoningEfforts,
               !supported.isEmpty,
               !supported.contains(effort) {
                throw ScheduledTaskPreflightError.unsupportedReasoning(effort.displayName)
            }
        }
    }

    nonisolated static func routingConfiguration(
        for task: ScheduledTask,
        policyDigest: String,
        eligibleProviders: [AgentProvider] = AgentProvider.selectable
    ) -> AgentRoutingConfiguration {
        AgentRoutingConfiguration(
            mode: task.effectiveRoutingMode,
            manualSelection: modelSelection(for: task),
            manualProviderInstanceId: task.providerInstanceID,
            eligibleProviders: eligibleProviders,
            policyDigest: task.effectiveRoutingMode == .auto ? policyDigest : "",
            revision: task.effectiveRoutingMode == .auto ? 1 : 0
        )
    }

    private func autoRoutingSnapshot(
        task: ScheduledTask,
        user: ScheduledSystemUser,
        snapshots: [AgentProviderSnapshot]
    ) async throws -> AgentOrchestrationRoutingSnapshot {
        var verifiedSnapshots: [AgentProviderSnapshot] = []
        var launches: [String: AgentOrchestrationLaunchConfiguration] = [:]
        let runAsForProbe = Self.resolveRunAsUser(task: task)

        // Scheduled Auto is host-bound: only the user-chosen provider may run.
        // Never admit other providers or substitute another host when the saved
        // provider is unavailable (SCHED-005).
        // Match Agent App Auto admission: requireLiveCatalog is false so
        // runnable built-in catalogs (e.g. Claude OAuth) are not rejected while
        // the same Source would still send from the play button.
        let candidateSnapshots = snapshots.filter {
            $0.provider == task.provider
                && $0.id == task.providerInstanceID
                && $0.enabled
                && $0.installed
                && $0.capabilities?.supportsStreaming == true
                && !$0.models.isEmpty
        }
        guard !candidateSnapshots.isEmpty else {
            throw ScheduledTaskPreflightError.providerUnavailable(
                "The selected provider (\(task.provider.rawValue.capitalized)) is unavailable for Auto model routing."
            )
        }

        for snapshot in candidateSnapshots {
            let binary = snapshot.binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseBinary = binary?.isEmpty == false ? binary! : snapshot.provider.rawValue
            // Probe and the eventual launch both use the shared helper for a
            // foreign account; the launch configuration remains the real,
            // allowlisted provider binary rather than a shell wrapper.
            let environment = user.name == NSUserName()
                ? router.providerEnvironment(provider: snapshot.provider, instanceId: snapshot.id)
                : [:]
            let authenticated = await ScheduledProviderAuthCache.authenticated(
                provider: snapshot.provider,
                binaryPath: baseBinary,
                runAsUser: runAsForProbe
            ) {
                await ScheduledProviderAuthCache.probeRetryingUnknown {
                    await ProviderCLIProbe.runOffCooperativePool {
                        ProviderCLIProbe.authStatus(
                            provider: snapshot.provider,
                            binaryPath: baseBinary,
                            environment: environment,
                            runAsUser: runAsForProbe
                        ).authenticated
                    }
                }
            }
            guard authenticated == true || (snapshot.provider == .distill && user.name != NSUserName() && authenticated == nil) else {
                throw ScheduledTaskPreflightError.providerUnavailable(
                    Self.signInUnavailableMessage(provider: snapshot.provider, userName: user.name, authenticated: authenticated)
                )
            }

            let verified = Self.snapshot(snapshot, authenticated: true)
            do {
                try AgentProviderRunPreflight.validate(
                    snapshot: verified,
                    interactionMode: .default,
                    permissionMode: .fullAccess,
                    attachments: []
                )
            } catch {
                throw ScheduledTaskPreflightError.providerUnavailable(String(describing: error))
            }
            verifiedSnapshots.append(verified)
            let launchProviderBinary: String = {
                if let path = snapshot.binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
                return baseBinary
            }()
            launches[snapshot.id] = AgentOrchestrationLaunchConfiguration(
                binary: launchProviderBinary,
                environment: environment
            )
        }

        let configuration = Self.routingConfiguration(
            for: task,
            policyDigest: orchestrationRuntime.policyDigest,
            eligibleProviders: [task.provider]
        )
        do {
            _ = try orchestrationRuntime.route(
                configuration: configuration,
                providerSnapshots: verifiedSnapshots
            )
        } catch {
            throw ScheduledTaskPreflightError.providerUnavailable(
                "Auto model routing is unavailable: \(error)"
            )
        }
        return AgentOrchestrationRoutingSnapshot(
            configuration: configuration,
            providerSnapshots: verifiedSnapshots,
            launchConfigurations: launches
        )
    }

    private static func snapshot(
        _ snapshot: AgentProviderSnapshot,
        authenticated: Bool
    ) -> AgentProviderSnapshot {
        AgentProviderSnapshot(
            id: snapshot.id,
            provider: snapshot.provider,
            driverKind: snapshot.driverKind,
            displayName: snapshot.displayName,
            accentColor: snapshot.accentColor,
            continuationGroup: snapshot.continuationGroup,
            interactionModes: snapshot.interactionModes,
            permissionModes: snapshot.permissionModes,
            enabled: snapshot.enabled,
            installed: snapshot.installed,
            version: snapshot.version,
            status: snapshot.status,
            statusDetail: snapshot.statusDetail,
            authenticated: authenticated,
            accountLabel: snapshot.accountLabel,
            accountAuthMethod: snapshot.accountAuthMethod,
            binaryPath: snapshot.binaryPath,
            homePath: snapshot.homePath,
            environmentKeys: snapshot.environmentKeys,
            models: snapshot.models,
            slashCommands: snapshot.slashCommands,
            skills: snapshot.skills,
            advisory: snapshot.advisory,
            updateState: snapshot.updateState,
            capabilities: snapshot.capabilities,
            modelDiscoverySource: snapshot.modelDiscoverySource,
            modelDiscoveryCacheKey: snapshot.modelDiscoveryCacheKey
        )
    }

}

/// What the scheduler's maintenance pass reads and writes, captured once so the
/// 30 s tick can run it off the main thread (S-F6). SQLiteDB serializes every
/// statement behind its operation lock, and the run repository and coordinator
/// are lock-protected, so the pass may use them from the maintenance queue.
struct ScheduledTaskSchedulerContext: @unchecked Sendable {
    let db: SQLiteDB
    let runRepo: AgentRunRepository
    let coordinator: AgentRunCoordinator
    /// Scheduled failures become Titio notices while the hub is on (§5).
    let titioNoticeCenter: TitioNoticeCenter
    let workspaceName: @MainActor (WorkspaceID) -> String?
}

@MainActor
public final class ScheduledTaskScheduler {
    /// Legacy name retained for tests; catch-up of missed fires is intentionally disabled.
    public nonisolated static let catchUpWindow: TimeInterval = 0
    private nonisolated let store: ScheduledTaskStore
    private nonisolated let context: ScheduledTaskSchedulerContext
    private let executor: ScheduledTaskExecutor
    private nonisolated let owner = UUID().uuidString.lowercased()
    private var tickTask: Task<Void, Never>?
    /// First tick after process start skips every past-due occurrence so reopening
    /// the app never replays work that fired while RemoteCode was closed.
    private var didSkipMissedOnLaunch = false
    /// Serial queue for the tick's SQLite work. A write can wait out a busy
    /// writer (busy_timeout plus retries), which must never stall the main thread.
    private nonisolated static let maintenanceQueue = DispatchQueue(
        label: "io.remotecode.scheduled-tasks.maintenance",
        qos: .utility
    )

    public init(context: AppContext, router: AppCommandRouter) {
        self.context = ScheduledTaskSchedulerContext(
            db: context.db,
            runRepo: context.runRepo,
            coordinator: context.coordinator,
            titioNoticeCenter: context.titioNoticeCenter,
            workspaceName: { [weak context] id in context?.state.workspaces[id]?.name }
        )
        self.store = ScheduledTaskStore(db: context.db)
        self.executor = ScheduledTaskExecutor(context: context, router: router)
    }

    /// The tick in flight, so tests can await its exact completion.
    var tickTaskForTesting: Task<Void, Never>? { tickTask }

    public func tick(now: Date = Date()) {
        guard tickTask == nil else { return }
        let skipMissedOnLaunch = !didSkipMissedOnLaunch
        tickTask = Task { [weak self] in
            guard let self else { return }
            defer { tickTask = nil }
            // Every read and write of the pass runs on the maintenance queue;
            // the main actor only records the launch skip and starts the
            // claimed runs, because the executor drives the router.
            let pass = await withCheckedContinuation { continuation in
                Self.maintenanceQueue.async {
                    continuation.resume(returning: self.maintain(now: now, skipMissedOnLaunch: skipMissedOnLaunch))
                }
            }
            if pass.skippedMissedOnLaunch { didSkipMissedOnLaunch = true }
            for claim in pass.claims { await execute(claim) }
        }
    }

    private struct MaintenancePass: Sendable {
        var skippedMissedOnLaunch = false
        var claims: [ScheduledTaskClaim] = []
    }

    nonisolated private func maintain(now: Date, skipMissedOnLaunch: Bool) -> MaintenancePass {
        var pass = MaintenancePass()
        do {
            if skipMissedOnLaunch {
                // Before any heartbeat: finish prior-process orphans and skip
                // past-due fires so relaunch cannot pin a lease forever.
                try reclaimOrphanedActiveRuns(now: now)
                try skipMissedOccurrencesOnLaunch(now: now)
                pass.skippedMissedOnLaunch = true
            }
            try observeRunning(now: now)
            _ = try store.recoverStaleLeases(now: now)
            try reconcileNextRunDates(now: now)
            // Global travel kill switch — still observe/finish live runs, but
            // do not claim new automatic occurrences while inactive.
            let settings = SettingsStore(db: context.db).load()
            guard settings.scheduledTasksActive else {
                scheduledTaskLog.debug("scheduler.tick_skipped global_active=false")
                return pass
            }
            pass.claims = try store.claimDue(now: now, owner: owner)
        } catch {
            scheduledTaskLog.error("scheduler.tick_failed error=\(error.localizedDescription, privacy: .public)")
        }
        return pass
    }

    public func runNow(
        taskID: UUID,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        Task {
            do {
                let claim = try store.claimManual(taskID: taskID, owner: owner)
                completion(.success(()))
                await execute(claim)
            } catch {
                scheduledTaskLog.error("scheduler.run_now_failed task=\(taskID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                completion(.failure(error))
            }
        }
    }

    /// Claims synchronously so callers see a busy or missing task as an error,
    /// then starts the run like `runNow`.
    @discardableResult
    public func claimAndRunNow(taskID: UUID) throws -> ScheduledTaskClaim {
        let claim = try store.claimManual(taskID: taskID, owner: owner)
        Task { await execute(claim) }
        return claim
    }

    private func execute(_ claim: ScheduledTaskClaim) async {
        defer { ScheduledTaskRunPhases.clear(taskID: claim.task.id) }
        do {
            // Spent-slot advance (+1s) so whole-second persistence / subsecond
            // anchors cannot re-select the occurrence that just claimed.
            let next = claim.task.calculatedNextRunAfterSpent(claim.run.scheduledAt)
            try store.advance(taskID: claim.task.id, nextRunAt: next, lastRunAt: claim.task.lastRunAt)
            ScheduledTaskCrossProcess.notifyStoreChanged(reason: "queued")
            let identifiers = try await executor.execute(claim.task) { [self] threadID in
                // Link ownership before provider start so main-app Stop can route.
                try self.store.attachThread(runID: claim.run.id, threadID: threadID)
                ScheduledTaskCrossProcess.notifyStoreChanged(reason: "thread_linked")
            }
            try store.markStarted(runID: claim.run.id, threadID: identifiers.threadID, agentRunID: identifiers.runID)
            ScheduledTaskCrossProcess.notifyStoreChanged(reason: "started")
        } catch {
            try? store.finish(runID: claim.run.id, status: .failed, errorSummary: String(describing: error))
            ScheduledTaskCrossProcess.notifyStoreChanged(reason: "failed")
            notifyFailure(for: claim.run)
        }
    }

    /// Stop a scheduled occurrence owned by this process's coordinator.
    public func stop(
        threadID: AgentThreadID,
        agentRunID: AgentRunID?,
        completion: @escaping @MainActor (ScheduledTaskStopResult, String?) -> Void
    ) {
        Task {
            let (result, message) = await stopOwned(threadID: threadID, agentRunID: agentRunID)
            completion(result, message)
        }
    }

    private func stopOwned(
        threadID: AgentThreadID,
        agentRunID: AgentRunID?
    ) async -> (ScheduledTaskStopResult, String?) {
        do {
            guard let occurrence = try store.activeRun(forThreadID: threadID) else {
                return (.notOwned, nil)
            }
            if let expected = agentRunID,
               let owned = occurrence.agentRunID,
               expected != owned {
                return (.notOwned, "Active scheduled run ID does not match.")
            }
            if occurrence.status == .queued {
                try store.finish(runID: occurrence.id, status: .cancelled, errorSummary: "Cancelled before start.")
                ScheduledTaskCrossProcess.notifyStoreChanged(reason: "cancelled")
                return (.alreadyTerminal, nil)
            }
            if let runID = occurrence.agentRunID ?? agentRunID {
                context.coordinator.stopRun(runID)
            }
            context.coordinator.stopRun(threadId: threadID)
            ScheduledTaskCrossProcess.notifyStoreChanged(reason: "stop_requested")
            return (.accepted, nil)
        } catch {
            return (.failed, error.localizedDescription)
        }
    }

    /// Finish scheduled runs left from a previous process (force-quit / crash).
    /// In-process ownership means there is no foreign LaunchAgent to preserve.
    nonisolated private func reclaimOrphanedActiveRuns(now: Date) throws {
        for run in try store.listActiveRuns() {
            if let threadID = run.threadID {
                let hasLocalSession = context.coordinator.hasProviderSession(threadId: threadID)
                    || context.coordinator.activeRunId(threadId: threadID) != nil
                if hasLocalSession { continue }
            }
            // Status + finished_at only. A leftover 10-column `get` (including
            // `error_message`) hitchs launch reclaim of every orphaned occurrence.
            if let agentRunID = run.agentRunID,
               let chrome = try context.runRepo.terminal(of: agentRunID) {
                switch chrome.status {
                case .completed:
                    try store.finish(runID: run.id, status: .completed, at: chrome.finishedAt ?? now)
                case .failed, .interrupted:
                    let errorSummary = (try? context.runRepo.errorMessage(of: agentRunID))
                        ?? "Scheduled run ended after app restart."
                    try store.finish(
                        runID: run.id,
                        status: .failed,
                        errorSummary: errorSummary,
                        at: chrome.finishedAt ?? now
                    )
                case .cancelled:
                    let errorSummary = try? context.runRepo.errorMessage(of: agentRunID)
                    try store.finish(
                        runID: run.id,
                        status: .cancelled,
                        errorSummary: errorSummary,
                        at: chrome.finishedAt ?? now
                    )
                case .pending, .running:
                    try store.finish(
                        runID: run.id,
                        status: .failed,
                        errorSummary: "Scheduled run did not survive app restart.",
                        at: now
                    )
                }
            } else if run.status == .queued {
                try store.finish(
                    runID: run.id,
                    status: .cancelled,
                    errorSummary: "Cancelled on app restart before start.",
                    at: now
                )
            } else {
                try store.finish(
                    runID: run.id,
                    status: .failed,
                    errorSummary: "Scheduled run did not survive app restart.",
                    at: now
                )
            }
            ScheduledTaskCrossProcess.notifyStoreChanged(reason: "orphan_reclaimed")
        }
    }

    /// On cold start / reopen: advance every past-due `next_run_at` to the next
    /// future occurrence without creating a run. Missed fires are intentionally
    /// ignored — schedules only run while RemoteCode is open.
    nonisolated private func skipMissedOccurrencesOnLaunch(now: Date) throws {
        for task in try store.list() where task.isEnabled {
            guard let due = task.nextRunAt, due < now else { continue }
            let future = task.calculatedNextRun(after: now)
            try store.advance(
                taskID: task.id,
                nextRunAt: future,
                lastRunAt: task.lastRunAt,
                at: now
            )
            scheduledTaskLog.info(
                "scheduler.skip_missed task=\(task.id.uuidString, privacy: .public) due=\(due.timeIntervalSince1970, privacy: .public)"
            )
        }
    }

    nonisolated private func observeRunning(now: Date) throws {
        for run in try store.listActiveRuns() where run.status == .running {
            try store.heartbeat(runID: run.id, at: now)
            guard let agentRunID = run.agentRunID else { continue }
            // Status + finished_at only. A leftover 10-column `get` (including
            // `error_message`) hitchs every scheduler tick while the run is live.
            guard let chrome = try context.runRepo.terminal(of: agentRunID) else { continue }
            switch chrome.status {
            case .completed:
                try store.finish(runID: run.id, status: .completed, at: chrome.finishedAt ?? now)
                ScheduledTaskCrossProcess.notifyStoreChanged(reason: "completed")
            case .failed, .interrupted:
                let errorSummary = try? context.runRepo.errorMessage(of: agentRunID)
                try store.finish(
                    runID: run.id,
                    status: .failed,
                    errorSummary: errorSummary,
                    at: chrome.finishedAt ?? now
                )
                ScheduledTaskCrossProcess.notifyStoreChanged(reason: "failed")
                notifyFailure(for: run)
            case .cancelled:
                let errorSummary = try? context.runRepo.errorMessage(of: agentRunID)
                try store.finish(
                    runID: run.id,
                    status: .cancelled,
                    errorSummary: errorSummary,
                    at: chrome.finishedAt ?? now
                )
                ScheduledTaskCrossProcess.notifyStoreChanged(reason: "cancelled")
            case .pending, .running:
                break
            }
        }
    }

    /// The Activity row a failure notification opens. Activity lists an occurrence that
    /// started an agent run only as that run, so routing to the occurrence id would always
    /// miss and report "Requested activity result was not found."
    nonisolated static func failureActivityItemID(for run: ScheduledTaskRun) -> String {
        if let agentRunID = run.agentRunID { return "run:\(agentRunID.description)" }
        return "scheduled-occurrence:\(run.id.uuidString.lowercased())"
    }

    nonisolated private func notifyFailure(for run: ScheduledTaskRun) {
        let task = try? store.get(id: run.taskID)
        let settings = SettingsStore(db: context.db).load()
        let content = RemoteCodeNotificationContent(
            identifier: "scheduled_task_run.\(run.id.uuidString).failed",
            title: "Scheduled task failed",
            body: "A scheduled task failed.",
            categoryIdentifier: "",
            threadIdentifier: "",
            userInfo: ["activityItemId": Self.failureActivityItemID(for: run), "workspaceId": task?.workspaceID.value.uuidString ?? "", "outcome": "failed"],
            soundEnabled: settings.notificationSoundEnabled
        )
        let center = context.titioNoticeCenter
        guard center.isEnabled(settings) else {
        guard RemoteCodeNotificationContent.AgentAppPushPolicy.allowsNotification(
            isAction: true,
            workspaceId: task?.workspaceID.value.uuidString,
            settings: settings
        ) else { return }
            SystemNotifier.shared.post(content, settings: settings)
            return
        }
        // With an agent run the key is the run's failure key, so the run's own
        // failure notice and this one merge into one (§3).
        let key = TitioNoticeIDs.scheduledFailure(
            scheduledRunId: run.id.uuidString,
            agentRunId: run.agentRunID?.value.uuidString
        )
        let workspaceID = task?.workspaceID
        let source = TitioNoticeSource(
            runId: run.agentRunID?.value.uuidString,
            workspaceId: workspaceID?.value.uuidString,
            scheduledTaskId: task?.id.uuidString.lowercased() ?? run.taskID.uuidString.lowercased(),
            activityItemId: Self.failureActivityItemID(for: run)
        )
        let title = task?.title
        let occurredAt = Date()
        let facts = TitioNoticeFacts(title: title)
        center.ingest(
            TitioNoticeFact(
                key: key, kind: .scheduledFailed, source: source, facts: facts,
                actions: TitioNoticeAction.defaultActions(kind: .scheduledFailed, facts: facts),
                occurredAt: occurredAt
            ),
            legacy: TitioNoticeLegacyDelivery(content: content, pushes: false)
        )
    }

    nonisolated private func reconcileNextRunDates(now: Date) throws {
        for task in try store.list() where task.isEnabled {
            let reconciled = Self.reconciledDueDate(task: task, now: now)
            if reconciled != task.nextRunAt {
                try store.advance(taskID: task.id, nextRunAt: reconciled, lastRunAt: task.lastRunAt, at: now)
            }
        }
    }

    /// Keep future/just-due dates. Never collapse a backlog into a catch-up
    /// claim — missed fires are skipped on launch via `skipMissedOccurrencesOnLaunch`.
    public nonisolated static func reconciledDueDate(task: ScheduledTask, now: Date) -> Date? {
        if let next = task.nextRunAt { return next }
        return task.calculatedNextRun(after: now.addingTimeInterval(-1))
    }
}

/// Cross-process result for scheduled-run stop requests (XPC-friendly strings).
public enum ScheduledTaskStopResult: String, Sendable, Equatable {
    case accepted
    case alreadyTerminal
    case notOwned
    case failed

    public var isSuccess: Bool {
        switch self {
        case .accepted, .alreadyTerminal: return true
        case .notOwned, .failed: return false
        }
    }

    public static func parse(_ raw: String?, message: String?) -> (ScheduledTaskStopResult, String?) {
        if let raw, let known = ScheduledTaskStopResult(rawValue: raw) {
            return (known, message)
        }
        return (.failed, message ?? raw ?? "Unknown stop result")
    }
}

/// Posts/observes Darwin distributed notifications so the interactive app can
/// reload rails after LaunchAgent SQLite commits (EventBus is in-process only).
public enum ScheduledTaskCrossProcess {
    public static let storeChangedName = Notification.Name("io.remotecode.scheduled-tasks.store-changed")

    public static func notifyStoreChanged(reason: String) {
        DistributedNotificationCenter.default().postNotificationName(
            storeChangedName,
            object: reason,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    @discardableResult
    public static func observeStoreChanged(
        queue: OperationQueue? = .main,
        handler: @escaping (String?) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: storeChangedName,
            object: nil,
            queue: queue
        ) { note in
            handler(note.object as? String)
        }
    }

    public static func removeObserver(_ token: NSObjectProtocol) {
        DistributedNotificationCenter.default().removeObserver(token)
    }
}

@objc public protocol ScheduledTaskAgentXPCProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func wake(taskID: String?, withReply reply: @escaping (Bool, String?) -> Void)
    /// Stop a LaunchAgent-owned scheduled provider run. Replies with
    /// (statusRaw: accepted|alreadyTerminal|notOwned|failed, message?).
    func stop(threadID: String, agentRunID: String?, withReply reply: @escaping (String, String?) -> Void)
}

@MainActor
private final class ScheduledTaskAgentXPCEndpoint: NSObject, @preconcurrency ScheduledTaskAgentXPCProtocol {
    private let scheduler: ScheduledTaskScheduler
    init(scheduler: ScheduledTaskScheduler) { self.scheduler = scheduler }

    func ping(withReply reply: @escaping (String) -> Void) {
        reply(ScheduledTaskAgentServiceManager.serviceVersion)
    }

    func wake(taskID: String?, withReply reply: @escaping (Bool, String?) -> Void) {
        if let taskID {
            guard let id = UUID(uuidString: taskID) else { reply(false, "Invalid task ID."); return }
            scheduler.runNow(taskID: id) { result in
                switch result {
                case .success:
                    reply(true, nil)
                case .failure(let error):
                    reply(false, error.localizedDescription)
                }
            }
            return
        } else {
            scheduler.tick()
        }
        reply(true, nil)
    }

    func stop(threadID: String, agentRunID: String?, withReply reply: @escaping (String, String?) -> Void) {
        guard let tid = UUID(uuidString: threadID).map(AgentThreadID.init) else {
            reply(ScheduledTaskStopResult.failed.rawValue, "Invalid thread ID.")
            return
        }
        let runID = agentRunID.flatMap(UUID.init(uuidString:)).map(AgentRunID.init)
        scheduler.stop(threadID: tid, agentRunID: runID) { result, message in
            reply(result.rawValue, message)
        }
    }
}

@MainActor
public final class ScheduledTaskAgentXPCListener: NSObject, @preconcurrency NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let endpoint: ScheduledTaskAgentXPCEndpoint

    public init(serviceName: String, scheduler: ScheduledTaskScheduler) {
        self.listener = NSXPCListener(machServiceName: serviceName)
        self.endpoint = ScheduledTaskAgentXPCEndpoint(scheduler: scheduler)
        super.init()
        listener.delegate = self
    }

    public func resume() { listener.resume() }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ScheduledTaskAgentXPCProtocol.self)
        connection.exportedObject = endpoint
        connection.resume()
        return true
    }
}

@MainActor
public final class ScheduledTaskAgentServiceManager {
    /// Bump when XPC methods change. Clients re-register a mismatched agent.
    public static let protocolVersion = 2
    // nonisolated: the launch path unregisters from a detached task so the
    // synchronous SMAppService XPC never runs on the main thread.
    nonisolated public static var serviceBaseName: String { (Bundle.main.bundleIdentifier ?? "io.remotecode.desktop") + ".scheduled-tasks" }
    nonisolated public static var plistName: String { serviceBaseName + ".plist" }
    public static var machServiceName: String { serviceBaseName }
    public static var serviceVersion: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        return "\(protocolVersion):\(build)"
    }

    public nonisolated init() {}

    public var status: SMAppService.Status { SMAppService.agent(plistName: Self.plistName).status }

    public var statusDescription: String {
        switch status {
        case .enabled: return "Background scheduler active"
        case .requiresApproval: return "Approval required in Login Items"
        case .notFound: return "Background scheduler is ready to register"
        case .notRegistered: return "Background scheduler is not registered"
        @unknown default: return "Background scheduler status unknown"
        }
    }

    public func register() throws {
        let service = SMAppService.agent(plistName: Self.plistName)
        guard Self.registrationIsRequired(for: service.status) else { return }
        try service.register()
    }

    public nonisolated func unregister() throws {
        try SMAppService.agent(plistName: Self.plistName).unregister()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public static func registrationIsRequired(for status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            return false
        case .notRegistered, .notFound:
            return true
        @unknown default:
            return true
        }
    }

    public func wake(taskID: UUID? = nil, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        withReadyProxy { proxy, connection, fail in
            proxy.wake(taskID: taskID?.uuidString) { ok, message in
                Task { @MainActor in
                    if ok { completion(.success(())) }
                    else {
                        completion(.failure(ScheduledTaskPreflightError.invalidTask(
                            message ?? "Background scheduler rejected the request."
                        )))
                    }
                    connection.invalidate()
                }
            }
        } onFailure: { error in
            completion(.failure(error))
        }
    }

    /// Ask the LaunchAgent to stop a scheduled provider run it owns.
    public func stop(
        threadID: AgentThreadID,
        agentRunID: AgentRunID?,
        completion: @escaping @MainActor (ScheduledTaskStopResult, String?) -> Void
    ) {
        withReadyProxy { proxy, connection, _ in
            proxy.stop(
                threadID: threadID.value.uuidString,
                agentRunID: agentRunID?.value.uuidString
            ) { statusRaw, message in
                Task { @MainActor in
                    let parsed = ScheduledTaskStopResult.parse(statusRaw, message: message)
                    completion(parsed.0, parsed.1)
                    connection.invalidate()
                }
            }
        } onFailure: { error in
            completion(.failed, error.localizedDescription)
        }
    }

    private func withReadyProxy(
        _ body: @escaping (ScheduledTaskAgentXPCProtocol, NSXPCConnection, @escaping (Error) -> Void) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        let connection = NSXPCConnection(machServiceName: Self.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ScheduledTaskAgentXPCProtocol.self)
        connection.interruptionHandler = { connection.invalidate() }
        connection.invalidationHandler = {}
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            Task { @MainActor in onFailure(error); connection.invalidate() }
        } as? ScheduledTaskAgentXPCProtocol
        guard let proxy else {
            Task { @MainActor in
                onFailure(ScheduledTaskPreflightError.providerUnavailable("Background scheduler is unavailable."))
            }
            connection.invalidate()
            return
        }
        proxy.ping { version in
            Task { @MainActor in
                guard version == Self.serviceVersion else {
                    do {
                        try self.unregister()
                        try self.register()
                    } catch {
                        onFailure(error)
                        connection.invalidate()
                        return
                    }
                    onFailure(ScheduledTaskPreflightError.invalidTask(
                        "Scheduler version mismatch. The background scheduler was re-registered; retry when its status becomes active."
                    ))
                    connection.invalidate()
                    return
                }
                body(proxy, connection, { error in
                    Task { @MainActor in onFailure(error) }
                })
            }
        }
    }
}

@MainActor
public final class ScheduledTaskAgentAppDelegate: NSObject, NSApplicationDelegate {
    private let channel: ReleaseChannel
    private let appSupportOverride: String?
    private let dbOverride: String?
    private var context: AppContext?
    private var router: AppCommandRouter?
    private var scheduler: ScheduledTaskScheduler?
    private var xpcListener: ScheduledTaskAgentXPCListener?
    private var timer: Timer?
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []

    public init(channel: ReleaseChannel, appSupportOverride: String?, dbOverride: String?) {
        self.channel = channel
        self.appSupportOverride = appSupportOverride
        self.dbOverride = dbOverride
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let appSupportDirectory = AppPaths.appSupportDirectory(
                for: channel,
                override: appSupportOverride
            )
            ProviderProcessOwnership.shared.configure(
                fileURL: Self.providerOwnershipFile(in: appSupportDirectory)
            )
            // Share the interactive app's SQLite, but do not run launch
            // reconciliation that marks every live Agent App run interrupted.
            let context = try AppContext(
                channel: channel,
                dbPathOverride: dbOverride,
                appSupportOverride: appSupportOverride,
                performLaunchRunReconciliation: false
            )
            let router = AppCommandRouter(context: context)
            context.router = router
            let scheduler = ScheduledTaskScheduler(context: context, router: router)
            let listener = ScheduledTaskAgentXPCListener(
                serviceName: ScheduledTaskAgentServiceManager.machServiceName,
                scheduler: scheduler
            )
            self.context = context
            self.router = router
            self.scheduler = scheduler
            self.xpcListener = listener
            SystemNotifier.shared.bootstrap()
            listener.resume()
            scheduler.tick()
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak scheduler] _ in
                Task { @MainActor in scheduler?.tick() }
            }
            observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification) { scheduler.tick() }
            observe(NotificationCenter.default, name: .NSSystemClockDidChange) { scheduler.tick() }
            observe(NotificationCenter.default, name: .NSSystemTimeZoneDidChange) { scheduler.tick() }
        } catch {
            scheduledTaskLog.fault("scheduler.launch_failed error=\(error.localizedDescription, privacy: .public)")
            NSApp.terminate(nil)
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        for (center, token) in notificationTokens { center.removeObserver(token) }
        notificationTokens.removeAll()
        context?.coordinator.stopAllProviderSessionsForAppTermination()
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name, handler: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in handler() }
        }
        notificationTokens.append((center, token))
    }

    public nonisolated static func providerOwnershipFile(in appSupportDirectory: URL) -> URL {
        appSupportDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("provider-process-ownership.json", isDirectory: false)
    }
}
