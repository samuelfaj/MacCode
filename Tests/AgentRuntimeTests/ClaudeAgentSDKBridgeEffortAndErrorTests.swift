import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime

/// Regression tests for two Agent SDK bridge gaps:
///
/// 1. Effort/ultracode plumbing (audit F0/F7): the SDK bridge is the DEFAULT
///    live Claude adapter, so if `rc_configure` drops `effort`/`settings` the
///    entire effort picker (and the whole Ultracode feature) is a silent no-op,
///    and since the SDK query has no live effort control a mid-thread effort
///    change must respawn the bridge session with resume.
/// 2. `sdk_error` termination (audit F2/F16): the bridge's query loop emits
///    `sdk_error` as its ONLY failure path. If it is dropped, no
///    `result`/`turnCompleted` ever arrives, the adapter never emits
///    `.finished`, and the run shows 'running' forever with no error text.
final class ClaudeAgentSDKBridgeEffortAndErrorTests: ProviderProcessTestCase {

    // MARK: - ClaudeParser sdk_error (F2)

    // WHY: sdk_error means the SDK query died mid-turn — no `result` will follow.
    // The parser must both surface the error AND complete the active turn so the
    // adapter's turnCompleted teardown emits .finished(.failed) instead of
    // leaving the run stuck in 'running' until the user guesses to press Stop.
    func test_parser_sdkErrorMidTurn_emitsTerminalErrorAndCompletesTheActiveTurn() {
        let parser = ClaudeParser()
        _ = parser.parseLine(#"{"type":"system","subtype":"init","session_id":"s1"}"#)
        let turnEvents = parser.parseLine(#"{"type":"assistant","message":{"content":[{"type":"text","text":"partial answer"}]},"session_id":"s1"}"#)
        let turnId = turnEvents.compactMap { event -> String? in
            if case .turnStarted(let id) = event { return id }
            return nil
        }.first
        XCTAssertNotNil(turnId, "sanity: the assistant message must have opened a turn")

        let events = parser.parseLine(#"{"type":"sdk_error","message":"spawn claude ENOENT"}"#)

        let errors = events.compactMap { event -> (message: String, recoverable: Bool)? in
            if case .error(let message, let recoverable) = event { return (message, recoverable) }
            return nil
        }
        XCTAssertEqual(errors.first?.message, "spawn claude ENOENT",
                       "the bridge's error text must reach the timeline so the user sees WHY the run died")
        XCTAssertEqual(errors.first?.recoverable, true,
                       "sdk_error ends only the active turn; the bridge accepts a fresh query on Retry and must expose that recovery")

        let completed = events.compactMap { event -> String? in
            if case .turnCompleted(let id, _) = event { return id }
            return nil
        }
        XCTAssertEqual(completed, [turnId!],
                       "sdk_error must complete the ACTIVE turn: without turnCompleted the adapter never emits .finished and the run hangs in 'running'")
    }

    // WHY: the query can also die before any turn event was emitted (e.g. the
    // inner CLI spawn fails instantly). The run is already in-flight on the
    // Swift side, so the parser must synthesize a turn and complete it —
    // otherwise inFlightRunId is never cleared.
    func test_parser_sdkErrorWithoutActiveTurn_synthesizesAndCompletesATurn() {
        let parser = ClaudeParser()
        let events = parser.parseLine(#"{"type":"sdk_error","message":"Claude Code process exited with code 1"}"#)

        XCTAssertTrue(events.contains { event in
            if case .error(_, let recoverable) = event { return recoverable }
            return false
        }, "the failure must surface with Retry because the warm bridge accepts a fresh query")
        XCTAssertTrue(events.contains { event in
            if case .turnStarted = event { return true }
            return false
        }, "a turn must be synthesized so the failure has a home in the transcript")
        XCTAssertTrue(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "the synthesized turn must complete so the adapter can finish the run as failed")
    }

    func test_parserPublishesBridgeHandshakeAsRuntimeEvidence() throws {
        let events = ClaudeParser().parseLine(
            #"{"type":"system","subtype":"rc_bridge_ready","session_id":"s1","bridge_protocol_version":1,"sdk_version":"0.3.157","claude_runtime_configured":true}"#
        )

        let runtime = try XCTUnwrap(events.compactMap { event -> ProviderRuntimeEvent? in
            if case .providerRuntime(let runtime) = event { return runtime }
            return nil
        }.first)
        XCTAssertEqual(runtime.method, "runtime.handshake")
        XCTAssertTrue(runtime.payloadJSON.contains(#""sdk_version":"0.3.157""#),
                      "the loaded SDK version must be persisted in the normalized runtime timeline for diagnostics")
    }

    // WHY: AppContext drains queued work from the provider-terminal callback.
    // The callback must therefore observe the resident Claude session as idle
    // immediately; relying on a later Task.yield makes queue progress scheduler-
    // dependent and can strand Force until another lifecycle event happens.
    func test_finishedCallbackObservesIdleSession() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-causal-idle")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try Self.loggingFakeBridgeSource(sessionId: "sdk-causal-idle")
            .write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let finished = expectation(description: "Claude terminal callback")
        let probe = ClaudeCausalIdleProbe()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "sonnet",
            cwd: tmp.path,
            prompt: "finish causally idle",
            extraArgs: [commandLog.path]
        )) { event in
            guard case .finished = event else { return }
            let status = adapter.listSessions()
                .first(where: { $0.threadId == threadId })?
                .status
            probe.observeTerminalCallback(sessionStatus: status)
            finished.fulfill()
        }
        defer { try? adapter.stopSession(threadId: threadId) }

        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(probe.observedStatuses, [.completed],
                       "the terminal callback is the causal idle edge; the adapter must commit idle state before publishing it")
    }

    // MARK: - Adapter: rc_configure carries effort + settings (F0)

    // WHY: the SDK bridge is the production-default Claude adapter. If
    // rc_configure omits effort/settings, picking Ultracode (or any effort)
    // silently runs at the CLI default with no Workflow tool — the canonical
    // ClaudeRunner mapping (ultracode wire effort + ultracode/enableWorkflows
    // settings) must reach the bridge verbatim.
    func test_rcConfigureCarriesUltracodeEffortAndSettings() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-effort-configure")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try Self.loggingFakeBridgeSource(sessionId: "sdk-effort-session").write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-opus-4-7",
            cwd: tmp.path,
            prompt: "first",
            reasoningEffort: .ultracode,
            extraArgs: [commandLog.path]
        )) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "DONE_1")
        defer { try? adapter.stopSession(threadId: threadId) }

        let configures = try Self.loggedCommands(at: commandLog, ofType: "rc_configure")
        XCTAssertEqual(configures.count, 1)
        XCTAssertEqual(configures.first?["effort"] as? String, "xhigh",
                       "SDK Options.effort has no ultracode member; wire xhigh and keep settings.ultracode")
        XCTAssertEqual(configures.first?["settings"] as? String, ClaudeRunner.ultracodeSettingsJSON,
                       "ultracode must carry the enableWorkflows settings payload — without it the Workflow tool is never exposed")
        let settingsData = try XCTUnwrap((configures.first?["settings"] as? String)?.data(using: .utf8))
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: settingsData) as? [String: Any]
        )
        XCTAssertEqual(
            (settings["env"] as? [String: String])?["CLAUDE_CODE_EFFORT_LEVEL"],
            "xhigh",
            "SDK settings must align with Ultracode's effective xhigh effort"
        )
        XCTAssertEqual(configures.first?["bridge_protocol_version"] as? Int, ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
                       "the host and Node bridge must negotiate one explicit command schema before the SDK query starts")
        XCTAssertEqual(configures.first?["expected_sdk_version"] as? String, "0.3.157",
                       "the bridge handshake must verify the exact SDK version provisioned by the host")
    }

    func test_rcTurnCarriesRawUserPromptSeparateIdentityAndExactRunMCP() async throws {
        // WHY: the primary AI must see the user's complete prompt unchanged and
        // author the peer prompt itself. Identity and active-run authority are
        // transport metadata, not host-side semantic extraction, and both must
        // refresh on the individual turn rather than freeze in SDK session state.
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-bot-peer-turn")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try Self.loggingFakeBridgeSource(sessionId: "sdk-bot-peer-session")
            .write(to: bridge, atomically: true, encoding: .utf8)

        let thread = "11111111-2222-3333-4444-555555555555"
        let run = "66666666-7777-8888-9999-AAAAAAAAAAAA"
        let turnContext = "REMOTE CODE IDENTITY ONLY: @nexus is Nexus"
        let original = "@nexus pergunte o nome e depois escolha outro nome"
        let environment = [
            BotPeerDelegation.threadEnvironmentKey: thread,
            BotPeerDelegation.runEnvironmentKey: run,
            BotPeerDelegation.socketEnvironmentKey: "/tmp/remote-code.sock",
            BotPeerDelegation.turnContextEnvironmentKey: turnContext,
        ]
        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadID = AgentThreadID(UUID(uuidString: thread)!)
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadID,
            provider: .claude,
            model: "sonnet",
            cwd: tmp.path,
            prompt: original,
            environment: environment,
            extraArgs: [commandLog.path]
        )) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "DONE_1")
        defer { try? adapter.stopSession(threadId: threadID) }

        let configure = try XCTUnwrap(Self.loggedCommands(at: commandLog, ofType: "rc_configure").first)
        let turn = try XCTUnwrap(Self.loggedCommands(at: commandLog, ofType: "rc_turn").first)
        let providerPrompt = try XCTUnwrap(turn["prompt"] as? String)
        XCTAssertTrue(providerPrompt.hasSuffix("User request:\n\(original)"),
                      "the provider envelope must carry the complete original request without extracting a Bot sub-prompt")
        XCTAssertEqual(providerPrompt.components(separatedBy: original).count - 1, 1)
        XCTAssertFalse(providerPrompt.contains(turnContext),
                       "resolved identity belongs in separate turn metadata, never inside rewritten user prose")
        XCTAssertEqual(turn["turn_context"] as? String, turnContext)
        for command in [configure, turn] {
            let servers = try XCTUnwrap(command["mcp_servers"] as? [String: Any])
            let server = try XCTUnwrap(servers[BotSelfConfigMCPAdmit.serverName] as? [String: Any])
            let forwarded = try XCTUnwrap(server["env"] as? [String: String])
            XCTAssertEqual(forwarded[BotPeerDelegation.threadEnvironmentKey], thread)
            XCTAssertEqual(forwarded[BotPeerDelegation.runEnvironmentKey], run)
            XCTAssertEqual(forwarded[BotPeerDelegation.socketEnvironmentKey], "/tmp/remote-code.sock")
            XCTAssertEqual(command["allowed_tools"] as? [String],
                           BotSelfConfigMCPAdmit.claudeAutomaticallyAllowedTools,
                           "only bot peer tools are pre-authorized")
        }
    }

    func test_rcConfigureOmitsHaikuEffortButKeepsThinkingEnabledAndSanitized() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-haiku-thinking")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try Self.loggingFakeBridgeSource(sessionId: "sdk-haiku-session")
            .write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "first",
            reasoningEffort: .max,
            environment: [
                "CLAUDE_CODE_DISABLE_THINKING": "1",
                "MAX_THINKING_TOKENS": "0",
                "CLAUDE_CODE_EFFORT_LEVEL": "low",
                "DISABLE_INTERLEAVED_THINKING": "1"
            ],
            extraArgs: [commandLog.path]
        )) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "DONE_1")
        defer { try? adapter.stopSession(threadId: threadId) }

        let configure = try XCTUnwrap(
            Self.loggedCommands(at: commandLog, ofType: "rc_configure").first
        )
        XCTAssertNil(configure["effort"], "Haiku must not receive an unsupported SDK effort")
        let settingsJSON = try XCTUnwrap(configure["settings"] as? String)
        let settingsData = try XCTUnwrap(settingsJSON.data(using: .utf8))
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: settingsData) as? [String: Any]
        )
        XCTAssertEqual(settings["alwaysThinkingEnabled"] as? Bool, true)
        XCTAssertEqual(settings["showThinkingSummaries"] as? Bool, true)
        XCTAssertNil(settings["ultracode"])
        let settingsEnvironment = try XCTUnwrap(settings["env"] as? [String: String])
        XCTAssertEqual(settingsEnvironment["CLAUDE_CODE_DISABLE_THINKING"], "0")
        XCTAssertEqual(settingsEnvironment["CLAUDE_CODE_EFFORT_LEVEL"], "")
        XCTAssertEqual(settingsEnvironment["DISABLE_INTERLEAVED_THINKING"], "0")
        XCTAssertEqual(settingsEnvironment["MAX_THINKING_TOKENS"], "32000")

        let environment = try XCTUnwrap(configure["environment"] as? [String: String])
        XCTAssertEqual(environment["CLAUDE_CODE_DISABLE_THINKING"], "0")
        XCTAssertEqual(environment["MAX_THINKING_TOKENS"], "32000")
        XCTAssertNil(environment["CLAUDE_CODE_EFFORT_LEVEL"])
        XCTAssertNil(environment["DISABLE_INTERLEAVED_THINKING"])
    }

    func test_initializerClaudePathIsRuntimeAuthorityWhenRequestHasNoBinary() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-runtime-authority")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try Self.loggingFakeBridgeSource(sessionId: "sdk-runtime-authority").write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(
            bridgeScriptPath: bridge.path,
            binaryNameOverride: "/usr/bin/true"
        )
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "sonnet",
            cwd: tmp.path,
            prompt: "prove runtime authority",
            extraArgs: [commandLog.path]
        )) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "DONE_1")
        defer { try? adapter.stopSession(threadId: threadId) }

        let configures = try Self.loggedCommands(at: commandLog, ofType: "rc_configure")
        XCTAssertEqual(configures.first?["claude_executable_path"] as? String, "/usr/bin/true",
                       "the saved Claude path must remain authoritative even before a refreshed provider snapshot adds providerBinary")
    }

    func test_recoverSessionConfiguresSavedCursorAndContinuesOnRecoveredBridge() async throws {
        // WHY: after a host restart the SDK adapter must configure the persisted
        // Claude cursor before accepting the next turn; starting a blank query
        // would silently discard the prior conversation.
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-saved-cursor")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try Self.loggingFakeBridgeSource(sessionId: "saved-claude-cursor")
            .write(to: bridge, atomically: true, encoding: .utf8)
        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let request = AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "sonnet",
            cwd: tmp.path,
            prompt: "",
            providerThreadId: "saved-claude-cursor",
            extraArgs: [commandLog.path]
        )
        let sink = EventSink()

        try await adapter.recoverSession(request) { event in
            Task { await sink.record(event) }
        }
        XCTAssertTrue(adapter.hasSession(threadId: threadId))
        let recovered = try XCTUnwrap(
            adapter.listSessions().first { $0.threadId == threadId }
        )
        XCTAssertEqual(recovered.providerThreadId, "saved-claude-cursor")
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "sonnet",
            cwd: tmp.path,
            prompt: "continue saved conversation",
            providerThreadId: "saved-claude-cursor",
            extraArgs: [commandLog.path]
        )) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "DONE_1")
        defer { try? adapter.stopSession(threadId: threadId) }

        let configures = try Self.loggedCommands(at: commandLog, ofType: "rc_configure")
        XCTAssertEqual(configures.count, 1,
                       "recovery and the following turn must reuse one configured bridge")
        XCTAssertEqual(configures.first?["provider_thread_id"] as? String, "saved-claude-cursor",
                       "the recovered bridge must receive the persisted Claude cursor used as the SDK resume option")
    }

    func test_realBridgeHandshakePublishesProtocolAndLoadedSDKVersion() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let harness = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query() { return (async function*() {})(); }
        """)
        defer { _ = harness.finish() }

        try harness.send([
            "type": "rc_configure",
            "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
            "expected_sdk_version": "0.3.157",
            "session_id": "handshake-session"
        ])
        try harness.send(["type": "rc_turn", "prompt": "handshake"])

        XCTAssertTrue(harness.waitFor(#""subtype":"rc_bridge_ready""#),
                      "the real Node bridge must acknowledge the command schema before accepting turns; stderr: \(harness.stderrText())")
        XCTAssertTrue(harness.output.contains("\"bridge_protocol_version\":\(ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion)"))
        XCTAssertTrue(harness.output.contains(#""sdk_version":"0.3.157""#),
                      "the handshake must publish the SDK version actually loaded by Node, not only the host's pinned constant")
    }

    func test_realBridgeRejectsSDKVersionMismatchBeforeQuery() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let harness = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query() {
          return (async function*() { yield { type: 'result', result: 'QUERY_MUST_NOT_RUN' }; })();
        }
        """)
        defer { _ = harness.finish() }

        try harness.send([
            "type": "rc_configure",
            "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
            "expected_sdk_version": "0.3.999",
            "session_id": "mismatch-session"
        ])
        try harness.send(["type": "rc_turn", "prompt": "must reject"])

        XCTAssertTrue(harness.waitFor("Claude Agent SDK version mismatch"),
                      "a host/Node SDK drift must fail loud instead of running against an unverified schema")
        XCTAssertFalse(harness.output.contains("QUERY_MUST_NOT_RUN"),
                       "the bridge must reject the turn before invoking query() when the loaded SDK violates the host contract")
    }

    func test_realBridgeUsesFullClaudeCodeToolPresetAndStructuredAttachment() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let harness = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query({ prompt, options }) {
          return (async function*() {
            const message = await prompt[Symbol.asyncIterator]().next();
            const contract = { tools: options.tools, content: message.value?.message?.content || [] };
            yield { type: 'result', subtype: 'success', is_error: false, result: 'CONTRACT:' + JSON.stringify(contract), session_id: 'contract-session' };
          })();
        }
        """)
        defer { _ = harness.finish() }

        try harness.send([
            "type": "rc_configure",
            "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
            "expected_sdk_version": "0.3.157",
            "session_id": "contract-session"
        ])
        try harness.send([
            "type": "rc_turn",
            "prompt": "inspect",
            "attachments": [["path": "/tmp/note.txt", "display_name": "note.txt", "kind": "file", "mime_type": "text/plain"]]
        ])

        XCTAssertTrue(harness.waitFor("CONTRACT:"), "the real bridge must invoke the SDK query")
        XCTAssertTrue(harness.output.contains(#"\"preset\":\"claude_code\""#),
                      "the production SDK path must expose Claude Code's Read/Edit/Bash agent tool preset")
        XCTAssertTrue(harness.output.contains(#"[Attachment: note.txt]\\n/tmp/note.txt"#),
                      "file attachments must reach the SDK prompt as a structured content block")
    }

    func test_realBridgeOmitsEmptyTextBlockOnAttachOnlyTurn() throws {
        // WHY: 2.1.277 rejects empty text content blocks. Agent App send is
        // enabled with files and empty text; pushPrompt must omit {type:text,text:""}.
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let harness = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query({ prompt }) {
          return (async function*() {
            const message = await prompt[Symbol.asyncIterator]().next();
            yield { type: 'result', subtype: 'success', is_error: false, result: 'ATTACH_ONLY:' + JSON.stringify(message.value?.message?.content || []), session_id: 'attach-only' };
          })();
        }
        """)
        defer { _ = harness.finish() }

        try harness.send([
            "type": "rc_configure",
            "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
            "expected_sdk_version": "0.3.157",
            "session_id": "attach-only"
        ])
        try harness.send([
            "type": "rc_turn",
            "prompt": "",
            "attachments": [["path": "/tmp/note.txt", "display_name": "note.txt", "kind": "file", "mime_type": "text/plain"]]
        ])

        XCTAssertTrue(harness.waitFor("ATTACH_ONLY:"), "the real bridge must invoke the SDK query")
        XCTAssertFalse(harness.output.contains(#"{"type":"text","text":""}"#)
            || harness.output.contains(#"{\"type\":\"text\",\"text\":\"\"}"#),
                       "attach-only turns must not emit an empty text content block")
        XCTAssertTrue(harness.output.contains(#"[Attachment: note.txt]\\n/tmp/note.txt"#),
                      "file attachments must still reach the SDK prompt")
    }

    // MARK: - Adapter: effort change is a runtime switch (F7)

    // WHY: the SDK query has no live effort control (unlike rc_set_model /
    // rc_set_permission), so bumping Medium→Ultracode mid-thread must respawn
    // the bridge with the previous session id as the resume cursor — otherwise
    // the change is silently ignored for the rest of the session.
    func test_effortChangeRespawnsBridgeWithResume() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-effort-switch")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try Self.loggingFakeBridgeSource(sessionId: "sdk-effort-session").write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let first = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-opus-4-7",
            cwd: tmp.path,
            prompt: "first",
            reasoningEffort: .medium,
            extraArgs: [commandLog.path]
        )) { event in
            Task { await first.record(event) }
        }
        try await waitForFinish(in: first, expected: "DONE_1")

        // NOTE: no providerThreadId on the request — the adapter must stash the
        // live session id itself so the respawned bridge resumes the conversation.
        let second = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-opus-4-7",
            cwd: tmp.path,
            prompt: "second",
            reasoningEffort: .ultracode,
            extraArgs: [commandLog.path]
        )) { event in
            Task { await second.record(event) }
        }
        // A RESPAWNED bridge restarts its per-process turn counter at 1; a
        // (wrongly) reused bridge would answer DONE_2 and this wait would fail.
        try await waitForFinish(in: second, expected: "DONE_1")
        defer { try? adapter.stopSession(threadId: threadId) }

        let configures = try Self.loggedCommands(at: commandLog, ofType: "rc_configure")
        XCTAssertEqual(configures.count, 2,
                       "an effort change must respawn the bridge session (one rc_configure per spawn) — the SDK has no live effort control")
        XCTAssertEqual(configures.first?["effort"] as? String, "medium",
                       "the effort flag is never omitted: nil/medium map to 'medium', mirroring ClaudeRunner")
        XCTAssertEqual(configures.last?["effort"] as? String, "xhigh")
        XCTAssertEqual(configures.last?["settings"] as? String, ClaudeRunner.ultracodeSettingsJSON)
        XCTAssertEqual(configures.last?["provider_thread_id"] as? String, "sdk-effort-session",
                       "the respawned session must resume the previous provider thread so no conversation context is lost")
    }

    func test_modelChangeRespawnsWhenEffectiveEffortOrWorkflowContractChanges() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }

        func assertRespawn(
            from firstModel: String,
            to secondModel: String,
            effort: AgentReasoningEffort,
            prefix: String,
            firstExpectedEffort: String?,
            secondExpectedEffort: String,
            secondUsesUltracode: Bool
        ) async throws {
            let tmp = try Self.makeTempDir(prefix: prefix)
            let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
            let commandLog = tmp.appendingPathComponent("commands.jsonl")
            try Self.loggingFakeBridgeSource(sessionId: "\(prefix)-session")
                .write(to: bridge, atomically: true, encoding: .utf8)

            let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
            let threadId = AgentThreadID()
            let first = EventSink()
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: threadId, provider: .claude, model: firstModel,
                cwd: tmp.path, prompt: "first", reasoningEffort: effort,
                extraArgs: [commandLog.path]
            )) { event in Task { await first.record(event) } }
            try await waitForFinish(in: first, expected: "DONE_1")

            let second = EventSink()
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: threadId, provider: .claude, model: secondModel,
                cwd: tmp.path, prompt: "second", reasoningEffort: effort,
                extraArgs: [commandLog.path]
            )) { event in Task { await second.record(event) } }
            try await waitForFinish(in: second, expected: "DONE_1")
            defer { try? adapter.stopSession(threadId: threadId) }

            let configures = try Self.loggedCommands(at: commandLog, ofType: "rc_configure")
            XCTAssertEqual(configures.count, 2, "a changed effective SDK contract must respawn")
            XCTAssertEqual(configures.first?["effort"] as? String, firstExpectedEffort)
            XCTAssertEqual(configures.last?["effort"] as? String, secondExpectedEffort)
            XCTAssertEqual(
                (configures.last?["settings"] as? String)?.contains(#""ultracode":true"#),
                secondUsesUltracode
            )
            XCTAssertEqual(configures.last?["provider_thread_id"] as? String, "\(prefix)-session")
        }

        try await assertRespawn(
            from: "claude-haiku-4-5", to: "claude-opus-5", effort: .medium,
            prefix: "sdk-model-effort", firstExpectedEffort: nil,
            secondExpectedEffort: "medium", secondUsesUltracode: false
        )
        try await assertRespawn(
            from: "claude-mythos-preview", to: "claude-fable-5", effort: .ultracode,
            prefix: "sdk-model-workflow", firstExpectedEffort: "high",
            secondExpectedEffort: "xhigh", secondUsesUltracode: true
        )
    }

    // MARK: - Adapter: sdk_error finishes the run as failed (F16)

    // WHY: when the bridge reports sdk_error the node process stays alive and no
    // result ever follows. The adapter must emit .finished(.failed) (clearing the
    // in-flight run) and surface the error — the pre-fix behavior left the thread
    // badge on 'running' forever with no explanation.
    func test_sdkErrorFailsTheRunInsteadOfHangingRunning() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-error-terminal")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        try """
        import readline from 'node:readline';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-error-session' });
          } else if (cmd.type === 'rc_turn') {
            write({ type: 'sdk_error', message: 'SDK exploded: spawn claude ENOENT' });
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "boom"
        )) { event in
            Task { await sink.record(event) }
        }
        defer { try? adapter.stopSession(threadId: threadId) }

        let deadline = Date().addingTimeInterval(3)
        var finishedStatus: AgentRunStatus?
        while Date() < deadline {
            let events = await sink.snapshot()
            if let status = events.compactMap({ event -> AgentRunStatus? in
                if case .finished(let status, _, _) = event { return status }
                return nil
            }).first {
                finishedStatus = status
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(finishedStatus, .failed,
                       "sdk_error must terminate the run as failed — without .finished the thread stays 'running' forever and queued messages never drain")

        let events = await sink.snapshot()
        XCTAssertTrue(events.contains { event in
            if case .event(.error(let message, let recoverable)) = event {
                return message.contains("SDK exploded") && recoverable
            }
            return false
        }, "the restartable sdk_error must remain visible and expose Retry because the warm session can run the next turn")
    }

    func test_interruptAfterBridgeClosesStdinThrowsTypedErrorAndRemovesSession() async throws {
        // WHY: the Node bridge can remain alive after its stdin closes. The
        // next control write must produce a typed error, never SIGPIPE/hang.
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-closed-stdin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let closedMarker = tmp.appendingPathComponent("stdin-closed")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        try """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-closed-stdin-session' });
          } else if (cmd.type === 'rc_turn') {
            fs.closeSync(0);
            fs.writeFileSync('\(closedMarker.path)', '');
            setTimeout(() => {}, 5000);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "wait"
        )) { _ in }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !FileManager.default.fileExists(atPath: closedMarker.path) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: closedMarker.path))
        XCTAssertTrue(adapter.hasSession(threadId: threadId))

        XCTAssertThrowsError(try adapter.interruptTurn(threadId: threadId)) { error in
            guard case AgentProviderAdapterError.sessionNotFound(let failedThreadId) = error else {
                return XCTFail("expected typed sessionNotFound, got \(error)")
            }
            XCTAssertEqual(failedThreadId, threadId)
        }
        XCTAssertFalse(adapter.hasSession(threadId: threadId),
                       "the failed control write must remove the dead bridge session")
    }

    func test_closedStdinInvalidatesEveryMutableBridgeControlBoundary() async throws {
        try skipUnlessLegacyClaudeIsSelectable()
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let boundaries = ["turn", "model", "permission", "user_input", "cancel_input"]

        for boundary in boundaries {
            let tmp = try Self.makeTempDir(prefix: "rc2-sdk-write-\(boundary)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let marker = tmp.appendingPathComponent("stdin-closed")
            let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
            try """
            import fs from 'node:fs';
            import readline from 'node:readline';
            const boundary = process.argv[2];
            const marker = process.argv[3];
            const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
            function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
            function closeInput() {
              fs.closeSync(0);
              fs.writeFileSync(marker, '');
              setTimeout(() => {}, 5000);
            }
            for await (const line of rl) {
              if (!line.trim()) continue;
              const cmd = JSON.parse(line);
              if (cmd.type === 'rc_configure') {
                write({ type: 'system', subtype: 'init', session_id: 'sdk-write-' + boundary });
              } else if (cmd.type === 'rc_turn') {
                if (boundary === 'permission') {
                  write({ type: 'permission_request', request_id: 'permission-1', tool_name: 'Bash', tool_input: { command: 'true' }, session_id: 'sdk-write-permission' });
                } else if (boundary === 'user_input' || boundary === 'cancel_input') {
                  write({ type: 'user_input_request', request_id: 'input-1', prompt: 'Choose', options: ['a'], session_id: 'sdk-write-input' });
                } else {
                  write({ type: 'result', subtype: 'success', is_error: false, result: 'FIRST_DONE', session_id: 'sdk-write-' + boundary });
                }
                closeInput();
              }
            }
            """.write(to: bridge, atomically: true, encoding: .utf8)

            let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
            let threadId = AgentThreadID()
            let sink = EventSink()
            // Keep the model-switch case on two models with the same effective
            // effort so it exercises rc_set_model. Haiku → Opus intentionally
            // respawns now because the model-aware effort contract changes.
            let initialModel = boundary == "model"
                ? "claude-opus-4-6"
                : "claude-haiku-4-5-20251001"
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: threadId,
                provider: .claude,
                model: initialModel,
                cwd: tmp.path,
                prompt: "first",
                extraArgs: [boundary, marker.path]
            )) { event in
                Task { await sink.record(event) }
            }

            let readyDeadline = Date().addingTimeInterval(3)
            var ready = false
            while Date() < readyDeadline {
                let events = await sink.snapshot()
                let expectedEvent: Bool
                switch boundary {
                case "permission":
                    expectedEvent = events.contains { if case .event(.requestOpened(let request)) = $0 { return request.id == "permission-1" }; return false }
                case "user_input", "cancel_input":
                    expectedEvent = events.contains { if case .event(.userInputRequested(let request)) = $0 { return request.id == "input-1" }; return false }
                default:
                    expectedEvent = events.contains { if case .finished(.completed, let final, _) = $0 { return final == "FIRST_DONE" }; return false }
                }
                ready = expectedEvent && FileManager.default.fileExists(atPath: marker.path)
                if ready { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(ready, "\(boundary) must be pending only after the bridge has closed stdin")

            var didThrow = false
            do {
                switch boundary {
                case "turn":
                    _ = try await adapter.sendTurn(AgentRunRequest(
                        threadId: threadId, provider: .claude, model: "claude-haiku-4-5-20251001",
                        cwd: tmp.path, prompt: "second", extraArgs: [boundary, marker.path]
                    )) { _ in }
                case "model":
                    _ = try await adapter.sendTurn(AgentRunRequest(
                        threadId: threadId, provider: .claude, model: "claude-opus-4-7",
                        cwd: tmp.path, prompt: "second", extraArgs: [boundary, marker.path]
                    )) { _ in }
                case "permission":
                    try await adapter.respondToRequest(threadId: threadId, requestId: "permission-1", response: .approve)
                case "user_input":
                    try adapter.respondToUserInput(threadId: threadId, requestId: "input-1", text: "a")
                default:
                    try adapter.cancelUserInput(threadId: threadId, requestId: "input-1")
                }
            } catch {
                didThrow = true
            }
            XCTAssertTrue(didThrow, "\(boundary) must fail loud when the bridge control pipe is closed")
            XCTAssertFalse(adapter.hasSession(threadId: threadId),
                           "\(boundary) must invalidate the dead session instead of leaving a zombie")

            if boundary == "permission" || boundary == "user_input" || boundary == "cancel_input" {
                let settlementDeadline = Date().addingTimeInterval(1)
                var settlementCount = 0
                while Date() < settlementDeadline {
                    settlementCount = await sink.snapshot().filter { event in
                        switch event {
                        case .event(.requestResolved(requestId: "permission-1", state: _)),
                             .event(.userInputResolved(requestId: "input-1", answer: _)):
                            return true
                        default:
                            return false
                        }
                    }.count
                    if settlementCount == 1 { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertEqual(settlementCount, 1,
                               "\(boundary) must settle its pending callback exactly once during invalidation")
            }
            adapter.stopAll()
        }
    }

    // WHY: cancelling one AskUserQuestion card is a request-scoped decision.
    // Sending rc_interrupt here stops the whole query and drains unrelated
    // approval/question callbacks, so one UI action can silently cancel work
    // the user never chose to cancel.
    func test_cancelUserInputSendsRequestScopedCommandAndKeepsOtherCallbacksUsable() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-question-cancel")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const log = process.argv[2];
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const command = JSON.parse(line);
          fs.appendFileSync(log, JSON.stringify(command) + '\\n');
          if (command.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-question-cancel' });
          } else if (command.type === 'rc_turn') {
            write({ type: 'user_input_request', request_id: 'question-cancel', prompt: 'Cancel me', options: ['cancel'] });
            write({ type: 'user_input_request', request_id: 'question-keep', prompt: 'Keep me', options: ['continue'] });
            write({ type: 'permission_request', request_id: 'approval-keep', tool_name: 'Bash', tool_input: { command: 'true' } });
          } else if (command.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "ask",
            extraArgs: [commandLog.path]
        )) { event in
            Task { await sink.record(event) }
        }
        defer { try? adapter.stopSession(threadId: threadId) }

        let deadline = Date().addingTimeInterval(3)
        var allCallbacksOpened = false
        while Date() < deadline {
            let events = await sink.snapshot()
            let questionIds = events.compactMap { event -> String? in
                if case .event(.userInputRequested(let request)) = event { return request.id }
                return nil
            }
            let approvalIds = events.compactMap { event -> String? in
                if case .event(.requestOpened(let request)) = event { return request.id }
                return nil
            }
            allCallbacksOpened = Set(questionIds) == ["question-cancel", "question-keep"]
                && approvalIds == ["approval-keep"]
            if allCallbacksOpened { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(allCallbacksOpened, "sanity: all independent callbacks must be pending before cancellation")

        try adapter.cancelUserInput(threadId: threadId, requestId: "question-cancel")
        try adapter.respondToUserInput(threadId: threadId, requestId: "question-keep", text: "continue")
        try await adapter.respondToRequest(threadId: threadId, requestId: "approval-keep", response: .approve)

        var commands: [[String: Any]] = []
        let commandDeadline = Date().addingTimeInterval(3)
        while Date() < commandDeadline {
            commands = (try? String(contentsOf: commandLog, encoding: .utf8))?
                .split(separator: "\n")
                .compactMap { line -> [String: Any]? in
                    try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                } ?? []
            let types = commands.compactMap { $0["type"] as? String }
            if types.contains("user_input_cancel")
                && types.contains("user_input_response")
                && types.contains("permission_response") {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let cancellation = try XCTUnwrap(commands.first { ($0["type"] as? String) == "user_input_cancel" })
        XCTAssertEqual(cancellation["request_id"] as? String, "question-cancel")
        XCTAssertFalse(commands.contains { ($0["type"] as? String) == "rc_interrupt" },
                       "question cancellation must not use the whole-turn interrupt command")
        XCTAssertTrue(commands.contains {
            ($0["type"] as? String) == "user_input_response" && ($0["request_id"] as? String) == "question-keep"
        }, "the unrelated question callback must remain answerable")
        XCTAssertTrue(commands.contains {
            ($0["type"] as? String) == "permission_response" && ($0["request_id"] as? String) == "approval-keep"
        }, "the unrelated approval callback must remain answerable")
        XCTAssertTrue(adapter.hasSession(threadId: threadId),
                      "request-scoped cancellation must preserve the warm Claude session")
    }

    func test_typedElicitationWritesSchemaValidContentAndKeepsInvalidCallbackPending() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-typed-elicitation")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const log = process.argv[2];
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const command = JSON.parse(line);
          fs.appendFileSync(log, JSON.stringify(command) + '\\n');
          if (command.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'typed-elicitation' });
          } else if (command.type === 'rc_turn') {
            write({
              type: 'user_input_request',
              request_id: 'typed-form',
              prompt: 'Configure deployment',
              requested_schema: {
                type: 'object',
                required: ['environment', 'replicas', 'dryRun'],
                properties: {
                  environment: { type: 'string', enum: ['staging', 'production'] },
                  replicas: { type: 'integer' },
                  dryRun: { type: 'boolean' }
                }
              }
            });
          } else if (command.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "typed elicitation",
            extraArgs: [commandLog.path]
        )) { event in Task { await sink.record(event) } }
        defer { try? adapter.stopSession(threadId: threadId) }

        let deadline = Date().addingTimeInterval(3)
        var request: AssistantUserInputRequest?
        while Date() < deadline, request == nil {
            request = await sink.snapshot().compactMap { event -> AssistantUserInputRequest? in
                if case .event(.userInputRequested(let request)) = event { return request }
                return nil
            }.first
            if request == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertEqual(request?.id, "typed-form")

        XCTAssertThrowsError(try adapter.respondToUserInput(
            threadId: threadId,
            requestId: "typed-form",
            text: #"{"environment":"staging","replicas":"invalid","dryRun":true}"#
        ), "invalid typed content must fail before the callback is marked resolved")

        try adapter.respondToUserInput(
            threadId: threadId,
            requestId: "typed-form",
            text: #"{"environment":"staging","replicas":3,"dryRun":true}"#
        )
        var responseCommand: [String: Any]?
        let commandDeadline = Date().addingTimeInterval(3)
        while Date() < commandDeadline, responseCommand == nil {
            responseCommand = (try? String(contentsOf: commandLog, encoding: .utf8))?
                .split(separator: "\n")
                .compactMap { line in
                    try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                }
                .first { ($0["type"] as? String) == "user_input_response" }
            if responseCommand == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let content = try XCTUnwrap(responseCommand?["content"] as? [String: Any])
        XCTAssertEqual(content["environment"] as? String, "staging")
        XCTAssertEqual(content["replicas"] as? Int, 3)
        XCTAssertEqual(content["dryRun"] as? Bool, true)
        let resolved = await sink.snapshot().filter { event in
            if case .event(.userInputResolved(let requestId, _)) = event { return requestId == "typed-form" }
            return false
        }
        XCTAssertEqual(resolved.count, 1, "the invalid attempt must not publish a false resolution")
    }

    // MARK: - Real bridge .mjs with a fake SDK (F0 + F16 bridge side)

    // WHY: the bridge must forward the host's effort and settings into the SDK
    // query options — storing them in rc_configure alone changes nothing if
    // query() never sees them.
    func test_bridgeForwardsEffortAndSettingsIntoQueryOptions() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let session = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query({ prompt, options }) {
          return (async function*() {
            const iterator = prompt[Symbol.asyncIterator]();
            await iterator.next();
            yield { type: 'assistant', message: { id: 'opt-1', content: [{ type: 'text', text: 'OPTIONS:' + JSON.stringify({ effort: options.effort ?? null, settings: options.settings ?? null, path: options.pathToClaudeCodeExecutable ?? null }) }] }, session_id: 'fake-effort' };
            yield { type: 'result', subtype: 'success', is_error: false, result: 'done', session_id: 'fake-effort' };
          })();
        }
        """)
        defer { _ = session.finish() }

        try session.send([
            "type": "rc_configure",
            "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
            "expected_sdk_version": "0.3.157",
            "cwd": NSTemporaryDirectory(),
            "model": "claude-haiku-4-5-20251001",
            "permission_mode": "supervised",
            "interaction_mode": "default",
            "provider_thread_id": "",
            "session_id": UUID().uuidString,
            "environment": [:],
            "effort": "xhigh",
            "settings": ClaudeRunner.ultracodeSettingsJSON,
            "claude_executable_path": "/usr/bin/true"
        ])
        try session.send(["type": "rc_turn", "prompt": "go"])

        XCTAssertTrue(session.waitFor("OPTIONS:"), "fake SDK never ran — bridge did not start the query. stderr: \(session.stderrText())")
        XCTAssertTrue(session.output.contains(#"\"effort\":\"xhigh\""#),
                      "query options must carry the effort from rc_configure — otherwise the effort picker is a no-op on the default adapter")
        XCTAssertTrue(session.output.contains("ultracode") && session.output.contains("enableWorkflows"),
                      "query options must carry the ultracode settings payload from rc_configure")
        XCTAssertTrue(session.output.contains(#"\"path\":\"/usr/bin/true\""#),
                      "query options must use the app-selected Claude executable path as the runtime authority")
    }

    func test_bridgeRefreshesBotMCPAndKeepsIdentitySeparateOnEveryTurn() throws {
        // WHY: Claude SDK reuses one query for multiple turns. A server admitted
        // only at query creation retains a stale run_id and fails the exact-run
        // authorization gate on the next mention. The bridge must refresh the
        // dynamic MCP before it delivers each untouched user prompt.
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let serverName = BotSelfConfigMCPAdmit.serverName
        let session = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query({ prompt, options }) {
          let servers = options.mcpServers || {};
          const allowed = options.allowedTools || [];
          return {
            async setMcpServers(next) {
              servers = next || {};
              return { added: Object.keys(servers), removed: [], errors: {} };
            },
            async *[Symbol.asyncIterator]() {
              for await (const message of prompt) {
                const content = message.message.content || [];
                const run = servers['\(serverName)']?.env?.RC_REMOTE_CODE_ROOT_RUN_ID || 'NO_RUN';
                const text = 'OBS:' + (content[0]?.text || '') + '|CTX:' + (content[1]?.text || '') + '|RUN:' + run + '|ALLOWED:' + allowed.join(',');
                yield { type: 'assistant', message: { id: 'peer-' + run, content: [{ type: 'text', text }] }, session_id: 'fake-peer-session' };
                yield { type: 'result', subtype: 'success', is_error: false, result: 'done-' + run, session_id: 'fake-peer-session' };
              }
            }
          };
        }
        """)
        defer { _ = session.finish() }

        func server(_ run: String) -> [String: Any] {
            [
                serverName: [
                    "command": "/bin/true",
                    "args": [BotSelfConfigMCPAdmit.cliArgument],
                    "env": [BotPeerDelegation.runEnvironmentKey: run],
                ]
            ]
        }
        try session.send([
            "type": "rc_configure",
            "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
            "expected_sdk_version": "0.3.157",
            "cwd": NSTemporaryDirectory(),
            "model": "claude-haiku-4-5-20251001",
            "permission_mode": "supervised",
            "interaction_mode": "default",
            "provider_thread_id": "",
            "session_id": UUID().uuidString,
            "environment": [:],
            "mcp_servers": server("RUN_ONE"),
            "allowed_tools": BotSelfConfigMCPAdmit.claudeAutomaticallyAllowedTools,
            "claude_executable_path": "/usr/bin/true",
        ])
        try session.send([
            "type": "rc_turn",
            "prompt": "ORIGINAL_ONE",
            "turn_context": "IDENTITY_ONE",
            "mcp_servers": server("RUN_ONE"),
        ])
        XCTAssertTrue(session.waitFor("done-RUN_ONE"), "first SDK turn did not complete: \(session.stderrText())")

        try session.send([
            "type": "rc_turn",
            "prompt": "ORIGINAL_TWO",
            "turn_context": "IDENTITY_TWO",
            "mcp_servers": server("RUN_TWO"),
        ])
        XCTAssertTrue(session.waitFor("done-RUN_TWO"), "second SDK turn did not receive refreshed MCP context: \(session.stderrText())")
        XCTAssertTrue(session.output.contains("OBS:ORIGINAL_ONE|CTX:<remote_code_turn_context>\\nIDENTITY_ONE"))
        XCTAssertTrue(session.output.contains("|RUN:RUN_ONE"))
        XCTAssertTrue(session.output.contains("OBS:ORIGINAL_TWO|CTX:<remote_code_turn_context>\\nIDENTITY_TWO"))
        XCTAssertTrue(session.output.contains("|RUN:RUN_TWO"),
                      "the long-lived query must replace the stale first-run MCP before the next user turn")
        XCTAssertTrue(session.output.contains("|ALLOWED:\(BotSelfConfigMCPAdmit.claudeAutomaticallyAllowedTools.joined(separator: ","))"),
                      "SDK supervised mode must pre-authorize only RemoteCode's host-guarded Bot delegation tools")
    }

    // WHY (AG-007): an approval response normally carries only the decision.
    // Returning `{}` as updatedInput erases the provider's command and nested
    // arguments. The real bridge must return a deep-equal copy of the original
    // canUseTool input unless the host explicitly supplies an override.
    func test_bridgeApprovalPreservesOriginalToolInputDeepEqual() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let session = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query({ prompt, options }) {
          return (async function*() {
            const iterator = prompt[Symbol.asyncIterator]();
            await iterator.next();
            const input = { command: 'printf ok', nested: { flags: ['a', 'b'], env: { A: '1' } }, allowedPrompts: [{ tool: 'Bash', prompt: 'safe' }] };
            const result = await options.canUseTool('Bash', input, { toolUseID: 'permission-deep-1' });
            yield { type: 'assistant', message: { id: 'permission-turn', content: [{ type: 'text', text: 'PERMISSION_RESULT:' + JSON.stringify(result.updatedInput) }] }, session_id: 'fake-permission' };
            yield { type: 'result', subtype: 'success', is_error: false, result: 'done', session_id: 'fake-permission' };
          })();
        }
        """)
        defer { _ = session.finish() }

        try session.send([
            "type": "rc_configure",
            "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
            "expected_sdk_version": "0.3.157",
            "cwd": NSTemporaryDirectory(),
            "model": "claude-haiku-4-5-20251001",
            "permission_mode": "supervised",
            "interaction_mode": "default",
            "provider_thread_id": "",
            "session_id": UUID().uuidString,
            "environment": [:]
        ])
        try session.send(["type": "rc_turn", "prompt": "run"])
        XCTAssertTrue(session.waitFor("permission-deep-1"),
                      "the real bridge must surface the fake SDK permission request. stderr: \(session.stderrText())")
        try session.send(["type": "permission_response", "request_id": "permission-deep-1", "decision": "approve"])
        XCTAssertTrue(session.waitFor("PERMISSION_RESULT:"),
                      "approval must resolve canUseTool with updatedInput. stderr: \(session.stderrText())")

        let resultText = session.output
            .split(separator: "\n")
            .compactMap { Data($0.utf8) }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .compactMap { ($0["message"] as? [String: Any])?["content"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["text"] as? String }
            .first { $0.hasPrefix("PERMISSION_RESULT:") }
        let json = try XCTUnwrap(resultText.map { String($0.dropFirst("PERMISSION_RESULT:".count)) })
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        let expected: NSDictionary = [
            "command": "printf ok",
            "nested": ["flags": ["a", "b"], "env": ["A": "1"]],
            "allowedPrompts": [["tool": "Bash", "prompt": "safe"]]
        ]
        XCTAssertEqual(actual, expected,
                       "approve without updated_input must preserve every original scalar, array, and nested object")
    }

    // WHY (AG-021): SDK plan approval normally continues directly into code
    // execution. RemoteCode must stop after the real ExitPlanModeOutput so the
    // user can review the persisted plan and choose Implement explicitly.
    func test_bridgeInterruptsPlanTurnAfterRealExitPlanModeOutput() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let session = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query({ prompt, options }) {
          let interrupted = false;
          const generator = (async function*() {
            await prompt[Symbol.asyncIterator]().next();
            await options.canUseTool('ExitPlanMode', { plan: '# Real plan', planFilePath: '/tmp/plan.md' }, { toolUseID: 'exit-plan-real' });
            yield {
              type: 'user',
              message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'exit-plan-real', content: 'approved' }] },
              tool_use_result: { plan: '# Real plan', filePath: '/tmp/plan.md', isAgent: false },
              session_id: 'fake-plan'
            };
            if (!interrupted) yield { type: 'assistant', message: { content: [{ type: 'text', text: 'MUTATION_STARTED' }] }, session_id: 'fake-plan' };
            yield { type: 'result', subtype: interrupted ? 'error_during_execution' : 'success', is_error: interrupted, result: interrupted ? 'INTERRUPTED_ERROR' : 'PLAN_RAN', session_id: 'fake-plan' };
          })();
          generator.interrupt = async () => { interrupted = true; };
          return generator;
        }
        """)
        defer { _ = session.finish() }

        try session.send([
            "type": "rc_configure",
            "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
            "expected_sdk_version": "0.3.157",
            "cwd": NSTemporaryDirectory(),
            "model": "claude-haiku-4-5-20251001",
            "permission_mode": "supervised",
            "interaction_mode": "plan",
            "provider_thread_id": "",
            "session_id": UUID().uuidString,
            "environment": [:]
        ])
        try session.send(["type": "rc_turn", "prompt": "plan"])
        XCTAssertTrue(session.waitFor("exit-plan-real"), "ExitPlanMode permission did not surface")
        try session.send(["type": "permission_response", "request_id": "exit-plan-real", "decision": "approve"])
        XCTAssertTrue(session.waitFor("Plan ready for review"), "bridge did not normalize its intentional plan-review interrupt")
        XCTAssertTrue(session.output.contains("\"plan\":\"# Real plan\""))
        XCTAssertFalse(session.output.contains("INTERRUPTED_ERROR"),
                       "the SDK's aborted_streaming result is expected for this host-owned pause and must not fail the run")
        XCTAssertFalse(session.output.contains("MUTATION_STARTED"),
                       "no implementation output may occur before the host's explicit Implement action")
    }

    // WHY: the bridge owns three independent callback maps. Cancelling one
    // question must resolve only that request and leave both the active query
    // and every unrelated question/approval callback intact.
    func test_bridgeQuestionCancelIsRequestScopedAndDoesNotInterruptQuery() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let session = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query({ prompt, options }) {
          const stream = (async function*() {
            const iterator = prompt[Symbol.asyncIterator]();
            await iterator.next();
            const cancelledQuestion = options.canUseTool(
              'AskUserQuestion',
              { questions: [{ question: 'Cancel?', options: [{ label: 'yes' }] }] },
              { toolUseID: 'question-cancel' }
            );
            const keptQuestion = options.canUseTool(
              'AskUserQuestion',
              { questions: [{ question: 'Continue?', options: [{ label: 'continue' }] }] },
              { toolUseID: 'question-keep' }
            );
            const keptApproval = options.canUseTool(
              'Bash',
              { command: 'true' },
              { toolUseID: 'approval-keep' }
            );
            const cancelled = await cancelledQuestion;
            yield { type: 'assistant', message: { id: 'cancel-result', content: [{ type: 'text', text: 'CANCEL_RESULT:' + JSON.stringify(cancelled) }] }, session_id: 'fake-cancel' };
            const survivors = await Promise.all([keptQuestion, keptApproval]);
            yield { type: 'assistant', message: { id: 'survivor-result', content: [{ type: 'text', text: 'SURVIVORS:' + JSON.stringify(survivors) }] }, session_id: 'fake-cancel' };
            yield { type: 'result', subtype: 'success', is_error: false, result: 'QUERY_CONTINUED', session_id: 'fake-cancel' };
          })();
          stream.interrupt = async () => { throw new Error('QUERY_WAS_INTERRUPTED'); };
          return stream;
        }
        """)
        defer { _ = session.finish() }

        try session.send([
            "type": "rc_configure",
            "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
            "expected_sdk_version": "0.3.157",
            "cwd": NSTemporaryDirectory(),
            "model": "claude-haiku-4-5-20251001",
            "permission_mode": "supervised",
            "interaction_mode": "default",
            "provider_thread_id": "",
            "session_id": UUID().uuidString,
            "environment": [:]
        ])
        try session.send(["type": "rc_turn", "prompt": "run"])
        XCTAssertTrue(session.waitFor("question-cancel") && session.waitFor("question-keep") && session.waitFor("approval-keep"),
                      "sanity: the bridge must expose all three independent callbacks. stderr: \(session.stderrText())")

        try session.send(["type": "user_input_cancel", "request_id": "question-cancel"])
        XCTAssertTrue(session.waitFor("CANCEL_RESULT:"),
                      "request-scoped cancellation must resolve its exact AskUser callback. stderr: \(session.stderrText())")
        XCTAssertTrue(session.output.contains(#"\"behavior\":\"deny\""#),
                      "the cancelled AskUser callback must be denied instead of treated as an empty answer")
        XCTAssertFalse(session.output.contains(#"\"interrupt\":true"#),
                       "cancelling a question must deny only that tool callback, not interrupt the query")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(session.output.contains("SURVIVORS:"),
                       "unrelated callbacks must remain pending instead of being drained by question cancellation")

        try session.send(["type": "user_input_response", "request_id": "question-keep", "text": "continue"])
        try session.send(["type": "permission_response", "request_id": "approval-keep", "decision": "approve"])
        XCTAssertTrue(session.waitFor("SURVIVORS:") && session.waitFor("QUERY_CONTINUED"),
                      "the remaining callbacks must resolve independently and let the original query finish. stderr: \(session.stderrText())")
        XCTAssertFalse(session.output.contains("QUERY_WAS_INTERRUPTED"))
    }

    func test_bridgeReturnsExactTypedElicitationContentToSDK() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let session = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query({ prompt, options }) {
          return (async function*() {
            const iterator = prompt[Symbol.asyncIterator]();
            await iterator.next();
            const result = await options.onElicitation({
              id: 'typed-sdk-form',
              message: 'Configure deployment',
              requestedSchema: {
                type: 'object',
                required: ['environment', 'replicas', 'dryRun'],
                properties: {
                  environment: { type: 'string', enum: ['staging', 'production'] },
                  replicas: { type: 'integer' },
                  dryRun: { type: 'boolean' }
                }
              }
            });
            yield { type: 'assistant', message: { id: 'typed-result', content: [{ type: 'text', text: 'ELICIT_RESULT:' + JSON.stringify(result) }] }, session_id: 'typed-sdk' };
            yield { type: 'result', subtype: 'success', is_error: false, result: 'DONE', session_id: 'typed-sdk' };
          })();
        }
        """)
        defer { _ = session.finish() }

        try session.send([
            "type": "rc_configure",
            "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
            "expected_sdk_version": "0.3.157",
            "cwd": NSTemporaryDirectory(),
            "model": "claude-haiku-4-5-20251001",
            "permission_mode": "supervised",
            "interaction_mode": "default",
            "provider_thread_id": "",
            "session_id": UUID().uuidString,
            "environment": [:]
        ])
        try session.send(["type": "rc_turn", "prompt": "run"])
        XCTAssertTrue(session.waitFor("typed-sdk-form"),
                      "bridge must expose the SDK elicitation. stderr: \(session.stderrText())")
        try session.send([
            "type": "user_input_response",
            "request_id": "typed-sdk-form",
            "text": #"{"environment":"staging","replicas":3,"dryRun":true}"#,
            "content": ["environment": "staging", "replicas": 3, "dryRun": true]
        ])
        XCTAssertTrue(session.waitFor("ELICIT_RESULT:"),
                      "SDK callback must receive the typed result. stderr: \(session.stderrText())")
        XCTAssertTrue(session.output.contains(#"\"action\":\"accept\""#))
        XCTAssertTrue(session.output.contains(#"\"environment\":\"staging\""#))
        XCTAssertTrue(session.output.contains(#"\"replicas\":3"#))
        XCTAssertTrue(session.output.contains(#"\"dryRun\":true"#))
    }

    // WHY: after the query loop dies the bridge previously kept the dead
    // iterator as activeQuery, so every later rc_turn queued a prompt nothing
    // would ever consume. The bridge must reset its stream state so the thread
    // is recoverable after the host surfaces the failure.
    func test_bridgeRestartsQueryAfterSDKError() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let session = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        let calls = 0;
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query({ prompt, options }) {
          calls += 1;
          const n = calls;
          return (async function*() {
            const iterator = prompt[Symbol.asyncIterator]();
            await iterator.next();
            if (n === 1) { throw new Error('QUERY_DIED'); }
            yield { type: 'result', subtype: 'success', is_error: false, result: 'RECOVERED_' + n, session_id: 'fake-recover' };
          })();
        }
        """)
        defer { _ = session.finish() }

        try session.send([
            "type": "rc_configure",
            "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
            "expected_sdk_version": "0.3.157",
            "cwd": NSTemporaryDirectory(),
            "model": "claude-haiku-4-5-20251001",
            "permission_mode": "supervised",
            "interaction_mode": "default",
            "provider_thread_id": "",
            "session_id": UUID().uuidString,
            "environment": [:]
        ])
        try session.send(["type": "rc_turn", "prompt": "one"])
        XCTAssertTrue(session.waitFor("QUERY_DIED"),
                      "the query failure must be emitted as sdk_error. stderr: \(session.stderrText())")
        XCTAssertTrue(session.output.contains(#""type":"sdk_error""#))

        try session.send(["type": "rc_turn", "prompt": "two"])
        XCTAssertTrue(session.waitFor("RECOVERED_2"),
                      "after sdk_error the bridge must start a FRESH query on the next rc_turn — a dead activeQuery would swallow the prompt forever. stderr: \(session.stderrText())")
    }

    // WHY: Claude's standalone SDK fork copies the transcript without adding a
    // synthetic prompt. The bridge must expose that exact API and keep list /
    // delete available for crash reconciliation and compensation.
    func test_realBridgeExposesPromptFreeSessionMutationContract() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let harness = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        const sessions = [{ sessionId: 'parent', customTitle: '' }];
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query() { throw new Error('query must not run for session mutation'); }
        export async function listSessions() { return sessions; }
        export async function forkSession(sourceSessionId, options) {
          if (sourceSessionId !== 'parent' || options.title !== 'stable-marker') throw new Error('bad fork args');
          sessions.push({ sessionId: 'child', customTitle: options.title });
          return { sessionId: 'child' };
        }
        export async function deleteSession(sessionId) {
          const index = sessions.findIndex((session) => session.sessionId === sessionId);
          if (index < 0) throw new Error('missing session');
          sessions.splice(index, 1);
        }
        """)
        defer { _ = harness.finish() }

        try harness.send([
            "type": "rc_configure",
            "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion,
            "expected_sdk_version": "0.3.157",
            "session_id": UUID().uuidString
        ])
        try harness.send([
            "type": "rc_fork_session",
            "request_id": "fork-request",
            "source_session_id": "parent",
            "title": "stable-marker"
        ])
        XCTAssertTrue(harness.waitFor(#""subtype":"rc_fork_session_result""#))
        XCTAssertTrue(harness.output.contains(#""session_id":"child""#))

        try harness.send(["type": "rc_list_sessions", "request_id": "list-request"])
        XCTAssertTrue(harness.waitFor(#""request_id":"list-request""#))
        XCTAssertTrue(harness.output.contains(#""custom_title":"stable-marker""#))

        try harness.send(["type": "rc_delete_session", "request_id": "delete-request", "session_id": "child"])
        XCTAssertTrue(harness.waitFor(#""subtype":"rc_delete_session_result""#))
        XCTAssertFalse(harness.output.contains("query must not run"))
    }

    func test_installedForkProtocolProbeFailsClosedOnMissingSDKSeam() throws {
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-fork-probe")
        let bridge = tmp.appendingPathComponent("ClaudeAgentSDKBridge.mjs")
        try """
        const BRIDGE_PROTOCOL_VERSION = 3;
        claudeSDK.listSessions();
        claudeSDK.forkSession();
        claudeSDK.deleteSession();
        """.write(to: bridge, atomically: true, encoding: .utf8)
        let sdk = tmp.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk", isDirectory: true)
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try #"{"version":"0.3.157"}"#.write(
            to: sdk.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        export declare function listSessions(): Promise<unknown[]>;
        export declare function forkSession(sessionId: string): Promise<unknown>;
        """.write(to: sdk.appendingPathComponent("sdk.d.ts"), atomically: true, encoding: .utf8)

        XCTAssertFalse(ClaudeAgentSDKBridgeAdapter.installedForkProtocolSupported(bridgeScriptPath: bridge.path))

        try """
        export declare function listSessions(): Promise<unknown[]>;
        export declare function forkSession(sessionId: string): Promise<unknown>;
        export declare function deleteSession(sessionId: string): Promise<void>;
        """.write(to: sdk.appendingPathComponent("sdk.d.ts"), atomically: true, encoding: .utf8)
        XCTAssertTrue(ClaudeAgentSDKBridgeAdapter.installedForkProtocolSupported(bridgeScriptPath: bridge.path))
    }

    func test_realInstalledForkProtocolProbeRecognizesPinnedRuntime() throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CLAUDE_FORK_GATE"] == "1" else {
            throw XCTSkip("set RC_REAL_CLAUDE_FORK_GATE=1 to verify the installed Claude SDK fork contract")
        }
        XCTAssertTrue(
            ClaudeAgentSDKBridgeAdapter.installedForkProtocolSupported(),
            "the installed bridge and pinned SDK must expose protocol v3 list/fork/delete before the UI advertises Claude fork"
        )
    }

    func test_nativeForkRetryReusesMarkerChildWithoutSecondProviderMutation() async throws {
        let mutator = ClaudeForkMutationMock(sessions: [
            ClaudeSDKSessionRecord(sessionId: "claude-parent", customTitle: nil)
        ], throwAfterFirstFork: true)
        let (adapter, threadId, tmp) = try await makeForkReadyAdapter(mutator: mutator)
        defer { try? adapter.stopSession(threadId: threadId) }
        let request = AgentProviderForkRequest(
            sourceThreadId: threadId,
            childThreadId: AgentThreadID(),
            idempotencyKey: "remotecode-thread-fork:stable",
            workingDirectory: tmp.path
        )

        do {
            _ = try await adapter.forkThread(request)
            XCTFail("the mock must lose the first provider response after creating the child")
        } catch {}
        let replay = try await adapter.forkThread(request)
        let forkCount = await mutator.forkCount()

        XCTAssertEqual(replay, "claude-child-1")
        XCTAssertEqual(forkCount, 1,
                       "a replay after the provider response crash window must resolve the marker child instead of creating an orphan")
    }

    func test_nativeForkDuplicateMarkerCleansAllChildrenAndFailsLoud() async throws {
        let key = "remotecode-thread-fork:duplicate"
        let marker = "MacCode fork \(key)"
        let mutator = ClaudeForkMutationMock(sessions: [
            ClaudeSDKSessionRecord(sessionId: "claude-parent", customTitle: nil),
            ClaudeSDKSessionRecord(sessionId: "duplicate-a", customTitle: marker),
            ClaudeSDKSessionRecord(sessionId: "duplicate-b", customTitle: marker)
        ])
        let (adapter, threadId, tmp) = try await makeForkReadyAdapter(mutator: mutator)
        defer { try? adapter.stopSession(threadId: threadId) }
        let request = AgentProviderForkRequest(
            sourceThreadId: threadId,
            childThreadId: AgentThreadID(),
            idempotencyKey: key,
            workingDirectory: tmp.path
        )

        do {
            _ = try await adapter.forkThread(request)
            XCTFail("duplicate marker children must not be selected arbitrarily")
        } catch let error as ClaudeForkReconciliationError {
            guard case .markerConflictCleaned(_, let ids) = error else {
                return XCTFail("unexpected reconciliation error: \(error)")
            }
            XCTAssertEqual(ids, ["duplicate-a", "duplicate-b"])
        }
        let deletedSessionIds = await mutator.deletedSessionIds()
        let forkCount = await mutator.forkCount()
        XCTAssertEqual(deletedSessionIds, ["duplicate-a", "duplicate-b"])
        XCTAssertEqual(forkCount, 0)
    }

    func test_nativeForkCompensationIsIdempotentAfterLostDeleteResponse() async throws {
        let key = "remotecode-thread-fork:compensate"
        let childId = "claude-child"
        let marker = "MacCode fork \(key)"
        let mutator = ClaudeForkMutationMock(sessions: [
            ClaudeSDKSessionRecord(sessionId: "claude-parent", customTitle: marker),
            ClaudeSDKSessionRecord(sessionId: childId, customTitle: marker)
        ], throwAfterFirstDelete: true)
        let adapter = ClaudeAgentSDKBridgeAdapter(sessionMutator: mutator)
        let request = AgentProviderForkRequest(
            sourceThreadId: AgentThreadID(),
            childThreadId: AgentThreadID(),
            idempotencyKey: key,
            sourceProviderThreadId: "claude-parent"
        )

        do {
            try await adapter.compensateFork(request, providerChildThreadId: childId)
            XCTFail("the mock must lose the first delete response after deleting the child")
        } catch {}
        try await adapter.compensateFork(request, providerChildThreadId: childId)
        let deletedSessionIds = await mutator.deletedSessionIds()

        XCTAssertEqual(deletedSessionIds, [childId],
                       "absence after a successful delete is success, and compensation must never delete the parent even if its title collides")
    }

    private func makeForkReadyAdapter(
        mutator: ClaudeSDKSessionMutating
    ) async throws -> (ClaudeAgentSDKBridgeAdapter, AgentThreadID, URL) {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-fork")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try Self.loggingFakeBridgeSource(sessionId: "claude-parent")
            .write(to: bridge, atomically: true, encoding: .utf8)
        let adapter = ClaudeAgentSDKBridgeAdapter(
            bridgeScriptPath: bridge.path,
            sessionMutator: mutator
        )
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "sonnet",
            cwd: tmp.path,
            prompt: "establish parent",
            extraArgs: [commandLog.path]
        )) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "DONE_1")
        return (adapter, threadId, tmp)
    }

    // MARK: - Helpers

    private static func makeTempDir(prefix: String) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Fake bridge that appends every host command to argv[2] and answers
    /// rc_turn with init + result. The result counter is PER PROCESS, so a
    /// respawned bridge answers 'DONE_1' again while a reused one answers
    /// 'DONE_2' — letting tests distinguish reuse from respawn by reply text.
    private static func loggingFakeBridgeSource(sessionId: String) -> String {
        """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const log = process.argv[2];
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        let turn = 0;
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          fs.appendFileSync(log, JSON.stringify(cmd) + '\\n');
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: '\(sessionId)' });
          } else if (cmd.type === 'rc_turn') {
            turn += 1;
            write({ type: 'result', subtype: 'success', is_error: false, result: 'DONE_' + turn, session_id: '\(sessionId)' });
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """
    }

    private static func loggedCommands(at url: URL, ofType type: String) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return object
            }
            .filter { ($0["type"] as? String) == type }
    }

    private func waitForFinish(in sink: EventSink, expected: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let events = await sink.snapshot()
            if events.contains(where: {
                if case .finished(.completed, let final, _) = $0 { return final == expected }
                return false
            }) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(expected)")
    }
}

