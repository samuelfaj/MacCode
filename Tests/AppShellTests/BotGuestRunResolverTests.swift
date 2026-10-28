import XCTest
import os
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

/// Plan A S8: which Distill runs go to the bot's Linux guest, and how a guest
/// run claims the bot, waits its turn, and is prepared and cleaned up.
@MainActor
final class BotGuestRunResolverTests: XCTestCase {
    private var root: URL!
    private var gateways: [BotGuestMCPGateway] = []

    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        // Resolved: the cwd rules compare symlink-resolved paths (/var → /private/var).
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("RC2GuestResolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        gateways.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    func test_autoProfileFailuresAreNotReportedAsVMFailures() {
        for failure in [DistillAutoRoutingError.disabled, .missingOptions, .noConnectedAccounts] {
            let surfaced = BotGuestRunResolver.launchError(failure)
            XCTAssertEqual(surfaced as? DistillAutoRoutingError, failure)
            XCTAssertFalse(String(describing: surfaced).contains("VM unavailable"))
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let ctx: AppContext
        let router: AppCommandRouter
        let bot: BotDefinition
        let workspace: Workspace
        let hostHome: URL
        let vm: FakeGuestVM
        let registry: BotVMRunRegistry
        let leases: DistillGuestLeases
        let barrier: DistillGuestLaunchBarrier
        let refreshes: Recorder<DistillAccountProvider?>
        let resolver: BotGuestRunResolver
        let deps: BotGuestRunResolver.Dependencies
        let appSupport: URL

        var guestHome: URL {
            BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: bot.id)
        }
        var guestDistillHome: URL { DistillGuestCredentials.distillHome(guestHome: guestHome) }
        var runsDirectory: URL { DistillGuestEnvironment.runsDirectory(appSupport: appSupport) }
    }

