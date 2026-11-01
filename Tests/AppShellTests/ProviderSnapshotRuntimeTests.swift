import XCTest
@testable import AppShell
@testable import CoreModel
@testable import AgentRuntime
@testable import Persistence
@testable import SocketServer
@testable import Surfaces

@MainActor
final class ProviderSnapshotRuntimeTests: XCTestCase {
    // Legacy-provider machinery is still exercised here; Distill-only rules run with the seam cleared.
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    private static let ownershipLedger = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-snapshot-tests-\(UUID().uuidString).json")

    override func setUp() {
        super.setUp()
        ProviderProcessOwnership.shared.configure(fileURL: Self.ownershipLedger)
    }

    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    /// Distill is the only provider RemoteCode ships, and its send preflight
    /// refuses a signed-out snapshot, so Distill queue fixtures seed a signed-in one.
    private func rememberSignedInSnapshot(_ provider: AgentProvider, router: AppCommandRouter) {
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "test-model", label: "Test Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        ])
    }

    private func isTerminal(_ status: AgentRunStatus?) -> Bool {
        switch status {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        case .pending, .running, nil:
            return false
        }
    }

    /// WHY: Auto admission and sudo -u spawn must resolve the same Claude binary
    /// for a foreign run-as-user (Settings absolute path + target home).
    func test_resolveProviderBinaryPathUsesForeignRunAsUserHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-runas-probe-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = bin.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: claude.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        let foreign = AgentRunAsUser(
            generatedUID: "test-foreign",
            shortName: "airtonempat",
            uid: 1501,
            gid: 20,
            homePath: root.path,
            fullName: "Airton"
        )
        // Only foreign when uid differs from process owner.
        XCTAssertNotEqual(foreign.uid, getuid())
        let path = AppCommandRouter.resolveProviderBinaryPath(binary: "claude", runAsUser: foreign)
        XCTAssertEqual(path, claude.path)
        // Absolute Settings path under another home stays usable for foreign run-as-user.
        XCTAssertEqual(
            AppCommandRouter.resolveProviderBinaryPath(binary: claude.path, runAsUser: foreign),
            claude.path
        )

