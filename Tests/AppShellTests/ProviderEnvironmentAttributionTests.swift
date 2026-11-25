import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime
import SocketServer
@testable import AppShell

/// The source of every agent run's environment is providerEnvironment(provider:instanceId:).
/// It must ALWAYS tag the provider (REMOTE_CODE_AGENT_PROVIDER), even when there is no
/// instance config (the path that once returned an empty env and attributed child work
/// to "unknown"), and it must never carry the removed Token Saver keys.
final class ProviderEnvironmentAttributionTests: XCTestCase {
    @MainActor
    private func admittedThread(in context: AppContext, provider: AgentProvider) throws -> AgentThread {
        let thread = AgentThread(
            projectId: ProjectID(), workspaceId: WorkspaceID(), title: "scoped",
            provider: provider, model: "test", status: .completed
        )
        try context.threadRepo.upsert(thread)
        return thread
    }

    @MainActor
    func test_autoAndNestedWorkerEnvironmentsCarryHostProviderSurface() async throws {
        // WHY: every Auto/orchestrate controller and every orchestrated worker
        // must receive the same host surface (provider tag, Subagents lifecycle,
        // managed PATH for nested provider proxies). providerEnvironment is the
        // building block for the Auto send base and
        // completeOrchestratedWorkerEnvironment; if it drops any of these keys,
        // workers inherit a thinned host surface. Token Saver was removed, so a
        // preference an older build left ON must add none of its keys.
        let appSupport = NSTemporaryDirectory() + "RC2AutoWorkerTS-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: context)
        let workspace = try router.createWorkspace(name: "auto-ts", cwd: NSTemporaryDirectory())
        try seedLegacyTokenSaverOn(context.settingsRepo)

        for provider in [AgentProvider.claude, .codex, .grok] {
            let thread = try admittedThread(in: context, provider: provider)
            // Prefer workspace binding so providerEnvironment scopes recovery.
            var bound = thread
            bound.workspaceId = workspace.id
            try context.threadRepo.upsert(bound)

            let env = router.providerEnvironment(
                provider: provider,
                instanceId: bound.providerInstanceId,
                threadId: bound.id
            )
            XCTAssertTrue(
                env.keys.filter { $0.hasPrefix("RC_TOKEN_SAVER_") }.isEmpty,
                "\(provider) must carry no Token Saver keys"
            )
            XCTAssertEqual(env["REMOTE_CODE_AGENT_PROVIDER"], provider.rawValue)
            XCTAssertEqual(
                env["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"],
                bound.id.value.uuidString,
                "\(provider) Subagents lifecycle scope"
            )
            let path = env["PATH"] ?? ""
            let managed = env["RC_REMOTE_CODE_MANAGED_BIN"] ?? ""
            XCTAssertFalse(managed.isEmpty, "\(provider) managed bin")
            XCTAssertTrue(
                path.hasPrefix(managed + ":") || path == managed,
                "\(provider) PATH must front managed bin for nested provider proxies: \(path)"
            )
            XCTAssertNil(env["REMOTE_CODE_DISTILL_STATE_PATH"])
        }
    }

    @MainActor
    func test_nestedAgentAppInheritsProjectScope() async throws {
        // WHY: a cross-provider child must keep the host-validated project
        // scope (and workspace, run-as user, execution mode) of its active
        // parent; otherwise the subagent runs outside the parent's scope.
        let appSupport = NSTemporaryDirectory() + "RC2NestedProject-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: context)
        let workspace = try router.createWorkspace(name: "nested", cwd: NSTemporaryDirectory())
        let projectID = ProjectID()
        let parentThread = AgentThread(
            projectId: projectID,
            workspaceId: workspace.id,
            title: "parent",
            provider: .codex,
            model: "gpt",
            permissionMode: .fullAccess
        )
        try context.threadRepo.upsert(parentThread)
        let parentRunID = AgentRunID()
        let parentCapability = AgentDelegationCapability.issue()
        _ = try context.orchestrationRuntime.recordExternalRoot(
            runId: parentRunID,
            threadId: parentThread.id,
            provider: .codex,
            providerInstanceId: "codex",
            model: "gpt",
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                parentCapability
            )
        )
        try seedLegacyTokenSaverOn(context.settingsRepo)