    private func makeFixture(openBarrier: Bool = true, legacyWorkspaceID: WorkspaceID? = nil) async throws -> Fixture {
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspaceDir = root.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let workspace = try router.createWorkspace(name: "ws", cwd: workspaceDir.path)
        let bot = try ctx.botStore.create(
            name: "Vera", title: "", description: "", desktopKind: .dockerDesktop, workspaceID: legacyWorkspaceID ?? workspace.id
        )
        // Provisioning creates the bot's guest home; the fake VM does not.
        try FileManager.default.createDirectory(
            at: BotComputerGuestSpec.guestHomeURL(appSupport: ctx.appSupportDirectory, botID: bot.id),
            withIntermediateDirectories: true
        )
        let hostHome = root.appendingPathComponent("host-distill", isDirectory: true)
        try FileManager.default.createDirectory(at: hostHome, withIntermediateDirectories: true)
        try """
            [models]
            default = "claude/claude-sonnet-4-5"

            [model.local]
            base_url = "http://127.0.0.1:8000/v1"
            api_key = "sk-local-secret"
            """.write(to: hostHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try #"{"access_token":"at-1","refresh_token":"rt-host-only","expires_at":4102444800000}"#
            .write(to: hostHome.appendingPathComponent("claude-auth.json"), atomically: true, encoding: .utf8)

        let vm = FakeGuestVM()
        let registry = BotVMRunRegistry()
        let leases = DistillGuestLeases()
        let barrier = DistillGuestLaunchBarrier()
        if openBarrier { await barrier.open() }
        let refreshes = Recorder<DistillAccountProvider?>()
        let gateway = BotGuestMCPGateway()
        gateways.append(gateway)
        let workspaces = [workspace.id: workspaceDir.path]
        let deps = BotGuestRunResolver.Dependencies(
            threadRepo: ctx.threadRepo,
            botStore: ctx.botStore,
            appSupport: ctx.appSupportDirectory,
            registry: registry,
            leases: leases,
            barrier: barrier,
            gateway: gateway,
            vm: vm,
            binaryGuestPath: { _, arch in
                XCTAssertEqual(arch, "aarch64")
                return "/opt/remotecode-agent/distill/2.0.31/distill-linux-aarch64"
            },
            refresh: { _, provider in refreshes.append(provider) },
            dockerExecutable: { "/usr/bin/true" },
            workspaces: { workspaces },
            hostBinary: { _ in nil },
            gitIdentity: { GitIdentity(name: "Ada", email: "ada@example.com") },
            processEnvironment: ["DISTILL_HOME": hostHome.path],
            heartbeatInterval: 0.05
        )
        return Fixture(
            ctx: ctx, router: router, bot: bot, workspace: workspace, hostHome: hostHome, vm: vm,
            registry: registry, leases: leases, barrier: barrier, refreshes: refreshes,
            resolver: BotGuestRunResolver(deps), deps: deps, appSupport: ctx.appSupportDirectory
        )
    }

    private func makeRecoveryFixture() async throws -> Fixture {
        let fixture = try await makeFixture()
        try fixture.ctx.botStore.setExecutionDestination(.ownVM, botID: fixture.bot.id)
        fixture.vm.container = BotComputerGuestSpec.containerName(botID: fixture.bot.id)
        return fixture
    }

    private func makeThread(
        _ f: Fixture, workspace: Bool = false, marked: Bool = true,
        target: ExecutionTarget = .vm, title: String = "Desk chat"
    ) throws -> AgentThread {
        let thread = try f.router.createAgentThread(
            workspace: workspace ? f.workspace.id : nil, title: title, provider: .distill,
            model: "claude/claude-sonnet-4-5", permissionMode: .supervised, reasoningEffort: .medium,
            routingConfiguration: nil, quiet: true
        )
        XCTAssertTrue(try f.ctx.threadRepo.setActor(
            id: thread.id, actor: .bot(f.bot.id), lockedAt: Date(), executionTarget: target
        ))
        if marked { XCTAssertTrue(try f.ctx.threadRepo.setGuestRuntime(id: thread.id, BotGuestRuntime.distillV1)) }
        return thread
    }

    private func request(
        _ thread: AgentThread, cwd: String? = nil, runAsUser: AgentRunAsUser? = nil,
        permit: AgentRunAcceptancePermit? = nil, providerThreadId: String? = nil
    ) -> AgentRunRequest {
        AgentRunRequest(
            threadId: thread.id, provider: .distill, model: "claude/claude-sonnet-4-5",
            cwd: cwd ?? root.appendingPathComponent("BotHome").path, prompt: "uname -a",
            providerThreadId: providerThreadId,
            environment: [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                BotSecretEnvironment.botIDEnvironmentKey: "bot",
                "PATH": "/Users/someone/bin:/usr/bin",
            ],
            runAsUser: runAsUser,
            acceptancePermit: permit
        )
    }

    private func envFile(_ f: Fixture, _ runID: AgentRunID) -> URL {
        f.runsDirectory.appendingPathComponent("\(runID.value.uuidString.lowercased()).env")
    }

    private func leaseFile(_ f: Fixture, _ runID: AgentRunID) -> URL {
        f.guestHome.appendingPathComponent(".rc-runs/\(runID.value.uuidString.lowercased()).lease")
    }

    func test_namedOnlyAutoGuestPlanRenewsNamedHomeAndLaunchesAutoWithoutLegacyCredential() async throws {
        let f = try await makeFixture()
        try FileManager.default.removeItem(at: f.hostHome.appendingPathComponent("claude-auth.json"))
        let folder = f.hostHome.appendingPathComponent("accounts/work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"access_token":"fixture","refresh_token":"host-only"}"#.utf8)
            .write(to: folder.appendingPathComponent("claude-auth.json"))
        let registry = #"{"version":1,"accounts":[{"id":"work","provider":"claude","label":"Work","legacy":false}],"routing":{"enabled":true,"strategy":"ordered_first","options":[{"id":"r","account_id":"work","main_model":"claude/claude-sonnet-4-5","worker_model":null}]}}"#
        try registry.write(to: f.hostHome.appendingPathComponent("accounts.json"), atomically: true, encoding: .utf8)
        var deps = f.deps
        let homes = Recorder<URL>()
        deps.refresh = { home, provider in
            homes.append(home)
            XCTAssertEqual(provider, .claude)
        }
        let resolver = BotGuestRunResolver(deps)
        let thread = try makeThread(f)
        let request = AgentRunRequest(threadId: thread.id, provider: .distill, model: "auto",
            cwd: root.path, prompt: "Go", reasoningModel: "stale-worker")
        let plan = try unwrapPlan(try await resolver.prepare(request) { _ in })
        defer { resolver.endRunsForAppTermination() }
        XCTAssertEqual(homes.values.map(\.path), [folder.path])
        let modelIndex = try XCTUnwrap(plan.guestCommand.firstIndex(of: "--model"))
        XCTAssertEqual(plan.guestCommand[modelIndex + 1], "auto")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.guestDistillHome.appendingPathComponent("claude-auth.json").path))
        let data = try Data(contentsOf: f.guestDistillHome.appendingPathComponent("accounts/work/claude-auth.json"))
        let credential = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(credential["refresh_token"] as? String, "")
        await plan.finish(.completed).value
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.guestDistillHome.appendingPathComponent("accounts").path))
    }

    func test_namedGrokRenewalDelegatesToScopedHostCLIAndRechecksTheSameChildHome() async throws {
        let f = try await makeFixture()
        let folder = f.hostHome.appendingPathComponent("accounts/work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"https://auth.x.ai::fixture":{"key":"fake-access","refresh_token":"host-only"}}"#.utf8)
            .write(to: folder.appendingPathComponent("auth.json"))
        let registry = #"{"version":1,"accounts":[{"id":"work","provider":"grok","label":"Work","legacy":false}],"routing":{"enabled":true,"strategy":"ordered_first","options":[{"id":"r","account_id":"work","main_model":"grok-4.6","worker_model":null}]}}"#
        try registry.write(to: f.hostHome.appendingPathComponent("accounts.json"), atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("fake-accounts-cli")
        let log = root.appendingPathComponent("account-argv")
        let script = """
        #!/bin/sh
        echo "$*" > "\(log.path)"
        echo '{"account_id":"work","checked_at":"2026-10-12T18:58:45.174778Z","fetched_at":null,"status":"unavailable","remaining_percent":null,"detail":null}'
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let homes = Recorder<URL>()
        var deps = f.deps
        deps.hostBinary = { _ in binary.path }
        deps.refresh = { home, provider in
            XCTAssertEqual(provider, .grok)
            homes.append(home)
            if homes.values.count == 1 { throw DistillGuestCredentialError.grokLoginExpiring(expiresAt: Date()) }
        }
        let resolver = BotGuestRunResolver(deps)
        defer { resolver.endRunsForAppTermination() }
        let thread = try makeThread(f)
        let req = AgentRunRequest(threadId: thread.id, provider: .distill, model: "auto", cwd: root.path, prompt: "Go")
        let plan = try unwrapPlan(try await resolver.prepare(req) { _ in })
        XCTAssertEqual(homes.values.map(\.path), [folder.path, folder.path])
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "accounts usage work\n")
        await plan.finish(.completed).value
    }

    func test_contextualRunsOnOneVMHoldIndependentLeases() async throws {
        // WHY: two conversations of one bot share its VM. A per-VM lease made
        // the second wait for the first run's teardown; a retry of the same
        // run must still wait for its own previous attempt.
        let identity = try BotContextRuntimeIdentity(hostID: "host", botID: BotID(), context: .general, policyRevision: 1)
        let leases = DistillGuestLeases()
        let first = AgentRunID()
        let held = try await leases.acquire(BotGuestRunResolver.contextLeaseKey(identity: identity, runID: first))
        let other = try await leases.acquire(BotGuestRunResolver.contextLeaseKey(identity: identity, runID: AgentRunID()))
        let retryHeld = await leases.isHeld(BotGuestRunResolver.contextLeaseKey(identity: identity, runID: first))
        XCTAssertTrue(retryHeld, "the same run's retry keeps waiting on its own lease")
        await other.release()
        await held.release()
    }

    func test_delegatedPeerClaimSharesTheVMWithItsWaitingParentOnly() {
        // WHY: a parent waiting on its delegated peer kept the VM, so the
        // exclusive peer claim on the same VM was refused forever.
        let registry = BotVMRunRegistry()
        let vm = BotID()
        let parent = BotVMRunRegistry.Entry(threadID: AgentThreadID(), runID: AgentRunID(), title: "Parent", workspace: "")
        XCTAssertNil(registry.tryBegin(botID: BotID(), entry: parent, resourceID: vm))
        let child = BotVMRunRegistry.Entry(threadID: AgentThreadID(), runID: AgentRunID(), title: "Peer", workspace: "", exclusive: true)
        XCTAssertNil(registry.tryBegin(botID: BotID(), entry: child, resourceID: vm, allowsSameThreadExclusive: false,
                                       parentRunID: parent.runID))
        let stranger = BotVMRunRegistry.Entry(threadID: AgentThreadID(), runID: AgentRunID(), title: "Other", workspace: "", exclusive: true)
        XCTAssertEqual(registry.tryBegin(botID: BotID(), entry: stranger, resourceID: vm, allowsSameThreadExclusive: false,
                                         parentRunID: AgentRunID())?.runID, parent.runID,
                       "an unrelated exclusive run still waits")
    }

    func test_contextPinnedThreadWithoutAdmissionPreparesLikeANormalThread() async throws {
        for marked in [true, false] {
            let f = try await makeFixture()
            let grant = try f.ctx.botStore.grantContext(
                hostID: f.ctx.liveActivityHostIdentity.serverId,
                botID: f.bot.id,
                context: .general,
                actions: [.read, .send],
                expectedRevision: nil
            )
            let thread = try makeThread(f, marked: marked)
            let conversation = BotConversation(botID: f.bot.id, title: "Pinned", linkedAgentThreadID: thread.id)
            try f.ctx.botStore.createContextualConversation(
                conversation,
                hostID: f.ctx.liveActivityHostIdentity.serverId,
                context: .general,
                policyRevision: grant.policyRevision
            )
            // Without an internal isolated admission, a pinned thread prepares exactly like a non-pinned one.
            let plan = try await f.resolver.prepare(request(thread)) { _ in }
            if marked {
                let launch = try unwrapPlan(plan)
                XCTAssertEqual(f.vm.calls.count, 1, "a marked pinned thread uses the bot's guest VM")
                await launch.finish(.completed).value
            } else {
                XCTAssertNil(plan, "an unmarked pinned thread stays on the Mac like a normal one")
                XCTAssertEqual(f.vm.calls.count, 0)
            }
            f.resolver.endRunsForAppTermination()
        }
    }

    // MARK: - Routing

    func test_authorizedWorkspaceConversationRunsDespiteLegacyBotWorkspace() async throws {
        let f = try await makeFixture(legacyWorkspaceID: WorkspaceID())
        defer { f.resolver.endRunsForAppTermination() }
        let thread = try makeThread(f, workspace: true)
        let host = f.ctx.liveActivityHostIdentity.serverId
        let grant = try f.ctx.botStore.grantContext(
            hostID: host, botID: f.bot.id, context: .workspace(f.workspace.id),
            actions: [.read, .send], expectedRevision: nil
        )
        try f.ctx.botStore.createContextualConversation(
            BotConversation(botID: f.bot.id, title: "Authorized", linkedAgentThreadID: thread.id),
            hostID: host, context: .workspace(f.workspace.id), policyRevision: grant.policyRevision
        )
        XCTAssertNotEqual(try f.ctx.botStore.get(id: f.bot.id)?.workspaceID, f.workspace.id)
        XCTAssertEqual(try f.ctx.threadRepo.get(id: thread.id)?.workspaceId, f.workspace.id)
        let plan = try unwrapPlan(try await f.resolver.prepare(request(thread, cwd: f.workspace.cwd)) { _ in })
        XCTAssertEqual(f.vm.calls.count, 1)
        XCTAssertEqual(plan.guestCwd, f.workspace.cwd)
        await plan.finish(.completed).value
    }

    // WHY: a conversation pinned to This Mac but still marked as a VM thread failed every
    // send with "this bot no longer has a Docker desktop" instead of running on the Mac.
    func test_threadPinnedToThisMacDropsStaleVMTarget() async throws {
        let f = try await makeFixture()
        let thread = try makeThread(f)
        try f.ctx.db.execute("UPDATE agent_threads SET execution_destination='mac', execution_target='vm' WHERE id='\(thread.id.value.uuidString)';")
        let stale = try XCTUnwrap(f.ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(stale.executionTarget, .vm)
        let repaired = try f.ctx.threadRepo.reconcileBotExecutionTarget(stale)
        XCTAssertEqual(repaired.executionTarget, .mac)
        XCTAssertEqual(try f.ctx.threadRepo.get(id: thread.id)?.executionTarget, .mac)
        f.resolver.endRunsForAppTermination()
    }

    func test_localBotRepairsStalePlacementButContextIsolationAndDockerFailuresStayClosed() async throws {
        let f = try await makeFixture()
        let ordinary = try makeThread(f)
        let pinned = try makeThread(f)
        try f.ctx.db.execute("UPDATE agent_threads SET execution_destination=NULL;")
        let grant = try f.ctx.botStore.grantContext(
            hostID: f.ctx.liveActivityHostIdentity.serverId, botID: f.bot.id,
            context: .general, actions: [.read, .send], expectedRevision: nil
        )
        try f.ctx.botStore.createContextualConversation(
            BotConversation(botID: f.bot.id, title: "Pinned", linkedAgentThreadID: pinned.id),
            hostID: f.ctx.liveActivityHostIdentity.serverId, context: .general, policyRevision: grant.policyRevision
        )
        _ = try f.ctx.botStore.publish(
            botID: f.bot.id, expectedCurrentRevisionID: f.bot.currentRevisionID,
            draft: BotRevisionDraft(name: f.bot.name, title: "", description: "", soul: "", desktopKind: .logicalExecutionSpace)
        )
        let repaired = try f.ctx.threadRepo.reconcileBotExecutionTarget(try XCTUnwrap(f.ctx.threadRepo.get(id: ordinary.id)))
        XCTAssertEqual(repaired.executionTarget, .mac)
        XCTAssertEqual(try f.ctx.threadRepo.guestPlacement(of: ordinary.id)?.macHandoffPending, true)
        let mac = try await f.resolver.prepare(request(repaired)) { _ in }
        XCTAssertNil(mac)
        XCTAssertTrue(f.vm.calls.isEmpty, "local execution must never provision Docker")

        let isolated = try f.ctx.threadRepo.reconcileBotExecutionTarget(try XCTUnwrap(f.ctx.threadRepo.get(id: pinned.id)))
        XCTAssertEqual(isolated.executionTarget, .vm)
        do {
            _ = try await f.resolver.prepare(request(isolated)) { _ in }
            XCTFail("a contextual thread must not silently execute on the Mac")
        } catch {
            XCTAssertTrue(error is DistillGuestLaunchError)
        }
    }

    func test_legacyVMThreadWithoutTheMarker_andAMarkedThreadMovedToTheMac_stayOnTheMac() async throws {
        // WHY (B3, D5): a `.vm` thread from before plan A has its Distill
        // session on the Mac; loading it in the guest would fail. And a thread
        // the user moved to the Mac must not go back to the guest.
        let f = try await makeFixture()
        let legacy = try makeThread(f, marked: false)
        let movedToMac = try makeThread(f, target: .mac)
        for thread in [legacy, movedToMac] {
            XCTAssertFalse(f.resolver.isGuestThread(thread.id))
            let plan = try await f.resolver.prepare(request(thread)) { _ in }
            XCTAssertNil(plan)
        }
        XCTAssertEqual(f.vm.calls.count, 0, "no guest work for a Mac thread")
        XCTAssertNil(f.registry.active(botID: f.bot.id), "a Mac run does not claim the bot's VM")
    }

    func test_theMarkerSurvivesWholeThreadWrites() async throws {
        // WHY: model, routing and title edits rewrite the whole thread row;
        // dropping the marker would send a guest thread (and its guest
        // session cursor) back to the Mac without anyone asking.
        let f = try await makeFixture()
        var thread = try XCTUnwrap(try f.ctx.threadRepo.get(id: try makeThread(f).id))
        thread.title = "Renamed"
        thread.model = "claude/claude-opus-4-1"
        try f.ctx.threadRepo.upsert(thread)
        XCTAssertTrue(try f.ctx.threadRepo.setActor(id: thread.id, actor: thread.actor, lockedAt: thread.actorLockedAt, executionTarget: .vm))
        XCTAssertEqual(try f.ctx.threadRepo.guestPlacement(of: thread.id),
                       AgentThreadGuestPlacement(executionTarget: .vm, guestRuntime: BotGuestRuntime.distillV1))
        XCTAssertTrue(f.resolver.isGuestThread(thread.id))
    }

    func test_deskThreadPlanRunsInTheGuestHomeWithACleanEnvAndRefreshBlankedSignIn_andTeardownLeavesNothing() async throws {
        let f = try await makeFixture()
        let thread = try makeThread(f)
        XCTAssertTrue(f.resolver.isGuestThread(thread.id))
        let stages = Recorder<DistillGuestStage>()
        let req = request(thread)
        let plan = try unwrapPlan(try await f.resolver.prepare(req) { stages.append($0) })

        XCTAssertEqual(plan.container, "remotecode-bot-test")
        XCTAssertEqual(plan.guestCwd, BotComputerGuestSpec.guestUserHome,
                       "a desk thread has no workspace: it runs in the guest home, never the Mac's BotHome path")
        XCTAssertEqual(plan.guestCommand.first, "/opt/remotecode-agent/distill/2.0.31/distill-linux-aarch64")
        XCTAssertEqual(f.vm.calls.first?.workspace, nil, "a desk thread is provisioned, never asked to mount BotHome (B5)")
        XCTAssertEqual(stages.values, [.startingVM, .preparingAgent, .signingIn, .launching])
        XCTAssertEqual(f.refreshes.values, [.claude], "the Mac renews the model's sign-in before the guest copy is made")
        XCTAssertEqual(f.registry.active(botID: f.bot.id)?.runID, req.runId,
                       "the spawn point claims the bot for every send path (B2)")

        // Environment: allowlisted, nothing of Token Saver or the Mac.
        let env = try String(contentsOf: plan.envFileURL, encoding: .utf8)
        XCTAssertEqual(try posixMode(plan.envFileURL), 0o600)
        XCTAssertTrue(env.contains("RC_GUEST_RUN_ID=\(req.runId.value.uuidString.lowercased())\n"))
        XCTAssertTrue(env.contains("RC_GUEST_GATEWAY_TOKEN="))
        XCTAssertTrue(env.contains("GIT_AUTHOR_EMAIL=ada@example.com\n"))
        XCTAssertFalse(env.contains("RC_TOKEN_SAVER"), "Token Saver injects nothing into guest runs")
        XCTAssertFalse(env.contains("/Users/"), "no Mac path reaches the guest")

        // Config: gateway by bearer env var; the model key moved out of the file.
        let config = try String(contentsOf: f.guestDistillHome.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("url = \"http://host.docker.internal:"))
        XCTAssertTrue(config.contains("bearer_token_env_var = \"RC_GUEST_GATEWAY_TOKEN\""))
        XCTAssertFalse(config.contains("sk-local-secret"), "secrets ride in the env file, not the guest-readable config")
        XCTAssertTrue(env.contains("sk-local-secret"))

        // Sign-in copy: the guest can never spend the refresh token.
        let copy = f.guestDistillHome.appendingPathComponent("claude-auth.json")
        let copied = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: copy)) as? [String: Any])
        XCTAssertEqual(copied["refresh_token"] as? String, "")
        XCTAssertEqual(copied["access_token"] as? String, "at-1")
        XCTAssertEqual(try posixMode(copy), 0o600)

        // Lease: written before the agent starts and renewed by re-creating it.
        let lease = leaseFile(f, req.runId)
        let firstInode = try inode(lease)
        try await waitUntil { (try? self.inode(lease)) != firstInode }

        await plan.finish(.completed).value
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "no sign-in copy outlives the run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.path), "no lease outlives the run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.envFileURL.path))
        let leaseHeld = await f.leases.isHeld(f.bot.id.value.uuidString.lowercased())
        XCTAssertFalse(leaseHeld)
    }

    func test_workspaceThreadRunsAtItsOwnPathInsideTheMountedWorkspace() async throws {
        let f = try await makeFixture()
        let thread = try makeThread(f, workspace: true)
        let sub = root.appendingPathComponent("ws/app", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let plan = try unwrapPlan(try await f.resolver.prepare(request(thread, cwd: sub.path)) { _ in })
        XCTAssertEqual(f.vm.calls.first?.workspace, root.appendingPathComponent("ws").path,
                       "the registered workspace root is what gets mounted")
        XCTAssertEqual(plan.guestCwd, sub.path, "the workspace is bound at the same path in the guest")
        await plan.finish(.completed).value
    }

    func test_workspacePinnedBotConversationInTheBotHomeRunsInTheGuestHome() async throws {
        // WHY: a workspace Bot's scheduled run is pinned to its workspace but runs
        // in the Bot's Mac home, which is never mounted. It failed every time with
        // "this conversation's folder …/bots/<id>/e1 is not inside a folder mounted".
        let f = try await makeFixture()
        let thread = try makeThread(f, workspace: true)
        let botHome = BotHome(appSupportDirectory: f.appSupport, bot: f.bot).root
        try FileManager.default.createDirectory(at: botHome, withIntermediateDirectories: true)
        let plan = try unwrapPlan(try await f.resolver.prepare(request(thread, cwd: botHome.path)) { _ in })
        XCTAssertEqual(plan.guestCwd, BotComputerGuestSpec.guestUserHome)
        await plan.finish(.completed).value
    }

    // MARK: - ChatGPT catalog parity

    func test_theGuestAsksChatGPTAsTheMacsCodexClientVersion_resolvedWhileTheVMComesUp() async throws {
        // WHY: the guest has no `codex`, so on its own it asks ChatGPT for
        // models as Distill's default version and does not list the newest
        // ones, which the picker (fed by the Mac's catalog) still offers:
        // "Selected Distill model 'chatgpt/…' is not advertised".
        let f = try await makeFixture()
        let asked = Recorder<[String: String]>()
        // Held like a `codex` that has not answered yet.
        let probeHeld = OSAllocatedUnfairLock(initialState: true)
        var deps = f.deps
        deps.codexClientVersion = { environment in
            asked.append(environment)
            while probeHeld.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 5_000_000) }
            return "0.162.1"
        }
        let resolver = BotGuestRunResolver(deps)
        let gate = DispatchSemaphore(value: 0)
        f.vm.gate = gate
        let req = request(try makeThread(f))
        let run = Task { try await resolver.prepare(req) { _ in } }
        // Both in flight: the VM start does not wait for `codex --version`
        // (up to 3 s), and the probe does not wait for the VM.
        try await waitUntil { asked.values.count == 1 && f.vm.calls.count == 1 }
        XCTAssertEqual(f.vm.calls.count, 1, "the VM must start while the Codex version is still unanswered, not after it")
        probeHeld.withLock { $0 = false }
        gate.signal()
        let plan = try unwrapPlan(try await run.value)

        let host = try XCTUnwrap(asked.values.first)
        XCTAssertEqual(host["DISTILL_HOME"], f.hostHome.path, "resolved from the environment the Mac's Distill would get")
        XCTAssertEqual(host["PATH"], "/Users/someone/bin:/usr/bin", "the run's own PATH is where the Mac's Distill finds codex")
        let env = try String(contentsOf: plan.envFileURL, encoding: .utf8)
        XCTAssertTrue(env.contains("DISTILL_CODEX_CLIENT_VERSION=0.162.1\n"), "the guest must ask as the Mac's version")
        XCTAssertFalse(env.contains("/Users/"), "no Mac path follows the version into the guest")
        await plan.finish(.completed).value
    }

    func test_aMacWithoutCodex_orASlowOrBrokenProbe_stillRunsAndSetsNoClientVersion() async throws {
        // WHY: most Macs have no codex; that is not a reason to refuse a run,
        // and a made-up version would make the guest differ from the Mac.
        let f = try await makeFixture()
        let probes: [@Sendable ([String: String]) async -> String?] = [
            f.deps.codexClientVersion, // the default: nothing to resolve
            { _ in
                try? await Task.sleep(nanoseconds: 300_000_000) // gave up on a hung codex
                return nil
            },
            { _ in "0.162.1\nHOME=/Users/me" }, // not a version: dropped, never an invalid env file
        ]
        for probe in probes {
            var deps = f.deps
            deps.codexClientVersion = probe
            let resolver = BotGuestRunResolver(deps)
            let thread = try makeThread(f)
            let req = request(thread)
            let plan = try unwrapPlan(try await resolver.prepare(req) { _ in })
            let env = try String(contentsOf: plan.envFileURL, encoding: .utf8)
            XCTAssertFalse(env.contains("CODEX_CLIENT_VERSION"), "unresolved: the guest uses Distill's default, as the Mac does")
            XCTAssertFalse(env.contains("/Users/"))
            await plan.finish(.completed).value
            _ = f.registry.releaseAndNextWaiting(runID: req.runId)
        }
    }

    func test_theAppResolvesTheCodexClientVersionFromTheEnvironmentTheMacsDistillIsStartedWith() throws {
        // WHY: every test above injects `codexClientVersion`, and its default
        // resolves nothing, so the app's own wiring could be dropped (or given
        // the GUI environment, whose PATH need not reach `codex`) with every
        // test green and the guest back to Distill's default version. A built
        // resolver cannot be asked what it was given, so the wiring is pinned
        // in the source, as `BotSendStageIntervalPlacementTests` pins this file.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotGuestRunResolver.swift"),
            encoding: .utf8
        )
        var cursor = try XCTUnwrap(source.range(of: "func makeBotGuestRunResolver(")?.upperBound)
        for marker in [
            "codexClientVersion: { hostEnvironment in",
            "DistillCodexClientVersion.resolve(environment: CodexRunner.processEnvironment(",
            "overrides: hostEnvironment, purpose: .agentTurn(.distill)",
        ] {
            let found = try XCTUnwrap(
                source[cursor...].range(of: marker),
                "the app must resolve the guest's Codex client version from the login-shell environment the Mac's Distill gets; missing or out of order: \(marker)"
            )
            cursor = found.upperBound
        }
    }

    // MARK: - Other sign-ins

    private func signInToChatGPT(_ f: Fixture) throws {
        try #"{"tokens":{"access_token":"at-codex","refresh_token":"rt-host-only"}}"#
            .write(to: f.hostHome.appendingPathComponent("codex-auth.json"), atomically: true, encoding: .utf8)
    }

    func test_aClaudeRunAlsoRenewsTheChatGPTSignIn_butNoSignInThatIsMissingOrNotRenewedHere() async throws {
        // WHY: a role model ([models] worker, session_summary, a subagent's)
        // can be served by another sign-in. The guest's copy has no refresh
        // token, so if the Mac does not renew it nobody does and that role
        // fails mid-run once its access token expires.
        let f = try await makeFixture()
        try signInToChatGPT(f)
        // Grok is renewed by its own CLI, OpenRouter has nothing to renew.
        try #"{"https://auth.x.ai::fixture":{"key":"fake-access","refresh_token":"host-only"}}"#
            .write(to: f.hostHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try #"{"key":"sk-or-fixture"}"#
            .write(to: f.hostHome.appendingPathComponent("openrouter-auth.json"), atomically: true, encoding: .utf8)
        let thread = try makeThread(f)
        let plan = try unwrapPlan(try await f.resolver.prepare(request(thread)) { _ in })
        XCTAssertEqual(f.refreshes.values, [.claude, .chatgpt],
                       "the run's own sign-in first, then the other one a role model may use; each once")
        await plan.finish(.completed).value
    }

    func test_aChatGPTRenewalFailureDoesNotStopAClaudeRun() async throws {
        // WHY: the run's own sign-in is good; refusing the run because a
        // sign-in it may never touch could not be renewed would be a regression.
        let f = try await makeFixture()
        try signInToChatGPT(f)
        let asked = Recorder<DistillAccountProvider?>()
        var deps = f.deps
        deps.refresh = { _, provider in
            asked.append(provider)
            if provider == .chatgpt {
                throw DistillGuestCredentialError.refreshRejected(.chatgpt, status: 401, code: "refresh_token_expired")
            }
        }
        let resolver = BotGuestRunResolver(deps)
        let thread = try makeThread(f)
        let plan = try unwrapPlan(try await resolver.prepare(request(thread)) { _ in })
        XCTAssertEqual(asked.values, [.claude, .chatgpt])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.guestDistillHome.appendingPathComponent("claude-auth.json").path), "the run is prepared as before")
        await plan.finish(.completed).value
    }

    func test_theRunsOwnSignInFailingStillFailsTheRun_andNothingElseIsRenewed() async throws {
        // WHY: renewing the other sign-ins is an addition after the strict
        // preflight, never a way around it.
        let f = try await makeFixture()
        try signInToChatGPT(f)
        let asked = Recorder<DistillAccountProvider?>()
        var deps = f.deps
        deps.refresh = { _, provider in
            asked.append(provider)
            if provider == .claude {
                throw DistillGuestCredentialError.refreshRejected(.claude, status: 401, code: "invalid_grant")
            }
        }
        let resolver = BotGuestRunResolver(deps)
        let thread = try makeThread(f)
        let req = request(thread)
        await assertUnavailable(containing: "Claude rejected the sign-in renewal on this Mac (HTTP 401, invalid_grant)") {
            _ = try await resolver.prepare(req) { _ in }
        }
        XCTAssertEqual(asked.values, [.claude])
        try await assertNothingLeft(f, req)
    }

    func test_stopWhileAnotherSignInIsRenewedStopsTheRunAtOnce_withoutCuttingThatRenewal() async throws {
        // WHY: only a failed renewal is forgiven; a Stop is not a failure,
        // and must not wait for a sign-in the run does not use. The renewal
        // it leaves behind must still run to its end: a token request that
        // is cut may already have spent the refresh token, and then that
        // sign-in needs a new login.
        let f = try await makeFixture()
        try signInToChatGPT(f)
        let asked = Recorder<DistillAccountProvider?>()
        let cancelledAtEnd = Recorder<Bool>()
        let held = OSAllocatedUnfairLock(initialState: true)
        var deps = f.deps
        deps.refresh = { _, provider in
            asked.append(provider)
            guard provider == .chatgpt else { return }
            // In flight until released; 5 s at most, so a regression fails instead of hanging.
            let limit = Date().addingTimeInterval(5)
            while held.withLock({ $0 }), Date() < limit { try? await Task.sleep(nanoseconds: 5_000_000) }
            cancelledAtEnd.append(Task.isCancelled)
        }
        let resolver = BotGuestRunResolver(deps)
        let permit = AgentRunAcceptancePermit()
        let req = request(try makeThread(f), permit: permit)
        let run = Task { try await resolver.prepare(req) { _ in } }
        try await waitUntil { asked.values == [.claude, .chatgpt] }
        permit.invalidate() // what the coordinator's Stop does to a pending start
        do {
            let plan = try await run.value
            XCTFail("a stopped run must not get a launch plan")
            await plan?.finish(.cancelled).value
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(cancelledAtEnd.values.isEmpty, "Stop must not wait for the renewal of a sign-in the run does not use")
        try await assertNothingLeft(f, req)
        held.withLock { $0 = false }
        try await waitUntil { cancelledAtEnd.values.count == 1 }
        XCTAssertEqual(cancelledAtEnd.values, [false],
                       "Stop must not cancel the renewal: a request that is cut can leave a spent refresh token on the Mac")
    }

    func test_aSignInTheRunDoesNotUseThatIsSlowToRenewDoesNotHoldTheRun() async throws {
        // WHY: the token server of a sign-in this run may never use can hang
        // (the request times out after 30 s). The run's own sign-in is ready,
        // so the run must not sit in "signing in" for it; the renewal goes on
        // and reaches the guest through the mirror.
        let f = try await makeFixture()
        try signInToChatGPT(f)
        let cancelledAtEnd = Recorder<Bool>()
        let held = OSAllocatedUnfairLock(initialState: true)
        var deps = f.deps
        deps.otherSignInWait = 0.05
        deps.refresh = { _, provider in
            guard provider == .chatgpt else { return }
            // In flight until released; 5 s at most, so a regression fails instead of hanging.
            let limit = Date().addingTimeInterval(5)
            while held.withLock({ $0 }), Date() < limit { try? await Task.sleep(nanoseconds: 5_000_000) }
            cancelledAtEnd.append(Task.isCancelled)
        }
        let resolver = BotGuestRunResolver(deps)
        let plan = try unwrapPlan(try await resolver.prepare(request(try makeThread(f))) { _ in })
        XCTAssertTrue(cancelledAtEnd.values.isEmpty, "the run is prepared while the other sign-in is still being renewed")
        held.withLock { $0 = false }
        try await waitUntil { cancelledAtEnd.values.count == 1 }
        XCTAssertEqual(cancelledAtEnd.values, [false],
                       "the wait ending must not cancel the renewal: a request that is cut can leave a spent refresh token on the Mac")
        await plan.finish(.completed).value
    }

    func test_anAutoRunOverTheMacsOwnClaudeSignInAsksThatFileOnce_notAgainAsAnOtherSignIn() async throws {
        // WHY: Auto has no main-model provider, so the routed sign-in is the
        // run's own. Claude rotates refresh tokens: the same credential file
        // must not be asked for a second time as an "other" sign-in.
        let f = try await makeFixture()
        try signInToChatGPT(f)
        let registry = #"{"version":1,"accounts":[{"id":"legacy-claude","provider":"claude","label":"Claude","legacy":true},{"id":"legacy-chatgpt","provider":"chatgpt","label":"ChatGPT","legacy":true}],"routing":{"enabled":true,"strategy":"ordered_first","options":[{"id":"r","account_id":"legacy-claude","main_model":"claude/claude-sonnet-4-5","worker_model":null}]}}"#
        try registry.write(to: f.hostHome.appendingPathComponent("accounts.json"), atomically: true, encoding: .utf8)
        let asked = Recorder<String>()
        var deps = f.deps
        deps.refresh = { home, provider in asked.append("\(provider?.rawValue ?? "nil") \(home.path)") }
        let resolver = BotGuestRunResolver(deps)
        defer { resolver.endRunsForAppTermination() }
        let thread = try makeThread(f)
        let req = AgentRunRequest(threadId: thread.id, provider: .distill, model: "auto", cwd: root.path, prompt: "Go")
        let plan = try unwrapPlan(try await resolver.prepare(req) { _ in })
        XCTAssertEqual(asked.values, ["claude \(f.hostHome.path)", "chatgpt \(f.hostHome.path)"],
                       "the routed Claude sign-in once, as the run's own, then the ChatGPT one; never the Claude file twice in one pass")
        await plan.finish(.completed).value
    }

    func test_aNamedAccountRunRenewsEachCredentialFileOnce() async throws {
        // WHY: Claude and ChatGPT rotate refresh tokens; the same file must
        // not be asked for twice in one pass, and a named account keeps the
        // renewal it has today.
        let f = try await makeFixture()
        try signInToChatGPT(f)
        let folder = f.hostHome.appendingPathComponent("accounts/work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"access_token":"fixture","refresh_token":"host-only"}"#.utf8)
            .write(to: folder.appendingPathComponent("claude-auth.json"))
        let registry = #"{"version":1,"accounts":[{"id":"work","provider":"claude","label":"Work","legacy":false},{"id":"legacy-chatgpt","provider":"chatgpt","label":"ChatGPT","legacy":true}],"routing":{"enabled":true,"strategy":"ordered_first","options":[{"id":"r","account_id":"work","main_model":"claude/claude-sonnet-4-5","worker_model":null}]}}"#
        try registry.write(to: f.hostHome.appendingPathComponent("accounts.json"), atomically: true, encoding: .utf8)
        let asked = Recorder<String>()
        var deps = f.deps
        deps.refresh = { home, provider in asked.append("\(provider?.rawValue ?? "nil") \(home.path)") }
        let resolver = BotGuestRunResolver(deps)
        defer { resolver.endRunsForAppTermination() }
        let thread = try makeThread(f)
        let plan = try unwrapPlan(try await resolver.prepare(request(thread)) { _ in })
        XCTAssertEqual(asked.values, ["claude \(folder.path)", "chatgpt \(f.hostHome.path)"],
                       "the named Claude account as today, then the Mac's ChatGPT sign-in; each once")
        await plan.finish(.completed).value
    }

    // MARK: - Fail closed

    func test_cwdOutsideEveryMountFailsClosed_andLeavesNothingBehind() async throws {
        // WHY (M6): falling back to the guest home would run the agent somewhere
        // the user did not ask for, with no error.
        let f = try await makeFixture()
        let thread = try makeThread(f, workspace: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let req = request(thread, cwd: elsewhere.path)
        await assertUnavailable(containing: "not inside a folder mounted") {
            _ = try await f.resolver.prepare(req) { _ in }
        }
        try await assertNothingLeft(f, req)
    }

    func test_dockerDownFailsClosed_freesTheLease_andLeavesNoSignInOrEnvFile() async throws {
        // WHY (D11): never fall back to the Mac; a failed start must not keep
        // the bot's lease or leave credentials on the guest-visible bind.
        let f = try await makeFixture()
        f.vm.error = BotComputerGuestError.dockerUnavailable
        let thread = try makeThread(f)
        let req = request(thread)
        await assertUnavailable(containing: "") {
            _ = try await f.resolver.prepare(req) { _ in }
        }
        try await assertNothingLeft(f, req)
        XCTAssertEqual(f.registry.active(botID: f.bot.id)?.runID, req.runId,
                       "the claim stays for the coordinator's run-finished, which also drains the next queued send")
    }

    func test_aForeignMacUserIsRefused() async throws {
        // WHY (M9): the guest gets the app user's own sign-ins; a run meant for
        // another macOS user must not run with them.
        let f = try await makeFixture()
        let thread = try makeThread(f)
        let other = AgentRunAsUser(
            generatedUID: "", shortName: "someone-else", uid: getuid() + 1, gid: getgid(), homePath: "/Users/someone-else"
        )
        await assertUnavailable(containing: "someone-else") {
            _ = try await f.resolver.prepare(self.request(thread, runAsUser: other)) { _ in }
        }
        XCTAssertEqual(f.vm.calls.count, 0)
        XCTAssertNil(f.registry.active(botID: f.bot.id))
    }

    func test_aMarkerFromANewerBuildFailsInsteadOfRunningOnTheMac() async throws {
        let f = try await makeFixture()
        let thread = try makeThread(f)
        XCTAssertTrue(try f.ctx.threadRepo.setGuestRuntime(id: thread.id, "guest-v9"))
        XCTAssertTrue(f.resolver.isGuestThread(thread.id), "the adapter must not open it on the Mac")
        await assertUnavailable(containing: "newer MacCode") {
            _ = try await f.resolver.prepare(self.request(thread)) { _ in }
        }
    }

    // MARK: - One run per bot

    func test_twoConversationsStartingTogether_bothRunOnTheVM() async throws {
        // WHY: a bot VM has no parallelism limit. Each run has its own env
        // file, lease file and gateway bearer, so both can run at once.
        let f = try await makeFixture()
        let first = try makeThread(f, title: "First chat")
        let second = try makeThread(f, title: "Second chat")
        let firstPlan = try unwrapPlan(try await f.resolver.prepare(request(first)) { _ in })
        let secondPlan = try unwrapPlan(try await f.resolver.prepare(request(second)) { _ in })
        XCTAssertEqual(f.vm.calls.count, 2)
        XCTAssertNotEqual(firstPlan.envFileURL, secondPlan.envFileURL)
        await firstPlan.finish(.completed).value
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.guestDistillHome.appendingPathComponent("claude-auth.json").path),
            "the first run's teardown keeps the sign-in copy the second run still uses")
        await secondPlan.finish(.completed).value
    }

    func test_delegatedGuestKeepsSharedVMExclusiveUntilTerminationAndCannotReleaseANewerRun() async throws {
        let f = try await makeFixture()
        let machine = try f.ctx.botStore.saveVirtualMachine(name: "Shared")
        try f.ctx.botStore.setExecutionDestination(.virtualMachine(machine.id), botID: f.bot.id)
        try FileManager.default.createDirectory(
            at: BotComputerGuestSpec.guestHomeURL(appSupport: f.appSupport, botID: machine.storageID),
            withIntermediateDirectories: true)
        let thread = try makeThread(f, title: "Peer consultation")
        let req = request(thread)
        let coordinator = f.ctx.coordinator
        coordinator.registerDelegatedRun(req.runId, threadId: thread.id, parentRunId: AgentRunID())
        let handoffs = Recorder<AgentThreadID>()
        var deps = f.deps
        deps.isDelegatedRun = { coordinator.isDelegatedRun($0, threadId: $1) }
        deps.onVMAvailable = { _, threadID in handoffs.append(threadID) }
        let resolver = BotGuestRunResolver(deps)
        let plan = try unwrapPlan(try await resolver.prepare(req) { _ in })
        let claim = try XCTUnwrap(f.registry.active(botID: f.bot.id, resourceID: machine.storageID))
        XCTAssertTrue(claim.exclusive)
        XCTAssertNil(f.registry.tryBegin(botID: f.bot.id, entry: claim, resourceID: machine.storageID,
                                         allowsSameThreadExclusive: false), "the same run can reclaim its own slot")

        do {
            _ = try await resolver.prepare(request(thread)) { _ in }
            XCTFail("a new run on the same thread must wait for the previous guest to end")
        } catch {
            XCTAssertEqual(error as? DistillGuestLaunchError, .busy("The VM is busy in Peer consultation"))
        }
        let otherBot = BotID()
        let next = BotVMRunRegistry.Entry(threadID: AgentThreadID(), runID: AgentRunID(), title: "Next", workspace: "")
        XCTAssertEqual(f.registry.tryBegin(botID: otherBot, entry: next, resourceID: machine.storageID)?.runID, req.runId,
                       "a different bot using the same VM sees the same exclusive claim")
        f.registry.addWaiting(botID: otherBot, threadID: next.threadID, resourceID: machine.storageID)

        let held = OSAllocatedUnfairLock(initialState: true)
        let closing = Recorder<Bool>()
        let finish = plan.finish(.completed) {
            closing.append(true)
            let limit = Date().addingTimeInterval(5)
            while held.withLock({ $0 }), Date() < limit { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await waitUntil { !closing.values.isEmpty }
        XCTAssertTrue(resolver.retainsExclusiveVMClaim(runID: req.runId))
        XCTAssertEqual(f.registry.active(botID: f.bot.id, resourceID: machine.storageID)?.runID, req.runId)
        XCTAssertTrue(handoffs.values.isEmpty)
        held.withLock { $0 = false }
        await finish.value
        XCTAssertFalse(resolver.retainsExclusiveVMClaim(runID: req.runId))
        XCTAssertNil(f.registry.active(botID: f.bot.id, resourceID: machine.storageID))
        XCTAssertEqual(handoffs.values, [next.threadID])

        let newer = BotVMRunRegistry.Entry(threadID: thread.id, runID: AgentRunID(), title: "Newer", workspace: "", exclusive: true)
        XCTAssertNil(f.registry.tryBegin(botID: f.bot.id, entry: newer, resourceID: machine.storageID,
                                         allowsSameThreadExclusive: false))
        await plan.finish(.completed).value
        await plan.killGuest()
        XCTAssertEqual(f.registry.active(botID: f.bot.id, resourceID: machine.storageID)?.runID, newer.runID)
        XCTAssertEqual(handoffs.values, [next.threadID], "old termination notifies only once")
        f.registry.endRun(runID: newer.runID)
    }

    func test_delegatedGuestKeepsItsExclusiveClaimWhenTerminationCannotBeConfirmed() async throws {
        let f = try await makeFixture()
        let thread = try makeThread(f)
        let req = request(thread)
        let coordinator = f.ctx.coordinator
        coordinator.registerDelegatedRun(req.runId, threadId: thread.id, parentRunId: AgentRunID())
        var deps = f.deps
        deps.isDelegatedRun = { coordinator.isDelegatedRun($0, threadId: $1) }
        deps.dockerExecutable = { "/usr/bin/false" }
        let resolver = BotGuestRunResolver(deps)
        let plan = try unwrapPlan(try await resolver.prepare(req) { _ in })
        await plan.finish(.cancelled).value

        XCTAssertTrue(resolver.retainsExclusiveVMClaim(runID: req.runId))
        XCTAssertEqual(f.registry.active(botID: f.bot.id)?.runID, req.runId)
        XCTAssertEqual(f.registry.active(botID: f.bot.id)?.exclusive, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.envFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.guestDistillHome.appendingPathComponent("claude-auth.json").path))
        f.registry.endRun(runID: req.runId)
    }

    func test_resynchronizeGuestWithoutLivePlanReturnsFalseAndDoesNotCopyCredentials() async throws {
        let f = try await makeRecoveryFixture()
        let thread = try makeThread(f)
        let req = request(thread)

        let resynchronized = try await f.resolver.resynchronizeGuest(req)
        XCTAssertFalse(resynchronized)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.guestDistillHome.appendingPathComponent("claude-auth.json").path))
    }

    func test_resynchronizeResumedGuestCopiesCurrentHostAccessTokenWithoutRefreshToken() async throws {
        let f = try await makeRecoveryFixture()
        let thread = try makeThread(f)
        let req = request(thread, providerThreadId: "existing-session")
        let plan = try unwrapPlan(try await f.resolver.prepare(req) { _ in })
        defer {
            plan.finish(.completed)
            f.registry.endRun(runID: req.runId)
        }
        try #"{"access_token":"at-2","refresh_token":"rt-new-host-only","expires_at":4102444800000}"#
            .write(to: f.hostHome.appendingPathComponent("claude-auth.json"), atomically: true, encoding: .utf8)

        let resynchronized = try await f.resolver.resynchronizeGuest(req)
        XCTAssertTrue(resynchronized)
        let copy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            f.guestDistillHome.appendingPathComponent("claude-auth.json"))) as? [String: Any])
        XCTAssertEqual(copy["access_token"] as? String, "at-2")
        XCTAssertEqual(copy["refresh_token"] as? String, "")
        XCTAssertEqual(f.refreshes.values, [.claude], "resynchronization only recopies credentials; it does not renew them")
    }

    func test_resynchronizeGuestAfterPlanFinishesDoesNotResurrectCredentialCopy() async throws {
        let f = try await makeRecoveryFixture()
        let thread = try makeThread(f)
        let req = request(thread)
        let plan = try unwrapPlan(try await f.resolver.prepare(req) { _ in })
        await plan.finish(.completed).value
        f.registry.endRun(runID: req.runId)

        let resynchronized = try await f.resolver.resynchronizeGuest(req)
        XCTAssertFalse(resynchronized)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.guestDistillHome.appendingPathComponent("claude-auth.json").path))
    }

    func test_resynchronizeGuestAfterOneParallelRunFinishesKeepsOtherRunCredentialsAndClaim() async throws {
        let f = try await makeRecoveryFixture()
        let first = try makeThread(f, title: "First chat")
        let second = try makeThread(f, title: "Second chat")
        let firstRequest = request(first)
        let secondRequest = request(second)
        let firstPlan = try unwrapPlan(try await f.resolver.prepare(firstRequest) { _ in })
        let secondPlan = try unwrapPlan(try await f.resolver.prepare(secondRequest) { _ in })
        await firstPlan.finish(.completed).value
        f.registry.endRun(runID: firstRequest.runId)

        let resynchronized = try await f.resolver.resynchronizeGuest(secondRequest)
        XCTAssertTrue(resynchronized)
        XCTAssertEqual(f.registry.active(botID: f.bot.id)?.runID, secondRequest.runId)
        let copy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            f.guestDistillHome.appendingPathComponent("claude-auth.json"))) as? [String: Any])
        XCTAssertEqual(copy["refresh_token"] as? String, "")
        await secondPlan.finish(.completed).value
        f.registry.endRun(runID: secondRequest.runId)
    }

    func test_resynchronizeGuestCancelledTaskThrowsBeforeCredentialWrite() async throws {
        let f = try await makeRecoveryFixture()
        let thread = try makeThread(f)
        let req = request(thread)
        let plan = try unwrapPlan(try await f.resolver.prepare(req) { _ in })
        defer {
            plan.finish(.completed)
            f.registry.endRun(runID: req.runId)
        }
        let copyURL = f.guestDistillHome.appendingPathComponent("claude-auth.json")
        try FileManager.default.removeItem(at: copyURL)
        let task = Task {
            try await f.resolver.resynchronizeGuest(req)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled resynchronization must throw before writing credentials")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
        }
    }

    func test_twoBotsShareOneVMAndRunTogether() async throws {
        let f = try await makeFixture()
        let machine = try f.ctx.botStore.saveVirtualMachine(name: "Shared")
        let peer = try f.ctx.botStore.create(name: "Peer", title: "", description: "", desktopKind: .dockerDesktop)
        try f.ctx.botStore.setExecutionDestination(.virtualMachine(machine.id), botID: f.bot.id)
        try f.ctx.botStore.setExecutionDestination(.virtualMachine(machine.id), botID: peer.id)
        try FileManager.default.createDirectory(
            at: BotComputerGuestSpec.guestHomeURL(appSupport: f.appSupport, botID: machine.storageID),
            withIntermediateDirectories: true)
        let first = try makeThread(f, title: "First")
        let second = AgentThread(title: "Second", provider: .distill, model: "claude/claude-sonnet-4-5")
        try f.ctx.threadRepo.upsert(second)
        try f.ctx.threadRepo.setActor(id: second.id, actor: .bot(peer.id), lockedAt: Date(), executionTarget: .vm)
        try f.ctx.threadRepo.setGuestRuntime(id: second.id, BotGuestRuntime.distillV1)
        let plan = try unwrapPlan(try await f.resolver.prepare(request(first)) { _ in })
        let peerPlan = try unwrapPlan(try await f.resolver.prepare(request(second)) { _ in })
        XCTAssertEqual(f.vm.calls.map(\.botID), [machine.storageID, machine.storageID])
        await plan.finish(.completed).value
        await peerPlan.finish(.completed).value
    }

    func test_aRebuildHoldingTheVMRefusesANewRun() async throws {
        // WHY: a rebuild replaces the container; a run started on it would be
        // stopped with the old container.
        let f = try await makeFixture()
        let thread = try makeThread(f, title: "Chat")
        let build = BotVMRunRegistry.Entry(threadID: AgentThreadID(), runID: AgentRunID(),
            title: "Linux desktop rebuild", workspace: "", exclusive: true)
        XCTAssertNil(f.registry.tryBegin(botID: f.bot.id, entry: build))
        do {
            _ = try await f.resolver.prepare(request(thread)) { _ in }
            XCTFail("no run during a rebuild")
        } catch {
            XCTAssertEqual(error as? DistillGuestLaunchError, .busy("The VM is busy in Linux desktop rebuild"))
        }
        XCTAssertTrue(f.vm.calls.isEmpty)
    }

    func test_guestRunsWaitForLaunchCleanupBeforeClaimingTheBot() async throws {
        // WHY (M5): launch cleanup deletes leftover sign-in copies and env
        // files; a run that started first would lose its own.
        let f = try await makeFixture(openBarrier: false)
        let thread = try makeThread(f)
        let run = Task { try await f.resolver.prepare(self.request(thread)) { _ in } }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(f.vm.calls.count, 0)
        XCTAssertNil(f.registry.active(botID: f.bot.id))
        await f.barrier.open()
        let plan = try unwrapPlan(try await run.value)
        await plan.finish(.completed).value
    }

    // MARK: - Stop while preparing

    func test_stopWhileTheVMIsStarting_copiesNoSignIn_writesNothing_andFreesTheBot() async throws {
        // WHY (AGENTS.md loading rules): a stopped send must not go on to
        // renew sign-ins, copy them into the guest, mint a gateway token and
        // spawn an agent minutes later (an image build), nor keep the bot's
        // lease so the next send waits on a run nobody wants.
        let f = try await makeFixture()
        let thread = try makeThread(f)
        let permit = AgentRunAcceptancePermit()
        let req = request(thread, permit: permit)
        let gate = DispatchSemaphore(value: 0)
        f.vm.gate = gate
        let run = Task { try await f.resolver.prepare(req) { _ in } }
        try await waitUntil { f.vm.calls.count == 1 }
        permit.invalidate() // what the coordinator's Stop does to a pending start
        gate.signal()
        do {
            let plan = try await run.value
            XCTFail("a stopped run must not get a launch plan")
            await plan?.finish(.cancelled).value
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(f.refreshes.values.isEmpty, "no sign-in renewal for a stopped run")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.guestDistillHome.appendingPathComponent("config.toml").path))
        try await assertNothingLeft(f, req)

        // Positive control: the same thread runs normally afterwards.
        _ = f.registry.releaseAndNextWaiting(runID: req.runId)
        f.vm.gate = nil
        let plan = try unwrapPlan(try await f.resolver.prepare(request(thread)) { _ in })
        await plan.finish(.completed).value
    }

    func test_stopWhileWaitingForLaunchCleanup_endsTheWaitWithoutClaimingTheBot() async throws {
        let f = try await makeFixture(openBarrier: false)
        let thread = try makeThread(f)
        let permit = AgentRunAcceptancePermit()
        let run = Task { try await f.resolver.prepare(self.request(thread, permit: permit)) { _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        permit.invalidate()
        let ended = OSAllocatedUnfairLock(initialState: false)
        Task { _ = try? await run.value; ended.withLock { $0 = true } }
        try await waitUntil(timeout: 2) { ended.withLock { $0 } } // fails: Stop did not end the wait
        if !ended.withLock({ $0 }) { await f.barrier.open() }
        do {
            let plan = try await run.value
            XCTFail("a stopped run must not get a launch plan")
            await plan?.finish(.cancelled).value
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(f.vm.calls.count, 0)
        XCTAssertNil(f.registry.active(botID: f.bot.id), "a run stopped before the barrier never claims the bot")
    }

    // MARK: - Guest-owned directories

    func test_aGuestSwappingItsDistillFolderForASymlink_neverGetsTheConfigWrittenIntoAMacFolder() async throws {
        // WHY: the guest owns `~/.distill`. A leftover guest process can flip
        // it between a folder and a symlink to a Mac folder (the user's own
        // ~/.distill, ~/.codex, ...); a config write that follows it would
        // replace the Mac's config.toml.
        let f = try await makeFixture()
        let thread = try makeThread(f)
        let victim = root.appendingPathComponent("mac-victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let distill = f.guestDistillHome.path
        let link = f.guestHome.appendingPathComponent("link").path
        try FileManager.default.createDirectory(atPath: distill, withIntermediateDirectories: true)
        XCTAssertEqual(symlink(victim.path, link), 0)
        // The attacker's primitive: atomically exchange the folder and the
        // symlink (Linux renameat2 RENAME_EXCHANGE; RENAME_SWAP here).
        let stop = OSAllocatedUnfairLock(initialState: false)
        let flipper = Thread {
            while !stop.withLock({ $0 }) {
                guard renamex_np(link, distill, UInt32(RENAME_SWAP)) == 0 else { continue }
                usleep(50)
                renamex_np(link, distill, UInt32(RENAME_SWAP))
                usleep(50)
            }
        }
        flipper.start()
        var plans = 0
        for _ in 0..<60 {
            let req = request(thread)
            if let plan = try? await f.resolver.prepare(req, progress: { _ in }) {
                plans += 1
                await plan.finish(.completed).value
            }
            _ = f.registry.releaseAndNextWaiting(runID: req.runId)
        }
        stop.withLock { $0 = true }
        while !flipper.isFinished { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertGreaterThan(plans, 0, "positive control: runs still prepare while the folder is real")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: victim.path), [],
                       "nothing the guest run writes may land in a Mac folder (\(plans) runs prepared)")
    }

    func test_aGuestSwappingItsLeaseFolderForASymlink_neverMakesTheMacWriteOrDeleteThere() async throws {
        // WHY: the agent owns `~/.rc-runs` during its run. Renewals, Stop and
        // the launch sweep must not create or delete `*.lease` files in a Mac
        // folder it points that name at.
        let f = try await makeFixture()
        let thread = try makeThread(f)
        let req = request(thread)
        let plan = try unwrapPlan(try await f.resolver.prepare(req) { _ in })
        let victim = root.appendingPathComponent("mac-victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let runLease = "\(req.runId.value.uuidString.lowercased()).lease"
        try "mine\n".write(to: victim.appendingPathComponent(runLease), atomically: true, encoding: .utf8)
        try "mine\n".write(to: victim.appendingPathComponent("other.lease"), atomically: true, encoding: .utf8)
        let leases = f.guestHome.appendingPathComponent(".rc-runs", isDirectory: true)
        try FileManager.default.removeItem(at: leases)
        try FileManager.default.createSymbolicLink(at: leases, withDestinationURL: victim)

        try await Task.sleep(nanoseconds: 300_000_000) // several 50 ms renewals
        await plan.finish(.completed).value
        BotGuestLaunchSweep.removeLeftovers(appSupport: f.appSupport)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: victim.path).sorted(),
                       ["other.lease", runLease].sorted())
        for name in ["other.lease", runLease] {
            XCTAssertEqual(try String(contentsOf: victim.appendingPathComponent(name), encoding: .utf8), "mine\n",
                           "\(name) was rewritten through the guest's symlink")
        }
    }

    func test_aSymlinkedLeaseFolderFailsTheRunClosed() async throws {
        // Positive control for the run itself: with no lease the guest
        // reaper would end the agent, so the start fails instead.
        let f = try await makeFixture()
        let thread = try makeThread(f)
        let victim = root.appendingPathComponent("mac-victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: f.guestHome.appendingPathComponent(".rc-runs"), withDestinationURL: victim
        )
        let req = request(thread)
        await assertUnavailable(containing: "") {
            _ = try await f.resolver.prepare(req) { _ in }
        }
        try await assertNothingLeft(f, req)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: victim.path), [])
    }

    // MARK: - Launch sweep and quit (S10)

    func test_launchSweep_endsLeftoversOnlyInRunningContainersOfThisAppsOwnBots() throws {
        // WHY: an agent left running by a crashed session keeps executing with
        // the user's sign-ins until something ends it, and a `bash -lc` whose
        // `docker exec` client died with the app keeps driving the bot's
        // desktop. The Docker daemon is shared with the user's installed app
        // (and other sandboxes), whose live runs must never be killed: only
        // containers named and labelled for this database's bots, with their
        // home bound from this app's Application Support, are touched, by
        // kill-agent AND by the root `bash -lc` reap.
        let appSupport = root.appendingPathComponent("support-a", isDirectory: true)
        let otherSupport = root.appendingPathComponent("support-b", isDirectory: true)
        let crashed = BotID(), cleanQuit = BotID(), macOrphan = BotID(), killFails = BotID(), swappedLeases = BotID()
        let stopped = BotID(), copiedDB = BotID(), relabelled = BotID(), noGuestHome = BotID()
        let foreign = BotID()
        let docker = SweepDocker()
        func name(_ bot: BotID) -> String { BotComputerGuestSpec.containerName(botID: bot) }
        func add(_ bot: BotID, running: Bool = true, label: BotID? = nil, support: URL? = nil, shells: Bool = true) {
            docker.containers[name(bot)] = BotComputerContainerInspect(
                running: running, imageID: "img", hostPort: 0,
                labels: [BotComputerGuestSpec.botIDLabelKey: (label ?? bot).value.uuidString.lowercased()],
                homeSource: BotComputerGuestSpec.guestHomeURL(appSupport: support ?? appSupport, botID: bot).path
            )
            if shells { docker.tops[name(bot)] = "PID CMD\n42 bash -lc sleep 999" }
        }
        func home(_ bot: BotID, lease: Bool = false) throws {
            let home = BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: bot)
            let leases = home.appendingPathComponent(".rc-runs", isDirectory: true)
            try FileManager.default.createDirectory(at: leases, withIntermediateDirectories: true)
            if lease { try Data().write(to: leases.appendingPathComponent("\(UUID().uuidString.lowercased()).lease")) }
        }
        add(crashed); try home(crashed, lease: true)
        add(cleanQuit, shells: false); try home(cleanQuit)
        add(macOrphan); try home(macOrphan) // a Mac-hosted bot_exec shell, no guest run
        add(killFails); try home(killFails, lease: true)
        add(swappedLeases, shells: false)
        try FileManager.default.createDirectory(
            at: BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: swappedLeases), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: swappedLeases).appendingPathComponent(".rc-runs"),
            withDestinationURL: root
        )
        add(stopped, running: false); try home(stopped, lease: true)
        add(copiedDB, support: otherSupport); try home(copiedDB, lease: true) // same bot id, the other app's container
        add(relabelled, label: BotID()); try home(relabelled, lease: true)
        add(noGuestHome)
        add(foreign) // a bot of the other app's database
        docker.failingExecs = [name(killFails)]

        let swept = BotGuestLaunchSweep.endLeftoverRuns(
            docker: docker, appSupport: appSupport,
            botIDs: [killFails, crashed, cleanQuit, macOrphan, swappedLeases, stopped, copiedDB, relabelled, noGuestHome]
        )

        XCTAssertEqual(swept, [name(crashed), name(swappedLeases)],
                       "a container whose kill-agent fails does not stop the sweep")
        let killAgent = [BotComputerGuestSpec.killAgentPath, "--all"]
        let reap = ["pkill", "-f", "bash -lc"]
        XCTAssertEqual(docker.execs.map { [$0.name] + $0.command + [$0.user ?? ""] }, [
            [name(killFails)] + killAgent + [BotComputerGuestSpec.agentUser],
            [name(killFails)] + reap + ["root"],
            [name(crashed)] + killAgent + [BotComputerGuestSpec.agentUser],
            [name(crashed)] + reap + ["root"],
            [name(macOrphan)] + reap + ["root"],
            [name(swappedLeases)] + killAgent + [BotComputerGuestSpec.agentUser],
        ], """
            kill-agent runs as the guest user (root cannot read another user's run tags) and only where a \
            lease survived (crash) or cannot be read safely; a clean quit leaves none, so its container costs \
            no exec; the root reap runs after it, only where a `bash -lc` is left
            """)
        for other in [stopped, copiedDB, relabelled] {
            XCTAssertFalse(docker.topped.contains(name(other)), "\(name(other)) is not this app's live container")
        }
        XCTAssertFalse(docker.inspected.contains(name(foreign)), "the other app's bots are not even looked at")
        XCTAssertFalse(docker.inspected.contains(name(noGuestHome)), "no guest home here: no Docker call at all")

        // Docker down: no container runs, nothing to end, no exec attempted.
        let down = SweepDocker()
        down.infoFails = true
        XCTAssertEqual(BotGuestLaunchSweep.endLeftoverRuns(docker: down, appSupport: appSupport, botIDs: [crashed]), [])
        XCTAssertTrue(down.inspected.isEmpty)
    }

    func test_launchSweep_endsLeftoversBeforeDeletingTheirSignInCopies_andOnlyThenAdmitsGuestRuns() async throws {
        // WHY (M5): a leftover agent must be dead before its copies go (it
        // would otherwise run on, then fail mid-turn), and a new run must not
        // start until the sweep is done: the root `bash -lc` reap would kill
        // the new run's tool shells, and the file cleanup would delete what it
        // just wrote.
        let f = try await makeFixture(openBarrier: false)
        try await f.ctx.botGuestLaunchBarrier.wait() // the context's own launch sweep is done
        let copy = f.guestDistillHome.appendingPathComponent("claude-auth.json")
        try FileManager.default.createDirectory(at: f.guestDistillHome, withIntermediateDirectories: true)
        try #"{"access_token":"stale","refresh_token":""}"#.write(to: copy, atomically: true, encoding: .utf8)
        let leases = f.guestHome.appendingPathComponent(".rc-runs", isDirectory: true)
        try FileManager.default.createDirectory(at: leases, withIntermediateDirectories: true)
        try Data().write(to: leases.appendingPathComponent("\(UUID().uuidString.lowercased()).lease")) // the crash's
        let docker = SweepDocker()
        let container = BotComputerGuestSpec.containerName(botID: f.bot.id)
        docker.containers[container] = BotComputerContainerInspect(
            running: true, imageID: "img", hostPort: 0,
            labels: [BotComputerGuestSpec.botIDLabelKey: f.bot.id.value.uuidString.lowercased()],
            homeSource: f.guestHome.path
        )
        docker.tops[container] = "PID CMD\n42 bash -lc sleep 999"
        let reaping = DispatchSemaphore(value: 0)
        let copyAtExec = Recorder<Bool>()
        docker.onExec = { command in
            copyAtExec.append(FileManager.default.fileExists(atPath: copy.path))
            if command.first == "pkill" { reaping.wait() } // hold the sweep inside the root reap
        }
        let thread = try makeThread(f)
        let run = Task { try await f.resolver.prepare(self.request(thread)) { _ in } }
        let sweep = Thread {
            BotGuestLaunchSweep.run(docker: docker, appSupport: f.appSupport, botIDs: [f.bot.id], barrier: f.barrier)
        }
        sweep.start()

        try await waitUntil { docker.execs.count == 2 }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(docker.execs.map(\.command), [[BotComputerGuestSpec.killAgentPath, "--all"], ["pkill", "-f", "bash -lc"]])
        XCTAssertEqual(copyAtExec.values, [true, true], "the agent and its shells are ended while its copies still exist")
        XCTAssertEqual(f.vm.calls.count, 0, "no guest run starts while the root reap can still kill its shells")
        XCTAssertNil(f.registry.active(botID: f.bot.id))
        reaping.signal()

        let plan = try unwrapPlan(try await run.value)
        XCTAssertEqual(f.vm.calls.count, 1)
        let fresh = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: copy)) as? [String: Any])
        XCTAssertEqual(fresh["access_token"] as? String, "at-1", "the new run's copy is written after the sweep, never deleted by it")
        await plan.finish(.completed).value
    }

    func test_launchSweepReportsMalformedContextLineageWithPhysicalRecoveryEmpty() async throws {
        let appSupport = root.appendingPathComponent("support", isDirectory: true)
        let db = try SQLiteDB(path: root.appendingPathComponent("bots.sqlite").path)
        try Schema.migrate(db)
        try db.execute("INSERT INTO bot_context_delegations(child_run_id, parent_run_id, payload_json, closed) VALUES('bad-child', 'bad-parent', 'not-json', 0);")
        let store = BotStore(db: db)
        let barrier = DistillGuestLaunchBarrier()

        let report = BotGuestLaunchSweep.run(
            docker: nil, appSupport: appSupport, botIDs: [], barrier: barrier, contextStore: store
        )

        XCTAssertNotNil(report.failures["context-lineage"])
        XCTAssertTrue(report.reconciled.isEmpty)
        XCTAssertTrue(report.failures.keys.allSatisfy { $0 == "context-lineage" })
        try await barrier.wait()
    }

    func test_launchSweep_trimsTheGuestDistillCacheBeforeAdmittingGuestRuns() async throws {
        // WHY: the cache trim deletes old guest builds. A run admitted before
        // it finished could be handed the path of a build the trim then
        // deletes, so the barrier must open only after it.
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-launch-trim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let barrier = DistillGuestLaunchBarrier()
        let trimmed = Recorder<Bool>()
        BotGuestLaunchSweep.run(docker: nil, appSupport: appSupport, botIDs: [], barrier: barrier, beforeOpening: {
            try? await Task.sleep(nanoseconds: 150_000_000)
            trimmed.append(true)
        })
        try await barrier.wait()
        XCTAssertEqual(trimmed.values, [true], "guest runs were admitted before the cache trim finished")
    }

    func test_quit_endsALiveGuestRun_deletesItsSignInCopyEnvFileAndLease_andNothingIsCopiedAgain() async throws {
        // WHY: after quit nothing renews the sign-in copies or the lease; the
        // agent must not keep running with the user's accounts, and the copies
        // must not sit in the guest-readable home until the next launch.
        let f = try await makeFixture()
        try await f.ctx.botGuestLaunchBarrier.wait() // the context's own launch sweep is done
        let log = root.appendingPathComponent("docker.log")
        let fakeDocker = root.appendingPathComponent("fake-docker")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\n".write(to: fakeDocker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDocker.path)
        var deps = f.deps
        deps.dockerExecutable = { fakeDocker.path }
        let resolver = BotGuestRunResolver(deps)
        let req = request(try makeThread(f))
        let plan = try unwrapPlan(try await resolver.prepare(req) { _ in })
        let copy = f.guestDistillHome.appendingPathComponent("claude-auth.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "positive control: the live run has its copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.envFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: leaseFile(f, req.runId).path))

        // The resolver kills it itself: a run whose turn is still ending is
        // no longer in the adapter's sessions, which the adapter's quit kill
        // walks.
        resolver.endRunsForAppTermination()

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.envFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseFile(f, req.runId).path))
        let runID = req.runId.value.uuidString.lowercased()
        try await waitUntil { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains(runID) }
        plan.killGuestDetached() // the adapter's own quit kill of the same run: no second docker call
        // A Mac renewal right after quit must not re-copy the sign-in.
        try #"{"access_token":"at-2","refresh_token":"rt-host-only","expires_at":4102444800000}"#
            .write(to: f.hostHome.appendingPathComponent("claude-auth.json"), atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 900_000_000) // past the mirror's 0.5 s debounce
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "exec -d -u remotecode remotecode-bot-test \(BotComputerGuestSpec.killAgentPath) \(runID)\n")
        await plan.finish(.cancelled).value
    }

    func test_quitOfAProcessThatHostsNoGuestRuns_leavesTheAppsLiveRunsAlone() async throws {
        // WHY: the scheduled-task agent shares this Application Support; its
        // exit must not delete the sign-in copies of the app's live runs.
        let f = try await makeFixture()
        let req = request(try makeThread(f))
        let plan = try unwrapPlan(try await f.resolver.prepare(req) { _ in })
        var deps = f.deps
        deps.hostsGuestRuns = false
        BotGuestRunResolver(deps).endRunsForAppTermination()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.guestDistillHome.appendingPathComponent("claude-auth.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.envFileURL.path))
        await plan.finish(.completed).value
    }

    // MARK: - Coordinator placement

    func test_aGuestThreadOnAnotherProviderFailsBeforeAnythingIsRecordedOrSpawned() async throws {
        // WHY (B4): only Distill runs in the guest. A guest thread switched to
        // another provider (picker, Auto routing) would otherwise run on the
        // Mac while it claims to run in the VM.
        let f = try await makeFixture()
        let runner = ControlledBotHandoffRunner(provider: .codex)
        f.ctx.coordinator.replaceProviderAdapter(.codex, adapter: TerminalRetiringOneShotAdapter(runner: runner))
        let thread = try f.router.createAgentThread(
            workspace: f.workspace.id, title: "Codex chat", provider: .codex, model: "fake-model",
            permissionMode: .supervised, reasoningEffort: .medium
        )
        XCTAssertTrue(try f.ctx.threadRepo.setActor(id: thread.id, actor: .bot(f.bot.id), lockedAt: Date(), executionTarget: .vm))
        XCTAssertTrue(try f.ctx.threadRepo.setGuestRuntime(id: thread.id, BotGuestRuntime.distillV1))
        let blocked = AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: f.workspace.cwd, prompt: "hi"
        )
        do {
            _ = try await f.ctx.coordinator.startRun(blocked)
            XCTFail("a non-Distill run of a guest thread must fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("only runs Distill"), "\(error)")
        }
        XCTAssertTrue(runner.requests.isEmpty, "nothing spawned")
        XCTAssertNil(try f.ctx.runRepo.status(of: blocked.runId), "no run recorded")

        // Positive control: the same send runs once the thread is not a guest thread.
        XCTAssertTrue(try f.ctx.threadRepo.setGuestRuntime(id: thread.id, nil))
        _ = try await f.ctx.coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: f.workspace.cwd, prompt: "hi"
        ))
        XCTAssertEqual(runner.requests.count, 1)
    }

    // MARK: - cwd rules

    func test_guestCwdRules() throws {
        let mount = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: mount + "/src", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: mount + "/.git", withIntermediateDirectories: true)
        XCTAssertEqual(try BotGuestRunResolver.guestCwd(requestCwd: "/anywhere", workspace: nil, mounted: []),
                       BotComputerGuestSpec.guestUserHome)
        XCTAssertEqual(try BotGuestRunResolver.guestCwd(requestCwd: mount, workspace: mount, mounted: [mount]), mount)
        XCTAssertEqual(try BotGuestRunResolver.guestCwd(requestCwd: mount + "/src", workspace: mount, mounted: [mount]),
                       mount + "/src")
        // A sibling sharing the prefix is not inside the mount.
        try FileManager.default.createDirectory(atPath: mount + "-other", withIntermediateDirectories: true)
        XCTAssertThrowsError(try BotGuestRunResolver.guestCwd(requestCwd: mount + "-other", workspace: mount, mounted: [mount]))

        // A linked worktree inside the mount whose repository is elsewhere.
        let worktree = mount + "/wt"
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let foreignGitDir = root.appendingPathComponent("other-repo/.git/worktrees/wt").path
        try "gitdir: \(foreignGitDir)\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BotGuestRunResolver.guestCwd(requestCwd: worktree, workspace: mount, mounted: [mount])) {
            XCTAssertTrue(String(describing: $0).contains("git worktree"))
        }
        // Its repository is the mounted one: fine.
        try "gitdir: ../.git/worktrees/wt\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        XCTAssertEqual(try BotGuestRunResolver.guestCwd(requestCwd: worktree, workspace: mount, mounted: [mount]), worktree)
    }

    // MARK: - Helpers

    private func assertNothingLeft(_ f: Fixture, _ req: AgentRunRequest) async throws {
        let leaseHeld = await f.leases.isHeld(f.bot.id.value.uuidString.lowercased())
        XCTAssertFalse(leaseHeld, "a failed start must not keep the bot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: envFile(f, req.runId).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.guestDistillHome.appendingPathComponent("claude-auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseFile(f, req.runId).path))
    }

    private func assertUnavailable(
        containing text: String,
        _ body: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected the guest run to fail", file: file, line: line)
        } catch let error as DistillGuestLaunchError {
            guard case .unavailable(let reason) = error else {
                return XCTFail("unexpected \(error)", file: file, line: line)
            }
            if !text.isEmpty { XCTAssertTrue(reason.contains(text), reason, file: file, line: line) }
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func posixMode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0) & 0o777
    }

    private func inode(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int ?? 0
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func unwrapPlan(_ plan: DistillGuestLaunchPlan?) throws -> DistillGuestLaunchPlan {
        try XCTUnwrap(plan, "expected a guest launch plan")
    }
}

private final class FakeGuestVM: BotGuestVMPreparing, @unchecked Sendable {
    struct Call { let botID: BotID; let workspace: String? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var error: Error?
    var gate: DispatchSemaphore?
    var onPrepare: (() -> Void)?
    var container = "remotecode-bot-test"

    var calls: [Call] { lock.withLock { recorded } }

    func prepare(
        botID: BotID, threadID: AgentThreadID, workspace: String?, registeredWorkspaces: Set<String>
    ) throws -> BotGuestVM {
        let (gate, error, onPrepare) = lock.withLock { () -> (DispatchSemaphore?, Error?, (() -> Void)?) in
            recorded.append(Call(botID: botID, workspace: workspace))
            return (self.gate, self.error, self.onPrepare)
        }
        onPrepare?()
        gate?.wait()
        if let error { throw error }
        return BotGuestVM(container: container, dockerArch: "aarch64", mountedWorkspaces: workspace.map { [$0] } ?? [])
    }
}

/// Docker for the launch sweep: containers by name, exec recording.
private final class SweepDocker: BotComputerDockerClienting, @unchecked Sendable {
    struct Exec { let name: String; let command: [String]; let user: String? }
    private let lock = NSLock()
    var containers: [String: BotComputerContainerInspect] = [:]
    var failingExecs: Set<String> = []
    var infoFails = false
    var tops: [String: String] = [:]
    var onExec: (([String]) -> Void)?
    private var recordedExecs: [Exec] = []
    private var recordedInspects: [String] = []
    private var recordedTops: [String] = []
    var execs: [Exec] { lock.withLock { recordedExecs } }
    var inspected: [String] { lock.withLock { recordedInspects } }
    var topped: [String] { lock.withLock { recordedTops } }

    func info() throws -> String {
        if infoFails { throw BotComputerDockerError.daemonUnavailable }
        return "Architecture: aarch64"
    }
    func inspect(name: String) throws -> BotComputerContainerInspect {
        lock.withLock { recordedInspects.append(name) }
        guard let container = containers[name] else { throw BotComputerDockerError.provisioningFailed }
        return container
    }
    func exec(name: String, command: [String], user: String?, detach: Bool, workdir: String?, environment: [String: String]) throws -> Data {
        lock.withLock { recordedExecs.append(Exec(name: name, command: command, user: user)) }
        onExec?(command)
        if failingExecs.contains(name) { throw BotComputerDockerError.provisioningFailed }
        return Data()
    }
    func imageExists(tag: String) throws -> Bool { true }
    func imageLabel(tag: String, key: String) throws -> String { "" }
    func imageID(tag: String) throws -> String { "" }
    func build(context: URL, tag: String) throws {}
    func create(options: BotComputerContainerCreateOptions) throws -> String { "" }
    func start(name: String) throws {}
    func stop(name: String) throws {}
    func rename(from: String, to: String) throws {}
    func ensureNetwork(name: String) throws {}
    func remove(name: String) throws { XCTFail("the launch sweep never removes a container") }
    func removeMatching(namePrefix: String) throws { XCTFail("the launch sweep never removes a container") }
    func top(name: String) throws -> String {
        lock.withLock { recordedTops.append(name) }
        return tops[name] ?? "PID CMD\n1 supervisord"
    }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}