        let current = AgentRunAsUser.current()
        let env = AppCommandRouter.probeEnvironment(
            base: ["PATH": "/usr/bin"],
            provider: .claude,
            runAsUser: foreign
        )
        XCTAssertEqual(env["HOME"], root.path, "foreign probe must force HOME to the target user")
        let currentEnv = AppCommandRouter.probeEnvironment(
            base: ["PATH": "/usr/bin"],
            provider: .claude,
            runAsUser: current
        )
        XCTAssertNil(currentEnv["HOME"], "current-user probe must not rewrite HOME")
    }

    func test_claudeLegacyFallbackPresentationFailsClosed() throws {
        let presentation = ClaudeProviderRuntimePresentation.resolve(
            agentSDKEnabled: false,
            probeAdvisory: "Update available."
        )

        XCTAssertEqual(presentation.interactionModes, [.default])
        XCTAssertEqual(presentation.permissionModes, [.supervised])
        let capabilities = try XCTUnwrap(presentation.capabilities)
        XCTAssertFalse(capabilities.supportsAttachments)
        XCTAssertFalse(capabilities.supportsApprovals)
        XCTAssertFalse(capabilities.supportsUserInput)
        XCTAssertTrue(capabilities.supportsStreaming,
                      "the legacy CLI still streams assistant text even though agent tools are disabled")
        XCTAssertTrue(presentation.advisory?.contains("Degraded text-only fallback") == true)
        XCTAssertTrue(presentation.advisory?.contains("Update available.") == true,
                      "degraded-state copy must preserve an independent CLI update warning")
    }

    func test_grokSkillsRootUsesGrokHomeAsTheConfigRoot() {
        XCTAssertEqual(
            AppCommandRouter.providerSkillsRoot(
                provider: .grok,
                environment: ["GROK_HOME": "/opt/team-grok", "HOME": "/Users/example"],
                defaultHome: "/Users/fallback"
            ).path,
            "/opt/team-grok/skills",
            "GROK_HOME already names the Grok config root; appending .grok again makes configured skills unreachable"
        )
    }

    func test_grokSkillsRootFallsBackToHomeDotGrok() {
        XCTAssertEqual(
            AppCommandRouter.providerSkillsRoot(
                provider: .grok,
                environment: ["HOME": "/Users/example"],
                defaultHome: "/Users/fallback"
            ).path,
            "/Users/example/.grok/skills",
            "without GROK_HOME, Grok skills must follow the CLI default under HOME/.grok/skills"
        )
    }

    func test_providerSnapshotsAdvertiseForkOnlyWhenExactProviderProtocolProbesPass() async throws {
        // WHY: generic provider capabilities or the presence of thread/fork are
        // insufficient. The selected Codex executable must prove marker, list,
        // parent-attribution, and delete compensation schema before UI exposure.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router

        var probedBinary = ""
        var probedEnvironment: [String: String] = [:]
        router.codexForkProtocolSupportProbe = { binary, environment in
            probedBinary = binary
            probedEnvironment = environment
            return true
        }
        router.claudeForkProtocolSupportProbe = { true }
        let supported = await router.listAgentProviderSnapshots()
        let codex = try XCTUnwrap(supported.first { $0.provider == .codex })
        XCTAssertTrue(codex.effectiveCapabilities.supportsFork)
        XCTAssertTrue(codex.slashCommands.contains("/fork"))
        XCTAssertEqual(probedBinary, codex.binaryPath ?? "",
                       "fork support must be probed against the exact executable advertised by the snapshot")
        XCTAssertEqual(probedEnvironment, [:])
        let claude = try XCTUnwrap(supported.first { $0.provider == .claude })
        XCTAssertTrue(claude.effectiveCapabilities.supportsFork,
                      "Claude fork is exposed only after the pinned bridge and installed SDK declaration probe succeeds")
        XCTAssertFalse(try XCTUnwrap(supported.first { $0.provider == .grok }).effectiveCapabilities.supportsFork)

        router.codexForkProtocolSupportProbe = { _, _ in false }
        router.claudeForkProtocolSupportProbe = { false }
        let unsupported = await router.listAgentProviderSnapshots()
        let oldCodex = try XCTUnwrap(unsupported.first { $0.provider == .codex })
        XCTAssertFalse(oldCodex.effectiveCapabilities.supportsFork,
                       "older or partial Codex schemas must fail closed")
        XCTAssertFalse(oldCodex.slashCommands.contains("/fork"))
        let oldClaude = try XCTUnwrap(unsupported.first { $0.provider == .claude })
        XCTAssertFalse(oldClaude.effectiveCapabilities.supportsFork,
                       "missing or mismatched Claude SDK fork declarations must fail closed")
    }

    func test_grokProviderSnapshotAndComposerDiscoverPhysicalSkillUnderGrokHome() async throws {
        // WHY: GROK_HOME already is Grok's config root. A path-only assertion
        // misses regressions where discovery or composer plumbing still reads
        // GROK_HOME/.grok/skills or labels a Grok skill as Codex-owned.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let grokHome = dir.appendingPathComponent("grok-home", isDirectory: true)
        let skillDir = grokHome.appendingPathComponent("skills/team-research", isDirectory: true)
        let wrongSkillDir = grokHome.appendingPathComponent(".grok/skills/wrong-root", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wrongSkillDir, withIntermediateDirectories: true)
        try "# Team Research\n".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "# Wrong Root\n".write(to: wrongSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let fakeGrok = dir.appendingPathComponent("fake-grok")
        try #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'grok-test 0.2.101\n'
          exit 0
        fi
        if [ "$1" = "models" ]; then
          printf 'You are logged in with test\n'
          exit 0
        fi
        if [ "$1" = "agent" ] && [ "$2" = "stdio" ]; then
          while IFS= read -r line; do
            id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
            if printf '%s' "$line" | grep -q '"method":"initialize"'; then
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"embeddedContext":true}}}}\n' "$id"
            elif printf '%s' "$line" | grep -q '"method":"session.*new"'; then
              printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"skills-session","models":{"currentModelId":"grok-4.5","availableModels":[{"modelId":"grok-4.5","name":"Grok 4.5"}]}}}\n' "$id"
            fi
          done
          exit 0
        fi
        exit 1
        """#.write(to: fakeGrok, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGrok.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "grok-team",
            "provider": "grok",
            "displayName": "Grok Team",
            "binaryPath": "\(fakeGrok.path)",
            "homePath": "\(grokHome.path)",
            "enabled": true
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let grok = try XCTUnwrap(snapshots.first { $0.id == "grok-team" })
        XCTAssertEqual(grok.environmentKeys, ["GROK_HOME"])
        XCTAssertEqual(grok.skills, ["team-research"],
                       "only <GROK_HOME>/skills must feed Grok composer skills")

        let suggestions = AgentComposerSuggestions.suggestions(
            for: "$team-r",
            snapshot: grok,
            localSlashCommands: []
        )
        XCTAssertEqual(suggestions.map(\.insertText), ["$team-research "])
        XCTAssertEqual(suggestions.first?.subtitle, "Grok Team skill")
    }

    func test_distillProviderSnapshotUsesACPNegotiatedModesAndCapabilities() async throws {
        // WHY: the Source picker must offer exactly what the signed-in harness
        // negotiated over ACP (models, Plan, permission modes), not the static
        // catalog. Distill is the only shipped provider; Grok's snapshot now
        // uses the static catalog, so this contract is pinned on Distill.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeDistill = dir.appendingPathComponent("fake-distill")
        try #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'distill 9.9.9\n'
          exit 0
        fi
        if [ "$1" = "agent" ]; then
          while IFS= read -r line; do
            id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
            if printf '%s' "$line" | grep -q '"method":"initialize"'; then
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":true},"sessionCapabilities":{}}}}\n' "$id"
            elif printf '%s' "$line" | grep -q '"method":"session.*new"'; then
              models='[{"modelId":"distill-negotiated","name":"Distill Negotiated","_meta":{"accountProvider":"chatgpt"}}]'
              if [ -f "$0.auto-enabled" ]; then
                models='[{"modelId":"distill-negotiated","name":"Distill Negotiated","_meta":{"accountProvider":"chatgpt"}},{"modelId":"auto","name":"Auto"},{"modelId":"new-account-model","name":"New account model","_meta":{"accountProvider":"chatgpt"}}]'
              fi
              printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"snapshot-session","models":{"currentModelId":"distill-negotiated","availableModels":%s},"modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"},{"id":"plan","name":"Plan"},{"id":"bypassPermissions","name":"Full access"}]}}}\n' "$id" "$models"
            fi
          done
          exit 0
        fi
        exit 1
        """#.write(to: fakeDistill, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDistill.path)

        let previousDistillHome = getenv("DISTILL_HOME").map { String(cString: $0) }
        setenv("DISTILL_HOME", dir.appendingPathComponent("distill-home").path, 1)
        defer {
            if let previousDistillHome { setenv("DISTILL_HOME", previousDistillHome, 1) }
            else { unsetenv("DISTILL_HOME") }
        }
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("cli.distill.path", fakeDistill.path)

        let snapshots = await router.listAgentProviderSnapshots()
        let distill = try XCTUnwrap(snapshots.first { $0.provider == .distill })

        XCTAssertEqual(distill.models.map(\.id), ["distill-negotiated"])
        XCTAssertEqual(distill.interactionModes, [.default, .plan])
        XCTAssertEqual(distill.effectivePermissionModes, [.supervised, .fullAccess],
                       "only the negotiated permission modes may be offered (acceptEdits was not advertised)")
        XCTAssertTrue(distill.effectiveCapabilities.supportsPlanReview)
        XCTAssertTrue(distill.effectiveCapabilities.supportsAttachments)
        XCTAssertTrue(distill.effectiveCapabilities.supportsApprovals)
        XCTAssertFalse(distill.effectiveCapabilities.supportsUserInput)
        XCTAssertTrue(distill.slashCommands.contains("/plan"))
        XCTAssertEqual(distill.modelDiscoverySource, .live)
        XCTAssertFalse(distill.modelListIsFallback)
        XCTAssertNotNil(distill.modelDiscoveryCacheKey,
                        "the snapshot must retain the opaque binary/account discovery identity")
        let warmedModels = await router.listAgentModels(provider: .distill)
        XCTAssertEqual(warmedModels.map(\.id), ["distill-negotiated"])
        try Data().write(to: URL(fileURLWithPath: fakeDistill.path + ".auto-enabled"))
        let stillCached = await router.listAgentProviderSnapshots()
        XCTAssertEqual(stillCached.first { $0.provider == .distill }?.models.map(\.id), ["distill-negotiated"],
                       "fixture data changes must not accidentally invalidate the binary/cwd/environment cache key")
        await router.refreshDistillProviderCatalog()
        let refreshed = await router.listAgentProviderSnapshots()
        let expectedIDs = ["distill-negotiated", "auto", "new-account-model"]
        XCTAssertEqual(refreshed.first { $0.provider == .distill }?.models.map(\.id), expectedIDs,
                       "the account/profile refresh path must bypass the warmed300-second snapshot catalog")
        XCTAssertEqual(ctx.distillAccountsController.models.map(\.id), expectedIDs,
                       "Accounts model choices must also refresh rather than depend on an earlier SwiftUI task")
        XCTAssertEqual(ctx.distillAccountsController.models.last?.accountProvider, "chatgpt")
    }

    func test_distillSnapshotKeepsFallbackCatalogMarkedAsFallbackWhenACPLaunchFails() async throws {
        // WHY: a useful static model list after ACP failure is not verified live account discovery.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeDistill = dir.appendingPathComponent("fake-distill")
        try #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'distill 0.2.101\n'
          exit 0
        fi
        exit 1
        """#.write(to: fakeDistill, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDistill.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [{"id":"distill-team","provider":"distill","binaryPath":"\(fakeDistill.path)","enabled":true}]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        XCTAssertTrue(snapshots.contains { $0.id == "distill-team" }, "configured Distill account must survive snapshot discovery; got ids: \(snapshots.map(\.id))")
        let distill = try XCTUnwrap(snapshots.first { $0.id == "distill-team" })
        XCTAssertFalse(distill.models.isEmpty, "fallback models should remain selectable while the harness is unavailable")
        XCTAssertEqual(distill.modelDiscoverySource, .builtInFallback,
                       "a nonempty fallback catalog must not be mislabeled as live discovery")
        XCTAssertTrue(distill.modelListIsFallback)
    }

    func test_providerSnapshotsUseConfiguredBinaryAndExposeVersion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fakeCodex = dir.appendingPathComponent("fake-codex")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'codex-test 9.9.9\\n'
          exit 0
        fi
        if [ "$1" = "login" ] && [ "$2" = "status" ]; then
          printf 'Logged in using ChatGPT\\n'
          exit 0
        fi
        exit 1
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("cli.codex.path", fakeCodex.path)

        let snapshots = await router.listAgentProviderSnapshots()
        let codex = try XCTUnwrap(snapshots.first { $0.provider == .codex })

        XCTAssertTrue(codex.installed)
        XCTAssertEqual(codex.version, "codex-test 9.9.9",
                       "provider cards must probe the configured binary path so settings, install state, and version state stay aligned")
        XCTAssertEqual(codex.authenticated, true,
                       "provider cards must include auth state from the configured Codex binary instead of waiting for a failed run")
    }

    func test_providerSnapshotsPreferCodexAppServerModelDiscoveryWhenAvailable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("""
        {"models":[{"slug":"gpt-6-astra","display_name":"GPT-6-Astra","visibility":"list","supported_in_api":true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}],"additional_speed_tiers":["fast"],"context_window":272000}]}
        """.utf8).write(to: home.appendingPathComponent("models_cache.json"))
        let fakeCodex = dir.appendingPathComponent("fake-codex")
        try """
        #!/usr/bin/python3
        import json, os, sys
        if len(sys.argv) > 1 and sys.argv[1] == "--version":
            print("codex-test 9.9.9")
            raise SystemExit(0)
        if len(sys.argv) > 2 and sys.argv[1:3] == ["login", "status"]:
            print("Logged in using ChatGPT")
            raise SystemExit(0)
        if len(sys.argv) > 1 and sys.argv[1] == "--help":
            print("Commands:\\n  exec\\n  review")
            raise SystemExit(0)
        if len(sys.argv) > 1 and sys.argv[1] == "app-server":
            for line in sys.stdin:
                msg = json.loads(line)
                method = msg.get("method")
                if method == "initialize":
                    print(json.dumps({"id": msg["id"], "result": {
                        "userAgent": "codex-test/9.9.9",
                        "codexHome": os.environ.get("CODEX_HOME"),
                        "platformFamily": "unix",
                        "platformOs": "macos"
                    }}), flush=True)
                elif method == "initialized":
                    pass
                elif method == "model/list":
                    print(json.dumps({"id": msg["id"], "result": {"data": [{
                        "model": "gpt-5.7-codex",
                        "displayName": "GPT-5.7 Codex",
                        "supportedReasoningEfforts": [
                            {"reasoningEffort": "low"},
                            {"reasoningEffort": "medium"},
                            {"reasoningEffort": "high"}
                        ],
                        "defaultReasoningEffort": "medium",
                        "additionalSpeedTiers": ["fast"],
                        "modelContextWindow": 512000
                    }]}}), flush=True)
            raise SystemExit(0)
        raise SystemExit(1)
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "codex-dynamic",
            "provider": "codex",
            "displayName": "Codex Dynamic",
            "binaryPath": "\(fakeCodex.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let codex = try XCTUnwrap(snapshots.first { $0.id == "codex-dynamic" })
        let model = try XCTUnwrap(codex.models.first)

        XCTAssertEqual(model.id, "gpt-5.7-codex",
                       "Codex provider snapshots should prefer app-server model/list discovery over static fallback models when available")
        XCTAssertEqual(model.supportedReasoningEfforts, [.low, .medium, .high])
        XCTAssertEqual(model.supportsServiceTier, true)
        XCTAssertEqual(model.contextWindowTokens, 512_000)
        let astra = try XCTUnwrap(codex.models.first { $0.id == "gpt-6-astra" })
        XCTAssertEqual(astra.supportedReasoningEfforts, [.low, .medium, .high, .xhigh, .max])
        XCTAssertEqual(astra.contextWindowTokens, 272_000)
        XCTAssertEqual(codex.environmentKeys, ["CODEX_HOME"])
    }

    func test_providerSnapshotsKeepSelectedAccountCacheWhenCodexAppServerInitializationFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("""
        {"models":[{"slug":"gpt-6-astra","display_name":"GPT-6-Astra","visibility":"list","supported_in_api":true}]}
        """.utf8).write(to: home.appendingPathComponent("models_cache.json"))

        let fakeCodex = dir.appendingPathComponent("fake-codex")
        try """
        #!/usr/bin/python3
        import sys
        if len(sys.argv) > 1 and sys.argv[1] == "--version":
            print("codex-test 9.9.9")
            raise SystemExit(0)
        if len(sys.argv) > 2 and sys.argv[1:3] == ["login", "status"]:
            print("Logged in using ChatGPT")
            raise SystemExit(0)
        if len(sys.argv) > 1 and sys.argv[1] == "app-server":
            raise SystemExit(1)
        raise SystemExit(1)
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "codex-selected-account",
            "provider": "codex",
            "displayName": "Codex Selected Account",
            "binaryPath": "\(fakeCodex.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let codex = try XCTUnwrap(snapshots.first { $0.id == "codex-selected-account" })

        XCTAssertTrue(codex.models.contains { $0.id == "gpt-6-astra" },
                      "a valid selected-account models_cache entry must remain selectable when live initialization fails")
        XCTAssertEqual(codex.modelDiscoverySource, .builtInFallback,
                       "same-account harness cache is selectable but must not be labeled live")
        XCTAssertNotEqual(codex.modelDiscoverySource, .live)
    }

    func test_providerSnapshotsCacheRuntimeProbesPerBinaryAndHome() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("codex-home", isDirectory: true)
        let skillDir = home.appendingPathComponent("skills/sam-review-code", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "# Review\n".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let fakeCodex = dir.appendingPathComponent("fake-codex")
        let probeCount = dir.appendingPathComponent("probe-count")
        try """
        #!/bin/sh
        if [ "$CODEX_HOME" != "\(home.path)" ]; then
          exit 1
        fi
        if [ "$1" = "--version" ]; then
          printf 'v' >> "\(probeCount.path)"
          printf 'codex-test 9.9.9\\nUpdate available: codex-test 10.0.0\\n'
          exit 0
        fi
        if [ "$1" = "login" ] && [ "$2" = "status" ]; then
          printf 'a' >> "\(probeCount.path)"
          printf 'Logged in using ChatGPT\\nLogged in as work@example.com\\n'
          exit 0
        fi
        if [ "$1" = "--help" ]; then
          printf 'h' >> "\(probeCount.path)"
          cat <<'EOF'
        Usage: codex [OPTIONS] <COMMAND>

        Commands:
          exec      Run Codex non-interactively
          review    Run a code review
          help      Print help
        EOF
          exit 0
        fi
        exit 1
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "codex-work",
            "provider": "codex",
            "displayName": "Codex Work",
            "binaryPath": "\(fakeCodex.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let first = await router.listAgentProviderSnapshots()
        let second = await router.listAgentProviderSnapshots()
        let codex = try XCTUnwrap(second.first { $0.id == "codex-work" })

        XCTAssertEqual(codex.version, "codex-test 9.9.9")
        XCTAssertEqual(codex.updateState, "update_available")
        XCTAssertEqual(codex.advisory, "Update available: codex-test 10.0.0")
        XCTAssertEqual(codex.statusDetail, "Update available: codex-test 10.0.0")
        XCTAssertEqual(codex.authenticated, true)
        XCTAssertEqual(codex.accountLabel, "work@example.com")
        XCTAssertEqual(codex.accountAuthMethod, "ChatGPT",
                       "provider snapshots must carry richer account auth metadata through the same instance-scoped probe cache as auth labels")
        XCTAssertFalse(codex.slashCommands.contains("/review"),
                       "provider --help lists CLI subcommands, not interactive slash commands; snapshots must not surface them as composer suggestions")
        XCTAssertEqual(codex.skills, ["sam-review-code"],
                       "provider snapshots must discover Codex skills from the selected CODEX_HOME so composer suggestions reflect the active provider instance")
        let count = try String(contentsOf: probeCount, encoding: .utf8)
        XCTAssertEqual(count, "av",
                       "provider cards reload frequently; version/auth probes must be cached per binary/home, and CLI help must not be probed for slash-command suggestions")
        XCTAssertEqual(first.count, second.count)
    }

    func test_providerSnapshotsDiscoverClaudeSkillsFromInstanceHome() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("claude-home", isDirectory: true)
        let skillDir = home.appendingPathComponent(".claude/skills/team-plan", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "# Team Plan\n".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let fakeClaude = dir.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'claude-test 2.1.0\\n'
          exit 0
        fi
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          printf 'Logged in as claude@example.com\\n'
          exit 0
        fi
        exit 1
        """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "claude-team",
            "provider": "claude",
            "displayName": "Claude Team",
            "binaryPath": "\(fakeClaude.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let claude = try XCTUnwrap(snapshots.first { $0.id == "claude-team" })

        XCTAssertEqual(claude.binaryPath, fakeClaude.path)
        XCTAssertEqual(claude.version, "claude-test 2.1.0",
                       "the provider card must publish the version from the exact Claude executable configured for SDK query execution")
        XCTAssertEqual(claude.skills, ["team-plan"],
                       "provider snapshots must discover Claude skills from the selected HOME/.claude/skills so Claude composer suggestions do not show Codex-home skills")
    }

    func test_providerSnapshotsGateClaudeModelsByInstalledVersion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("claude-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fakeClaude = dir.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'Claude Code 1.5.0\\n'
          exit 0
        fi
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          printf 'Logged in as claude@example.com\\n'
          exit 0
        fi
        exit 1
        """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "claude-old",
            "provider": "claude",
            "displayName": "Claude Old",
            "binaryPath": "\(fakeClaude.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let claude = try XCTUnwrap(snapshots.first { $0.id == "claude-old" })

        XCTAssertEqual(claude.models.map(\.id), ["fable", "opus", "sonnet", "haiku"],
                       "provider snapshots must use versionless Claude Code model aliases when the dynamic Anthropic Models API is unavailable")
        XCTAssertEqual(claude.models.first?.supportedReasoningEfforts, AgentReasoningEffort.claudeSupportedCases,
                       "alias fallback Claude models must preserve the full Claude effort picker (incl. Max + Ultracode) on macOS and iOS")
    }

    func test_agentSurfaceRefreshesCurrentProviderModelsOnStartup() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fakeClaude = dir.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'Claude Code 2.1.156\\n'
          exit 0
        fi
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          printf 'Logged in as claude@example.com\\n'
          exit 0
        fi
        exit 1
        """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("cli.claude.path", fakeClaude.path)
        let workspace = try router.createWorkspace(name: "startup-models", cwd: dir.path)
        let descriptor = try router.createSurface(workspace: workspace.id, type: .agentApp, paneID: nil, title: "Agent App")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface)
        defer { closeAndUnregisterAllSurfaces() }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if surface.viewModel.providerSnapshots.contains(where: {
                $0.provider == .claude && $0.models.contains { $0.id == "opus" }
            }) {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(surface.viewModel.providerSnapshots.contains(where: {
            $0.provider == .claude && $0.models.contains { $0.id == "opus" }
        }), "opening a macOS Agent App surface must refresh provider snapshots immediately so the model menu sees current Claude aliases without waiting for a manual retry")
    }

    func test_providerUpdateRunsSerializedForSelectedInstance() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fakeCodex = dir.appendingPathComponent("fake-codex")
        let started = dir.appendingPathComponent("started")
        try """
        #!/bin/sh
        if [ "$1" = "update" ] && [ "$CODEX_HOME" = "\(home.path)" ]; then
          printf started > "\(started.path)"
          sleep 1
          printf 'updated codex\\n'
          exit 0
        fi
        exit 7
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "codex-work",
            "provider": "codex",
            "displayName": "Codex Work",
            "binaryPath": "\(fakeCodex.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let first = Task { try await router.updateAgentProvider(provider: .codex, providerInstanceId: "codex-work") }
        while !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        do {
            _ = try await router.updateAgentProvider(provider: .codex, providerInstanceId: "codex-work")
            XCTFail("second update should be rejected while provider update is already running")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32041)
        }

        let value = try await first.value
        guard case .object(let payload) = value else { return XCTFail("expected update payload") }
        XCTAssertEqual(payload["ok"], .bool(true))
        XCTAssertEqual(payload["provider_instance_id"], .string("codex-work"))
        XCTAssertEqual(payload["stdout"], .string("updated codex\n"),
                       "provider update actions must use the selected provider instance environment and serialize duplicate update starts")
    }

    func test_providerUpdateFailureReleasesLockForRetry() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fakeCodex = dir.appendingPathComponent("fake-codex")
        let attempts = dir.appendingPathComponent("attempts")
        try """
        #!/bin/sh
        count=0
        if [ -f "\(attempts.path)" ]; then
          count=$(cat "\(attempts.path)")
        fi
        count=$((count + 1))
        printf "$count" > "\(attempts.path)"
        if [ "$1" = "update" ] && [ "$CODEX_HOME" = "\(home.path)" ] && [ "$count" = "1" ]; then
          printf 'network unavailable\\n' >&2
          exit 7
        fi
        if [ "$1" = "update" ] && [ "$CODEX_HOME" = "\(home.path)" ]; then
          printf 'updated after retry\\n'
          exit 0
        fi
        exit 8
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "codex-work",
            "provider": "codex",
            "displayName": "Codex Work",
            "binaryPath": "\(fakeCodex.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let failed = try await router.updateAgentProvider(provider: .codex, providerInstanceId: "codex-work")
        guard case .object(let failedPayload) = failed else { return XCTFail("expected failed update payload") }
        XCTAssertEqual(failedPayload["ok"], .bool(false))
        XCTAssertEqual(failedPayload["status"], .number(7))
        XCTAssertEqual(failedPayload["stderr"], .string("network unavailable\n"))

        let retried = try await router.updateAgentProvider(provider: .codex, providerInstanceId: "codex-work")
        guard case .object(let retriedPayload) = retried else { return XCTFail("expected retried update payload") }
        XCTAssertEqual(retriedPayload["ok"], .bool(true))
        XCTAssertEqual(retriedPayload["stdout"], .string("updated after retry\n"),
                       "provider update failure must report the provider-native error and release the serialized update lock so users can retry after fixing the CLI/network state")
    }

    func test_providerInstanceConfigExposesSnapshotsAndRoutesRunIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let fakeBinary = "/usr/bin/env"
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "codex-work",
            "provider": "codex",
            "displayName": "Codex Work",
            "binaryPath": "\(fakeBinary)",
            "homePath": "\(codexHome.path)",
            "accentColor": "#125A9C",
            "enabled": true,
            "env": {"REMOTE_CODE_INSTANCE": "work"}
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let codex = try XCTUnwrap(snapshots.first { $0.id == "codex-work" })
        XCTAssertEqual(codex.displayName, "Codex Work")
        XCTAssertEqual(codex.binaryPath, fakeBinary)
        XCTAssertEqual(codex.homePath, codexHome.path)
        XCTAssertEqual(codex.environmentKeys, ["CODEX_HOME", "REMOTE_CODE_INSTANCE"],
                       "provider snapshots must show which instance-scoped environment keys isolate account/session state without leaking values")

        let capture = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: capture)
        let workspace = try router.createWorkspace(name: "instance", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "instance",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            providerInstanceId: "codex-work"
        )

        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "check isolation",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )

        let request = try XCTUnwrap(capture.lastRequest)
        XCTAssertEqual(request.providerInstanceId, "codex-work")
        XCTAssertEqual(request.providerBinary, fakeBinary)
        XCTAssertEqual(request.environment["CODEX_HOME"], codexHome.path)
        XCTAssertEqual(request.environment["REMOTE_CODE_INSTANCE"], "work")
    }

    func test_sendOnStartedThreadToleratesMismatchedProviderInstanceIdAndKeepsLockedInstance() async throws {
        // A thread is locked to one of several configured provider instances. A
        // mirror client (iOS/macOS) can re-derive its provider-instance id from the
        // provider snapshot list and end up forwarding a DIFFERENT, still-valid
        // instance id than the one the thread is bound to. Once the thread has
        // started, a message-send carrying that mismatched id must NOT be rejected
        // with the provider-instance lock (-32013): the user must always be able to
        // send, and the run must stay on the thread's original locked instance —
        // never silently hop to the forwarded one. This reproduces the field bug
        // "Provider instance is locked once the thread has started" that blocked
        // sending from the mobile mirror.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        let homeA = root.appendingPathComponent("codex-a", isDirectory: true)
        let homeB = root.appendingPathComponent("codex-b", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let fakeBinary = "/usr/bin/env"
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {"id":"codex-a","provider":"codex","displayName":"Codex A","binaryPath":"\(fakeBinary)","homePath":"\(homeA.path)","enabled":true,"env":{"REMOTE_CODE_INSTANCE":"a"}},
          {"id":"codex-b","provider":"codex","displayName":"Codex B","binaryPath":"\(fakeBinary)","homePath":"\(homeB.path)","enabled":true,"env":{"REMOTE_CODE_INSTANCE":"b"}}
        ]
        """)

        let capture = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: capture)
        let workspace = try router.createWorkspace(name: "instance-lock", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "locked",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            providerInstanceId: "codex-b"
        )
        XCTAssertEqual(thread.providerInstanceId, "codex-b")

        // Mark the thread "started" so its provider/instance are locked host-side.
        try ctx.messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: "first"))
        try ctx.messageRepo.append(AgentMessage(threadId: thread.id, role: .assistant, content: "reply"))

        // Mirror client forwards the OTHER (still-valid) instance id on the started
        // thread. Before the fix this threw -32013; now the send must proceed.
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "second message",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            interactionMode: nil,
            modelSelection: nil,
            providerInstanceId: "codex-a"
        )

        let request = try XCTUnwrap(capture.lastRequest)
        XCTAssertEqual(request.providerInstanceId, "codex-b",
                       "a started-thread send must run on the thread's locked instance, never the mismatched id the client forwarded")
        XCTAssertEqual(request.environment["CODEX_HOME"], homeB.path,
                       "the run must stay isolated to the locked instance's home, proving the forwarded instance did not take effect")
        XCTAssertEqual(request.environment["REMOTE_CODE_INSTANCE"], "b")
    }

    func test_providerInstanceConfigRoutesClaudeHomeThroughProcessHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        let claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let fakeBinary = "/usr/bin/env"
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "claude-personal",
            "provider": "claude",
            "displayName": "Claude Personal",
            "binaryPath": "\(fakeBinary)",
            "homePath": "\(claudeHome.path)",
            "enabled": true,
            "env": {"REMOTE_CODE_INSTANCE": "personal"}
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let claude = try XCTUnwrap(snapshots.first { $0.id == "claude-personal" })
        XCTAssertEqual(claude.environmentKeys, ["HOME", "REMOTE_CODE_INSTANCE"],
                       "Claude Code stores account/session state under HOME; provider instances must isolate HOME instead of an ignored config-only variable")

        let capture = RequestCaptureRunner(provider: .claude)
        ctx.coordinator.replaceProvider(.claude, runner: capture)
        let workspace = try router.createWorkspace(name: "claude-instance", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "claude instance",
            provider: .claude,
            model: "claude-opus-4-7",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            providerInstanceId: "claude-personal"
        )

        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "check claude isolation",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )

        let request = try XCTUnwrap(capture.lastRequest)
        XCTAssertEqual(request.providerInstanceId, "claude-personal")
        XCTAssertEqual(request.providerBinary, fakeBinary)
        XCTAssertEqual(request.environment["HOME"], claudeHome.path)
        XCTAssertNil(request.environment["CLAUDE_CONFIG_DIR"],
                     "Claude provider isolation should follow Claude Code's HOME-based state model")
        XCTAssertEqual(request.environment["REMOTE_CODE_INSTANCE"], "personal")
    }

    func test_claudeRunCarriesNoTokenSaverHookEnvironment_evenWithLegacyPreferenceOn() async throws {
        // WHY: Token Saver was removed. A preference an older build left ON must
        // not bring back the Claude PostToolUse compression hook.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let support = root.appendingPathComponent("support", isDirectory: true)
        let ctx = try AppContext(channel: .debug, appSupportOverride: support.path)
        try seedLegacyTokenSaverOn(ctx.settingsRepo)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router

        let capture = RequestCaptureRunner(provider: .claude)
        ctx.coordinator.replaceProvider(.claude, runner: capture)
        let workspace = try router.createWorkspace(name: "claude-token-saver-hook", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "claude token saver hook",
            provider: .claude,
            model: "claude-opus-4-7",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "check post tool hook env",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )

        let request = try XCTUnwrap(capture.lastRequest)
        XCTAssertNil(request.environment["RC_TOKEN_SAVER_POST_TOOL_USE"])
        XCTAssertNil(request.environment["REMOTE_CODE_DISTILL_STATE_PATH"])
    }

    func test_stopAgentRunCancelsCoordinatorThreadRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = BlockingCancelRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "stop", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "stop",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        _ = try await router.sendAgentMessage(thread: thread.id,
                                              text: "wait",
                                              provider: nil,
                                              model: nil,
                                              permissionMode: nil,
                                              reasoningEffort: nil)
        try router.stopAgentRun(thread: thread.id)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if runner.cancelled, try ctx.threadRepo.get(id: thread.id)?.status == .cancelled {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(runner.cancelled,
                      "agent.run.stop must reach the active provider handle instead of returning a no-op success")
        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.status, .cancelled,
                       "stopped runs must update persisted thread status so macOS and iOS leave running state")
    }

    func test_terminalPersistenceRetainsRunBoundQueueRecoveryEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        ctx.coordinator.replaceProvider(.codex, runner: RequestCaptureRunner(provider: .codex))
        let workspace = try router.createWorkspace(name: "terminal-run-evidence", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "terminal run evidence",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        let result = try await router.sendAgentMessage(
            thread: thread.id,
            text: "finish immediately",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let runId = try XCTUnwrap(result.runId)
        let deadline = Date().addingTimeInterval(2)
        while try ctx.runRepo.get(id: runId)?.status != .completed, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastRunId, runId,
                       "terminal persistence must not erase the run id required to reconcile a prepared queue row after a crash")
        XCTAssertEqual(try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastEventKind, "run.finished")
    }

    func test_queuedPermissionSnapshotUpgradesLegacyRowsAndRemainsDowngradeReadable() throws {
        // WHY: permission was added to the existing queue-routing JSON without
        // a schema migration. New hosts must read legacy bare configurations,
        // while old hosts must keep decoding rows written by the new host.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root.path).run()
        let threadRepo = AgentThreadRepository(db: db)
        let queueRepo = AgentQueuedMessageRepository(db: db)
        let thread = AgentThread(
            title: "permission compatibility",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        try threadRepo.upsert(thread)
        let routing = thread.effectiveRoutingConfiguration

        let legacy = try queueRepo.enqueue(
            threadId: thread.id,
            text: "legacy routing row",
            attachments: [],
            interactionMode: .default,
            routingSnapshot: AgentQueuedMessageRoutingSnapshot(
                configuration: routing,
                permissionMode: .fullAccess
            )
        )
        let legacyData = try JSONEncoder().encode(routing)
        let legacyJSON = try XCTUnwrap(String(data: legacyData, encoding: .utf8))
        let replaceWithLegacy = try db.prepare("""
            UPDATE agent_queued_message_routing
            SET configuration_json = ?
            WHERE queued_message_id = ?;
        """)
        try replaceWithLegacy.bind(1, legacyJSON)
        try replaceWithLegacy.bind(2, legacy.id.value.uuidString)
        _ = try replaceWithLegacy.step()

        let upgradedLegacy = try XCTUnwrap(queueRepo.routingSnapshot(id: legacy.id))
        XCTAssertEqual(upgradedLegacy.configuration, routing)
        XCTAssertNil(
            upgradedLegacy.permissionMode,
            "a pre-upgrade queue row has no frozen permission and must preserve the legacy fallback contract"
        )

        let frozen = AgentQueuedMessageRoutingSnapshot(
            configuration: routing,
            permissionMode: .autoAcceptEdits
        )
        let modern = try queueRepo.enqueue(
            threadId: thread.id,
            text: "modern routing row",
            attachments: [],
            interactionMode: .default,
            routingSnapshot: frozen
        )
        XCTAssertEqual(
            try queueRepo.routingSnapshot(id: modern.id),
            frozen,
            "an explicit permission must survive the real queue repository round trip"
        )

        let readModernJSON = try db.prepare("""
            SELECT configuration_json
            FROM agent_queued_message_routing
            WHERE queued_message_id = ?;
        """)
        try readModernJSON.bind(1, modern.id.value.uuidString)
        XCTAssertTrue(try readModernJSON.step())
        let modernJSON = try XCTUnwrap(readModernJSON.columnText(0))
        let modernData = try XCTUnwrap(modernJSON.data(using: .utf8))
        let modernObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: modernData) as? [String: Any]
        )
        XCTAssertEqual(modernObject["permissionMode"] as? String, AgentPermissionMode.autoAcceptEdits.rawValue)
        XCTAssertEqual(
            try JSONDecoder().decode(AgentRoutingConfiguration.self, from: modernData),
            routing,
            "the additive flat permission key must remain readable by the pre-upgrade routing decoder"
        )
    }

    func test_preallocatedDirectRunIdentityReachesTheProviderUnchanged() async throws {
        // WHY: a handoff binds its run before provider spawn. Replacing that ID
        // inside the ordinary direct-send path breaks waiter, checkpoint, and
        // reply ownership even when the provider itself succeeds.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: AgentProvider.codex.rawValue
            )
        ])
        let workspace = try router.createWorkspace(name: "prebound-direct", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "prebound direct",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let futureRunID = AgentRunID()

        let result = try await router.sendAgentMessage(
            thread: thread.id,
            text: "use the bound direct id",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil,
            requestedRunID: futureRunID,
            routingSnapshot: AgentQueuedMessageRoutingSnapshot(
                configuration: thread.effectiveRoutingConfiguration
            )
        )

        XCTAssertEqual(result.status, .started)
        XCTAssertEqual(result.runId, futureRunID)
        XCTAssertEqual(runner.lastRequest?.runId, futureRunID)
        XCTAssertEqual(try ctx.runRepo.get(id: futureRunID)?.threadId, thread.id)
    }

    func test_preallocatedQueuedRunIdentitySurvivesQueueDrainUnchanged() async throws {
        // WHY: a busy Agent App thread queues the host continuation. Its queue
        // row UUID is the already-bound future run UUID, so draining must not
        // allocate a second identity that the handoff waiter cannot observe.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProviderAdapter(
            .codex,
            adapter: TerminalRetiringOneShotAdapter(runner: runner)
        )
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: AgentProvider.codex.rawValue
            )
        ])
        let workspace = try router.createWorkspace(name: "prebound-queued", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "prebound queued",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let active = try await router.sendAgentMessage(
            thread: thread.id,
            text: "occupy the thread",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let activeRunID = try XCTUnwrap(active.runId)
        let futureRunID = AgentRunID()

        let queued = try await router.sendAgentMessage(
            thread: thread.id,
            text: "bound continuation",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil,
            requestedRunID: futureRunID,
            routingSnapshot: AgentQueuedMessageRoutingSnapshot(
                configuration: thread.effectiveRoutingConfiguration
            )
        )

        XCTAssertEqual(queued.status, .queued)
        XCTAssertEqual(queued.runId, futureRunID)
        XCTAssertEqual(queued.queuedMessage?.id, AgentQueuedMessageID(futureRunID.value))
        XCTAssertEqual(
            try ctx.queuedMessageRepo.get(id: AgentQueuedMessageID(futureRunID.value))?.text,
            "bound continuation"
        )

        XCTAssertTrue(runner.finish(runID: activeRunID, status: .completed, reply: "first complete"))
        let firstRunSettled = await waitUntil(timeout: 5) {
            isTerminal(try? ctx.runRepo.get(id: activeRunID)?.status)
                && isTerminal(try? ctx.threadRepo.get(id: thread.id)?.status)
        }
        let firstRun = try ctx.runRepo.get(id: activeRunID)
        let firstRunStatus = firstRun?.status
        let firstThreadStatus = try ctx.threadRepo.get(id: thread.id)?.status
        let providerSessionRemains = ctx.coordinator.hasProviderSession(threadId: thread.id)
        XCTAssertTrue(
            firstRunSettled,
            "first run must become durably terminal before drain; run=\(String(describing: firstRunStatus)) "
                + "thread=\(String(describing: firstThreadStatus)) session=\(providerSessionRemains) "
                + "error=\(String(describing: firstRun?.errorMessage))"
        )
        guard firstRunSettled else { return }
        XCTAssertFalse(
            providerSessionRemains,
            "a provider session remaining after durable terminal state prevents automatic queue drain"
        )
        let drained = await waitUntil(timeout: 5) { runner.requests.count >= 2 }
        let queuedAfterTerminal = try ctx.queuedMessageRepo.get(id: AgentQueuedMessageID(futureRunID.value))
        XCTAssertTrue(
            drained,
            "the exact preallocated queue row must drain after terminal; firstRun=\(String(describing: firstRunStatus)) "
                + "thread=\(String(describing: firstThreadStatus)) session=\(providerSessionRemains) "
                + "waiters=\(ctx.queueDrainWaiterCountForTesting) "
                + "queue=\(String(describing: queuedAfterTerminal))"
        )
        guard drained else { return }
        XCTAssertEqual(runner.requests.last?.runId, futureRunID)
        XCTAssertEqual(try ctx.runRepo.get(id: futureRunID)?.threadId, thread.id)
        let exactQueueRowRemoved = await waitUntil(timeout: 5) {
            (try? ctx.queuedMessageRepo.get(id: AgentQueuedMessageID(futureRunID.value))) == nil
        }
        XCTAssertTrue(
            exactQueueRowRemoved,
            "provider start and durable queue acknowledgement may interleave, but the exact row must be removed"
        )
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: AgentQueuedMessageID(futureRunID.value)))
        XCTAssertTrue(runner.finish(runID: futureRunID, status: .completed, reply: "second complete"))
    }

    func test_normalBusySendFreezesPermissionBeforeQueuedThreadMutation() async throws {
        // WHY: Agent App can queue a host continuation on a legacy thread that
        // has no stored routing row. A later picker change must not silently
        // broaden or narrow the already-admitted provider request.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProviderAdapter(
            .codex,
            adapter: TerminalRetiringOneShotAdapter(runner: runner)
        )
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: AgentProvider.codex.rawValue
            )
        ])
        let workspace = try router.createWorkspace(
            name: "queued-permission",
            cwd: workspaceDir.path
        )
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "queued permission",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        XCTAssertNil(
            thread.routingConfiguration,
            "the regression requires the ordinary legacy-thread path, not an explicit routing fixture"
        )

        let active = try await router.sendAgentMessage(
            thread: thread.id,
            text: "occupy permission thread",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let activeRunID = try XCTUnwrap(active.runId)
        let queued = try await router.sendAgentMessage(
            thread: thread.id,
            text: "keep supervised permission",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let queuedMessage = try XCTUnwrap(queued.queuedMessage)

        XCTAssertEqual(queued.status, .queued)
        XCTAssertEqual(queuedMessage.routingSnapshot?.permissionMode, .supervised)
        XCTAssertEqual(
            try ctx.queuedMessageRepo.routingSnapshot(id: queuedMessage.id)?.permissionMode,
            .supervised,
            "the permission must be durable before a post-bind picker mutation"
        )
        let mutated = try router.configureAgentThread(
            thread: thread.id,
            provider: nil,
            model: nil,
            permissionMode: .fullAccess,
            reasoningEffort: nil
        )
        XCTAssertEqual(mutated.permissionMode, .fullAccess)

        XCTAssertTrue(runner.finish(runID: activeRunID, status: .completed, reply: "first complete"))
        let firstRunSettled = await waitUntil(timeout: 5) {
            isTerminal(try? ctx.runRepo.get(id: activeRunID)?.status)
                && isTerminal(try? ctx.threadRepo.get(id: thread.id)?.status)
        }
        XCTAssertTrue(firstRunSettled, "the active run must become terminal before its queued successor drains")
        guard firstRunSettled else { return }

        let drained = await waitUntil(timeout: 5) {
            runner.requests.contains { $0.prompt.contains("keep supervised permission") }
        }
        XCTAssertTrue(drained, "the normal queue waiter must drain the already-bound continuation")
        guard drained else { return }
        let drainedRequest = try XCTUnwrap(
            runner.requests.first { $0.prompt.contains("keep supervised permission") }
        )
        XCTAssertEqual(
            drainedRequest.permissionMode,
            .supervised,
            "post-bind thread changes must not alter the permission sent to the provider"
        )
        XCTAssertEqual(drainedRequest.runId, AgentRunID(queuedMessage.id.value))
        let queueRemoved = await waitUntil(timeout: 5) {
            (try? ctx.queuedMessageRepo.get(id: queuedMessage.id)) == nil
        }
        let queuedAfterDrain = try ctx.queuedMessageRepo.get(id: queuedMessage.id)
        XCTAssertTrue(
            queueRemoved,
            "accepted queued work must be acknowledged after provider start; row=\(String(describing: queuedAfterDrain))"
        )
        XCTAssertTrue(
            runner.finish(runID: drainedRequest.runId, status: .completed, reply: "second complete")
        )
    }

    func test_sendAgentMessageStartsPendingNewThreadInsteadOfQueueing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "pending-start", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "New thread",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        let result = try await router.sendAgentMessage(thread: thread.id,
                                                       text: "count to 10",
                                                       provider: nil,
                                                       model: nil,
                                                       permissionMode: nil,
                                                       reasoningEffort: nil)

        XCTAssertEqual(result.status, .started,
                       "a freshly-created pending Agent thread must start its first provider run; queuing here leaves iOS waiting forever")
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id), [],
                       "the first prompt in a new iOS thread must not be stored as an editable follow-up queue item")
        XCTAssertEqual(runner.lastRequest?.prompt, "count to 10")
    }

    func test_sendAgentMessageQueuesWhenAdapterTurnOutlivesPersistedThreadStatus() async throws {
        // WHY: mirror/RPC sends do not share the macOS surface's in-memory run
        // projection. The adapter's running session must still route the message
        // into the durable queue instead of creating a duplicate failed turn.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let adapter = OneShotProviderAdapter(runner: BlockingCancelRunner(provider: .codex))
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        let workspace = try router.createWorkspace(name: "orphaned-live-turn", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "orphaned live turn",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-5.5",
            cwd: workspaceDir.path,
            prompt: "existing turn"
        )) { _ in }

        let result = try await router.sendAgentMessage(
            thread: thread.id,
            text: "queue from mirror exactly once",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )

        XCTAssertEqual(result.status, .queued)
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["queue from mirror exactly once"])
        XCTAssertTrue(try ctx.messageRepo.list(threadId: thread.id).isEmpty,
                      "adapter-busy RPC sends must not persist a duplicate user bubble")
        adapter.stopAll()
    }

    func test_drainQueueWaitsWhenAdapterTurnOutlivesPersistedThreadStatus() async throws {
        // WHY: lifecycle reconciliation can observe stale persisted status while
        // the adapter still owns a turn. It must not claim or dispatch the queue
        // head until that provider turn is actually idle.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let (ctx, router, adapter, thread) = try await makeLiveAdapterRouterFixture(root: root)
        var staleThread = thread
        staleThread.status = .completed
        try ctx.threadRepo.upsert(staleThread)
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "wait for the live turn",
            attachments: [],
            interactionMode: .default
        )

        try await router.drainNextQueuedAgentMessage(thread: thread.id)

        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: queued.id)?.text, "wait for the live turn")
        let dispatch = try XCTUnwrap(ctx.queuedMessageRepo.dispatch(id: queued.id))
        XCTAssertEqual(dispatch.state, .queued,
                       "busy-provider drain must not claim or prepare the queue head")
        XCTAssertNil(dispatch.runId)
        XCTAssertTrue(try ctx.messageRepo.list(threadId: thread.id).isEmpty)
        adapter.stopAll()
    }

    func test_forceQueuedMessageTreatsLiveAdapterSessionAsActive() async throws {
        // WHY: Force must promote the requested item and stop the real provider
        // turn even when persisted thread status has already become stale.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let (ctx, router, adapter, thread) = try await makeLiveAdapterRouterFixture(root: root)
        var staleThread = thread
        staleThread.status = .completed
        try ctx.threadRepo.upsert(staleThread)
        _ = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "later", attachments: [], interactionMode: .default)
        let forced = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "force first", attachments: [], interactionMode: .default)

        let result = try await router.forceAgentQueuedMessageNow(id: forced.id)

        XCTAssertEqual(result.status, .queued)
        XCTAssertEqual(result.queuedMessage?.id, forced.id)
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["force first", "later"])
        adapter.stopAll()
    }

    func test_forceQueuedMessageDrainsOnceWhenProviderBecomesIdleAfterTimeoutAcrossProviders() async throws {
        // WHY: stopRun publishes the host-side cancellation before a native
        // provider necessarily becomes idle. The first drain can therefore see
        // a live adapter session; Force still owes exactly one later start.
        // Distill is the only shipped provider. Its adapter keeps the session
        // live until the provider acknowledges the Stop, and it names its
        // thread when the prompt is accepted; the fixture models both.
        for provider in [AgentProvider.distill] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            defer { closeAndUnregisterAllSurfaces() }

            let ctx = try AppContext(
                channel: .debug,
                appSupportOverride: root.appendingPathComponent("support").path
            )
            ctx.queueDrainProviderIdleTimeout = 0.05
            let sleeper = QueueDrainTestSleeper()
            ctx.queueDrainSleepForTesting = { try await sleeper.sleep(threadId: $0, duration: $1) }
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            rememberSignedInSnapshot(provider, router: router)
            let runner = DelayedCancelQueueRunner(provider: provider, reportsProviderThreadAtStart: true)
            ctx.coordinator.replaceProviderAdapter(provider, adapter: TerminalRetiringOneShotAdapter(runner: runner))
            let workspace = try router.createWorkspace(
                name: "delayed-force-\(provider.rawValue)",
                cwd: workspaceDir.path
            )
            let thread = try router.createAgentThread(
                workspace: workspace.id,
                title: "delayed force \(provider.rawValue)",
                provider: provider,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "existing turn",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            _ = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "later",
                attachments: [],
                interactionMode: .default
            )
            let forced = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "force exactly once",
                attachments: [],
                interactionMode: .default
            )
            let failures = QueueFailureCounter(threadId: thread.id)
            let drained = QueueEventSignal(
                threadId: thread.id,
                kind: "agent.message.queue.drained"
            )
            let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
                failures.record($0)
                drained.record($0)
            }
            defer { EventBus.shared.unsubscribe(subscription) }

            let result = try await router.forceAgentQueuedMessageNow(id: forced.id)
            XCTAssertEqual(result.status, .queued)
            await sleeper.advanceNext(threadId: thread.id)
            await failures.waitForCount(1)
            runner.finishRun(ordinal: 1, status: .cancelled)
            await runner.waitForStartCount(2)
            await drained.waitForCount(1)
            XCTAssertEqual(runner.startCount, 2,
                           "\(provider.rawValue) Force must retry after delayed provider idle and start once")
            XCTAssertEqual(
                try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text),
                ["later"],
                "\(provider.rawValue) must acknowledge only the forced queue row"
            )
            XCTAssertEqual(
                try ctx.messageRepo.list(threadId: thread.id)
                    .filter { $0.role == .user && $0.content == "force exactly once" }.count,
                1,
                "\(provider.rawValue) delayed cancellation must not duplicate the forced user message"
            )
            XCTAssertEqual(runner.startCount, 2,
                           "\(provider.rawValue) must remain at exactly one forced restart after settling")
            XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["later"])
            XCTAssertEqual(
                try ctx.messageRepo.list(threadId: thread.id)
                    .filter { $0.role == .user && $0.content == "force exactly once" }.count,
                1
            )
            XCTAssertEqual(failures.count, 1,
                           "\(provider.rawValue) must emit one timeout status while continuing the late-idle watcher")
            XCTAssertTrue(failures.failureMessages.allSatisfy { $0.hasPrefix("Provider is still stopping.") },
                          "the one failure must be the delayed-stop status, not a dispatch error: \(failures.failureMessages)")
            ctx.coordinator.stopRun(threadId: thread.id)
        }
    }

    func test_normalQueuedMessageWaitsPastTimeoutWithoutFalseFailureAndDrainsOnceAcrossProviders() async throws {
        // WHY: the queue timeout describes delayed stop recovery, not normal
        // queue residence. A legitimately running turn may exceed it without
        // making the durable follow-up unsafe or showing a false failure.
        // Distill is the only shipped provider.
        for provider in [AgentProvider.distill] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            defer { closeAndUnregisterAllSurfaces() }
            let ctx = try AppContext(
                channel: .debug,
                appSupportOverride: root.appendingPathComponent("support").path
            )
            ctx.queueDrainProviderIdleTimeout = 0.02
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            rememberSignedInSnapshot(provider, router: router)
            let runner = DelayedCancelQueueRunner(provider: provider, cancellationDelay: nil)
            ctx.coordinator.replaceProvider(provider, runner: runner)
            let sleeper = QueueDrainTestSleeper()
            ctx.queueDrainSleepForTesting = { try await sleeper.sleep(threadId: $0, duration: $1) }
            let workspace = try router.createWorkspace(
                name: "normal-queue-\(provider.rawValue)",
                cwd: workspaceDir.path
            )
            let thread = try router.createAgentThread(
                workspace: workspace.id,
                title: "normal queue \(provider.rawValue)",
                provider: provider,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "legitimately long turn",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            let failures = QueueFailureCounter(threadId: thread.id)
            let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
                failures.record($0)
            }
            defer { EventBus.shared.unsubscribe(subscription) }

            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "ordinary queued follow-up",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            await sleeper.advanceNext(threadId: thread.id)

            XCTAssertEqual(failures.count, 0,
                           "\(provider.rawValue) normal queue residence must not look like stop failure")
            XCTAssertEqual(runner.startCount, 1)
            XCTAssertEqual(
                try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text),
                ["ordinary queued follow-up"]
            )
            XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)

            let drained = QueueDrainAsyncSignal()
            let drainedSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
                guard $0.kind == "agent.message.queue.drained",
                      $0.payload.objectValue?["thread_id"]?.stringValue == thread.id.value.uuidString else {
                    return
                }
                Task { await drained.signal() }
            }
            defer { EventBus.shared.unsubscribe(drainedSubscription) }
            runner.finishRun(ordinal: 1, status: .completed)
            await drained.wait()

            XCTAssertEqual(runner.startCount, 2)
            XCTAssertEqual(failures.count, 0)
            XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
            XCTAssertEqual(
                try ctx.messageRepo.list(threadId: thread.id)
                    .filter { $0.role == .user && $0.content == "ordinary queued follow-up" }.count,
                1,
                "\(provider.rawValue) normal completion must drain the queued intent exactly once"
            )
            runner.finishRun(ordinal: 2, status: .completed)
        }
    }

    func test_forceQueueNeverIdlePreservesIntentWithSingleTimeoutFailureAcrossProviders() async throws {
        // WHY: a provider that ignores cancellation must not trigger repeated
        // drain attempts, emit a false terminal failure, or consume the row.
        // Distill is the only shipped provider; its adapter keeps the session
        // live until the provider acknowledges the Stop.
      for provider in [AgentProvider.distill] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        ctx.queueDrainProviderIdleTimeout = 0.05
        let sleeper = QueueDrainTestSleeper()
        ctx.queueDrainSleepForTesting = { try await sleeper.sleep(threadId: $0, duration: $1) }
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        rememberSignedInSnapshot(provider, router: router)
        let runner = DelayedCancelQueueRunner(
            provider: provider,
            cancellationDelay: nil,
            reportsProviderThreadAtStart: true
        )
        ctx.coordinator.replaceProviderAdapter(provider, adapter: TerminalRetiringOneShotAdapter(runner: runner))
        let workspace = try router.createWorkspace(name: "never-idle", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "never idle",
            provider: provider,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let forced = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "preserve after timeout",
            attachments: [],
            interactionMode: .default
        )
        let failures = QueueFailureCounter(threadId: thread.id)
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { failures.record($0) }
        defer { EventBus.shared.unsubscribe(subscription) }

        _ = try await router.forceAgentQueuedMessageNow(id: forced.id)
        await sleeper.advanceNext(threadId: thread.id)
        await failures.waitForCount(1)

        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.failureMessages.allSatisfy { $0.hasPrefix("Provider is still stopping.") },
                      "the one failure must be the delayed-stop status, not a dispatch error: \(failures.failureMessages)")
        XCTAssertEqual(runner.startCount, 1)
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["preserve after timeout"])
        XCTAssertEqual(
            try ctx.messageRepo.list(threadId: thread.id)
                .filter { $0.role == .user && $0.content == "preserve after timeout" }.count,
            0
        )

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(runner.startCount, 1)
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["preserve after timeout"])
      }
    }

    func test_terminalRunWithNoQueuedRowsSkipsNeverIdleWaitAcrossProviders() async throws {
      // Distill is the only shipped provider.
      for provider in [AgentProvider.distill] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        ctx.queueDrainProviderIdleTimeout = 0.02
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        rememberSignedInSnapshot(provider, router: router)
        let runner = DelayedCancelQueueRunner(provider: provider, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(provider, runner: runner)
        let workspace = try router.createWorkspace(name: "empty-queue", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "empty queue",
            provider: provider,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let failures = QueueFailureCounter(threadId: thread.id)
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            failures.record($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "terminal without follow-up",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )

        ctx.coordinator.stopRun(threadId: thread.id)

        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
        XCTAssertEqual(failures.count, 0)
        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
      }
    }

    func test_enqueueAfterTerminalCallbackCoalescesLateIdleDrainAcrossProviders() async throws {
        // WHY: a host terminal callback can run before a follow-up is enqueued
        // while the native provider session remains live. The enqueue path must
        // arm the one waiter that the earlier empty-queue callback skipped.
        // Distill is the only shipped provider. Its adapter keeps the session
        // live until the provider acknowledges the Stop, and it names its
        // thread when the prompt is accepted; the fixture models both.
        for provider in [AgentProvider.distill] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            defer { closeAndUnregisterAllSurfaces() }
            let ctx = try AppContext(
                channel: .debug,
                appSupportOverride: root.appendingPathComponent("support").path
            )
            ctx.queueDrainProviderIdleTimeout = 0.05
            let sleeper = QueueDrainTestSleeper()
            ctx.queueDrainSleepForTesting = { try await sleeper.sleep(threadId: $0, duration: $1) }
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            rememberSignedInSnapshot(provider, router: router)
            let runner = DelayedCancelQueueRunner(
                provider: provider,
                cancellationDelay: nil,
                reportsProviderThreadAtStart: true
            )
            ctx.coordinator.replaceProviderAdapter(provider, adapter: TerminalRetiringOneShotAdapter(runner: runner))
            let workspace = try router.createWorkspace(
                name: "late-enqueue-\(provider.rawValue)",
                cwd: workspaceDir.path
            )
            let thread = try router.createAgentThread(
                workspace: workspace.id,
                title: "late enqueue \(provider.rawValue)",
                provider: provider,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "existing turn",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            let failures = QueueFailureCounter(threadId: thread.id)
            let drained = QueueEventSignal(
                threadId: thread.id,
                kind: "agent.message.queue.drained"
            )
            let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
                failures.record($0)
                drained.record($0)
            }
            defer { EventBus.shared.unsubscribe(subscription) }

            ctx.coordinator.stopRun(threadId: thread.id)
            XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0,
                           "the terminal callback must skip a waiter when no queued intent exists yet")

            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "late first",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "late second",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1,
                           "\(provider.rawValue) repeated enqueue must coalesce to one waiter")

            await sleeper.advanceNext(threadId: thread.id)
            await failures.waitForCount(1)
            XCTAssertEqual(failures.count, 1,
                           "\(provider.rawValue) one waiter may publish only one delayed-idle status")
            XCTAssertTrue(failures.failureMessages.allSatisfy { $0.hasPrefix("Provider is still stopping.") },
                          "the one failure must be the delayed-stop status, not a dispatch error: \(failures.failureMessages)")
            runner.finishRun(ordinal: 1, status: .cancelled)
            await runner.waitForStartCount(2)
            await drained.waitForCount(1)
            XCTAssertEqual(runner.startCount, 2)
            XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["late second"])

            runner.finishRun(ordinal: 2, status: .completed)
            await runner.waitForStartCount(3)
            await drained.waitForCount(2)
            XCTAssertEqual(runner.startCount, 3)
            runner.finishRun(ordinal: 3, status: .completed)

            XCTAssertFalse(ctx.coordinator.hasProviderSession(threadId: thread.id))
            XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
            XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
            XCTAssertEqual(failures.count, 1)
            XCTAssertEqual(
                try ctx.messageRepo.list(threadId: thread.id)
                    .filter { $0.role == .user && ($0.content == "late first" || $0.content == "late second") }.count,
                2,
                "\(provider.rawValue) must dispatch each late intent exactly once"
            )
        }
    }

    func test_cancellingFinalQueuedRowCancelsLateIdleWaiter() async throws {
        // WHY: a follow-up sent after Stop waits for the still-live provider.
        // Cancelling that last queued row must also cancel its idle waiter.
        // Distill's adapter keeps the session live until the provider
        // acknowledges the Stop, and names its thread when the prompt is
        // accepted; the fixture models both.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        ctx.queueDrainProviderIdleTimeout = 0.5
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        rememberSignedInSnapshot(.distill, router: router)
        let runner = DelayedCancelQueueRunner(
            provider: .distill,
            cancellationDelay: nil,
            reportsProviderThreadAtStart: true
        )
        ctx.coordinator.replaceProviderAdapter(.distill, adapter: TerminalRetiringOneShotAdapter(runner: runner))
        let workspace = try router.createWorkspace(name: "cancel-waiter", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "cancel waiter",
            provider: .distill,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        ctx.coordinator.stopRun(threadId: thread.id)
        let queued = try await router.sendAgentMessage(
            thread: thread.id,
            text: "cancel me",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)

        _ = try router.cancelAgentQueuedMessage(id: try XCTUnwrap(queued.queuedMessage?.id))

        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
        runner.finishRun(ordinal: 1, status: .cancelled)
    }

    func test_queueDrainWaiterImmediatelyDrainsWhenProviderIsAlreadyIdle() async throws {
        // WHY: provider state can become idle between the enqueue decision and
        // waiter installation. The waiter itself must own that second check.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "already-idle", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "already idle",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .completed
        try ctx.threadRepo.upsert(thread)
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "drain after idle transition",
            attachments: [],
            interactionMode: .default
        )
        let drained = QueueEventSignal(
            threadId: thread.id,
            kind: "agent.message.queue.drained"
        )
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            drained.record($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        await runner.waitForStartCount(1)
        await drained.waitForCount(1)
        XCTAssertEqual(runner.startCount, 1)
        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
        runner.finishRun(ordinal: 1, status: .completed)
    }

    func test_cancelledWaiterCannotRemoveImmediateReplacementGeneration() async throws {
        // WHY: cancellation resumes the old task asynchronously. Its cleanup
        // must not remove a new waiter installed for an immediate re-enqueue.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        ctx.queueDrainProviderIdleTimeout = 1
        let sleeper = QueueDrainTestSleeper()
        ctx.queueDrainSleepForTesting = { try await sleeper.sleep(threadId: $0, duration: $1) }
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "waiter-generation", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "waiter generation",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let first = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "cancel first generation",
            attachments: [],
            interactionMode: .default
        )
        let drained = QueueEventSignal(
            threadId: thread.id,
            kind: "agent.message.queue.drained"
        )
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            drained.record($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        await sleeper.waitForRequestCount(1, threadId: thread.id)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)

        _ = try router.cancelAgentQueuedMessage(id: first.id)
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "replacement generation",
            attachments: [],
            interactionMode: .default
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        await sleeper.waitForRequestCount(2, threadId: thread.id)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)

        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1,
                       "old cancellation cleanup must be token-checked")
        runner.finishRun(ordinal: 1, status: .cancelled)
        await runner.waitForStartCount(2)
        await drained.waitForCount(1)
        XCTAssertEqual(runner.startCount, 2)
        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
        runner.finishRun(ordinal: 2, status: .completed)
    }

    func test_backgroundProviderFinishSerializesWithQueueCancelAndReenqueue() async throws {
        // WHY: provider completion callbacks are not main-thread-affine. Their
        // queue recovery must serialize with a simultaneous user cancellation
        // and replacement enqueue without duplicating or losing the waiter.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "background-finish", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "background finish",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let cancelled = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "cancelled queued turn",
            attachments: [],
            interactionMode: .default
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        let drained = QueueEventSignal(
            threadId: thread.id,
            kind: "agent.message.queue.drained"
        )
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            drained.record($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        let finishTask = Task.detached {
            runner.finishRun(ordinal: 1, status: .cancelled)
        }
        _ = try router.cancelAgentQueuedMessage(id: cancelled.id)
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "replacement queued turn",
            attachments: [],
            interactionMode: .default
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        await finishTask.value
        await runner.waitForStartCount(2)
        await drained.waitForCount(1)
        XCTAssertFalse(runner.lastFinishWasMainThread)
        XCTAssertEqual(runner.startCount, 2)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
        XCTAssertEqual(
            try ctx.messageRepo.list(threadId: thread.id)
                .filter { $0.role == .user && $0.content == "replacement queued turn" }.count,
            1
        )
        runner.finishRun(ordinal: 2, status: .completed)
    }

    func test_deleteAgentThreadRetiresOnlyVictimQueuedHandoffWithoutRedispatchOrV1Rewrite() async throws {
        // WHY: deleting an Agent thread is an authoritative lifecycle boundary.
        // A future-ID host continuation queued on that thread must retire before
        // drain, while the sibling queue row and v1 downgrade bytes survive.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-delete-agent-handoff-\(UUID().uuidString)", isDirectory: true)
        let workspaceDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let context = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let botsViewModel = BotsViewModel(context: context, router: router)
        router.botsViewModel = botsViewModel
        let quinn = try botsViewModel.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        botsViewModel.openDesk(quinn)
        botsViewModel.setDeskProvider(.claude)
        wireCallerThreadHandoff(
            context: context,
            peer: quinn,
            peerRunner: peerRunner,
            hostRunner: hostRunner
        )
        let workspace = try router.createWorkspace(name: "t005 agent delete", cwd: workspaceDirectory.path)
        let victimThread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Victim queued handoff",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let siblingThread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Sibling queued handoff",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let surface = AgentAppSurface(
            workspaceID: workspace.id,
            cwd: workspaceDirectory.path,
            coordinator: context.coordinator,
            threadRepo: context.threadRepo,
            messageRepo: context.messageRepo,
            queuedMessageRepo: context.queuedMessageRepo,
            providerSessionRepo: context.providerSessionRuntimeRepo,
            checkpointRepo: context.turnCheckpointRepo,
            initialThreadId: victimThread.id
        )
        surface.viewModel.mentionableBotsProvider = { botsViewModel.bots }
        let victimOccupyingResult = try await router.sendAgentMessage(
            thread: victimThread.id,
            text: "occupy victim",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let victimOccupying = try XCTUnwrap(victimOccupyingResult.runId)
        let siblingOccupyingResult = try await router.sendAgentMessage(
            thread: siblingThread.id,
            text: "occupy sibling",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let siblingOccupying = try XCTUnwrap(siblingOccupyingResult.runId)

        let victimDispatch = MilestoneBoundedHandoffDispatch {
            await router.dispatchAgentAppBotMentions(
                peers: [quinn],
                text: "@\(quinn.handle) T005_DELETE_AGENT_VICTIM",
                threadId: victimThread.id,
                onto: surface,
                continueHost: true
            )
        }
        let siblingDispatch = MilestoneBoundedHandoffDispatch {
            await router.dispatchAgentAppBotMentions(
                peers: [quinn],
                text: "@\(quinn.handle) T005_DELETE_AGENT_SIBLING",
                threadId: siblingThread.id,
                onto: surface,
                continueHost: true
            )
        }
        let bothPeersStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("T005_DELETE_AGENT_VICTIM") }
                && peerRunner.requests.contains { $0.prompt.contains("T005_DELETE_AGENT_SIBLING") }
        }
        XCTAssertTrue(bothPeersStarted)
        XCTAssertTrue(peerRunner.finish(
            promptContaining: "T005_DELETE_AGENT_VICTIM",
            reply: "victim queued reply"
        ))
        XCTAssertTrue(peerRunner.finish(
            promptContaining: "T005_DELETE_AGENT_SIBLING",
            reply: "sibling queued reply"
        ))
        let bothHostsQueued = await waitUntil(timeout: 5) {
            let victim = botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: victimThread.id
            ).first
            let sibling = botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: siblingThread.id
            ).first
            guard let victimRunID = victim?.hostRunID,
                  let siblingRunID = sibling?.hostRunID else { return false }
            return (try? context.queuedMessageRepo.get(id: AgentQueuedMessageID(victimRunID.value))) != nil
                && (try? context.queuedMessageRepo.get(id: AgentQueuedMessageID(siblingRunID.value))) != nil
        }
        XCTAssertTrue(bothHostsQueued)
        let victimDispatchSettled = await victimDispatch.settle(timeout: 5)
        XCTAssertTrue(victimDispatchSettled, "WHY: the victim dispatch must reach its milestone; an unbounded wait would hang the class instead of reporting")
        let siblingDispatchSettled = await siblingDispatch.settle(timeout: 5)
        XCTAssertTrue(siblingDispatchSettled, "WHY: the sibling dispatch must reach its milestone; an unbounded wait would hang the class instead of reporting")
        let victimHandoff = try XCTUnwrap(botsViewModel.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: victimThread.id
        ).first)
        let siblingHandoff = try XCTUnwrap(botsViewModel.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: siblingThread.id
        ).first)
        let victimFutureRunID = try XCTUnwrap(victimHandoff.hostRunID)
        let siblingFutureRunID = try XCTUnwrap(siblingHandoff.hostRunID)
        XCTAssertNotEqual(victimFutureRunID, victimOccupying)
        XCTAssertNotEqual(siblingFutureRunID, siblingOccupying)
        let legacyBytes = Data(#"{"t005":"agent-delete-v1-exact"}"#.utf8)
        UserDefaults.standard.set(legacyBytes, forKey: "bots.peerTurns")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        try await router.deleteAgentThread(thread: victimThread.id)
        let victimRetired = await waitUntil(timeout: 2) {
            botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: victimThread.id
            ).isEmpty
        }
        XCTAssertTrue(victimRetired, "the production router deletion must retire the victim authority row")
        XCTAssertNil(try context.threadRepo.get(id: victimThread.id))
        XCTAssertNil(try context.queuedMessageRepo.get(id: AgentQueuedMessageID(victimFutureRunID.value)))
        XCTAssertFalse(
            hostRunner.requests.contains { $0.runId == victimFutureRunID },
            "deletion suppression must prevent the victim future run from reaching the provider"
        )
        XCTAssertEqual(
            botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: siblingThread.id
            ).first?.hostRunID,
            siblingFutureRunID
        )
        XCTAssertNotNil(try context.queuedMessageRepo.get(id: AgentQueuedMessageID(siblingFutureRunID.value)))
        XCTAssertEqual(try context.runRepo.get(id: siblingOccupying)?.status, .running)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)

        botsViewModel.reconcilePeerHandoffsForTesting()
        let reloaded = BotsViewModel(context: context, router: router)
        XCTAssertTrue(reloaded.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: victimThread.id
        ).isEmpty)
        XCTAssertEqual(
            reloaded.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: siblingThread.id
            ).first?.hostRunID,
            siblingFutureRunID,
            "fresh authority state must preserve the sibling without resurrecting the victim"
        )
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)
        try await router.deleteAgentThread(thread: siblingThread.id)
    }

    func test_agentAppSurfaceRelationalDeleteRetiresQueuedVictimWhileActiveSiblingSurvives() async throws {
        // WHY: the Agent App rail uses its relational-snapshot delete entrypoint,
        // not AppCommandRouter.deleteAgentThread. That production path must retire
        // the same queued authority row without cancelling an active sibling.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-surface-delete-handoff-\(UUID().uuidString)", isDirectory: true)
        let workspaceDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let context = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let botsViewModel = BotsViewModel(context: context, router: router)
        router.botsViewModel = botsViewModel
        let quinn = try botsViewModel.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        botsViewModel.openDesk(quinn)
        botsViewModel.setDeskProvider(.claude)
        wireCallerThreadHandoff(
            context: context,
            peer: quinn,
            peerRunner: peerRunner,
            hostRunner: hostRunner
        )
        let workspace = try router.createWorkspace(name: "t005 surface delete", cwd: workspaceDirectory.path)
        let victimThread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Surface victim",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let siblingThread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Surface sibling",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "T005 Agent App"
        )
        let surface = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
        )
        surface.viewModel.selectThread(victimThread.id)
        let occupyingResult = try await router.sendAgentMessage(
            thread: victimThread.id,
            text: "occupy victim for queued host",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let occupyingRunID = try XCTUnwrap(occupyingResult.runId)

        let victimDispatch = MilestoneBoundedHandoffDispatch {
            await router.dispatchAgentAppBotMentions(
                peers: [quinn],
                text: "@\(quinn.handle) T005_SURFACE_DELETE_VICTIM",
                threadId: victimThread.id,
                onto: surface,
                continueHost: true
            )
        }
        let siblingDispatch = MilestoneBoundedHandoffDispatch {
            await router.dispatchAgentAppBotMentions(
                peers: [quinn],
                text: "@\(quinn.handle) T005_SURFACE_DELETE_SIBLING",
                threadId: siblingThread.id,
                onto: surface,
                continueHost: true
            )
        }
        let bothPeersStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("T005_SURFACE_DELETE_VICTIM") }
                && peerRunner.requests.contains { $0.prompt.contains("T005_SURFACE_DELETE_SIBLING") }
        }
        XCTAssertTrue(bothPeersStarted)
        XCTAssertTrue(peerRunner.finish(
            promptContaining: "T005_SURFACE_DELETE_VICTIM",
            reply: "victim future host reply"
        ))
        let victimQueued = await waitUntil(timeout: 5) {
            guard let futureRunID = botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: victimThread.id
            ).first?.hostRunID else { return false }
            return (try? context.queuedMessageRepo.get(id: AgentQueuedMessageID(futureRunID.value))) != nil
        }
        XCTAssertTrue(victimQueued)
        let siblingRunning = await waitUntil(timeout: 5) {
            botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: siblingThread.id
            ).first?.phase == .peerRunning
        }
        XCTAssertTrue(siblingRunning)
        let victimHandoff = try XCTUnwrap(botsViewModel.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: victimThread.id
        ).first)
        let siblingHandoff = try XCTUnwrap(botsViewModel.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: siblingThread.id
        ).first)
        let victimFutureRunID = try XCTUnwrap(victimHandoff.hostRunID)
        let siblingPeerRunID = try XCTUnwrap(siblingHandoff.peerRunID)
        let legacyBytes = Data(#"{"t005":"surface-delete-v1-exact"}"#.utf8)
        UserDefaults.standard.set(legacyBytes, forKey: "bots.peerTurns")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        let deleted = await surface.viewModel.deleteThread(victimThread.id)
        XCTAssertTrue(deleted, "the real relational delete must commit before authority retirement")
        let victimRetired = await waitUntil(timeout: 2) {
            botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: victimThread.id
            ).isEmpty
        }
        XCTAssertTrue(victimRetired, "Agent App relational deletion must retire the victim authority row")
        XCTAssertNil(try context.threadRepo.get(id: victimThread.id))
        XCTAssertNil(try context.queuedMessageRepo.get(id: AgentQueuedMessageID(victimFutureRunID.value)))
        XCTAssertFalse(hostRunner.requests.contains { $0.runId == victimFutureRunID })
        XCTAssertNil(try context.runRepo.get(id: occupyingRunID))
        XCTAssertFalse(
            hostRunner.finish(runID: occupyingRunID, status: .completed, reply: "late occupying reply"),
            "relational deletion must stop the provider before its cascaded run row disappears"
        )
        XCTAssertFalse(context.coordinator.hasProviderSession(threadId: victimThread.id))
        XCTAssertEqual(
            botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: siblingThread.id
            ).first?.peerRunID,
            siblingPeerRunID
        )
        XCTAssertEqual(try context.runRepo.get(id: siblingPeerRunID)?.status, .running)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)

        botsViewModel.reconcilePeerHandoffsForTesting()
        let reloaded = BotsViewModel(context: context, router: router)
        XCTAssertTrue(reloaded.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: victimThread.id
        ).isEmpty)
        XCTAssertEqual(
            reloaded.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: siblingThread.id
            ).first?.peerRunID,
            siblingPeerRunID
        )
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)
        let victimDispatchSettled = await victimDispatch.settle(timeout: 5)
        XCTAssertTrue(victimDispatchSettled, "WHY: the victim dispatch must reach its milestone; an unbounded wait would hang the class instead of reporting")
        XCTAssertTrue(peerRunner.finish(
            runID: siblingPeerRunID,
            status: .cancelled,
            reply: nil
        ))
        let siblingDispatchSettled = await siblingDispatch.settle(timeout: 5)
        XCTAssertTrue(siblingDispatchSettled, "WHY: the sibling dispatch must reach its milestone; an unbounded wait would hang the class instead of reporting")
        try await router.deleteAgentThread(thread: siblingThread.id)
    }

    func test_routerDeleteRollbackResumesExactTerminalHandoffAfterSourceFailureWithoutRedispatch() async throws {
        // WHY: deletion fencing starts before provider shutdown can suspend.
        // If the exact peer finishes inside that window but source deletion
        // fails, rollback must release that same durable result—not strand it,
        // retire it, or launch the peer a second time—while a sibling stays live.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-delete-rollback-fence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        let hostRunner = ControlledBotHandoffRunner(
            provider: .codex,
            defersCancellationForTesting: true
        )
        let fixture = try makeT005AgentMentionFixture(
            root: root,
            peerRunner: peerRunner,
            hostRunner: hostRunner
        )
        let victimThread = try XCTUnwrap(fixture.context.threadRepo.get(id: fixture.threadID))
        let workspaceID = try XCTUnwrap(victimThread.workspaceId)
        let siblingThread = try fixture.router.createAgentThread(
            workspace: workspaceID,
            title: "T005 rollback sibling",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let occupying = try await fixture.router.sendAgentMessage(
            thread: fixture.threadID,
            text: "occupy deletion target until rollback cut",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let occupyingRunID = try XCTUnwrap(occupying.runId)

        let victimDispatch = MilestoneBoundedHandoffDispatch {
            await fixture.router.dispatchAgentAppBotMentions(
                peers: [fixture.peer],
                text: "@\(fixture.peer.handle) T005_ROLLBACK_VICTIM",
                threadId: fixture.threadID,
                onto: fixture.surface,
                continueHost: true
            )
        }
        let siblingDispatch = MilestoneBoundedHandoffDispatch {
            await fixture.router.dispatchAgentAppBotMentions(
                peers: [fixture.peer],
                text: "@\(fixture.peer.handle) T005_ROLLBACK_SIBLING",
                threadId: siblingThread.id,
                onto: fixture.surface,
                continueHost: true
            )
        }
        let bothPeersStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("T005_ROLLBACK_VICTIM") }
                && peerRunner.requests.contains { $0.prompt.contains("T005_ROLLBACK_SIBLING") }
        }
        XCTAssertTrue(bothPeersStarted)
        let bothPeersDurablyRunning = await waitUntil(timeout: 2) {
            fixture.botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: fixture.threadID
            ).first?.phase == .peerRunning
                && fixture.botsViewModel.peerHandoffSnapshotsForTesting(
                    originConversationID: nil,
                    originThreadID: siblingThread.id
                ).first?.phase == .peerRunning
        }
        XCTAssertTrue(
            bothPeersDurablyRunning,
            "the deletion cut begins only after both accepted provider starts are durably peerRunning"
        )
        let victimHandoff = try XCTUnwrap(fixture.botsViewModel.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: fixture.threadID
        ).first)
        let siblingHandoff = try XCTUnwrap(fixture.botsViewModel.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: siblingThread.id
        ).first)
        let victimPeerRunID = try XCTUnwrap(victimHandoff.peerRunID)
        let victimPeerThreadID = try XCTUnwrap(victimHandoff.peerThreadID)
        let victimHostRunID = try XCTUnwrap(victimHandoff.hostRunID)
        let siblingPeerRunID = try XCTUnwrap(siblingHandoff.peerRunID)
        let legacyBytes = Data(#"{"t005":"rollback-v1-exact"}"#.utf8)
        UserDefaults.standard.set(legacyBytes, forKey: "bots.peerTurns")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        try fixture.context.db.execute("""
            CREATE TRIGGER fail_t005_router_source_delete
            BEFORE DELETE ON agent_threads
            WHEN OLD.id = '\(fixture.threadID.value.uuidString)'
            BEGIN
                SELECT RAISE(ABORT, 'forced T005 source delete failure');
            END;
        """)
        defer { try? fixture.context.db.execute("DROP TRIGGER fail_t005_router_source_delete;") }

        let deletionFinished = QueueDrainAsyncSignal()
        let deletion = Task { @MainActor () -> Error? in
            do {
                try await fixture.router.deleteAgentThread(thread: fixture.threadID)
                await deletionFinished.signal()
                return nil
            } catch {
                await deletionFinished.signal()
                return error
            }
        }
        let cancellationReachedFence = await waitUntil(timeout: 2) {
            hostRunner.cancellationRequestedRunIDs.contains(occupyingRunID)
        }
        XCTAssertTrue(cancellationReachedFence)
        let deletionFinishedBeforeTerminal = await deletionFinished.isSignalled
        XCTAssertFalse(deletionFinishedBeforeTerminal)

        XCTAssertTrue(peerRunner.finish(
            runID: victimPeerRunID,
            status: .completed,
            reply: "EXACT_REPLY_DURING_DELETE_FENCE"
        ))
        let exactTerminalPersisted = await waitUntil(timeout: 2) {
            guard (try? fixture.context.runRepo.get(id: victimPeerRunID)?.status) == .completed,
                  let checkpoint = try? fixture.context.turnCheckpointRepo
                    .list(threadId: victimPeerThreadID)
                    .first(where: { $0.runId == victimPeerRunID }) else { return false }
            return checkpoint.assistantMessageId != nil
        }
        XCTAssertTrue(exactTerminalPersisted)
        let deletionFinishedAfterTerminal = await deletionFinished.isSignalled
        XCTAssertFalse(deletionFinishedAfterTerminal)
        XCTAssertEqual(
            fixture.botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: fixture.threadID
            ).first?.phase,
            .peerRunning,
            "the terminal must wait behind the deletion fence until commit or rollback"
        )

        XCTAssertTrue(hostRunner.finish(
            runID: occupyingRunID,
            status: .cancelled,
            reply: nil
        ))
        let deletionError = await deletion.value
        XCTAssertNotNil(deletionError, "the SQLite trigger must reject the source delete")
        XCTAssertNotNil(try fixture.context.threadRepo.get(id: fixture.threadID))

        let exactHostStarted = await waitUntil(timeout: 5) {
            hostRunner.requests.contains { $0.runId == victimHostRunID }
        }
        XCTAssertTrue(exactHostStarted, "rollback must resume the fenced exact handoff")
        XCTAssertEqual(
            peerRunner.requests.filter { $0.runId == victimPeerRunID }.count,
            1,
            "rollback must never redispatch the already-terminal peer"
        )
        XCTAssertEqual(hostRunner.requests.filter { $0.runId == victimHostRunID }.count, 1)
        let inbound = try XCTUnwrap(
            try fixture.context.messageRepo.get(id: AgentMessageID(victimHandoff.inboundMessageID))
        )
        XCTAssertEqual(
            BotPeerTranscript.parse(inbound.content)?.body,
            "EXACT_REPLY_DURING_DELETE_FENCE"
        )
        XCTAssertTrue(hostRunner.finish(
            runID: victimHostRunID,
            status: .completed,
            reply: "EXACT_HOST_AFTER_ROLLBACK"
        ))
        let victimCompleted = await waitUntil(timeout: 5) {
            fixture.botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: fixture.threadID
            ).first?.phase == .completed
        }
        XCTAssertTrue(victimCompleted)

        let preservedSibling = try XCTUnwrap(fixture.botsViewModel.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: siblingThread.id
        ).first)
        XCTAssertEqual(preservedSibling.activityID, siblingHandoff.activityID)
        XCTAssertEqual(preservedSibling.peerRunID, siblingPeerRunID)
        XCTAssertEqual(preservedSibling.phase, .peerRunning)
        XCTAssertEqual(peerRunner.requests.filter { $0.runId == siblingPeerRunID }.count, 1)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)

        let victimDispatchSettled = await victimDispatch.settle(timeout: 5)
        XCTAssertTrue(victimDispatchSettled, "WHY: the victim dispatch must reach its milestone; an unbounded wait would hang the class instead of reporting")
        XCTAssertTrue(peerRunner.finish(
            runID: siblingPeerRunID,
            status: .cancelled,
            reply: nil
        ))
        let siblingDispatchSettled = await siblingDispatch.settle(timeout: 5)
        XCTAssertTrue(siblingDispatchSettled, "WHY: the sibling dispatch must reach its milestone; an unbounded wait would hang the class instead of reporting")
    }

    func test_peerHandoffAtomicCommitCutsConvergeSQLiteMirrorAndFreshAuthoritiesBeforeDispatch() async throws {
        // WHY: UserDefaults set/synchronize/readback cannot roll back a mirror
        // write. SQLite must remain the one commit authority at every crash cut,
        // and a fresh process must repair the raw mirror before it can dispatch.
        enum Cut: String, CaseIterable {
            case beforeMirrorSet
            case afterMirrorSetBeforeGateReturn
            case sqliteCommit
        }

        let suiteRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-peer-atomic-cuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: suiteRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: suiteRoot) }
        defer {
            UserDefaults.standard.removeObject(forKey: "bots.peerTurns")
            UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
        }
        let settingsKey = "bots.peerTurns.v2"
        let baselineBytes = Data("[]".utf8)
        let baselineSQLite = "base64:\(baselineBytes.base64EncodedString())"

        for cut in Cut.allCases {
            let root = suiteRoot.appendingPathComponent(cut.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let v1Bytes = Data("{\"t005\":\"atomic-\(cut.rawValue)-v1\"}".utf8)
            UserDefaults.standard.set(v1Bytes, forKey: "bots.peerTurns")
            UserDefaults.standard.set(baselineBytes, forKey: settingsKey)
            XCTAssertTrue(UserDefaults.standard.synchronize())

            var dispatches: [AgentRunID] = []
            let fixture = try makeT005PeerPersistenceContext(root: root) {
                dispatches.append($0)
            }
            let piper = try fixture.viewModel.create(
                name: "Piper \(cut.rawValue)",
                title: "Atomic origin",
                provider: .codex
            )
            let quinn = try fixture.viewModel.create(
                name: "Quinn \(cut.rawValue)",
                title: "Atomic peer",
                provider: .claude
            )
            fixture.viewModel.openDesk(quinn)
            fixture.viewModel.setDeskProvider(.claude)
            fixture.viewModel.openDesk(piper)
            fixture.viewModel.setDeskProvider(.codex)
            fixture.viewModel.createDeskThread()

            var capturedCandidate: Data?
            var failCommit = false
            fixture.context.db.beforeExecuteForTesting = { sql in
                guard failCommit, sql == "COMMIT;" else { return }
                failCommit = false
                fixture.context.db.injectedResultCodesForTesting.append(10) // SQLITE_IOERR
            }
            fixture.context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = { data in
                capturedCandidate = data
                if cut == .beforeMirrorSet {
                    throw NSError(domain: "T005.AtomicCut", code: 1)
                }
                UserDefaults.standard.set(data, forKey: settingsKey)
                guard UserDefaults.standard.synchronize(),
                      UserDefaults.standard.data(forKey: settingsKey) == data else {
                    throw NSError(domain: "T005.AtomicCut", code: 2)
                }
                if cut == .afterMirrorSetBeforeGateReturn {
                    throw NSError(domain: "T005.AtomicCut", code: 3)
                }
                failCommit = true
            }

            let accepted = try submitT005DeskPeerMention(
                context: fixture.context,
                viewModel: fixture.viewModel,
                host: piper,
                peer: quinn,
                provider: .claude,
                text: "@\(quinn.handle) T005_ATOMIC_\(cut.rawValue)"
            )
            fixture.context.db.beforeExecuteForTesting = nil
            fixture.context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = nil
            failCommit = false
            XCTAssertNotNil(capturedCandidate, "\(cut.rawValue) must reach the exact candidate mirror gate")
            XCTAssertNil(accepted, "\(cut.rawValue) must reject the uncommitted handoff")

            _ = await waitUntil(timeout: 0.2) { !dispatches.isEmpty }
            XCTAssertTrue(dispatches.isEmpty, "\(cut.rawValue) must not cross the provider boundary")
            if let peerRunID = fixture.peerRunner.requests.first?.runId {
                _ = fixture.peerRunner.finish(runID: peerRunID, status: .cancelled, reply: nil)
                _ = await waitUntil(timeout: 1) {
                    (try? fixture.context.runRepo.get(id: peerRunID)?.status) == .cancelled
                }
            }

            XCTAssertTrue(fixture.viewModel.peerHandoffSnapshotsForTesting().isEmpty)
            XCTAssertEqual(try fixture.context.settingsRepo.get(settingsKey), baselineSQLite)
            XCTAssertEqual(UserDefaults.standard.data(forKey: settingsKey), baselineBytes)
            XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), v1Bytes)

            var firstRelaunchDispatches: [AgentRunID] = []
            let firstRelaunch = try makeT005PeerPersistenceContext(root: root) {
                firstRelaunchDispatches.append($0)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(firstRelaunchDispatches.isEmpty)
            XCTAssertTrue(firstRelaunch.viewModel.peerHandoffSnapshotsForTesting().isEmpty)
            XCTAssertTrue(firstRelaunch.viewModel.liveWorkingBots().isEmpty)
            XCTAssertEqual(try firstRelaunch.context.settingsRepo.get(settingsKey), baselineSQLite)
            XCTAssertEqual(UserDefaults.standard.data(forKey: settingsKey), baselineBytes)
            XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), v1Bytes)

            var secondRelaunchDispatches: [AgentRunID] = []
            let secondRelaunch = try makeT005PeerPersistenceContext(root: root) {
                secondRelaunchDispatches.append($0)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(secondRelaunchDispatches.isEmpty)
            XCTAssertTrue(secondRelaunch.viewModel.peerHandoffSnapshotsForTesting().isEmpty)
            XCTAssertTrue(secondRelaunch.viewModel.liveWorkingBots().isEmpty)
            XCTAssertEqual(try secondRelaunch.context.settingsRepo.get(settingsKey), baselineSQLite)
            XCTAssertEqual(UserDefaults.standard.data(forKey: settingsKey), baselineBytes)
            XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), v1Bytes)
        }
    }

    func test_peerHandoffFutureMirrorDivergenceStaysByteExactAndMutationFailsClosed() async throws {
        // WHY: an older build must never repair over bytes owned by a newer
        // envelope. Even with a valid SQLite baseline, a divergent future raw
        // mirror is opaque and blocks mutation/provider launch byte-for-byte.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-peer-future-divergence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer {
            UserDefaults.standard.removeObject(forKey: "bots.peerTurns")
            UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
        }
        let settingsKey = "bots.peerTurns.v2"
        let baselineBytes = Data("[]".utf8)
        let baselineSQLite = "base64:\(baselineBytes.base64EncodedString())"
        let v1Bytes = Data(#"{"t005":"future-divergence-v1-exact"}"#.utf8)
        UserDefaults.standard.set(v1Bytes, forKey: "bots.peerTurns")
        UserDefaults.standard.set(baselineBytes, forKey: settingsKey)
        XCTAssertTrue(UserDefaults.standard.synchronize())

        var initialDispatches: [AgentRunID] = []
        let fixture = try makeT005PeerPersistenceContext(root: root) {
            initialDispatches.append($0)
        }
        try fixture.context.settingsRepo.set(settingsKey, baselineSQLite)
        let piper = try fixture.viewModel.create(
            name: "Piper future divergence",
            title: "Opaque origin",
            provider: .codex
        )
        let quinn = try fixture.viewModel.create(
            name: "Quinn future divergence",
            title: "Opaque peer",
            provider: .claude
        )
        fixture.viewModel.openDesk(quinn)
        fixture.viewModel.setDeskProvider(.claude)
        fixture.viewModel.openDesk(piper)
        fixture.viewModel.setDeskProvider(.codex)
        fixture.viewModel.createDeskThread()
        var candidateBytes: Data?
        fixture.context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = { data in
            candidateBytes = data
            throw NSError(domain: "T005.FutureFixture", code: 1)
        }
        let accepted = try submitT005DeskPeerMention(
            context: fixture.context,
            viewModel: fixture.viewModel,
            host: piper,
            peer: quinn,
            provider: .claude,
            text: "@\(quinn.handle) T005_CAPTURE_FUTURE_CANDIDATE"
        )
        XCTAssertNil(accepted, "the candidate must be refused while the mirror commit fails")
        fixture.context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = nil
        XCTAssertTrue(initialDispatches.isEmpty)

        var entries = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(candidateBytes)) as? [Any]
        )
        let recordIndex = try XCTUnwrap(entries.firstIndex { $0 is [String: Any] })
        var futureRecord = try XCTUnwrap(entries[recordIndex] as? [String: Any])
        futureRecord["version"] = 3
        futureRecord["futureOpaqueField"] = ["owner": "newer-build", "preserve": true]
        entries[recordIndex] = futureRecord
        let futureBytes = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        UserDefaults.standard.set(futureBytes, forKey: settingsKey)
        XCTAssertTrue(UserDefaults.standard.synchronize())

        var relaunchDispatches: [AgentRunID] = []
        let relaunch = try makeT005PeerPersistenceContext(root: root) {
            relaunchDispatches.append($0)
        }
        XCTAssertTrue(relaunch.viewModel.peerHandoffSnapshotsForTesting().isEmpty)
        XCTAssertEqual(try relaunch.context.settingsRepo.get(settingsKey), baselineSQLite)
        XCTAssertEqual(UserDefaults.standard.data(forKey: settingsKey), futureBytes)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), v1Bytes)

        relaunch.viewModel.openDesk(quinn)
        relaunch.viewModel.setDeskProvider(.claude)
        relaunch.viewModel.openDesk(piper)
        relaunch.viewModel.setDeskProvider(.codex)
        relaunch.viewModel.createDeskThread()
        let relaunchAccepted = try submitT005DeskPeerMention(
            context: relaunch.context,
            viewModel: relaunch.viewModel,
            host: piper,
            peer: quinn,
            provider: .claude,
            text: "@\(quinn.handle) T005_FUTURE_MUST_NOT_MUTATE"
        )
        XCTAssertNil(relaunchAccepted, "future/opaque divergence must refuse a down-level mutation")
        _ = await waitUntil(timeout: 0.2) { !relaunchDispatches.isEmpty }
        XCTAssertTrue(relaunchDispatches.isEmpty, "fail-closed restore must precede provider dispatch")
        XCTAssertTrue(relaunch.viewModel.peerHandoffSnapshotsForTesting().isEmpty)
        XCTAssertEqual(try relaunch.context.settingsRepo.get(settingsKey), baselineSQLite)
        XCTAssertEqual(UserDefaults.standard.data(forKey: settingsKey), futureBytes)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), v1Bytes)

        if let peerRunID = relaunch.peerRunner.requests.first?.runId {
            _ = relaunch.peerRunner.finish(runID: peerRunID, status: .cancelled, reply: nil)
        }
    }

    func test_peerHandoffPostCacheOpaqueMirrorDriftFailsClosedWithoutOverwriteOrDispatch() async throws {
        // WHY: a future writer can replace the compatibility mirror after this
        // authority cached a supported row. The next mutation must inspect raw
        // mirror identity before CAS and must never overwrite opaque bytes.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-peer-post-cache-opaque-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer {
            UserDefaults.standard.removeObject(forKey: "bots.peerTurns")
            UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
        }
        let v1Bytes = Data(#"{"t005":"post-cache-opaque-v1"}"#.utf8)
        let fixture = try makeT005CachedPeerHandoffFixture(root: root, v1Bytes: v1Bytes)
        let canonicalValue = "base64:\(fixture.seedBytes.base64EncodedString())"
        let futureBytes = try t005PeerHandoffPayload(
            fixture.seedBytes,
            replacingVersion: 3,
            addingOpaqueField: true
        )
        UserDefaults.standard.set(futureBytes, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        var mirrorGateCalls = 0
        fixture.context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = { data in
            mirrorGateCalls += 1
            UserDefaults.standard.set(data, forKey: "bots.peerTurns.v2")
            guard UserDefaults.standard.synchronize(),
                  UserDefaults.standard.data(forKey: "bots.peerTurns.v2") == data else {
                throw NSError(domain: "T005.PostCacheOpaqueMirror", code: 1)
            }
        }
        let accepted = try submitT005DeskPeerMention(
            context: fixture.context,
            viewModel: fixture.viewModel,
            host: fixture.piper,
            peer: fixture.quinn,
            provider: .claude,
            text: "@\(fixture.quinn.handle) POST_CACHE_OPAQUE_MUST_FAIL"
        )
        XCTAssertNil(accepted, "opaque mirror bytes must refuse the mutation")
        _ = await waitUntil(timeout: 0.2) { !fixture.dispatches.runIDs.isEmpty }
        XCTAssertEqual(mirrorGateCalls, 0)
        XCTAssertTrue(fixture.dispatches.runIDs.isEmpty)
        XCTAssertTrue(fixture.peerRunner.requests.isEmpty)
        XCTAssertEqual(try fixture.context.settingsRepo.get("bots.peerTurns.v2"), canonicalValue)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"), futureBytes)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), v1Bytes)
    }

    func test_peerHandoffCachedSQLiteCASMismatchRejectsStaleCandidateAndAdoptsCanonicalExactly() async throws {
        // WHY: another writer can commit a new canonical sibling after this
        // authority cached its candidate. The first stale mutation must lose,
        // refresh the exact newer snapshot, and only a newly-built candidate
        // may proceed through the mirror gate.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-peer-cached-cas-mismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer {
            UserDefaults.standard.removeObject(forKey: "bots.peerTurns")
            UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
        }
        let v1Bytes = Data(#"{"t005":"cached-cas-v1"}"#.utf8)
        let fixture = try makeT005CachedPeerHandoffFixture(root: root, v1Bytes: v1Bytes)
        let (newerBytes, siblingActivityID) = try t005PeerHandoffPayloadAddingSibling(
            fixture.seedBytes
        )
        let newerCanonical = "base64:\(newerBytes.base64EncodedString())"
        try fixture.context.settingsRepo.set("bots.peerTurns.v2", newerCanonical)
        UserDefaults.standard.set(newerBytes, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        var mirrorGateCalls = 0
        fixture.context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = { data in
            mirrorGateCalls += 1
            UserDefaults.standard.set(data, forKey: "bots.peerTurns.v2")
            guard UserDefaults.standard.synchronize(),
                  UserDefaults.standard.data(forKey: "bots.peerTurns.v2") == data else {
                throw NSError(domain: "T005.CachedCASMismatch", code: 1)
            }
        }
        let staleAccepted = try submitT005DeskPeerMention(
            context: fixture.context,
            viewModel: fixture.viewModel,
            host: fixture.piper,
            peer: fixture.quinn,
            provider: .claude,
            text: "@\(fixture.quinn.handle) STALE_CANDIDATE_MUST_LOSE"
        )
        guard staleAccepted == nil else {
            if let peerRunID = fixture.peerRunner.requests.first?.runId {
                _ = fixture.peerRunner.finish(runID: peerRunID, status: .cancelled, reply: nil)
            }
            return XCTFail("a stale candidate must not overwrite the newer canonical sibling")
        }
        XCTAssertEqual(mirrorGateCalls, 0)
        XCTAssertTrue(fixture.dispatches.runIDs.isEmpty)
        XCTAssertEqual(try fixture.context.settingsRepo.get("bots.peerTurns.v2"), newerCanonical)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"), newerBytes)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), v1Bytes)
        XCTAssertNotNil(
            fixture.viewModel.peerHandoffSnapshotsForTesting().first {
                $0.activityID == siblingActivityID
            },
            "refresh must adopt the exact externally committed sibling"
        )

        let freshAccepted = try submitT005DeskPeerMention(
            context: fixture.context,
            viewModel: fixture.viewModel,
            host: fixture.piper,
            peer: fixture.quinn,
            provider: .claude,
            text: "@\(fixture.quinn.handle) FRESH_CANDIDATE_MAY_WIN"
        )
        XCTAssertNotNil(freshAccepted, "a fresh candidate over the refreshed canonical state must commit")
        // The submit commits synchronously; later phase writes also mirror, so
        // only this reading isolates the mutation's own gate call.
        XCTAssertEqual(mirrorGateCalls, 1, "only the fresh candidate may reach the mirror gate")
        let dispatched = await waitUntil(timeout: 5) { fixture.dispatches.runIDs.count == 1 }
        XCTAssertTrue(dispatched)
        let peerStarted = await waitUntil(timeout: 5) { !fixture.peerRunner.requests.isEmpty }
        XCTAssertTrue(
            peerStarted,
            "the committed peer run must reach the runner the origin thread's provider selects"
        )
        let peerRunID = try XCTUnwrap(fixture.peerRunner.requests.first?.runId)
        XCTAssertTrue(fixture.peerRunner.finish(runID: peerRunID, status: .cancelled, reply: nil))
    }

    func test_peerHandoffSupportedMirrorDivergenceRepairsCanonicalWithoutApplyingFirstStaleMutation() async throws {
        // WHY: a supported but stale mirror is repairable from SQLite, yet the
        // candidate built before that refresh is stale too. Repair and mutation
        // must be two separate attempts so the first never drops canonical rows.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-peer-supported-mirror-drift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer {
            UserDefaults.standard.removeObject(forKey: "bots.peerTurns")
            UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
        }
        let v1Bytes = Data(#"{"t005":"supported-mirror-drift-v1"}"#.utf8)
        let fixture = try makeT005CachedPeerHandoffFixture(root: root, v1Bytes: v1Bytes)
        let canonicalValue = "base64:\(fixture.seedBytes.base64EncodedString())"
        let supportedButStaleMirror = Data("[]".utf8)
        UserDefaults.standard.set(supportedButStaleMirror, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        var mirrorGateCalls = 0
        fixture.context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = { data in
            mirrorGateCalls += 1
            UserDefaults.standard.set(data, forKey: "bots.peerTurns.v2")
            guard UserDefaults.standard.synchronize(),
                  UserDefaults.standard.data(forKey: "bots.peerTurns.v2") == data else {
                throw NSError(domain: "T005.SupportedMirrorDrift", code: 1)
            }
        }
        let staleAccepted = try submitT005DeskPeerMention(
            context: fixture.context,
            viewModel: fixture.viewModel,
            host: fixture.piper,
            peer: fixture.quinn,
            provider: .claude,
            text: "@\(fixture.quinn.handle) REPAIR_BEFORE_MUTATION"
        )
        guard staleAccepted == nil else {
            if let peerRunID = fixture.peerRunner.requests.first?.runId {
                _ = fixture.peerRunner.finish(runID: peerRunID, status: .cancelled, reply: nil)
            }
            return XCTFail("repair must not apply the candidate built against the stale mirror")
        }
        XCTAssertEqual(mirrorGateCalls, 0)
        XCTAssertTrue(fixture.dispatches.runIDs.isEmpty)
        XCTAssertEqual(try fixture.context.settingsRepo.get("bots.peerTurns.v2"), canonicalValue)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"), fixture.seedBytes)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), v1Bytes)
        XCTAssertNotNil(
            fixture.viewModel.peerHandoffSnapshotsForTesting().first {
                $0.activityID == fixture.seedActivityID
            }
        )

        let freshAccepted = try submitT005DeskPeerMention(
            context: fixture.context,
            viewModel: fixture.viewModel,
            host: fixture.piper,
            peer: fixture.quinn,
            provider: .claude,
            text: "@\(fixture.quinn.handle) FRESH_AFTER_REPAIR"
        )
        XCTAssertNotNil(freshAccepted, "a candidate rebuilt after the repair must commit")
        // The submit commits synchronously; later phase writes also mirror, so
        // only this reading isolates the mutation's own gate call.
        XCTAssertEqual(mirrorGateCalls, 1, "only the candidate rebuilt after the repair may reach the mirror gate")
        let dispatched = await waitUntil(timeout: 5) { fixture.dispatches.runIDs.count == 1 }
        XCTAssertTrue(dispatched)
        let peerStarted = await waitUntil(timeout: 5) { !fixture.peerRunner.requests.isEmpty }
        XCTAssertTrue(
            peerStarted,
            "the committed peer run must reach the runner the origin thread's provider selects"
        )
        let peerRunID = try XCTUnwrap(fixture.peerRunner.requests.first?.runId)
        XCTAssertTrue(fixture.peerRunner.finish(runID: peerRunID, status: .cancelled, reply: nil))
    }

    func test_deleteThreadSuppressesQueuedDrainBeforeAwaitingProviderTermination() async throws {
        // WHY: thread deletion awaits provider shutdown. A terminal callback in
        // that window must not observe idle and start durable queued work.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: 0.05)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "delete-no-drain", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "delete no drain",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "must never start",
            attachments: [],
            interactionMode: .default
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)

        try await router.deleteAgentThread(thread: thread.id)

        XCTAssertEqual(runner.startCount, 1,
                       "deletion shutdown must not start the queued follow-up")
        XCTAssertNil(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
    }

    func test_overlappingQueueDrainSuppressionLeasesRearmOnlyAfterFinalRelease() async throws {
        // WHY: UI and RPC deletion can overlap for the same thread. Releasing
        // either owner must not rearm queued work while the other still owns
        // destructive shutdown.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "overlapping-delete", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "overlapping delete",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "must remain suppressed",
            attachments: [],
            interactionMode: .default
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)

        let firstLease = await ctx.acquireQueueDrainSuppression(threadId: thread.id)
        let secondLease = await ctx.acquireQueueDrainSuppression(threadId: thread.id)
        XCTAssertEqual(ctx.queueDrainSuppressedThreadCountForTesting, 1)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)

        ctx.releaseQueueDrainSuppression(threadId: thread.id, lease: firstLease)
        XCTAssertEqual(ctx.queueDrainSuppressedThreadCountForTesting, 1)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)

        ctx.releaseQueueDrainSuppression(threadId: thread.id, lease: secondLease)
        XCTAssertEqual(ctx.queueDrainSuppressedThreadCountForTesting, 0)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)
        _ = await ctx.acquireQueueDrainSuppression(threadId: thread.id)
        runner.finishRun(ordinal: 1, status: .cancelled)
    }

    func test_deletionAwaitsInFlightQueueDrainBeforeRemovingThread() async throws {
        // WHY: cancellation alone is not a barrier. A waiter that already
        // entered drain must finish observing cancellation before destructive
        // deletion can remove its thread or start queued work afterward.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "delete-drain-barrier", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "delete drain barrier",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "must not start after delete",
            attachments: [],
            interactionMode: .default
        )
        let barrier = QueueDrainAsyncBarrier()
        ctx.queueDrainBeforeDispatchForTesting = { await barrier.enterAndWait() }
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        runner.finishRun(ordinal: 1, status: .completed)
        await barrier.waitUntilEntered()

        let suppression = QueueDrainAsyncSignal()
        ctx.queueDrainSuppressionAcquiredForTesting = {
            guard $0 == thread.id else { return }
            await suppression.signal()
        }
        let deletion = Task { try await router.deleteAgentThread(thread: thread.id) }
        await suppression.wait()
        XCTAssertNotNil(try ctx.threadRepo.get(id: thread.id),
                        "deletion must await the in-flight waiter cancellation barrier")
        await barrier.release()
        try await deletion.value

        XCTAssertNil(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(runner.startCount, 1)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
    }

    func test_agentAppDeletionSuppressesQueueAfterPreflightBeforeProviderStart() async throws {
        // WHY: queue dispatch awaits provider preflight after its outer guards.
        // Deletion suppression acquired during that suspension must still win at
        // the actual start boundary, release the prepared lease, and preserve
        // the queued intent in the completed deletion's undo snapshot.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "post-preflight-delete", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "post preflight delete",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Agent App"
        )
        let surface = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
        )
        surface.viewModel.selectThread(thread.id)
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "preserve across delete",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let failures = QueueFailureCounter(threadId: thread.id)
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            failures.record($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        let barrier = QueueDrainAsyncBarrier()
        router.queueDispatchBeforeProviderStartForTesting = { await barrier.enterAndWait() }
        runner.finishRun(ordinal: 1, status: .completed)
        await barrier.waitUntilEntered()

        let suppression = QueueDrainAsyncSignal()
        ctx.queueDrainSuppressionAcquiredForTesting = {
            guard $0 == thread.id else { return }
            await suppression.signal()
        }
        let deletion = Task { await surface.viewModel.deleteThread(thread.id) }
        await suppression.wait()
        XCTAssertNotNil(try ctx.threadRepo.get(id: thread.id))
        await barrier.release()
        let deleted = await deletion.value
        XCTAssertTrue(deleted)

        XCTAssertEqual(runner.startCount, 1,
                       "suppression after preflight must prevent queued provider start")
        XCTAssertEqual(failures.count, 0,
                       "deliberate suppression cancellation must not report a queue failure")
        XCTAssertNil(try ctx.threadRepo.get(id: thread.id),
                     "the deletion owner must complete after the cancelled drain exits")
        XCTAssertTrue(surface.viewModel.undoLastThreadDeletion())
        XCTAssertEqual(
            try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text),
            ["preserve across delete"],
            "pre-start cancellation must release the prepared lease before deletion snapshots it"
        )
    }

    func test_agentAppBulkDeletionSuppressesEveryThreadBeforeAwaitingStuckDrain() async throws {
        // WHY: bulk deletion must not await thread A's already-entered drain
        // before protecting idle thread B; B can become idle during that wait.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "bulk-delete-barrier", cwd: workspaceDir.path)
        let threads = try (0..<2).map { index in
            try router.createAgentThread(
                workspace: workspace.id,
                title: "bulk \(index)",
                provider: .claude,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
        }
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Agent App"
        )
        let surface = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
        )
        for (index, thread) in threads.enumerated() {
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "running \(index)",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "recover \(index)",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
        }

        let barrier = QueueDrainAsyncBarrier()
        router.queueDispatchBeforeProviderStartForTesting = { await barrier.enterAndWait() }
        runner.finishRun(ordinal: 1, status: .completed)
        await barrier.waitUntilEntered()

        let allSuppressed = QueueDrainAsyncSignal()
        ctx.queueDrainSuppressionAcquiredForTesting = { _ in await allSuppressed.signal() }
        let deletion = Task {
            await surface.viewModel.deleteThreads(Set(threads.map(\.id)))
        }
        await allSuppressed.wait()

        XCTAssertEqual(
            ctx.queueDrainSuppressedThreadCountForTesting,
            2,
            "both leases must exist before bulk deletion awaits A's stuck waiter"
        )
        runner.finishRun(ordinal: 2, status: .completed)
        XCTAssertEqual(runner.startCount, 2,
                       "B becoming idle while A is stuck must not start B's queued prompt")

        await barrier.release()
        let deleted = await deletion.value
        XCTAssertTrue(deleted)
        XCTAssertEqual(runner.startCount, 2)
        XCTAssertTrue(surface.viewModel.undoLastThreadDeletion())
        for (index, thread) in threads.enumerated() {
            XCTAssertEqual(
                try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text),
                ["recover \(index)"]
            )
        }
    }

    func test_routerBulkDeletionStartsEveryStopTogetherAndPreservesAllRowsWhenOneFails() async throws {
        // WHY: bulk deletion is one transaction from the user's perspective.
        // Every provider gets the same shutdown window, and a partial shutdown
        // must not partially delete the durable thread set.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(
            name: "concurrent bulk stop",
            cwd: workspaceDir.path
        )
        let threads = try (0..<2).map { index in
            try router.createAgentThread(
                workspace: workspace.id,
                title: "bulk stop \(index)",
                provider: .claude,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
        }
        let stopBarrier = ConcurrentBulkStopBarrier()
        let runner = ConcurrentBulkStopRunner(
            failingThreadId: threads[1].id,
            barrier: stopBarrier
        )
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        ctx.coordinator.gracefulStopTimeout = 0.05
        ctx.coordinator.hardStopTimeout = 0.15
        for thread in threads {
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "running",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
        }

        let deletion = Task { () -> Error? in
            do {
                try await router.deleteAgentThreads(threads.map(\.id))
                return nil
            } catch {
                return error
            }
        }
        await stopBarrier.waitUntilEntered(2)

        for thread in threads {
            XCTAssertNotNil(
                try ctx.threadRepo.get(id: thread.id),
                "no row may be deleted while any member of the batch is still stopping"
            )
        }
        stopBarrier.releaseAll(2)

        let failure = await deletion.value
        XCTAssertNotNil(failure, "one unconfirmed provider termination must fail the whole batch")
        for thread in threads {
            XCTAssertNotNil(
                try ctx.threadRepo.get(id: thread.id),
                "a failed batch must preserve every selected thread row"
            )
        }
    }

    func test_applicationTerminationBlocksDrainAlreadyAtDispatchBarrier() async throws {
        // WHY: app termination is synchronous and cannot await waiter tasks.
        // Its gate must make a waiter already inside drain abandon dispatch as
        // soon as that waiter resumes.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "quit-drain-barrier", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "quit drain barrier",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "must remain queued at quit",
            attachments: [],
            interactionMode: .default
        )
        let barrier = QueueDrainAsyncBarrier()
        ctx.queueDrainBeforeDispatchForTesting = { await barrier.enterAndWait() }
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        runner.finishRun(ordinal: 1, status: .completed)
        await barrier.waitUntilEntered()

        let cancelledWaiters = ctx.prepareForApplicationTermination()
        await barrier.release()
        for waiter in cancelledWaiters {
            await waiter.value
        }

        XCTAssertEqual(runner.startCount, 1)
        XCTAssertEqual(
            try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text),
            ["must remain queued at quit"]
        )
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
    }

    func test_hundredLateIdleWaitersScheduleOneDeadlineAndZeroPeriodicPolls() async throws {
        // WHY: queue recovery is provider-idle driven. One hundred live threads
        // may each own one warning deadline, but must schedule zero periodic
        // MainActor/SQLite poll wakeups. Distill is the only shipped provider.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        ctx.queueDrainProviderIdleTimeout = 1_000
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .distill, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.distill, runner: runner)
        let sleeper = QueueDrainTestSleeper()
        ctx.queueDrainSleepForTesting = { try await sleeper.sleep(threadId: $0, duration: $1) }
        // A workspace holds at most maxThreadsPerWorkspace (20) threads, so the
        // hundred live threads are spread over workspaces of that size.
        var workspace = try router.createWorkspace(name: "causal-idle-scale-0", cwd: workspaceDir.path)
        var threads: [AgentThread] = []
        for index in 1...100 {
            if (index - 1) % AgentThreadRepository.maxThreadsPerWorkspace == 0, index > 1 {
                workspace = try router.createWorkspace(name: "causal-idle-scale-\(index)", cwd: workspaceDir.path)
            }
            let thread = try router.createAgentThread(
                workspace: workspace.id,
                title: "causal \(index)",
                provider: .distill,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
            threads.append(thread)
            _ = try await ctx.coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .distill,
                model: "test-model",
                cwd: workspaceDir.path,
                prompt: "long turn \(index)"
            ))
            _ = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "queued \(index)",
                attachments: [],
                interactionMode: .default
            )
            ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        }

        for thread in threads {
            await sleeper.waitForRequestCount(1, threadId: thread.id)
            let intervals = await sleeper.requestedIntervals(threadId: thread.id)
            XCTAssertEqual(intervals, [.seconds(1_000)],
                           "each thread may schedule one warning deadline and no periodic polls")
        }
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 100)
        _ = await ctx.acquireQueueDrainSuppressions(threadIds: threads.map(\.id))
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
    }

    func test_agentAppDeleteThreadSuppressesQueuedDrainBeforeAwaitingProviderTermination() async throws {
        // WHY: the macOS Agent App owns a direct delete path in addition to the
        // router RPC. Both must suppress terminal-triggered queue drain before
        // awaiting provider shutdown or deletion can start work it is deleting.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: 0.05)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "agent-app-delete-no-drain", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Agent App delete no drain",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Agent App"
        )
        let surface = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
        )
        surface.viewModel.selectThread(thread.id)
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "must never start from Agent App deletion",
            attachments: [],
            interactionMode: .default
        )

        let deleted = await surface.viewModel.deleteThread(thread.id)

        XCTAssertTrue(deleted)
        XCTAssertEqual(runner.startCount, 1,
                       "Agent App deletion shutdown must not start the queued follow-up")
        XCTAssertNil(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
    }

    func test_applicationTerminationSynchronouslyFlushesUsageAndCancelsQueueWaiters() async throws {
        // WHY: NSApplication termination does not await unstructured tasks.
        // Durable usage and queue-waiter cancellation must both finish before
        // the synchronous notification callback returns.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "termination-flush", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "termination flush",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let started = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let runId = try XCTUnwrap(started.runId)
        ctx.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(
                inputTokens: 321,
                outputTokens: 0,
                totalTokens: 321
            )),
            thread.id,
            runId
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "queued at quit",
            attachments: [],
            interactionMode: .default
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)

        ctx.prepareForApplicationTermination()

        let usage = ProviderUsageStore(appSupportDirectory: ctx.appSupportDirectory).load()
        XCTAssertEqual(
            usage.providers.first { $0.provider == .claude }?.actualProviderTokens,
            321,
            "termination must persist pending usage before returning"
        )
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0,
                       "termination must cancel queue waiters before returning")
        runner.finishRun(ordinal: 1, status: .cancelled)
    }

    func test_continueRejectsLiveAdapterSessionWithoutQueueingEmptyPrompt() async throws {
        // WHY: Continue is a recovery action, not a message. If the provider is
        // still live it must fail as already active, never enqueue an empty turn.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let (ctx, router, adapter, thread) = try await makeLiveAdapterRouterFixture(root: root)
        var staleThread = thread
        staleThread.status = .interrupted
        try ctx.threadRepo.upsert(staleThread)

        do {
            _ = try await router.continueAgentRun(thread: thread.id)
            XCTFail("Continue must reject a still-live provider turn")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("active run"))
        }

        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty,
                      "Continue must not turn its empty recovery prompt into a queue item")
        adapter.stopAll()
    }

    func test_claudeSDKTerminalCallbackDrainsAndAcknowledgesNextQueueRowExactlyOnce() async throws {
        // WHY: AppContext starts queued work from the provider terminal callback.
        // The real Claude SDK adapter must already report the resident session
        // idle at that edge so the next row starts and is acknowledged without
        // scheduler yields, sleeps, or a later lifecycle event.
        guard ProcessLocator.resolve("node") != nil else {
            throw XCTSkip("node not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-sdk-causal-drain-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        let bridge = root.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = root.appendingPathComponent("commands.jsonl")
        let releaseFIFO = root.appendingPathComponent("release-first-turn")
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        try Self.causalQueueFakeClaudeBridge(
            commandLogPath: commandLog.path,
            releaseFIFOPath: releaseFIFO.path
        ).write(to: bridge, atomically: true, encoding: .utf8)
        let mkfifo = Process()
        mkfifo.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
        mkfifo.arguments = [releaseFIFO.path]
        try mkfifo.run()
        mkfifo.waitUntilExit()
        XCTAssertEqual(mkfifo.terminationStatus, 0)

        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        ctx.coordinator.replaceProviderAdapter(.claude, adapter: adapter)
        defer { adapter.stopAll() }
        let workspace = try router.createWorkspace(
            name: "Claude SDK causal drain",
            cwd: workspaceDir.path
        )
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Claude SDK causal drain",
            provider: .claude,
            model: "sonnet",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        let first = try await router.sendAgentMessage(
            thread: thread.id,
            text: "hold the first turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        XCTAssertEqual(first.status, .started)
        let queuedResult = try await router.sendAgentMessage(
            thread: thread.id,
            text: "drain exactly once",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        XCTAssertEqual(queuedResult.status, .queued)
        let queued = try XCTUnwrap(queuedResult.queuedMessage)

        let drained = QueueDrainAsyncSignal()
        let drainedSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            guard $0.kind == "agent.message.queue.drained",
                  $0.payload.objectValue?["queued_message_id"]?.stringValue
                    == queued.id.value.uuidString else {
                return
            }
            Task { await drained.signal() }
        }
        defer { EventBus.shared.unsubscribe(drainedSubscription) }

        try await Task.detached {
            let handle = try FileHandle(forWritingTo: releaseFIFO)
            try handle.write(contentsOf: Data([0x31]))
            try handle.close()
        }.value
        await drained.wait()

        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queued.id))
        for _ in 0..<200 where (try? Self.loggedClaudeBridgeCommands(at: commandLog, type: "rc_turn").count) != 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let turnCommands = try Self.loggedClaudeBridgeCommands(
            at: commandLog,
            type: "rc_turn"
        )
        XCTAssertEqual(turnCommands.count, 2,
                       "the first turn and one queued turn must be the only provider writes")
        let prompts = turnCommands.compactMap { $0["prompt"] as? String }
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(try XCTUnwrap(prompts.first).hasSuffix("User request:\nhold the first turn"))
        XCTAssertTrue(try XCTUnwrap(prompts.dropFirst().first).hasSuffix("User request:\ndrain exactly once"))
    }

    func test_drainQueue_definiteStartFailureRequeuesForOneExplicitRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "queue-retry", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "retry exactly once", attachments: [], interactionMode: .default)
        let failing = ThrowingStartRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: failing)

        do {
            try await router.drainNextQueuedAgentMessage(thread: thread.id)
            XCTFail("provider start must fail")
        } catch {}

        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.id), [queued.id],
                       "a definite pre-write failure must preserve the queue intent")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
        XCTAssertEqual(try ctx.messageRepo.list(threadId: thread.id).filter { $0.role == .user }.count, 1)
        let failedRun = try XCTUnwrap(ctx.runRepo.get(id: AgentRunID(queued.id.value)))
        XCTAssertEqual(failedRun.status, .failed,
                       "the visible failed run must explain the failed start without deleting the unaccepted queue intent")
        XCTAssertEqual(
            try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastRunId,
            failedRun.id,
            "start-failure persistence must retain the run-bound evidence needed if the host crashes before queue acknowledgement"
        )
        XCTAssertEqual(failing.startCount, 1,
                       "the same-call cleanup must not replay a failed provider start")

        do {
            _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
            XCTFail("the explicit retry must surface the provider failure")
        } catch {}
        XCTAssertEqual(failing.startCount, 2,
                       "Force must retry the definitely unaccepted prompt exactly once per action")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
    }

    func test_forceQueue_requeuesDefiniteFailureButPreservesAmbiguousTimeout() async throws {
        let startErrors: [(label: String, error: Error, claimsWrite: Bool, expectedState: AgentQueuedMessageDispatchState)] = [
            ("failure", AgentRunError.spawnFailed("intentional queue-start failure"), false, .queued),
            ("timeout", CodexAppServerError.requestTimedOut(method: "turn/start", timeout: 30), true, .prepared)
        ]

        for provider in AgentProvider.allCases {
          for startError in startErrors {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            defer { closeAndUnregisterAllSurfaces() }
            let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let workspace = try router.createWorkspace(name: "queue-force-\(startError.label)", cwd: workspaceDir.path)
            var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: provider, model: "test-model", permissionMode: .supervised, reasoningEffort: .medium)
            thread.status = .failed
            try ctx.threadRepo.upsert(thread)
            let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "one recovery surface", attachments: [], interactionMode: .default)
            let failing = ThrowingStartRunner(
                provider: provider,
                error: startError.error,
                claimAcceptanceBeforeThrow: startError.claimsWrite
            )
            ctx.coordinator.replaceProvider(provider, runner: failing)

            do {
                _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
                XCTFail("provider \(startError.label) must fail")
            } catch {}

            XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.id), [queued.id],
                           "same-call \(startError.label) is not positive provider acceptance evidence")
            XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, startError.expectedState)
            XCTAssertEqual(try ctx.messageRepo.list(threadId: thread.id).filter { $0.role == .user }.count, 1)
            XCTAssertEqual(try ctx.runRepo.get(id: AgentRunID(queued.id.value))?.status, .failed)
            XCTAssertEqual(failing.startCount, 1)
          }
        }
    }

    func test_grokPromptWriteFailurePersistsCanonicalStartFailureAndPreparedQueueAcrossRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let peer = try PromptWriteFailureGrokPeer(root: root.appendingPathComponent("peer"))
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        ctx.coordinator.replaceProviderAdapter(
            .grok,
            adapter: GrokACPAdapter(binaryNameOverride: peer.path)
        )
        let workspace = try router.createWorkspace(name: "grok-write-failure", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "grok write failure",
            provider: .grok,
            model: "account-live-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "preserve exact prompt",
            attachments: [],
            interactionMode: .default
        )

        do {
            _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
            XCTFail("the real ACP prompt write must fail")
        } catch {}

        let runId = AgentRunID(queued.id.value)
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
        XCTAssertEqual(
            try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastEventKind,
            "run.start_failed"
        )
        XCTAssertEqual(try ctx.runRepo.get(id: runId)?.status, .failed)
        let launchCountBeforeRecovery = peer.launchCount

        await router.reconcileQueuedAgentMessagesOnLaunch()

        XCTAssertEqual(peer.launchCount, launchCountBeforeRecovery + 1,
                       "relaunch reconciliation must retry a definitely rejected prompt once")
        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: queued.id)?.text, "preserve exact prompt")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
    }

    func test_routerCoordinatorPreservesRevokedAcceptancePermitToEveryProviderWire() async throws {
        // WHY: queued requests are rebuilt inside AgentRunCoordinator. The
        // runtime-only permit must survive that copy or the real provider write
        // boundary silently receives nil and suppression cannot win.
        for provider in AgentProvider.allCases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("provider-permit-\(provider.rawValue)-\(UUID().uuidString)", isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            defer { closeAndUnregisterAllSurfaces() }
            let peer = try ProviderAcceptanceProbePeer(provider: provider, root: root.appendingPathComponent("peer"))
            let concrete: AgentProviderAdapter
            switch provider {
            case .codex:
                concrete = CodexAppServerAdapter(binaryNameOverride: peer.path)
            case .claude:
                concrete = ClaudeStreamingCLIAdapter(binaryNameOverride: peer.path)
            case .grok:
                concrete = GrokACPAdapter(binaryNameOverride: peer.path)
            case .distill:
                concrete = DistillACPAdapter(binaryNameOverride: peer.path)
            }
            let revoking = RevokingAcceptanceAdapter(inner: concrete)
            let ctx = try AppContext(
                channel: .debug,
                appSupportOverride: root.appendingPathComponent("support").path
            )
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            ctx.coordinator.replaceProviderAdapter(provider, adapter: revoking)
            let workspace = try router.createWorkspace(
                name: "permit \(provider.rawValue)",
                cwd: workspaceDir.path
            )
            var thread = try router.createAgentThread(
                workspace: workspace.id,
                title: "permit \(provider.rawValue)",
                provider: provider,
                model: "account-live-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
            thread.status = .failed
            try ctx.threadRepo.upsert(thread)
            let descriptor = try router.createSurface(
                workspace: workspace.id,
                type: .agentApp,
                paneID: nil,
                title: "Agent App"
            )
            let surface = try XCTUnwrap(
                SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
            )
            surface.viewModel.selectThread(thread.id)
            let queued = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "must not cross \(provider.rawValue) wire",
                attachments: [],
                interactionMode: .default
            )

            await surface.viewModel.forceQueuedMessageNow(queued)

            XCTAssertTrue(revoking.sawAcceptancePermit,
                          "local macOS Force must delegate through router/coordinator and preserve the \(provider.rawValue) permit")
            XCTAssertEqual(peer.acceptedPromptCount, 0,
                           "\(provider.rawValue) must receive no prompt bytes after revocation")
            XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
            XCTAssertEqual(
                try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastEventKind,
                "run.start_failed"
            )
            concrete.stopAll()
        }
    }

    func test_localAgentAppForceCannotCrossDeleteBulkOrTerminationSuppressionAcrossProviders() async throws {
        let destructiveActions = ["delete", "bulk", "termination"]
        for provider in AgentProvider.allCases {
            for action in destructiveActions {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("local-force-\(provider.rawValue)-\(action)-\(UUID().uuidString)", isDirectory: true)
                let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
                try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                defer { closeAndUnregisterAllSurfaces() }
                let peer = try ProviderAcceptanceProbePeer(
                    provider: provider,
                    root: root.appendingPathComponent("peer")
                )
                let concrete: AgentProviderAdapter
                switch provider {
                case .codex:
                    concrete = CodexAppServerAdapter(binaryNameOverride: peer.path)
                case .claude:
                    concrete = ClaudeStreamingCLIAdapter(binaryNameOverride: peer.path)
                case .grok:
                    concrete = GrokACPAdapter(binaryNameOverride: peer.path)
                case .distill:
                    concrete = DistillACPAdapter(binaryNameOverride: peer.path)
                }
                let ctx = try AppContext(
                    channel: .debug,
                    appSupportOverride: root.appendingPathComponent("support").path
                )
                let router = AppCommandRouter(context: ctx)
                ctx.router = router
                ctx.coordinator.replaceProviderAdapter(provider, adapter: concrete)
                let workspace = try router.createWorkspace(
                    name: "local force \(provider.rawValue) \(action)",
                    cwd: workspaceDir.path
                )
                var thread = try router.createAgentThread(
                    workspace: workspace.id,
                    title: action,
                    provider: provider,
                    model: "account-live-model",
                    permissionMode: .supervised,
                    reasoningEffort: .medium
                )
                thread.status = .failed
                try ctx.threadRepo.upsert(thread)
                let descriptor = try router.createSurface(
                    workspace: workspace.id,
                    type: .agentApp,
                    paneID: nil,
                    title: "Agent App"
                )
                let surface = try XCTUnwrap(
                    SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
                )
                surface.viewModel.selectThread(thread.id)
                let queued = try ctx.queuedMessageRepo.enqueue(
                    threadId: thread.id,
                    text: "must not survive \(action)",
                    attachments: [],
                    interactionMode: .default
                )
                let barrier = QueueDrainAsyncBarrier()
                router.queueDispatchBeforeProviderStartForTesting = {
                    await barrier.enterAndWait()
                }
                let force = Task {
                    await surface.viewModel.forceQueuedMessageNow(queued)
                }
                await barrier.waitUntilEntered()

                var terminationWaiters: [Task<Void, Never>] = []
                switch action {
                case "delete":
                    let deleted = await surface.viewModel.deleteThread(thread.id)
                    XCTAssertTrue(deleted)
                case "bulk":
                    let deleted = await surface.viewModel.deleteThreads([thread.id])
                    XCTAssertTrue(deleted)
                default:
                    terminationWaiters = ctx.prepareForApplicationTermination()
                }

                await barrier.release()
                await force.value
                for waiter in terminationWaiters { await waiter.value }
                XCTAssertEqual(
                    peer.acceptedPromptCount,
                    0,
                    "\(provider.rawValue) local Force must not cross \(action) suppression"
                )
                concrete.stopAll()
            }
        }
    }

    func test_localAgentAppPostClaimPreHandleForceSettlesBeforeDeleteBulkOrTerminationCompletes() async throws {
        // WHY: once the physical write claims acceptance, invalidation cannot
        // revoke it. Destructive flows must stop promptly, then await both that
        // claimed write and coordinator handle registration before they delete
        // durable state or certify termination.
        for action in ["delete", "bulk", "termination"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("post-claim-\(action)-\(UUID().uuidString)", isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            defer { closeAndUnregisterAllSurfaces() }
            let ctx = try AppContext(
                channel: .debug,
                appSupportOverride: root.appendingPathComponent("support").path
            )
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let startBarrier = PostClaimPreHandleStartBarrier()
            let runner = PostClaimPreHandleRunner(barrier: startBarrier)
            ctx.coordinator.replaceProvider(.claude, runner: runner)
            let workspace = try router.createWorkspace(
                name: "post claim \(action)",
                cwd: workspaceDir.path
            )
            var thread = try router.createAgentThread(
                workspace: workspace.id,
                title: action,
                provider: .claude,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
            thread.status = .failed
            try ctx.threadRepo.upsert(thread)
            let descriptor = try router.createSurface(
                workspace: workspace.id,
                type: .agentApp,
                paneID: nil,
                title: "Agent App"
            )
            let surface = try XCTUnwrap(
                SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
            )
            surface.viewModel.selectThread(thread.id)
            let queued = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "claimed before \(action)",
                attachments: [],
                interactionMode: .default
            )
            let force = Task {
                await surface.viewModel.forceQueuedMessageNow(queued)
            }
            await startBarrier.waitUntilClaimed()

            switch action {
            case "delete":
                let stopIssued = QueueDrainAsyncSignal()
                ctx.queueDrainSuppressionAcquiredForTesting = {
                    guard $0 == thread.id else { return }
                    await stopIssued.signal()
                }
                let deletion = Task {
                    await surface.viewModel.deleteThread(thread.id)
                }
                await stopIssued.wait()
                XCTAssertNotNil(
                    try ctx.threadRepo.get(id: thread.id),
                    "delete must wait while the claimed write has no provider handle"
                )
                startBarrier.releaseWrite()
                let deleted = await deletion.value
                XCTAssertTrue(deleted)
                XCTAssertNil(try ctx.threadRepo.get(id: thread.id))
            case "bulk":
                let stopIssued = QueueDrainAsyncSignal()
                ctx.queueDrainSuppressionAcquiredForTesting = {
                    guard $0 == thread.id else { return }
                    await stopIssued.signal()
                }
                let deletion = Task {
                    await surface.viewModel.deleteThreads([thread.id])
                }
                await stopIssued.wait()
                XCTAssertNotNil(
                    try ctx.threadRepo.get(id: thread.id),
                    "bulk delete must preserve every row until the claimed start settles"
                )
                startBarrier.releaseWrite()
                let deleted = await deletion.value
                XCTAssertTrue(deleted)
                XCTAssertNil(try ctx.threadRepo.get(id: thread.id))
            default:
                let terminationWaiters = ctx.prepareForApplicationTermination()
                XCTAssertNotNil(
                    try ctx.threadRepo.get(id: thread.id),
                    "termination must return waiters for a claimed pre-handle write"
                )
                startBarrier.releaseWrite()
                for waiter in terminationWaiters {
                    await waiter.value
                }
            }

            await startBarrier.waitUntilCancelled()
            await force.value
            XCTAssertEqual(startBarrier.physicalWriteCount, 1)
            XCTAssertGreaterThanOrEqual(startBarrier.cancelCount, 1)
        }
    }

    func test_secondForceDuringPostClaimPreHandleStartKeepsFirstOwnerAndQueueIntent() async throws {
        // WHY: a claimed provider write has durable `.pending` state before its
        // adapter session/handle exists. A second Force must queue behind that
        // owner, not claim a second write or replace coordinator ownership.
        // Distill is the only shipped provider; like its adapter, the fixture
        // names the provider thread once the prompt is accepted.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-claim-second-force-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        rememberSignedInSnapshot(.distill, router: router)
        let startBarrier = PostClaimPreHandleStartBarrier()
        let runner = PostClaimPreHandleRunner(
            barrier: startBarrier,
            provider: .distill,
            reportsProviderThreadOnAccept: true
        )
        ctx.coordinator.replaceProvider(.distill, runner: runner)
        let workspace = try router.createWorkspace(
            name: "post claim second Force",
            cwd: workspaceDir.path
        )
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "second Force",
            provider: .distill,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let first = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "first pending owner",
            attachments: [],
            interactionMode: .default
        )
        let second = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "second preserved intent",
            attachments: [],
            interactionMode: .default
        )

        let firstForce = Task {
            try? await router.forceAgentQueuedMessageNow(id: first.id)
        }
        await startBarrier.waitUntilClaimed()

        let secondResult = try await router.forceAgentQueuedMessageNow(id: second.id)
        XCTAssertEqual(secondResult.status, .queued)
        XCTAssertEqual(secondResult.queuedMessage?.id, second.id)
        XCTAssertTrue(ctx.coordinator.hasPendingProviderStart(threadId: thread.id))
        XCTAssertEqual(
            try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastRunId,
            AgentRunID(first.id.value),
            "the first claimed run must retain pending provider ownership"
        )
        XCTAssertEqual(startBarrier.claimCount, 1,
                       "the second Force must not reach a second physical write")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: second.id)?.state, .queued)
        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: second.id)?.text, "second preserved intent")

        let secondDrained = QueueDrainAsyncSignal()
        let drainedSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            guard $0.kind == "agent.message.queue.drained",
                  $0.payload.objectValue?["queued_message_id"]?.stringValue
                    == second.id.value.uuidString else {
                return
            }
            Task { await secondDrained.signal() }
        }
        defer { EventBus.shared.unsubscribe(drainedSubscription) }
        startBarrier.releaseWrite()
        _ = await firstForce.value
        await startBarrier.waitUntilCancelled()
        await secondDrained.wait()
        XCTAssertEqual(startBarrier.claimCount, 2,
                       "the preserved second intent must drain only after the first owner settles")
        XCTAssertEqual(startBarrier.physicalWriteCount, 2)
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: second.id))
        ctx.coordinator.stopRun(threadId: thread.id)
    }

    func test_secondForceDuringOnRunPreparedPendingWindowStopsFirstOwnerAndDrains() async throws {
        // WHY: durable `.pending` is exposed before the adapter session and
        // physical-write helper exist. Pending ownership must already be
        // registered so Force interrupts that first owner instead of attempting
        // a competing start during the onRunPrepared suspension.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prepared-second-force-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let startBarrier = PostClaimPreHandleStartBarrier()
        ctx.coordinator.replaceProvider(
            .claude,
            runner: PostClaimPreHandleRunner(barrier: startBarrier)
        )
        let preparedBarrier = QueueDrainAsyncBarrier()
        let originalOnRunPrepared = ctx.coordinator.onRunPrepared
        ctx.coordinator.onRunPrepared = { request, prompt in
            await originalOnRunPrepared?(request, prompt)
            await preparedBarrier.enterAndWait()
        }
        let workspace = try router.createWorkspace(
            name: "prepared second Force",
            cwd: workspaceDir.path
        )
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "prepared second Force",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let first = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "durable pending owner",
            attachments: [],
            interactionMode: .default
        )
        let second = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "force during prepared callback",
            attachments: [],
            interactionMode: .default
        )

        let firstForce = Task {
            try? await router.forceAgentQueuedMessageNow(id: first.id)
        }
        await preparedBarrier.waitUntilEntered()

        XCTAssertTrue(ctx.coordinator.hasPendingProviderStart(threadId: thread.id))
        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.status, .pending)
        XCTAssertEqual(try ctx.runRepo.get(id: AgentRunID(first.id.value))?.status, .pending)
        XCTAssertEqual(startBarrier.claimCount, 0,
                       "the adapter write helper must not exist yet at this seam")

        let secondResult = try await router.forceAgentQueuedMessageNow(id: second.id)
        XCTAssertEqual(secondResult.status, .queued)
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: second.id)?.state, .queued)
        XCTAssertEqual(
            try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastRunId,
            AgentRunID(first.id.value),
            "the first durable pending run must retain ownership"
        )

        let secondDrained = QueueDrainAsyncSignal()
        let drainedSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            guard $0.kind == "agent.message.queue.drained",
                  $0.payload.objectValue?["queued_message_id"]?.stringValue
                    == second.id.value.uuidString else {
                return
            }
            Task { await secondDrained.signal() }
        }
        defer { EventBus.shared.unsubscribe(drainedSubscription) }
        await preparedBarrier.release()
        _ = await firstForce.value
        await startBarrier.waitUntilClaimed()
        XCTAssertEqual(startBarrier.claimCount, 1)
        XCTAssertEqual(
            startBarrier.physicalWriteCount,
            0,
            "the invalidated first owner must stop before claiming a provider write"
        )
        startBarrier.releaseWrite()
        await secondDrained.wait()

        XCTAssertEqual(startBarrier.claimCount, 1,
                       "only the second intent may claim a provider write after the first owner settles")
        XCTAssertEqual(startBarrier.physicalWriteCount, 1)
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: second.id))
        ctx.coordinator.stopRun(threadId: thread.id)
    }

    func test_earlyAdmissionFailureCompletesConcurrentTerminationWithoutProviderWrite() async throws {
        // WHY: pending ownership is registered before provider admission. If
        // admission throws before sendTurn, a destructive waiter must observe
        // that failed completion rather than waiting five seconds for a handle
        // that can never exist. The prepared queue intent must roll back safely.
        // Distill is the only shipped provider; its send preflight needs a
        // signed-in snapshot so the Force reaches provider admission.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-failure-stop-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        rememberSignedInSnapshot(.distill, router: router)
        let runner = RequestCaptureRunner(provider: .distill)
        ctx.coordinator.replaceProvider(.distill, runner: runner)
        ctx.coordinator.hardStopTimeout = 0.25
        let admissionBarrier = QueueDrainAsyncBarrier()
        ctx.coordinator.providerAdmissionCheck = { _, _ in
            await admissionBarrier.enterAndWait()
            throw NSError(
                domain: "ProviderSnapshotRuntimeTests.Admission",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "intentional admission rejection"]
            )
        }
        let workspace = try router.createWorkspace(
            name: "admission failure stop",
            cwd: workspaceDir.path
        )
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "admission failure stop",
            provider: .distill,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "preserve before provider admission",
            attachments: [],
            interactionMode: .default
        )

        let force = Task {
            do {
                _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
                return false
            } catch {
                return true
            }
        }
        await admissionBarrier.waitUntilEntered()

        XCTAssertTrue(ctx.coordinator.hasPendingProviderStart(threadId: thread.id))
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .prepared)
        XCTAssertNil(runner.lastRequest)
        XCTAssertNil(try ctx.runRepo.get(id: AgentRunID(queued.id.value)))

        let terminationFinished = QueueDrainAsyncSignal()
        let termination = Task {
            do {
                try await ctx.coordinator.stopAndAwaitTermination(threadId: thread.id)
                await terminationFinished.signal()
                return true
            } catch {
                await terminationFinished.signal()
                return false
            }
        }
        for _ in 0..<1_000 {
            if try ctx.threadRepo.get(id: thread.id)?.status == .cancelled { break }
            await Task.yield()
        }
        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.status, .cancelled,
                       "the concurrent termination task must reach the pending owner before admission is released")
        let terminationCompletedBeforeRelease = await terminationFinished.isSignalled
        XCTAssertFalse(terminationCompletedBeforeRelease)

        let releasedAt = ContinuousClock.now
        await admissionBarrier.release()
        let forceFailed = await force.value
        let terminationSucceeded = await termination.value
        XCTAssertTrue(forceFailed)
        XCTAssertTrue(terminationSucceeded,
                      "an early admission failure must complete termination without a hard timeout")
        XCTAssertLessThan(releasedAt.duration(to: .now), .milliseconds(200))

        // Once the thread is idle the queue waiter may retry the restored row;
        // admission rejects that retry the same way, so let it settle.
        let settled = await waitUntil(timeout: 2) {
            !ctx.coordinator.hasPendingProviderStart(threadId: thread.id)
                && (try? ctx.queuedMessageRepo.dispatch(id: queued.id)?.state) == .queued
        }
        XCTAssertTrue(settled, "the prepared queue intent must roll back to queued")
        XCTAssertFalse(ctx.coordinator.hasPendingProviderStart(threadId: thread.id))
        XCTAssertNil(runner.lastRequest,
                     "provider admission failure must not cross the physical write boundary")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
        XCTAssertEqual(
            try ctx.queuedMessageRepo.get(id: queued.id)?.text,
            "preserve before provider admission"
        )
        XCTAssertNil(try ctx.runRepo.get(id: AgentRunID(queued.id.value)))
        XCTAssertTrue(try ctx.messageRepo.list(threadId: thread.id).isEmpty)
    }

    func test_pendingAdmissionTerminationUsesOneDeadlineAndPreservesDurableIntent() async throws {
        // WHY: provider admission may never resume. Destructive callers still
        // need one bounded shutdown deadline, and timeout must preserve both the
        // thread and its queued user intent instead of deleting unconfirmed work.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-admission-timeout-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .claude)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        ctx.coordinator.gracefulStopTimeout = 0.02
        ctx.coordinator.hardStopTimeout = 0.12
        let admissionBarrier = QueueDrainAsyncBarrier()
        ctx.coordinator.providerAdmissionCheck = { _, _ in
            await admissionBarrier.enterAndWait()
        }
        let workspace = try router.createWorkspace(
            name: "pending admission timeout",
            cwd: workspaceDir.path
        )
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "pending admission timeout",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "preserve across admission timeout",
            attachments: [],
            interactionMode: .default
        )
        let force = Task {
            do {
                _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
                return false
            } catch {
                return true
            }
        }
        await admissionBarrier.waitUntilEntered()

        let startedAt = ContinuousClock.now
        let deletionError = await Task { () -> Error? in
            do {
                try await router.deleteAgentThread(thread: thread.id)
                return nil
            } catch {
                return error
            }
        }.value

        XCTAssertEqual((deletionError as NSError?)?.code, 504)
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1),
                          "the pending-start wait must consume the same hard-stop deadline")
        XCTAssertNotNil(try ctx.threadRepo.get(id: thread.id),
                        "timeout cannot authorize destructive thread deletion")
        XCTAssertNotNil(try ctx.queuedMessageRepo.get(id: queued.id),
                        "timeout must preserve the queued user intent")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .prepared)
        XCTAssertNil(runner.lastRequest,
                     "an admission timeout must not cross the provider write boundary")

        let cleanupSuppression = await ctx.acquireQueueDrainSuppression(threadId: thread.id)
        defer {
            ctx.releaseQueueDrainSuppression(
                threadId: thread.id,
                lease: cleanupSuppression
            )
        }
        await admissionBarrier.release()
        let forceFailed = await force.value
        XCTAssertTrue(forceFailed)
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
        XCTAssertFalse(ctx.coordinator.hasPendingProviderStart(threadId: thread.id))
    }

    func test_secondForceBeforePendingPersistenceStopsFirstWithoutProviderWrite() async throws {
        // WHY: pending ownership exists before the run/thread pending rows. A
        // second Force in that window must stop the first launch causally before
        // it claims a provider write, while keeping both user intents durable.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-persist-second-force-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = CompletingAcceptanceCaptureRunner(provider: .claude)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let admissionBarrier = QueueDrainAsyncBarrier()
        ctx.coordinator.providerAdmissionCheck = { _, _ in
            await admissionBarrier.enterAndWait()
        }
        let workspace = try router.createWorkspace(
            name: "pre persist second Force",
            cwd: workspaceDir.path
        )
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "pre persist second Force",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let first = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "first pre-persistence owner",
            attachments: [],
            interactionMode: .default
        )
        let second = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "second Force owner",
            attachments: [],
            interactionMode: .default
        )
        let firstForce = Task {
            do {
                _ = try await router.forceAgentQueuedMessageNow(id: first.id)
                return false
            } catch {
                return true
            }
        }
        await admissionBarrier.waitUntilEntered()

        XCTAssertTrue(ctx.coordinator.hasPendingProviderStart(threadId: thread.id))
        XCTAssertNil(try ctx.runRepo.get(id: AgentRunID(first.id.value)))
        XCTAssertTrue(runner.acceptedRunIDs.isEmpty)
        let secondResult = try await router.forceAgentQueuedMessageNow(id: second.id)
        XCTAssertEqual(secondResult.status, .queued)
        XCTAssertEqual(secondResult.queuedMessage?.id, second.id)

        let cleanupSuppression = await ctx.acquireQueueDrainSuppression(threadId: thread.id)
        await admissionBarrier.release()
        let firstForceFailed = await firstForce.value
        XCTAssertTrue(firstForceFailed)

        XCTAssertTrue(runner.acceptedRunIDs.isEmpty,
                       "the invalidated first launch must never claim a provider write")
        XCTAssertNotNil(try ctx.queuedMessageRepo.get(id: first.id))
        XCTAssertNotNil(try ctx.queuedMessageRepo.get(id: second.id))

        let secondDrained = QueueDrainAsyncSignal()
        let drainedSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            guard $0.kind == "agent.message.queue.drained",
                  $0.payload.objectValue?["queued_message_id"]?.stringValue
                    == second.id.value.uuidString else {
                return
            }
            Task { await secondDrained.signal() }
        }
        defer { EventBus.shared.unsubscribe(drainedSubscription) }

        ctx.releaseQueueDrainSuppression(
            threadId: thread.id,
            lease: cleanupSuppression
        )
        await secondDrained.wait()

        XCTAssertEqual(
            runner.acceptedRunIDs,
            [AgentRunID(second.id.value)],
            "releasing suppression must start the forced second intent exactly once"
        )
        XCTAssertNotNil(
            try ctx.queuedMessageRepo.get(id: first.id),
            "the invalidated first intent must remain durable for explicit recovery"
        )
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: second.id))
    }

    func test_continueRejectsPendingProviderStartBeforePersistence() async throws {
        // WHY: Continue must not race an admitted-but-not-yet-persisted launch
        // and create a second provider turn while durable status still looks idle.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-pending-start-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .claude)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let admissionBarrier = QueueDrainAsyncBarrier()
        ctx.coordinator.providerAdmissionCheck = { _, _ in
            await admissionBarrier.enterAndWait()
        }
        let workspace = try router.createWorkspace(
            name: "continue pending start",
            cwd: workspaceDir.path
        )
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "continue pending start",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let initialStart = Task {
            do {
                _ = try await router.sendAgentMessage(
                    thread: thread.id,
                    text: "pending admission",
                    provider: nil,
                    model: nil,
                    permissionMode: nil,
                    reasoningEffort: nil
                )
                return false
            } catch {
                return true
            }
        }
        await admissionBarrier.waitUntilEntered()

        do {
            _ = try await router.continueAgentRun(thread: thread.id)
            XCTFail("Continue must reject pending provider ownership")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("active run"))
        }
        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty,
                      "Continue must not enqueue an empty recovery prompt")
        XCTAssertNil(runner.lastRequest)

        ctx.coordinator.stopRun(threadId: thread.id)
        await admissionBarrier.release()
        let initialStartFailed = await initialStart.value
        XCTAssertTrue(initialStartFailed)
        XCTAssertNil(runner.lastRequest,
                     "the stopped pending launch must not reach the provider writer")
    }

    func test_drainQueue_relaunchAcknowledgesDispatchedHeadWithoutProviderReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-relaunch", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .completed
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "already dispatched", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "dead-process"))
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
        XCTAssertTrue(try ctx.queuedMessageRepo.markDispatched(lease, runId: runId))

        try await router.drainNextQueuedAgentMessage(thread: thread.id)

        XCTAssertNil(runner.lastRequest,
                     "relaunch recovery must acknowledge durable dispatched proof without invoking the provider")
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queued.id))
    }

    func test_forceDispatchedQueueRowFinishesCleanupBeforeBusyThreadHandling() async throws {
        // WHY: dispatched is positive provider-start evidence. The recovery
        // action is ack-only even while that same provider run remains busy;
        // routing through Force promotion would try to interrupt or replay it.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("force-dispatched-busy-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(
            name: "force dispatched busy",
            cwd: workspaceDir.path
        )
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "force dispatched busy",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .running
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "provider already accepted",
            attachments: [],
            interactionMode: .default
        )
        let normalNext = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "normal next",
            attachments: [],
            interactionMode: .default
        )
        let forcedNext = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "forced next",
            attachments: [],
            interactionMode: .default
        )
        let lease = try XCTUnwrap(
            ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "accepted-provider-start")
        )
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
        XCTAssertTrue(try ctx.queuedMessageRepo.markDispatched(lease, runId: runId))
        ctx.deferQueuePromotion(
            id: forcedNext.id,
            after: queued.id,
            threadId: thread.id
        )

        let result = try await router.forceAgentQueuedMessageNow(id: queued.id)

        XCTAssertEqual(result.status, .started)
        XCTAssertEqual(result.runId, runId)
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queued.id))
        XCTAssertNil(runner.lastRequest,
                     "Finish cleanup must not call the provider or replay dispatched work")
        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.status, .running,
                       "ack-only cleanup must not stop the already accepted provider run")
        XCTAssertEqual(
            try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.id),
            [forcedNext.id, normalNext.id],
            "dispatched cleanup must preserve the user's deferred Force priority"
        )
    }

    func test_automaticDispatchedRecoveryConsumesDeferredForceBeforeNextProviderWrite() async throws {
        // WHY: the automatic recovery path must consume the same owner-bound
        // promotion as the manual Finish cleanup action.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-dispatched-force-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(
            name: "automatic dispatched force",
            cwd: workspaceDir.path
        )
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "automatic dispatched force",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .completed
        try ctx.threadRepo.upsert(thread)
        let owner = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "accepted owner",
            attachments: [],
            interactionMode: .default
        )
        let normalNext = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "normal next",
            attachments: [],
            interactionMode: .default
        )
        let forcedNext = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "forced next",
            attachments: [],
            interactionMode: .default
        )
        let lease = try XCTUnwrap(
            ctx.queuedMessageRepo.claim(id: owner.id, leaseId: "accepted-owner")
        )
        let ownerRunId = AgentRunID(owner.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: ownerRunId))
        XCTAssertTrue(try ctx.queuedMessageRepo.markDispatched(lease, runId: ownerRunId))
        ctx.deferQueuePromotion(
            id: forcedNext.id,
            after: owner.id,
            threadId: thread.id
        )

        try await router.drainNextQueuedAgentMessage(thread: thread.id)

        XCTAssertEqual(runner.lastRequest?.runId, AgentRunID(forcedNext.id.value),
                       "automatic recovery must write only the deferred forced intent next")
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: owner.id))
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: forcedNext.id))
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.id), [normalNext.id])
    }

    func test_drainQueue_relaunchRequeuesPreparedHeadWhenNoRunExistsAndStartsExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-ambiguous", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .completed
        try ctx.threadRepo.upsert(thread)
        let head = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "ambiguous", attachments: [], interactionMode: .default)
        _ = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "later", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: head.id, leaseId: "dead-process"))
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: AgentRunID(head.id.value)))

        await router.reconcileQueuedAgentMessagesOnLaunch()

        XCTAssertEqual(runner.lastRequest?.runId.value, head.id.value,
                       "absence of the deterministic run row proves provider start was never reached and permits one retry")
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["later"],
                       "safe relaunch recovery must drain the original head without skipping the later row")
    }

    func test_drainQueue_relaunchKeepsPreparedHeadWhenProviderStartWasNeverConfirmed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-pending-start", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .interrupted
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "must remain visible", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "dead-process"))
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
        try ctx.runRepo.upsert(AgentRun(id: runId, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .pending))
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .pending,
            lastRunId: runId,
            lastEventKind: "run.pending"
        ))

        do {
            try await router.drainNextQueuedAgentMessage(
                thread: thread.id,
                recoverPreparedFromPriorProcess: true
            )
            XCTFail("launch recovery must fail loud while provider acceptance is unconfirmed")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("remains queued"),
                          "launch recovery must explain that the protected message was preserved")
        } catch {
            XCTFail("launch recovery returned an unexpected error: \(error)")
        }

        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: queued.id)?.text, "must remain visible",
                       "a pre-provider crash must preserve the only actionable queue intent")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .prepared,
                       "ambiguous launch recovery must not make the message claimable or replay it")
        XCTAssertNil(runner.lastRequest,
                     "launch recovery must not replay a prepared message with ambiguous provider state")
    }

    func test_forceQueuedMessageKeepsPreparedHeadWhenProviderStartWasNeverConfirmed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-force-pending-start", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .interrupted
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "do not force replay", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "dead-process"))
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
        try ctx.runRepo.upsert(AgentRun(id: runId, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .pending))
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .pending,
            lastRunId: runId,
            lastEventKind: "run.pending"
        ))

        do {
            _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
            XCTFail("Force must fail loud while provider acceptance is unconfirmed")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("remains queued"),
                          "Force must explain that the protected message was preserved")
        } catch {
            XCTFail("Force returned an unexpected error: \(error)")
        }

        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: queued.id)?.text, "do not force replay",
                       "Force must not delete a queue intent that the provider may never have seen")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .prepared)
        XCTAssertNil(runner.lastRequest,
                     "Force must not replay an ambiguous prepared dispatch")
    }

    func test_forceQueuedMessagePreservesAmbiguousPreparedEvidenceBeforeBusyThread() async throws {
        // WHY: Force must not let a stale busy projection turn any ambiguous
        // start diagnostic into an acknowledgement or a replay.
      for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: provider)
        ctx.coordinator.replaceProvider(provider, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-force-busy-prepared", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: provider, model: "test-model", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .running
        try ctx.threadRepo.upsert(thread)
        let ambiguousEvidence: [(kind: String, status: AgentRunStatus)] = [
            ("run.pending", .pending),
            ("threadStarted(codex-thread-1)", .pending),
            ("run.start_failed", .failed),
            ("run.start_timeout", .failed)
        ]
        for (index, evidence) in ambiguousEvidence.enumerated() {
            let queued = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "do not preempt ambiguity \(index)",
                attachments: [],
                interactionMode: .default
            )
            let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "interrupted-start-\(index)"))
            let runId = AgentRunID(queued.id.value)
            XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
            try ctx.runRepo.upsert(AgentRun(
                id: runId,
                threadId: thread.id,
                provider: provider,
                model: "test-model",
                status: evidence.status
            ))
            try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
                threadId: thread.id,
                provider: provider,
                status: evidence.status,
                lastRunId: runId,
                lastEventKind: evidence.kind
            ))

            do {
                _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
                XCTFail("Force must fail loud while \(evidence.kind) leaves provider acceptance unconfirmed")
            } catch let error as JSONRPCError {
                XCTAssertTrue(error.message.contains("remains queued"),
                              "prepared \(evidence.kind) ambiguity must win over the stale busy-thread projection")
            }

            XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .prepared)
        }
        XCTAssertNil(runner.lastRequest,
                     "Force must not stop/replay a prepared message before its prior start is resolved")
      }
    }

    func test_drainQueue_relaunchAcknowledgesPreparedHeadWithExistingRunWithoutProviderReplay() async throws {
      for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: provider)
        ctx.coordinator.replaceProvider(provider, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-existing-run", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: provider, model: "test-model", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "already represented by run", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "dead-process"))
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
        var failedRun = AgentRun(id: runId, threadId: thread.id, provider: provider, model: "test-model", status: .failed)
        failedRun.finishedAt = Date()
        failedRun.errorMessage = "provider start outcome retained"
        try ctx.runRepo.upsert(failedRun)
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: provider,
            status: .failed,
            lastRunId: runId,
            lastEventKind: "run.started"
        ))

        try await router.drainNextQueuedAgentMessage(thread: thread.id)

        XCTAssertNil(runner.lastRequest,
                     "a durable matching run owns Retry/Continue; launch recovery must never invoke the provider again")
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queued.id),
                     "the redundant prepared queue intent must be acknowledged instead of poisoning the queue head")
        XCTAssertEqual(try ctx.runRepo.get(id: runId)?.status, .failed,
                       "queue acknowledgement must preserve the visible run recovery record")
      }
    }

    func test_drainQueueDoesNotUseLaterRunSessionEvidenceForPreparedEarlierRun() async throws {
        // WHY: provider-session diagnostics are thread-scoped. Without the
        // matching run id, a later turn's run.started can silently delete an
        // earlier prompt that crashed before provider acceptance.
      for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "queue-run-evidence", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: provider, model: "test-model", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .interrupted
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "run A must remain", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "dead-process"))
        let runA = AgentRunID(queued.id.value)
        let runB = AgentRunID()
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runA))
        try ctx.runRepo.upsert(AgentRun(id: runA, threadId: thread.id, provider: provider, model: "test-model", status: .pending))
        var completedB = AgentRun(id: runB, threadId: thread.id, provider: provider, model: "test-model", status: .completed)
        completedB.finishedAt = Date()
        try ctx.runRepo.upsert(completedB)
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: provider,
            status: .completed,
            lastRunId: runB,
            lastEventKind: "run.started"
        ))

        do {
            try await router.drainNextQueuedAgentMessage(thread: thread.id)
            XCTFail("later run evidence must not acknowledge the earlier prepared prompt")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("remains queued"))
        }
        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: queued.id)?.text, "run A must remain")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .prepared)
      }
    }

    func test_drainQueue_postAcceptMarkDispatchedFailureStillAcknowledgesWithoutReplay() async throws {
        // WHY: after acceptancePermit.accepted, markDispatched can return false
        // (CAS race / lease drift). The old path threw with providerStartConfirmed
        // true and left a sticky prepared head while the agent was already running.
        // finalizeQueueDispatchAfterProviderStart must fall back to
        // acknowledgePreparedWithRunEvidence without a second provider write.
      for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = ConcurrentPreparedAckRunner(
            provider: provider,
            queuedMessageRepo: ctx.queuedMessageRepo
        )
        ctx.coordinator.replaceProvider(provider, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-mark-fail", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "queue",
            provider: provider,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .completed
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "accept then CAS-lose",
            attachments: [],
            interactionMode: .default
        )

        try await router.drainNextQueuedAgentMessage(thread: thread.id)

        XCTAssertEqual(runner.startCount, 1, "provider must start exactly once")
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queued.id),
                     "post-accept markDispatched failure must still drain the prepared head")
        XCTAssertEqual(try ctx.runRepo.get(id: AgentRunID(queued.id.value))?.status, .running)
      }
    }

    func test_checkpointEnrichmentBlockedAfterCallbackCannotDelayExactHostSettlement() async throws {
        // WHY: Git/file enrichment is optional metadata, while didFinish and the
        // exact host waiter are user-visible terminal ownership. A blocked Git
        // read must not keep an Agent App Bot handoff running or dispatch twice.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-blocked-checkpoint-enrichment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        let fixture = try makeT005AgentMentionFixture(
            root: root,
            peerRunner: peerRunner,
            hostRunner: hostRunner
        )
        let barrier = T005CheckpointEnrichmentBarrier()

        let dispatch = Task { @MainActor in
            await fixture.router.dispatchAgentAppBotMentions(
                peers: [fixture.peer],
                text: "@\(fixture.peer.handle) T005_BLOCK_ENRICHMENT",
                threadId: fixture.threadID,
                onto: fixture.surface,
                continueHost: true
            )
        }
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("T005_BLOCK_ENRICHMENT") }
        }
        XCTAssertTrue(peerStarted)
        XCTAssertTrue(peerRunner.finish(
            promptContaining: "T005_BLOCK_ENRICHMENT",
            reply: "checkpoint-owned peer reply"
        ))
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let handoff = try XCTUnwrap(fixture.botsViewModel.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: fixture.threadID
        ).first)
        let hostRunID = try XCTUnwrap(handoff.hostRunID)
        XCTAssertEqual(hostRunner.requests.first?.runId, hostRunID)

        barrier.target(hostRunID)
        fixture.context.coordinator.checkpointEnrichmentBarrierForTesting = { runID in
            await barrier.waitIfTarget(runID)
        }
        defer {
            barrier.release()
            fixture.context.coordinator.checkpointEnrichmentBarrierForTesting = nil
        }
        let finishes = T005RunFinishRecorder(targetRunID: hostRunID)
        fixture.context.coordinator.addObserver(finishes)
        defer { fixture.context.coordinator.removeObserver(finishes) }
        let hostFinish = Task.detached {
            hostRunner.finish(
                runID: hostRunID,
                status: .completed,
                reply: "checkpoint-owned host outcome"
            )
        }

        let enrichmentIsBlocked = await waitUntil(timeout: 1) { barrier.didEnter }
        XCTAssertTrue(enrichmentIsBlocked, "the test must hold the exact host run before optional Git enrichment")
        let callbackArrived = await waitUntil(timeout: 1) { finishes.records.count == 1 }
        XCTAssertTrue(callbackArrived, "didFinish must precede optional checkpoint enrichment")
        let hostSettled = await waitUntil(timeout: 1) {
            fixture.botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: fixture.threadID
            ).first?.phase == .completed
        }
        XCTAssertTrue(hostSettled, "the exact host waiter must settle while enrichment remains blocked")

        let minimal = try XCTUnwrap(
            fixture.context.turnCheckpointRepo.list(threadId: fixture.threadID)
                .first { $0.runId == hostRunID }
        )
        let exactAssistantID = try XCTUnwrap(minimal.assistantMessageId)
        XCTAssertEqual(
            try fixture.context.messageRepo.get(id: exactAssistantID)?.content,
            "checkpoint-owned host outcome",
            "the pre-callback minimal checkpoint must already own the exact assistant"
        )
        XCTAssertEqual(hostRunner.requests.filter { $0.runId == hostRunID }.count, 1)
        XCTAssertEqual(finishes.records.first?.finalMessage, "checkpoint-owned host outcome")
        barrier.release()
        let hostFinishReturned = await hostFinish.value
        XCTAssertTrue(hostFinishReturned)
        await dispatch.value
    }

    func test_minimalCheckpointUpsertFailurePublishesOneNilIdentityAndNeedsAttention() async throws {
        // WHY: terminal status alone does not own a reply. If the minimal exact
        // checkpoint cannot commit, the one authoritative callback must carry
        // nil identity and the Bot handoff must fail closed instead of hanging.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-minimal-checkpoint-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        let fixture = try makeT005AgentMentionFixture(
            root: root,
            peerRunner: peerRunner,
            hostRunner: hostRunner
        )

        let dispatch = Task { @MainActor in
            await fixture.router.dispatchAgentAppBotMentions(
                peers: [fixture.peer],
                text: "@\(fixture.peer.handle) T005_FAIL_MINIMAL_CHECKPOINT",
                threadId: fixture.threadID,
                onto: fixture.surface,
                continueHost: true
            )
        }
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("T005_FAIL_MINIMAL_CHECKPOINT") }
        }
        XCTAssertTrue(peerStarted)
        XCTAssertTrue(peerRunner.finish(
            promptContaining: "T005_FAIL_MINIMAL_CHECKPOINT",
            reply: "peer reply still has exact ownership"
        ))
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let handoff = try XCTUnwrap(fixture.botsViewModel.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: fixture.threadID
        ).first)
        let hostRunID = try XCTUnwrap(handoff.hostRunID)
        let finishes = T005RunFinishRecorder(targetRunID: hostRunID)
        fixture.context.coordinator.addObserver(finishes)
        defer { fixture.context.coordinator.removeObserver(finishes) }

        try fixture.context.db.execute("""
            CREATE TRIGGER fail_t005_minimal_checkpoint
            BEFORE INSERT ON agent_turn_checkpoints
            WHEN NEW.run_id = '\(hostRunID.value.uuidString)'
            BEGIN
                SELECT RAISE(ABORT, 'forced minimal checkpoint failure');
            END;
        """)
        defer { try? fixture.context.db.execute("DROP TRIGGER fail_t005_minimal_checkpoint;") }
        XCTAssertTrue(hostRunner.finish(
            runID: hostRunID,
            status: .completed,
            reply: "unowned host assistant"
        ))

        let callbackArrived = await waitUntil(timeout: 1) { finishes.records.count == 1 }
        XCTAssertTrue(callbackArrived, "checkpoint failure must not suppress terminal cleanup or didFinish")
        let durableTerminal = await waitUntil(timeout: 1) {
            (try? fixture.context.runRepo.get(id: hostRunID)?.status) == .completed
        }
        XCTAssertTrue(durableTerminal)
        XCTAssertTrue(
            try fixture.context.turnCheckpointRepo.list(threadId: fixture.threadID)
                .allSatisfy { $0.runId != hostRunID },
            "the injected failure must leave no counterfeit exact checkpoint"
        )
        let record = try XCTUnwrap(finishes.records.first)
        XCTAssertNil(record.finalMessage, "failed ownership persistence must publish no reply identity")
        XCTAssertNil(record.providerThreadID, "failed ownership persistence must publish no provider identity")
        let needsAttention = await waitUntil(timeout: 1) {
            fixture.botsViewModel.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: fixture.threadID
            ).first?.phase == .needsAttention
        }
        XCTAssertTrue(needsAttention, "the exact owning activity must settle needsAttention without hanging")
        await dispatch.value
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(finishes.records.count, 1, "one terminal attempt must fan out one authoritative callback")
        XCTAssertEqual(hostRunner.requests.filter { $0.runId == hostRunID }.count, 1)
    }

    func test_terminalGraphFailureClearsAttemptMarkerSoDurableStaleReleaseFiresOnce() async throws {
        // WHY: a failed terminal transaction is not provenance forever. Its
        // exact attempt marker must retire on the failure return, allowing a
        // separately durable terminal row to release ownership exactly once.
        // Distill is the only shipped provider; a signed-in snapshot lets the
        // send reach the fixture runner.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-terminal-attempt-marker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let workspaceDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        let context = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: context)
        context.router = router
        rememberSignedInSnapshot(.distill, router: router)
        let runner = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.distill, runner: runner)
        let workspace = try router.createWorkspace(name: "t005 terminal marker", cwd: workspaceDirectory.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "T005 terminal marker",
            provider: .distill,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let send = try await router.sendAgentMessage(
            thread: thread.id,
            text: "hold terminal graph",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let runID = try XCTUnwrap(send.runId)
        let finishes = T005RunFinishRecorder(targetRunID: runID)
        context.coordinator.addObserver(finishes)
        defer { context.coordinator.removeObserver(finishes) }
        // The terminal graph stamps the existing run row (`stampTerminal`
        // UPDATE), so the forced failure and the step gate target that write.
        try context.db.execute("""
            CREATE TRIGGER fail_t005_terminal_graph
            BEFORE UPDATE OF status ON agent_runs
            WHEN NEW.id = '\(runID.value.uuidString)' AND NEW.status = 'completed'
            BEGIN
                SELECT RAISE(ABORT, 'forced terminal graph failure');
            END;
        """)
        defer { try? context.db.execute("DROP TRIGGER fail_t005_terminal_graph;") }

        let writeGate = T005SynchronousStepGate()
        context.db.beforeStatementStepForTesting = { sql in
            guard sql.contains("UPDATE agent_runs"), sql.contains("terminal_reason") else { return }
            writeGate.enterAndWait()
        }
        defer {
            writeGate.release()
            context.db.beforeStatementStepForTesting = nil
        }
        let finishTask = Task.detached {
            runner.finish(runID: runID, status: .completed, reply: "terminal graph reply")
        }
        let writeWasReached = await writeGate.waitUntilEntered(timeout: 1)
        XCTAssertTrue(writeWasReached, "the fixture must stop inside the exact terminal graph attempt")
        XCTAssertTrue(
            context.coordinator.terminalCheckpointAttemptIsActiveForTesting(runID),
            "the attempt marker must cover terminal persistence and minimal checkpoint identity"
        )
        writeGate.release()
        let finishReturned = await finishTask.value
        XCTAssertTrue(finishReturned)
        context.db.beforeStatementStepForTesting = nil

        let markerCleared = await waitUntil(timeout: 0.05) {
            !context.coordinator.terminalCheckpointAttemptIsActiveForTesting(runID)
        }
        XCTAssertTrue(markerCleared, "every terminal-graph failure return must retire the exact attempt marker")
        XCTAssertTrue(finishes.records.isEmpty, "failed durability cannot present a terminal callback")
        XCTAssertEqual(try context.runRepo.get(id: runID)?.status, .running)

        var durableRun = try XCTUnwrap(context.runRepo.get(id: runID))
        durableRun.status = .failed
        durableRun.finishedAt = Date()
        durableRun.errorMessage = "separately durable terminal"
        try context.runRepo.upsert(durableRun)
        var durableThread = try XCTUnwrap(context.threadRepo.get(id: thread.id))
        durableThread.status = .failed
        durableThread.updatedAt = Date()
        try context.threadRepo.upsert(durableThread)

        XCTAssertEqual(context.coordinator.reconcileStaleActiveOwnershipWithDurableState(), 1)
        let staleReleaseArrived = await waitUntil(timeout: 1) { finishes.records.count == 1 }
        XCTAssertTrue(staleReleaseArrived)
        XCTAssertEqual(finishes.records.first?.status, .failed)
        XCTAssertNil(finishes.records.first?.finalMessage)
        XCTAssertNil(finishes.records.first?.providerThreadID)
        XCTAssertEqual(context.coordinator.reconcileStaleActiveOwnershipWithDurableState(), 0)
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(finishes.records.count, 1, "a retained retry must not duplicate the stale terminal release")
    }

    /// WHY: desk mentions no longer dispatch the peer at send time — `sendMention`
    /// was replaced by tool-based delegation (`814506c7`), so a mention compiles a
    /// turn directive and the host agent reaches this same persist path through
    /// `askBotPeer` → `askPeerFromActiveProvider`. That path hands the origin Bot
    /// conversation and thread to `submitAgentAppMention`; `provider` is the one
    /// the peer's desk was pinned to, since the delegation derives the peer route
    /// from the origin thread (`BotDeskRouting` falls back to `thread.provider`).
    private func submitT005DeskPeerMention(
        context: AppContext,
        viewModel: BotsViewModel,
        host: BotDefinition,
        peer: BotDefinition,
        provider: AgentProvider,
        text: String
    ) throws -> Task<Void, Never>? {
        let conversation = try XCTUnwrap(viewModel.selectedConversation)
        var origin = conversation
        let thread: AgentThread
        if let linkedID = conversation.linkedAgentThreadID,
           let linked = try context.threadRepo.get(id: linkedID) {
            thread = linked
        } else {
            thread = try XCTUnwrap(context.router).createAgentThread(
                workspace: nil,
                title: conversation.title,
                provider: provider,
                model: "fake-model",
                permissionMode: .supervised,
                reasoningEffort: .medium,
                routingConfiguration: nil,
                quiet: true
            )
            origin.linkedAgentThreadID = thread.id
            try context.botStore.upsertConversation(origin)
        }
        return context.botPeerHandoffAuthority.submitAgentAppMention(
            peer: peer,
            text: text,
            peerText: text,
            originThread: thread,
            activityID: AgentMessageID(),
            hostRunID: nil,
            providerSnapshots: [],
            resumeHostAfterPeer: false,
            originBot: host,
            originConversation: origin
        )
    }

    /// A peer handoff run inherits the origin thread's provider (`BotDeskRouting`
    /// falls back to `thread.provider` because this seam dispatches a future host
    /// run id), so host and peer runs share one provider. Both runners register on
    /// that provider and the bot id the run carries in its environment picks the
    /// peer runner — the same seam `AgentAppBotMentionTests` exercises.
    private func wireCallerThreadHandoff(
        context: AppContext,
        peer: BotDefinition,
        peerRunner: ControlledBotHandoffRunner,
        hostRunner: ControlledBotHandoffRunner
    ) {
        context.coordinator.replaceProviderAdapter(
            hostRunner.provider,
            adapter: TerminalRetiringOneShotAdapter(
                runner: CallerThreadHandoffRunner(
                    hostRunner: hostRunner,
                    peerRunners: [peer.id: peerRunner]
                )
            )
        )
    }

    private func makeT005AgentMentionFixture(
        root: URL,
        peerRunner: ControlledBotHandoffRunner,
        hostRunner: ControlledBotHandoffRunner
    ) throws -> (
        context: AppContext,
        router: AppCommandRouter,
        botsViewModel: BotsViewModel,
        surface: AgentAppSurface,
        peer: BotDefinition,
        threadID: AgentThreadID
    ) {
        let workspaceDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        let context = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: context)
        context.router = router
        context.coordinator.replaceProvider(
            .grok,
            runner: FakeProviderRunner(provider: .grok, scenario: .simpleAssistant(reply: "unused"))
        )
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let botsViewModel = BotsViewModel(context: context, router: router)
        router.botsViewModel = botsViewModel
        let peer = try botsViewModel.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        botsViewModel.openDesk(peer)
        botsViewModel.setDeskProvider(.claude)
        wireCallerThreadHandoff(
            context: context,
            peer: peer,
            peerRunner: peerRunner,
            hostRunner: hostRunner
        )
        let workspace = try router.createWorkspace(name: "t005 checkpoint", cwd: workspaceDirectory.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "T005 checkpoint host",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let surface = AgentAppSurface(
            workspaceID: workspace.id,
            cwd: workspaceDirectory.path,
            coordinator: context.coordinator,
            threadRepo: context.threadRepo,
            messageRepo: context.messageRepo,
            queuedMessageRepo: context.queuedMessageRepo,
            providerSessionRepo: context.providerSessionRuntimeRepo,
            checkpointRepo: context.turnCheckpointRepo,
            initialThreadId: thread.id
        )
        surface.viewModel.mentionableBotsProvider = { botsViewModel.bots }
        surface.viewModel.selectThread(thread.id)
        return (context, router, botsViewModel, surface, peer, thread.id)
    }

    private func makeT005PeerPersistenceContext(
        root: URL,
        onDispatch: @escaping (AgentRunID) -> Void
    ) throws -> (
        context: AppContext,
        router: AppCommandRouter,
        viewModel: BotsViewModel,
        peerRunner: ControlledBotHandoffRunner,
        hostRunner: ControlledBotHandoffRunner
    ) {
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        context.coordinator.replaceProvider(.codex, runner: hostRunner)
        context.coordinator.replaceProvider(
            .grok,
            runner: FakeProviderRunner(provider: .grok, scenario: .simpleAssistant(reply: "unused"))
        )
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        context.botPeerHandoffAuthority.beforeBotRunDispatchForTesting = onDispatch
        let viewModel = BotsViewModel(context: context, router: router)
        router.botsViewModel = viewModel
        return (context, router, viewModel, peerRunner, hostRunner)
    }

    private func makeT005CachedPeerHandoffFixture(
        root: URL,
        v1Bytes: Data
    ) throws -> T005CachedPeerHandoffFixture {
        let emptyBytes = Data("[]".utf8)
        UserDefaults.standard.set(v1Bytes, forKey: "bots.peerTurns")
        UserDefaults.standard.set(emptyBytes, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        let dispatches = T005PeerDispatchRecorder()
        let base = try makeT005PeerPersistenceContext(root: root) {
            dispatches.record($0)
        }
        let piper = try base.viewModel.create(
            name: "Piper cached authority",
            title: "Cached origin",
            provider: .codex
        )
        let quinn = try base.viewModel.create(
            name: "Quinn cached authority",
            title: "Cached peer",
            provider: .claude
        )
        base.viewModel.openDesk(quinn)
        base.viewModel.setDeskProvider(.claude)
        base.viewModel.openDesk(piper)
        base.viewModel.setDeskProvider(.codex)
        base.viewModel.createDeskThread()

        var candidateBytes: Data?
        base.context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = { data in
            candidateBytes = data
            throw NSError(domain: "T005.CachedPeerFixture", code: 1)
        }
        let capturedHandoff = try submitT005DeskPeerMention(
            context: base.context,
            viewModel: base.viewModel,
            host: piper,
            peer: quinn,
            provider: .claude,
            text: "@\(quinn.handle) CAPTURE_SUPPORTED_CACHE_ROW"
        )
        XCTAssertNil(capturedHandoff, "the refused mirror commit must reject the handoff")
        base.context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = nil
        XCTAssertTrue(dispatches.runIDs.isEmpty)
        XCTAssertTrue(base.peerRunner.requests.isEmpty)

        var entries = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(candidateBytes)) as? [Any]
        )
        let recordIndex = try XCTUnwrap(entries.firstIndex { $0 is [String: Any] })
        var record = try XCTUnwrap(entries[recordIndex] as? [String: Any])
        let seedActivityID = try XCTUnwrap(
            (record["activityID"] as? String).flatMap(UUID.init(uuidString:))
        )
        record["phase"] = BotPeerHandoffPhase.needsAttention.rawValue
        entries[recordIndex] = record
        let seedBytes = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        try base.context.settingsRepo.set(
            "bots.peerTurns.v2",
            "base64:\(seedBytes.base64EncodedString())"
        )
        UserDefaults.standard.set(seedBytes, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())
        base.viewModel.reconcilePeerHandoffsForTesting()
        XCTAssertNotNil(
            base.viewModel.peerHandoffSnapshotsForTesting().first {
                $0.activityID == seedActivityID && $0.phase == .needsAttention
            }
        )

        return T005CachedPeerHandoffFixture(
            context: base.context,
            router: base.router,
            viewModel: base.viewModel,
            peerRunner: base.peerRunner,
            hostRunner: base.hostRunner,
            piper: piper,
            quinn: quinn,
            seedBytes: seedBytes,
            seedActivityID: seedActivityID,
            dispatches: dispatches
        )
    }

    private func t005PeerHandoffPayload(
        _ data: Data,
        replacingVersion version: Int,
        addingOpaqueField: Bool
    ) throws -> Data {
        var entries = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Any])
        let recordIndex = try XCTUnwrap(entries.firstIndex { $0 is [String: Any] })
        var record = try XCTUnwrap(entries[recordIndex] as? [String: Any])
        record["version"] = version
        if addingOpaqueField {
            record["futureOpaqueField"] = ["owner": "newer-build", "preserve": true] as [String: Any]
        }
        entries[recordIndex] = record
        return try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
    }

    private func t005PeerHandoffPayloadAddingSibling(
        _ data: Data
    ) throws -> (Data, UUID) {
        var entries = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Any])
        let recordIndex = try XCTUnwrap(entries.firstIndex { $0 is [String: Any] })
        var sibling = try XCTUnwrap(entries[recordIndex] as? [String: Any])
        let siblingActivityID = UUID()
        sibling["activityID"] = siblingActivityID.uuidString.lowercased()
        sibling["inboundMessageID"] = UUID().uuidString.lowercased()
        sibling["outboundText"] = "EXTERNALLY_COMMITTED_SIBLING"
        sibling["phase"] = BotPeerHandoffPhase.needsAttention.rawValue
        entries.append(siblingActivityID.uuidString.lowercased())
        entries.append(sibling)
        return (
            try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]),
            siblingActivityID
        )
    }

    private static func causalQueueFakeClaudeBridge(
        commandLogPath: String,
        releaseFIFOPath: String
    ) -> String {
        """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const commandLog = '\(commandLogPath)';
        const releaseFIFO = '\(releaseFIFOPath)';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        let turn = 0;
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        function finishTurn(ordinal) {
          write({
            type: 'result',
            subtype: 'success',
            is_error: false,
            result: 'DONE_' + ordinal,
            session_id: 'sdk-causal-queue'
          });
        }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const command = JSON.parse(line);
          fs.appendFileSync(commandLog, JSON.stringify(command) + '\\n');
          if (command.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-causal-queue' });
          } else if (command.type === 'rc_turn') {
            turn += 1;
            if (turn === 1) {
              const gate = fs.createReadStream(releaseFIFO);
              gate.once('data', () => {
                gate.close();
                finishTurn(turn);
              });
            } else {
              finishTurn(turn);
            }
          } else if (command.type === 'rc_close') {
            process.exit(0);
          }
        }
        """
    }

    private static func loggedClaudeBridgeCommands(
        at url: URL,
        type: String
    ) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else {
                    return nil
                }
                return object
            }
            .filter { ($0["type"] as? String) == type }
    }

    private func makeLiveAdapterRouterFixture(
        root: URL
    ) async throws -> (AppContext, AppCommandRouter, OneShotProviderAdapter, AgentThread) {
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let adapter = OneShotProviderAdapter(runner: BlockingCancelRunner(provider: .codex))
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        let workspace = try router.createWorkspace(name: "live-adapter-fixture", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "live adapter fixture",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-5.5",
            cwd: workspaceDir.path,
            prompt: "existing turn"
        )) { _ in }
        return (ctx, router, adapter, thread)
    }
}