private actor EventSink {
    private var events: [AgentRunEvent] = []
    func record(_ event: AgentRunEvent) { events.append(event) }
    func snapshot() -> [AgentRunEvent] { events }
}

private final class ClaudeCausalIdleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [AgentRunStatus?] = []

    func observeTerminalCallback(sessionStatus: AgentRunStatus?) {
        lock.withLock {
            statuses.append(sessionStatus)
        }
    }

    var observedStatuses: [AgentRunStatus?] {
        lock.withLock { statuses }
    }
}

private actor ClaudeForkMutationMock: ClaudeSDKSessionMutating {
    private var sessions: [ClaudeSDKSessionRecord]
    private var forks = 0
    private var deletes: [String] = []
    private var throwAfterFirstFork: Bool
    private var throwAfterFirstDelete: Bool

    init(
        sessions: [ClaudeSDKSessionRecord],
        throwAfterFirstFork: Bool = false,
        throwAfterFirstDelete: Bool = false
    ) {
        self.sessions = sessions
        self.throwAfterFirstFork = throwAfterFirstFork
        self.throwAfterFirstDelete = throwAfterFirstDelete
    }

    func listSessions() async throws -> [ClaudeSDKSessionRecord] {
        sessions
    }

    func forkSession(sourceSessionId: String, title: String) async throws -> String {
        guard sessions.contains(where: { $0.sessionId == sourceSessionId }) else {
            throw AgentProviderAdapterError.unsupported("mock source missing")
        }
        forks += 1
        let childId = "claude-child-\(forks)"
        sessions.append(ClaudeSDKSessionRecord(sessionId: childId, customTitle: title))
        if throwAfterFirstFork {
            throwAfterFirstFork = false
            throw AgentProviderAdapterError.unsupported("mock lost fork response")
        }
        return childId
    }

    func deleteSession(sessionId: String) async throws {
        guard sessions.contains(where: { $0.sessionId == sessionId }) else {
            throw AgentProviderAdapterError.unsupported("mock child missing")
        }
        sessions.removeAll { $0.sessionId == sessionId }
        deletes.append(sessionId)
        if throwAfterFirstDelete {
            throwAfterFirstDelete = false
            throw AgentProviderAdapterError.unsupported("mock lost delete response")
        }
    }

    func forkCount() -> Int { forks }
    func deletedSessionIds() -> [String] { deletes }
}