        let child = try await router.createAgentThreadRouting(
            workspace: workspace.id,
            title: "child",
            provider: .grok,
            model: "grok",
            permissionMode: .supervised,
            reasoningEffort: .high,
            serviceTier: .auto,
            modelSelection: nil,
            providerInstanceId: nil,
            runAsUser: nil,
            surfaceID: nil,
            routing: nil,
            nestedRunContext: AgentNestedRunContext(
                parentRunID: parentRunID,
                parentThreadID: parentThread.id,
                nodeID: "nested.grok.project",
                parentCapability: parentCapability
            )
        )

        XCTAssertEqual(child.projectId, projectID)
        XCTAssertEqual(child.workspaceId, parentThread.workspaceId)
        XCTAssertEqual(child.runAsUser, parentThread.runAsUser)
        XCTAssertEqual(child.executionMode, parentThread.executionMode)
        XCTAssertNil(
            router.providerEnvironment(
                provider: .grok,
                instanceId: child.providerInstanceId,
                threadId: child.id
            )["RC_TOKEN_SAVER_DISTILL_HINT"]
        )
    }

    @MainActor
    func test_nestedAgentAppRejectsForeignRunAsParentBeforePersistingChildThread() async throws {
        // WHY: the Agent App middleware returns through an owner-only local IPC
        // socket. Persisting a foreign run-as child would claim an execution
        // identity that the host cannot actually launch or reconnect.
        let appSupport = NSTemporaryDirectory() + "RC2NestedForeignUser-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: context)
        let workspace = try router.createWorkspace(name: "nested-foreign", cwd: NSTemporaryDirectory())
        let foreignUser = AgentRunAsUser(
            generatedUID: "foreign-user",
            shortName: "foreign-user",
            uid: getuid() &+ 1,
            gid: getgid(),
            homePath: "/Users/foreign-user"
        )
        let parentThread = AgentThread(
            workspaceId: workspace.id,
            title: "foreign parent",
            provider: .codex,
            model: "gpt",
            permissionMode: .fullAccess,
            runAsUser: foreignUser
        )
        try context.threadRepo.upsert(parentThread)
        let parentRunID = AgentRunID()
        let parentCapability = AgentDelegationCapability.issue()
        _ = try context.orchestrationRuntime.recordExternalRoot(
            runId: parentRunID,
            threadId: parentThread.id,
            provider: .codex,
            providerInstanceId: "codex",
            model: "gpt",
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                parentCapability
            )
        )

        do {
            _ = try await router.createAgentThreadRouting(
                workspace: workspace.id,
                title: "must not persist",
                provider: .grok,
                model: "grok-4.5",
                permissionMode: .supervised,
                reasoningEffort: .high,
                serviceTier: .auto,
                modelSelection: nil,
                providerInstanceId: nil,
                runAsUser: nil,
                surfaceID: nil,
                routing: nil,
                nestedRunContext: AgentNestedRunContext(
                    parentRunID: parentRunID,
                    parentThreadID: parentThread.id,
                    nodeID: "nested.grok.foreign",
                    parentCapability: parentCapability
                )
            )
            XCTFail("foreign-user parent must fail before child persistence")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32020)
            XCTAssertEqual(
                error.message,
                "Nested Agent App cannot cross the host IPC user boundary."
            )
        }

        let persisted = try context.threadRepo.list(workspaceId: workspace.id)
        XCTAssertEqual(persisted.map(\.id), [parentThread.id])
    }

    @MainActor
    func test_providerEnvironmentAlwaysTagsProvider_evenWithoutInstanceConfig() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvEnv-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)

        // instanceId nil => no provider instance config => previously returned [:] => "unknown".
        XCTAssertEqual(
            router.providerEnvironment(provider: .claude, instanceId: nil)["REMOTE_CODE_AGENT_PROVIDER"],
            "claude",
            "the agent environment must tag the provider so child work attributes to claude, not unknown"
        )
        XCTAssertEqual(
            router.providerEnvironment(provider: .codex, instanceId: nil)["REMOTE_CODE_AGENT_PROVIDER"],
            "codex"
        )
    }

    @MainActor
    func test_distillHighParallelismSettingAddsNestingDepthOnlyForDistill() throws {
        // WHY: the setting is global, but only Distill reads the key. Off must leave
        // the run at its configured default instead of forcing depth 2.
        let appSupport = NSTemporaryDirectory() + "RC2ProvEnvDepth-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          { "id": "distill-x", "provider": "distill", "displayName": "D", "homePath": "/tmp/distill-home-y", "enabled": true, "env": {} },
          { "id": "grok-x", "provider": "grok", "displayName": "G", "homePath": "/tmp/grok-home-y", "enabled": true, "env": {} }
        ]
        """)
        let router = AppCommandRouter(context: ctx)

        XCTAssertNil(
            router.providerEnvironment(provider: .distill, instanceId: "distill-x")["GROK_SUBAGENTS_MAX_DEPTH"],
            "default OFF must not raise Distill nesting"
        )

        var settings = SettingsStore(db: ctx.db).load()
        settings.distillHighParallelism = true
        SettingsStore(db: ctx.db).save(settings)
        XCTAssertTrue(SettingsStore(db: ctx.db).load().distillHighParallelism, "the setting must persist")

        XCTAssertEqual(
            router.providerEnvironment(provider: .distill, instanceId: "distill-x")["GROK_SUBAGENTS_MAX_DEPTH"],
            "2"
        )
        XCTAssertNil(
            router.providerEnvironment(provider: .grok, instanceId: "grok-x")["GROK_SUBAGENTS_MAX_DEPTH"],
            "the Distill setting must not touch other providers"
        )
    }

    @MainActor
    func test_providerEnvironmentSetsDistillHomeForDistillOnly() throws {
        // WHY: Distill 2.0.24 reads DISTILL_HOME and never adopts ~/.grok; an instance home must reach it, not GROK_HOME.
        let appSupport = NSTemporaryDirectory() + "RC2ProvEnvDistillHome-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          { "id": "distill-x", "provider": "distill", "displayName": "D", "homePath": "/tmp/distill-home-x", "enabled": true, "env": {} },
          { "id": "grok-x", "provider": "grok", "displayName": "G", "homePath": "/tmp/grok-home-x", "enabled": true, "env": {} }
        ]
        """)
        let router = AppCommandRouter(context: ctx)
        let distill = router.providerEnvironment(provider: .distill, instanceId: "distill-x")
        XCTAssertEqual(distill["DISTILL_HOME"], "/tmp/distill-home-x")
        XCTAssertNil(distill["GROK_HOME"])
        let grok = router.providerEnvironment(provider: .grok, instanceId: "grok-x")
        XCTAssertEqual(grok["GROK_HOME"], "/tmp/grok-home-x")
        XCTAssertNil(grok["DISTILL_HOME"])
    }

    /// Token Saver was removed: no provider gets the distill hint or Claude's
    /// PostToolUse hook, even when an older build left the preference ON.
    @MainActor
    func test_providerEnvironment_neverEmitsTokenSaverKeys_evenWithLegacyPreferenceOn() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvEnvHint-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let codexThread = try admittedThread(in: ctx, provider: .codex)
        let claudeThread = try admittedThread(in: ctx, provider: .claude)
        let grokThread = try admittedThread(in: ctx, provider: .grok)

        ctx.reconcileManagedIntegration()
        XCTAssertNil(
            router.providerEnvironment(provider: .codex, instanceId: nil, threadId: codexThread.id)["RC_TOKEN_SAVER_DISTILL_HINT"]
        )
        XCTAssertNil(
            router.providerEnvironment(provider: .claude, instanceId: nil, threadId: claudeThread.id)["RC_TOKEN_SAVER_POST_TOOL_USE"]
        )

        try seedLegacyTokenSaverOn(ctx.settingsRepo)

        XCTAssertNil(
            router.providerEnvironment(provider: .codex, instanceId: nil, threadId: codexThread.id)["RC_TOKEN_SAVER_DISTILL_HINT"]
        )
        XCTAssertNil(
            router.providerEnvironment(provider: .claude, instanceId: nil, threadId: claudeThread.id)["RC_TOKEN_SAVER_DISTILL_HINT"]
        )
        XCTAssertNil(
            router.providerEnvironment(provider: .grok, instanceId: nil, threadId: grokThread.id)["RC_TOKEN_SAVER_DISTILL_HINT"]
        )
        XCTAssertNil(
            router.providerEnvironment(provider: .claude, instanceId: nil, threadId: claudeThread.id)["RC_TOKEN_SAVER_POST_TOOL_USE"],
            "a legacy ON preference must not bring back Claude's PostToolUse compression hook"
        )
    }

    @MainActor
    func test_providerEnvironment_alwaysCarriesSubagentTelemetryScope_withoutTokenSaverLanes() throws {
        // WHY: Subagents activity is user-visible; telemetry must stay scoped
        // without enabling any compression lane.
        let appSupport = NSTemporaryDirectory() + "RC2SubagentTelemetryEnv-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)

        for provider in AgentProvider.allCases {
            let thread = try admittedThread(in: ctx, provider: provider)
            let environment = router.providerEnvironment(
                provider: provider,
                instanceId: nil,
                threadId: thread.id
            )
            XCTAssertEqual(environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"], appSupport)
            XCTAssertEqual(environment["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"], thread.id.value.uuidString)
            XCTAssertEqual(environment["REMOTE_CODE_AGENT_PROVIDER"], provider.rawValue)
            XCTAssertEqual(environment["REMOTE_CODE_AGENT_MODEL"], thread.model)
            XCTAssertNil(environment["RC_TOKEN_SAVER_DISTILL_HINT"])
            XCTAssertNil(environment["RC_TOKEN_SAVER_POST_TOOL_USE"])
        }
    }

    /// Nested provider proxies only resolve inside Codex/Claude provider shells if the
    /// managed bin directory wins PATH lookup inside the provider process.
    @MainActor
    func test_providerEnvironmentPrependsManagedBinToProviderPath() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvEnvPath-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let codexThread = try admittedThread(in: ctx, provider: .codex)
        let claudeThread = try admittedThread(in: ctx, provider: .claude)

        let managedBin = AgentSkillInstaller.defaultManagedCLIBinDirectory().path
        let codexPath = try XCTUnwrap(router.providerEnvironment(provider: .codex, instanceId: nil, threadId: codexThread.id)["PATH"])
        let claudePath = try XCTUnwrap(router.providerEnvironment(provider: .claude, instanceId: nil, threadId: claudeThread.id)["PATH"])

        XCTAssertTrue(codexPath.hasPrefix(managedBin + ":"), "Codex provider shell must resolve nested provider proxies through managed bin first")
        XCTAssertTrue(claudePath.hasPrefix(managedBin + ":"), "Claude provider shell must resolve nested provider proxies through managed bin first")
    }

    /// Nested provider proxies must always resolve: Subagents telemetry is always-on,
    /// and bare `grok`/`claude`/`codex` shell calls need the managed PATH controller
    /// without any distillation lane.
    @MainActor
    func test_providerEnvironmentPrependsManagedBinForEveryProvider() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvProxyPathOff-" + UUID().uuidString
        let skillsHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ProvProxyHome-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: skillsHome) }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            agentSkillsHomeOverrideForTesting: skillsHome
        )
        ctx.reconcileManagedIntegration()
        let router = AppCommandRouter(context: ctx)
        let managedBin = skillsHome.appendingPathComponent(".remote-code/bin").path
        let shellBridge = skillsHome.appendingPathComponent(".remote-code/shell/zsh").path

        for provider in AgentProvider.allCases {
            let thread = try admittedThread(in: ctx, provider: provider)
            let env = router.providerEnvironment(provider: provider, instanceId: nil, threadId: thread.id)
            let path = try XCTUnwrap(env["PATH"], "\(provider) must expose PATH with managed bin")
            XCTAssertTrue(
                path.hasPrefix(managedBin + ":") || path == managedBin,
                "\(provider): managed bin must lead PATH for nested provider proxies"
            )
            XCTAssertEqual(env["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"], thread.id.value.uuidString)
            XCTAssertEqual(env["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"], "1")
            XCTAssertEqual(env["RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH"], AppPaths.socketPath(for: .debug))
            XCTAssertEqual(
                env["RC_REMOTE_CODE_AGENT_APP_COMMAND"],
                skillsHome.appendingPathComponent(".remote-code/bin")
                    .appendingPathComponent(AgentSkillInstaller.agentAppMiddlewareCommand).path
            )
            XCTAssertEqual(
                env["ZDOTDIR"],
                shellBridge,
                "the provider shell must use RemoteCode's profile-preserving login bridge"
            )
            XCTAssertNil(env["RC_TOKEN_SAVER_DISTILL_HINT"])
        }
    }

    @MainActor
    func test_providerEnvironmentUsesCustomProviderHOMEAsOriginalZDOTDIR() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2CustomProviderHome-\(UUID().uuidString)", isDirectory: true)
        let skillsHome = root.appendingPathComponent("managed", isDirectory: true)
        let providerHome = root.appendingPathComponent("claude-home", isDirectory: true)
        try FileManager.default.createDirectory(at: providerHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path,
            agentSkillsHomeOverrideForTesting: skillsHome
        )
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "claude-isolated",
            "provider": "claude",
            "displayName": "Claude Isolated",
            "binaryPath": "/usr/bin/env",
            "homePath": "\(providerHome.path)",
            "enabled": true,
            "env": {}
          }
        ]
        """)
        let router = AppCommandRouter(context: ctx)
        let thread = try admittedThread(in: ctx, provider: .claude)

        let env = router.providerEnvironment(
            provider: .claude,
            instanceId: "claude-isolated",
            threadId: thread.id
        )

        XCTAssertEqual(env["HOME"], providerHome.path)
        XCTAssertEqual(env["RC_REMOTE_CODE_ORIGINAL_ZDOTDIR"], providerHome.path)
        XCTAssertEqual(env["RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR"], providerHome.path)
        XCTAssertEqual(
            env["ZDOTDIR"],
            skillsHome.appendingPathComponent(".remote-code/shell/zsh").path
        )
    }

    @MainActor
    func test_providerEnvironmentDoesNotAdvertiseUserOwnedAgentAppAlias() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ForeignAgentAppAlias-\(UUID().uuidString)", isDirectory: true)
        let skillsHome = root.appendingPathComponent("managed", isDirectory: true)
        let managedBin = skillsHome.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(
            to: managedBin.appendingPathComponent(AgentSkillInstaller.agentAppMiddlewareCommand)
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path,
            agentSkillsHomeOverrideForTesting: skillsHome
        )
        let router = AppCommandRouter(context: ctx)
        let thread = try admittedThread(in: ctx, provider: .codex)

        let env = router.providerEnvironment(
            provider: .codex,
            instanceId: nil,
            threadId: thread.id
        )

        XCTAssertEqual(env["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"], "1")
        XCTAssertNil(
            env["RC_REMOTE_CODE_AGENT_APP_COMMAND"],
            "provider prompts must not receive a missing or user-owned launcher path"
        )
    }

    /// Recovered provider sessions bypass AppCommandRouter.providerEnvironment.
    /// WHY: without the managed PATH here, a resumed parent silently loses the
    /// provider middleware for every nested child even though fresh runs keep it.
    @MainActor
    func test_recoveryEnvironmentAlwaysCarriesManagedMiddlewarePath_withoutTokenSaverKeys() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2RecoveryProxyPath-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let thread = try admittedThread(in: ctx, provider: .codex)
        let managedBin = AgentSkillInstaller.defaultManagedCLIBinDirectory().path
        let recoveryEnvironment = try XCTUnwrap(ctx.coordinator.recoveryEnvironmentProvider)

        ctx.reconcileManagedIntegration()
        let recovered = await recoveryEnvironment(.codex, thread.id)
        let recoveredPath = try XCTUnwrap(recovered["PATH"])
        XCTAssertTrue(recoveredPath.hasPrefix(managedBin + ":") || recoveredPath == managedBin)
        XCTAssertEqual(recovered["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"], "1")
        XCTAssertNil(recovered["RC_TOKEN_SAVER_DISTILL_HINT"])

        // A preference an older build left ON must not bring the hint back.
        try seedLegacyTokenSaverOn(ctx.settingsRepo)
        let legacyOn = await recoveryEnvironment(.codex, thread.id)
        let legacyOnPath = try XCTUnwrap(legacyOn["PATH"])
        XCTAssertTrue(legacyOnPath.hasPrefix(managedBin + ":") || legacyOnPath == managedBin)
        XCTAssertNil(legacyOn["RC_TOKEN_SAVER_DISTILL_HINT"])
    }

    /// Without a thread id there is no nested-provider interception scope.
    @MainActor
    func test_providerEnvironment_withoutThreadDoesNotRequireManagedPath() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvProxyNoThread-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let env = router.providerEnvironment(provider: .codex, instanceId: nil, threadId: nil)
        XCTAssertEqual(env["REMOTE_CODE_AGENT_PROVIDER"], "codex")
        XCTAssertNil(env["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"])
        if let path = env["PATH"] {
            let managedBin = AgentSkillInstaller.defaultManagedCLIBinDirectory().path
            XCTAssertFalse(
                path.split(separator: ":").map(String.init).contains(managedBin),
                "no-thread env must not inject managed bin (scrubbed raw path)"
            )
        }
    }

    @MainActor
    func test_providerEnvironmentStampsCallerBotIdAndLogicalHostAdmission() throws {
        // WHY: self-config MCP must inherit the calling bot, not a baked home-MCP id.
        let appSupport = NSTemporaryDirectory() + "RC2BotSelfConfigEnv-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let bot = try ctx.botStore.create(name: "Piper", title: "", description: "", provider: .claude)
        let thread = try admittedThread(in: ctx, provider: .claude)
        try ctx.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Desk", linkedAgentThreadID: thread.id)
        )

        let env = router.providerEnvironment(provider: .claude, instanceId: nil, threadId: thread.id)
        XCTAssertEqual(
            env[BotSelfConfigCatalog.callerEnvironmentKey],
            bot.id.value.uuidString.lowercased()
        )
        XCTAssertEqual(env[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey], "1")

        let other = try admittedThread(in: ctx, provider: .grok)
        let unbound = router.providerEnvironment(provider: .grok, instanceId: nil, threadId: other.id)
        XCTAssertNil(unbound[BotSelfConfigCatalog.callerEnvironmentKey])
    }

    @MainActor
    func test_providerEnvironmentStubsDockerAndExcludesHostMCP() throws {
        // WHY: dockerDesktop child PATH must retain failing host stubs and must
        // not keep DOCKER_HOST or the native physical-host MCP admission.
        let appSupport = NSTemporaryDirectory() + "RC2DockerPath-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let dockerBot = try ctx.botStore.create(
            name: "Piper",
            title: "",
            description: "",
            provider: .claude,
            desktopKind: .dockerDesktop
        )
        let dockerThread = try admittedThread(in: ctx, provider: .claude)
        try ctx.botStore.upsertConversation(
            BotConversation(botID: dockerBot.id, title: "Desk", linkedAgentThreadID: dockerThread.id)
        )
        let dockerEnv = router.providerEnvironment(
            provider: .claude,
            instanceId: nil,
            threadId: dockerThread.id
        )
        XCTAssertNil(dockerEnv["DOCKER_HOST"])
        XCTAssertNil(dockerEnv["DOCKER_CONTEXT"])
        XCTAssertNil(dockerEnv[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey])
        let stub = URL(fileURLWithPath: appSupport, isDirectory: true)
            .appendingPathComponent("bot-desktop-stubs", isDirectory: true)
            .appendingPathComponent("dockerDesktop", isDirectory: true)
        let path = try XCTUnwrap(dockerEnv["PATH"])
        XCTAssertTrue(
            path.split(separator: ":").map(String.init).contains(stub.path),
            "dockerDesktop PATH must include the stub dir, got \(path)"
        )
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: stub.appendingPathComponent("macos-harness").path)
        )
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: stub.appendingPathComponent("docker").path)
        )

        let hostBot = try ctx.botStore.create(
            name: "Scout",
            title: "",
            description: "",
            provider: .claude,
            desktopKind: .logicalExecutionSpace
        )
        let hostThread = try admittedThread(in: ctx, provider: .claude)
        try ctx.botStore.upsertConversation(
            BotConversation(botID: hostBot.id, title: "Desk", linkedAgentThreadID: hostThread.id)
        )
        let hostEnv = router.providerEnvironment(
            provider: .claude,
            instanceId: nil,
            threadId: hostThread.id
        )
        XCTAssertEqual(hostEnv[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey], "1")
        let hostPath = hostEnv["PATH"] ?? ""
        XCTAssertFalse(
            hostPath.split(separator: ":").map(String.init).contains(stub.path),
            "this-Mac PATH must not include the dockerDesktop stub dir"
        )
    }
}