private struct T005CachedPeerHandoffFixture {
    let context: AppContext
    let router: AppCommandRouter
    let viewModel: BotsViewModel
    let peerRunner: ControlledBotHandoffRunner
    let hostRunner: ControlledBotHandoffRunner
    let piper: BotDefinition
    let quinn: BotDefinition
    let seedBytes: Data
    let seedActivityID: UUID
    let dispatches: T005PeerDispatchRecorder
}

/// A handoff dispatch only resumes when the handoff reaches a milestone
/// (`hostRunning`, `completed` or `needsAttention`). A peer run the spec never
/// finishes leaves that await pending forever, so a spec that waits on the
/// dispatch unbounded reports nothing at all and hangs the whole class. Bounding
/// it turns "no verdict" into a named failure the round can attribute.
@MainActor
final class MilestoneBoundedHandoffDispatch {
    private(set) var isSettled = false

    init(_ body: @escaping @MainActor () async -> Void) {
        Task { @MainActor [self] in
            await body()
            isSettled = true
        }
    }

    /// False when the dispatch never reached its milestone within `timeout`.
    func settle(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isSettled { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return isSettled
    }
}

private final class T005PeerDispatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentRunID] = []

    var runIDs: [AgentRunID] {
        lock.withLock { stored }
    }

    func record(_ runID: AgentRunID) {
        lock.withLock { stored.append(runID) }
    }
}