private final class LockedTextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ text: String) { lock.lock(); storage += text; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Runs the REAL Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs under node with a
/// fake `@anthropic-ai/claude-agent-sdk` module so tests can drive the bridge's
/// query()/options plumbing end to end (same pattern as the AskUserQuestion
/// bridge harness in ClaudeStreamingCLIAdapterTests).
private final class RealBridgeHarness {
    let process: Process
    private let stdin: Pipe
    private let buffer = LockedTextBuffer()
    private let stderrBuffer = LockedTextBuffer()
    private let reader: Thread
    private let stderrReader: Thread

    init(node: String, fakeSDKIndexJS: String) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-bridge-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("ClaudeAgentSDKBridge.mjs")
        try FileManager.default.copyItem(
            at: Self.packageRoot().appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs"),
            to: bridge
        )
        let sdkModule = tmp.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk", isDirectory: true)
        try FileManager.default.createDirectory(at: sdkModule, withIntermediateDirectories: true)
        try #"{"type":"module","main":"index.js","version":"0.3.157"}"#.write(to: sdkModule.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try fakeSDKIndexJS.write(to: sdkModule.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        let zodModule = tmp.appendingPathComponent("node_modules/zod", isDirectory: true)
        try FileManager.default.createDirectory(at: zodModule, withIntermediateDirectories: true)
        try #"{"type":"module","main":"index.js"}"#.write(to: zodModule.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "export const z = {};\n".write(to: zodModule.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [bridge.path]
        process.currentDirectoryURL = tmp
        stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let buffer = self.buffer
        let readerHandle = stdout.fileHandleForReading
        reader = Thread {
            while true {
                let chunk = readerHandle.availableData
                if chunk.isEmpty { break }
                buffer.append(String(decoding: chunk, as: UTF8.self))
            }
        }
        let stderrBuffer = self.stderrBuffer
        let stderrHandle = stderr.fileHandleForReading
        stderrReader = Thread {
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }
                stderrBuffer.append(String(decoding: chunk, as: UTF8.self))
            }
        }
        reader.stackSize = 1 << 20
        reader.start()
        stderrReader.stackSize = 1 << 20
        stderrReader.start()
        try process.run()
    }

    func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        stdin.fileHandleForWriting.write(data)
        stdin.fileHandleForWriting.write(Data("\n".utf8))
    }

    @discardableResult
    func waitFor(_ marker: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if buffer.value.contains(marker) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    var output: String { buffer.value }

    func stderrText() -> String { stderrBuffer.value }

    /// Closes stdin and waits for exit.
    func finish() -> Bool {
        try? send(["type": "rc_close"])
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        reader.cancel()
        stderrReader.cancel()
        return process.terminationStatus == 0
    }

    static func packageRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