private final class T005CheckpointEnrichmentBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var targetRunID: AgentRunID?
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    var didEnter: Bool {
        lock.withLock { entered }
    }

    func target(_ runID: AgentRunID) {
        lock.withLock {
            targetRunID = runID
            entered = false
            released = false
        }
    }

    func waitIfTarget(_ runID: AgentRunID) async {
        let shouldWait = lock.withLock { targetRunID == runID && !released }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                entered = true
                if released { return true }
                self.continuation = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        continuation?.resume()
    }
}

private final class T005RunFinishRecorder: AgentRunObserver, @unchecked Sendable {
    struct Record {
        let status: AgentRunStatus
        let finalMessage: String?
        let providerThreadID: String?
    }

    private let targetRunID: AgentRunID
    private let lock = NSLock()
    private var stored: [Record] = []

    init(targetRunID: AgentRunID) {
        self.targetRunID = targetRunID
    }

    var records: [Record] {
        lock.withLock { stored }
    }

    func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didReceive event: AssistantEvent,
        run: AgentRunID,
        threadId: AgentThreadID
    ) {}

    func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didFinish runID: AgentRunID,
        threadId: AgentThreadID,
        status: AgentRunStatus,
        finalMessage: String?,
        providerThreadId: String?
    ) {
        guard runID == targetRunID else { return }
        lock.withLock {
            stored.append(Record(
                status: status,
                finalMessage: finalMessage,
                providerThreadID: providerThreadId
            ))
        }
    }

    func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didChangeStatus status: AgentRunStatus,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {}
}

private final class T005SynchronousStepGate: @unchecked Sendable {
    private let lock = NSLock()
    private let enteredSignal = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var hasEntered = false
    private var hasReleased = false

    func enterAndWait() {
        let shouldWait = lock.withLock { () -> Bool in
            guard !hasEntered else { return false }
            hasEntered = true
            enteredSignal.signal()
            return !hasReleased
        }
        if shouldWait {
            _ = releaseSignal.wait(timeout: .now() + 2)
        }
    }

    func waitUntilEntered(timeout: TimeInterval) async -> Bool {
        if lock.withLock({ hasEntered }) { return true }
        return await Task.detached { [enteredSignal] in
            enteredSignal.wait(timeout: .now() + timeout) == .success
        }.value
    }

    func release() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !hasReleased else { return false }
            hasReleased = true
            return true
        }
        if shouldSignal { releaseSignal.signal() }
    }
}

private final class ThrowingStartRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    let error: Error
    let claimAcceptanceBeforeThrow: Bool
    private let lock = NSLock()
    private var starts = 0
    init(
        provider: AgentProvider,
        error: Error = AgentRunError.spawnFailed("intentional queue-start failure"),
        claimAcceptanceBeforeThrow: Bool = false
    ) {
        self.provider = provider
        self.error = error
        self.claimAcceptanceBeforeThrow = claimAcceptanceBeforeThrow
    }
    var startCount: Int { lock.withLock { starts } }
    func listModels() async -> [AgentModelDescriptor] { [] }
    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.withLock { starts += 1 }
        if claimAcceptanceBeforeThrow, let acceptancePermit = request.acceptancePermit {
            try acceptancePermit.withAcceptance { throw error }
        }
        throw error
    }
}

private final class RequestCaptureRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let queue = DispatchQueue(label: "RequestCaptureRunner")
    private var captured: AgentRunRequest?

    init(provider: AgentProvider) {
        self.provider = provider
    }

    var lastRequest: AgentRunRequest? {
        queue.sync { captured }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        queue.sync { captured = request }
        Task.detached {
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: "turn-1")))
            onEvent(.event(.turnCompleted(turnId: "turn-1", finalMessage: "ok")))
            onEvent(.finished(.completed, finalMessage: "ok", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

/// Accepts the provider write, then deletes the matching prepared queue row so
/// the caller's subsequent `markDispatched` CAS returns false — proving the
/// post-accept finalize fallback path.
private final class ConcurrentPreparedAckRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    let queuedMessageRepo: AgentQueuedMessageRepository
    private let lock = NSLock()
    private var starts = 0

    init(provider: AgentProvider, queuedMessageRepo: AgentQueuedMessageRepository) {
        self.provider = provider
        self.queuedMessageRepo = queuedMessageRepo
    }

    var startCount: Int { lock.withLock { starts } }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.withLock { starts += 1 }
        guard let acceptancePermit = request.acceptancePermit else {
            throw AgentRunAcceptanceError.cancelled
        }
        try acceptancePermit.withAcceptance {
            _ = try queuedMessageRepo.acknowledgePreparedWithRunEvidence(
                id: AgentQueuedMessageID(request.runId.value),
                runId: request.runId
            )
        }
        // Leave the run non-terminal so post-accept recovery is visible while
        // the provider turn is still considered live.
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class CompletingAcceptanceCaptureRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var capturedRunIDs: [AgentRunID] = []

    init(provider: AgentProvider) {
        self.provider = provider
    }

    var acceptedRunIDs: [AgentRunID] {
        lock.withLock { capturedRunIDs }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        guard let acceptancePermit = request.acceptancePermit else {
            throw AgentRunAcceptanceError.cancelled
        }
        try acceptancePermit.withAcceptance {
            lock.withLock { capturedRunIDs.append(request.runId) }
        }
        Task.detached {
            onEvent(.status(.completed))
            onEvent(.finished(
                .completed,
                finalMessage: "accepted",
                providerThreadId: request.providerThreadId
            ))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class BlockingCancelRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var _cancelled = false

    init(provider: AgentProvider) {
        self.provider = provider
    }

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        onEvent(.event(.turnStarted(turnId: "turn-blocking")))
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            self?.lock.lock()
            self?._cancelled = true
            self?.lock.unlock()
            onEvent(.status(.cancelled))
            onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: nil))
        }
    }
}

private final class DelayedCancelQueueRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var starts = 0
    private var runIDs: [AgentRunID] = []
    private var callbacks: [Int: @Sendable (AgentRunEvent) -> Void] = [:]
    private var finishWasMainThread = true
    private let finishOnCancel: Bool
    private let reportsProviderThreadAtStart: Bool

    /// `reportsProviderThreadAtStart` names the provider thread as soon as the
    /// turn starts, as Distill does once session/new accepts the prompt, so a
    /// later turn can retire the session under a new process scope.
    init(
        provider: AgentProvider,
        cancellationDelay: TimeInterval? = nil,
        reportsProviderThreadAtStart: Bool = false
    ) {
        self.provider = provider
        self.finishOnCancel = cancellationDelay != nil
        self.reportsProviderThreadAtStart = reportsProviderThreadAtStart
    }

    var startCount: Int {
        lock.withLock { starts }
    }
    var startedRunIDs: [AgentRunID] {
        lock.withLock { runIDs }
    }
    var lastFinishWasMainThread: Bool {
        lock.withLock { finishWasMainThread }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let ordinal = lock.withLock { () -> Int in
            starts += 1
            runIDs.append(request.runId)
            callbacks[starts] = onEvent
            return starts
        }
        onEvent(.status(.running))
        if reportsProviderThreadAtStart {
            onEvent(.event(.threadStarted(threadId: "delayed-session", providerThreadId: "delayed-session")))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {
            guard ordinal == 1, self.finishOnCancel else { return }
            self.finishRun(ordinal: ordinal, status: .cancelled)
        }
    }

    /// Bounded so a start that never happens fails the test instead of hanging the suite.
    func waitForStartCount(
        _ count: Int,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while lock.withLock({ starts < count }) {
            guard Date() < deadline else {
                XCTFail("runner reached \(startCount) starts, expected \(count)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func finishRun(ordinal: Int, status: AgentRunStatus) {
        guard let callback = lock.withLock({
            finishWasMainThread = Thread.isMainThread
            return callbacks.removeValue(forKey: ordinal)
        }) else { return }
        callback(.status(status))
        callback(.finished(status, finalMessage: nil, providerThreadId: "delayed-session"))
    }
}

private final class ConcurrentBulkStopRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .claude
    private let failingThreadId: AgentThreadID
    private let barrier: ConcurrentBulkStopBarrier

    init(failingThreadId: AgentThreadID, barrier: ConcurrentBulkStopBarrier) {
        self.failingThreadId = failingThreadId
        self.barrier = barrier
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: nil) {
            self.barrier.enterAndBlock(threadId: request.threadId)
            guard request.threadId != self.failingThreadId else { return }
            onEvent(.status(.cancelled))
            onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: nil))
        }
    }
}

private final class PostClaimPreHandleRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let barrier: PostClaimPreHandleStartBarrier
    private let reportsProviderThreadOnAccept: Bool

    /// `reportsProviderThreadOnAccept` names the provider thread once the
    /// prompt write is accepted, as Distill does.
    init(
        barrier: PostClaimPreHandleStartBarrier,
        provider: AgentProvider = .claude,
        reportsProviderThreadOnAccept: Bool = false
    ) {
        self.barrier = barrier
        self.provider = provider
        self.reportsProviderThreadOnAccept = reportsProviderThreadOnAccept
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        guard let acceptancePermit = request.acceptancePermit else {
            throw AgentRunAcceptanceError.cancelled
        }
        try acceptancePermit.withAcceptance {
            barrier.claimAndBlockPhysicalWrite()
        }
        onEvent(.status(.running))
        if reportsProviderThreadOnAccept {
            onEvent(.event(.threadStarted(threadId: "post-claim-session", providerThreadId: "post-claim-session")))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {
            self.barrier.recordCancellation()
            onEvent(.status(.cancelled))
            onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: nil))
        }
    }
}

private final class PostClaimPreHandleStartBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let writeRelease = DispatchSemaphore(value: 0)
    private var claimed = false
    private var claims = 0
    private var writes = 0
    private var cancellations = 0

    var physicalWriteCount: Int { lock.withLock { writes } }
    var claimCount: Int { lock.withLock { claims } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func claimAndBlockPhysicalWrite() {
        let claim = lock.withLock { () -> Int in
            claimed = true
            claims += 1
            return claims
        }
        if claim == 1 {
            writeRelease.wait()
        }
        lock.withLock { writes += 1 }
    }

    /// Bounded so a claim that never happens fails the test instead of hanging the suite.
    func waitUntilClaimed(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("provider write claimed", timeout: timeout, file: file, line: line) { claimed }
    }

    func releaseWrite() {
        writeRelease.signal()
    }

    func recordCancellation() {
        lock.withLock { cancellations += 1 }
    }

    /// Bounded so a cancellation that never happens fails the test instead of hanging the suite.
    func waitUntilCancelled(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("provider run cancelled", timeout: timeout, file: file, line: line) { cancellations > 0 }
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval,
        file: StaticString,
        line: UInt,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !lock.withLock(condition) {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class ConcurrentBulkStopBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var enteredThreadIds = Set<AgentThreadID>()
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func enterAndBlock(threadId: AgentThreadID) {
        let entry = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            guard enteredThreadIds.insert(threadId).inserted else { return (false, []) }
            let count = enteredThreadIds.count
            let ready = waiters.filter { $0.0 <= count }.map(\.1)
            waiters.removeAll { $0.0 <= count }
            return (true, ready)
        }
        guard entry.0 else { return }
        entry.1.forEach { $0.resume() }
        releaseSemaphore.wait()
    }

    func waitUntilEntered(_ expected: Int) async {
        if lock.withLock({ enteredThreadIds.count >= expected }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard enteredThreadIds.count < expected else { return true }
                waiters.append((expected, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func releaseAll(_ count: Int) {
        for _ in 0..<count {
            releaseSemaphore.signal()
        }
    }
}

private final class QueueFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let threadId: String
    private var value = 0
    private var messages: [String] = []

    init(threadId: AgentThreadID) {
        self.threadId = threadId.value.uuidString
    }

    var count: Int { lock.withLock { value } }
    var failureMessages: [String] { lock.withLock { messages } }

    func record(_ event: EventBus.Event) {
        guard event.kind == "agent.message.queue.failed",
              event.payload.objectValue?["thread_id"]?.stringValue == threadId else { return }
        let message = event.payload.objectValue?["message"]?.stringValue ?? ""
        lock.withLock {
            value += 1
            messages.append(message)
        }
    }

    /// Bounded so a missing failure event fails the test instead of hanging the suite.
    func waitForCount(
        _ expected: Int,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while lock.withLock({ value < expected }) {
            guard Date() < deadline else {
                XCTFail("saw \(count) queue failures, expected \(expected)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class QueueEventSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let threadId: String
    private let kind: String
    private var count = 0

    init(threadId: AgentThreadID, kind: String) {
        self.threadId = threadId.value.uuidString
        self.kind = kind
    }

    func record(_ event: EventBus.Event) {
        guard event.kind == kind,
              event.payload.objectValue?["thread_id"]?.stringValue == threadId else { return }
        lock.withLock { count += 1 }
    }

    /// Bounded so a missing event fails the test instead of hanging the suite.
    func waitForCount(
        _ expected: Int,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while lock.withLock({ count < expected }) {
            guard Date() < deadline else {
                let seen = lock.withLock { count }
                XCTFail("saw \(seen) \(kind) events, expected \(expected)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor QueueDrainAsyncSignal {
    private var signalled = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        signalled = true
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    /// Resumes as soon as `signal()` runs (callers rely on that ordering), and
    /// fails after `timeout` instead of hanging the suite.
    func wait(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard !signalled else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.expire(id, file: file, line: line)
            }
        }
    }

    private func expire(_ id: UUID, file: StaticString, line: UInt) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        XCTFail("signal never arrived", file: file, line: line)
        waiter.resume()
    }

    var isSignalled: Bool { signalled }
}

private actor QueueDrainTestSleeper {
    private struct PendingSleep {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Duration, Error>
    }

    private var elapsedByThread: [AgentThreadID: Duration] = [:]
    private var intervalsByThread: [AgentThreadID: [Duration]] = [:]
    private var pendingByThread: [AgentThreadID: PendingSleep] = [:]
    private var cancelledSleepIDs = Set<UUID>()

    func sleep(threadId: AgentThreadID, duration: Duration) async throws -> Duration {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || cancelledSleepIDs.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                intervalsByThread[threadId, default: []].append(duration)
                pendingByThread[threadId] = PendingSleep(
                    id: id,
                    duration: duration,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(threadId: threadId, sleepID: id) }
        }
    }

    func advanceNext(threadId: AgentThreadID) async {
        if pendingByThread[threadId] == nil {
            await waitForRequestCount(
                intervalsByThread[threadId, default: []].count + 1,
                threadId: threadId
            )
        }
        guard let pending = pendingByThread.removeValue(forKey: threadId) else { return }
        let elapsed = elapsedByThread[threadId, default: .zero] + pending.duration
        elapsedByThread[threadId] = elapsed
        pending.continuation.resume(returning: elapsed)
    }

    /// Bounded so a sleep that is never requested fails the test instead of hanging the suite.
    func waitForRequestCount(
        _ count: Int,
        threadId: AgentThreadID,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while intervalsByThread[threadId, default: []].count < count {
            guard Date() < deadline else {
                XCTFail(
                    "saw \(intervalsByThread[threadId, default: []].count) drain sleeps, expected \(count)",
                    file: file,
                    line: line
                )
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func requestedIntervals(threadId: AgentThreadID) -> [Duration] {
        intervalsByThread[threadId, default: []]
    }

    private func cancel(threadId: AgentThreadID, sleepID: UUID) {
        guard let pending = pendingByThread[threadId], pending.id == sleepID else {
            cancelledSleepIDs.insert(sleepID)
            return
        }
        pendingByThread.removeValue(forKey: threadId)
        pending.continuation.resume(throwing: CancellationError())
    }
}

private actor QueueDrainAsyncBarrier {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class PromptWriteFailureGrokPeer {
    let root: URL
    let path: String
    private let launchCountPath: String

    var launchCount: Int {
        ((try? String(contentsOfFile: launchCountPath, encoding: .utf8)) ?? "").count
    }

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("grok")
        launchCountPath = root.appendingPathComponent("launch-count").path
        let source = #"""
        #!/bin/sh
        printf x >> "COUNT_PATH"
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
          if printf '%s' "$line" | grep -q '"method":"initialize"'; then
            printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":true},"sessionCapabilities":{}}}}\n' "$id"
          elif printf '%s' "$line" | grep -q '"method":"session.*new"'; then
            exec 0<&-
            printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"session-fixed","models":{"currentModelId":"account-live-model","availableModels":[{"modelId":"account-live-model","name":"Live"}]},"modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"}]}}}\n' "$id"
            exec tail -f "COUNT_PATH" >/dev/null
          fi
        done
        """#
            .replacingOccurrences(of: "COUNT_PATH", with: launchCountPath)
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        path = script.path
    }
}

final class TerminalRetiringOneShotAdapter: AgentProviderAdapter, @unchecked Sendable {
    private let inner: OneShotProviderAdapter
    private let lock = NSLock()
    private var retiredThreadIDs = Set<AgentThreadID>()

    init(runner: AgentProviderRunner) {
        inner = OneShotProviderAdapter(runner: runner)
    }

    var provider: AgentProvider { inner.provider }

    func listModels() async -> [AgentModelDescriptor] { await inner.listModels() }

    func startSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        _ = lock.withLock { retiredThreadIDs.remove(request.threadId) }
        return try await inner.startSession(request, onEvent: onEvent)
    }

    func sendTurn(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        _ = lock.withLock { retiredThreadIDs.remove(request.threadId) }
        return try await inner.sendTurn(request, onEvent: onEvent)
    }

    func interruptTurn(threadId: AgentThreadID) throws {
        try inner.interruptTurn(threadId: threadId)
    }

    func respondToRequest(
        threadId: AgentThreadID,
        requestId: String,
        response: AgentProviderRequestResponse
    ) async throws {
        try await inner.respondToRequest(threadId: threadId, requestId: requestId, response: response)
    }

    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        try inner.respondToUserInput(threadId: threadId, requestId: requestId, text: text)
    }

    func stopSession(threadId: AgentThreadID) throws {
        let terminalWithoutHandle = inner.listSessions().contains {
            $0.threadId == threadId && $0.status != .pending && $0.status != .running
        }
        if terminalWithoutHandle {
            _ = lock.withLock { retiredThreadIDs.insert(threadId) }
            return
        }
        try inner.stopSession(threadId: threadId)
        _ = lock.withLock { retiredThreadIDs.insert(threadId) }
    }

    func recoverSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws {
        _ = lock.withLock { retiredThreadIDs.remove(request.threadId) }
        try await inner.recoverSession(request, onEvent: onEvent)
    }

    func listSessions() -> [AgentProviderSessionSummary] {
        let retired = lock.withLock { retiredThreadIDs }
        return inner.listSessions().filter { !retired.contains($0.threadId) }
    }

    func hasSession(threadId: AgentThreadID) -> Bool {
        !lock.withLock { retiredThreadIDs.contains(threadId) }
            && inner.hasSession(threadId: threadId)
    }

    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        try await inner.readThread(threadId: threadId)
    }

    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        try await inner.rollbackThread(threadId: threadId, toTurnId: toTurnId)
    }

    func stopAll() {
        inner.stopAll()
        lock.withLock { retiredThreadIDs.removeAll() }
    }

    func streamEvents(
        threadId: AgentThreadID,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) throws {
        try inner.streamEvents(threadId: threadId, onEvent: onEvent)
    }
}

private final class RevokingAcceptanceAdapter: AgentProviderAdapter, @unchecked Sendable {
    private let inner: AgentProviderAdapter
    private let lock = NSLock()
    private var sawPermit = false

    init(inner: AgentProviderAdapter) {
        self.inner = inner
    }

    var provider: AgentProvider { inner.provider }
    var forkSafety: AgentProviderForkSafety { inner.forkSafety }
    var sawAcceptancePermit: Bool { lock.withLock { sawPermit } }

    func forkSafety(threadId: AgentThreadID) -> AgentProviderForkSafety {
        inner.forkSafety(threadId: threadId)
    }

    func listModels() async -> [AgentModelDescriptor] { await inner.listModels() }

    func startSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        try await revokeAndSend(request, onEvent: onEvent)
    }

    func sendTurn(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        try await revokeAndSend(request, onEvent: onEvent)
    }

    private func revokeAndSend(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        if let permit = request.acceptancePermit {
            lock.withLock { sawPermit = true }
            permit.invalidate()
        }
        return try await inner.sendTurn(request, onEvent: onEvent)
    }

    func interruptTurn(threadId: AgentThreadID) throws {
        try inner.interruptTurn(threadId: threadId)
    }

    func respondToRequest(
        threadId: AgentThreadID,
        requestId: String,
        response: AgentProviderRequestResponse
    ) async throws {
        try await inner.respondToRequest(threadId: threadId, requestId: requestId, response: response)
    }

    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        try inner.respondToUserInput(threadId: threadId, requestId: requestId, text: text)
    }

    func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {
        try inner.cancelUserInput(threadId: threadId, requestId: requestId)
    }

    func stopSession(threadId: AgentThreadID) throws {
        try inner.stopSession(threadId: threadId)
    }

    func recoverSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws {
        try await inner.recoverSession(request, onEvent: onEvent)
    }

    func listSessions() -> [AgentProviderSessionSummary] { inner.listSessions() }
    func hasSession(threadId: AgentThreadID) -> Bool { inner.hasSession(threadId: threadId) }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        try await inner.readThread(threadId: threadId)
    }
    func forkThread(threadId: AgentThreadID) async throws -> String {
        try await inner.forkThread(threadId: threadId)
    }
    func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
        try await inner.forkThread(request)
    }
    func compensateFork(
        _ request: AgentProviderForkRequest,
        providerChildThreadId: String
    ) async throws {
        try await inner.compensateFork(request, providerChildThreadId: providerChildThreadId)
    }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        try await inner.rollbackThread(threadId: threadId, toTurnId: toTurnId)
    }
    func stopAll() { inner.stopAll() }
    func stopAllForAppTermination() { inner.stopAllForAppTermination() }
    func streamEvents(
        threadId: AgentThreadID,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) throws {
        try inner.streamEvents(threadId: threadId, onEvent: onEvent)
    }
}

private final class ProviderAcceptanceProbePeer {
    let path: String
    private let markerPath: String

    var acceptedPromptCount: Int {
        ((try? String(contentsOfFile: markerPath, encoding: .utf8)) ?? "").count
    }

    init(provider: AgentProvider, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        markerPath = root.appendingPathComponent("accepted-prompts").path
        let script = root.appendingPathComponent(provider.rawValue)
        let source: String
        switch provider {
        case .codex:
            source = """
            #!/usr/bin/env python3
            import json, pathlib, sys
            marker = pathlib.Path(\(String(reflecting: markerPath)))
            for line in sys.stdin:
                message = json.loads(line)
                method = message.get("method")
                if method == "initialize":
                    result = {"userAgent": "permit-probe"}
                elif method == "thread/start":
                    result = {"thread": {"id": "codex-thread", "turns": [], "status": {"state": "idle"}}}
                elif method == "turn/start":
                    marker.write_text("x")
                    result = {"turn": {"id": "codex-turn"}}
                else:
                    result = {}
                print(json.dumps({"id": message["id"], "result": result}), flush=True)
            """
        case .claude:
            source = """
            #!/usr/bin/env python3
            import json, pathlib, sys
            marker = pathlib.Path(\(String(reflecting: markerPath)))
            print(json.dumps({"type":"system","subtype":"init","session_id":"claude-thread"}), flush=True)
            for line in sys.stdin:
                if line.strip():
                    marker.write_text("x")
            """
        case .grok, .distill:
            source = """
            #!/usr/bin/env python3
            import json, pathlib, sys
            marker = pathlib.Path(\(String(reflecting: markerPath)))
            for line in sys.stdin:
                message = json.loads(line)
                method = message.get("method")
                if method == "initialize":
                    result = {"protocolVersion":1,"agentCapabilities":{"loadSession":True,"promptCapabilities":{"image":False,"audio":False,"embeddedContext":True},"sessionCapabilities":{}}}
                elif method == "session/new":
                    result = {"sessionId":"grok-thread","models":{"currentModelId":"account-live-model","availableModels":[{"modelId":"account-live-model","name":"Live"}]},"modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"}]}}
                elif method == "session/prompt":
                    marker.write_text("x")
                    result = {"stopReason":"end_turn"}
                else:
                    result = {}
                print(json.dumps({"jsonrpc":"2.0","id":message["id"],"result":result}), flush=True)
            """
        }
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        path = script.path
    }
}
