import XCTest
@testable import AgentRuntime

/// WHY: Auto-orchestration must not drop Graphify host injects when a launch
/// config exists — otherwise agents report BANNER_MISSING / no graph.
final class AgentHostEnvironmentMergeTests: XCTestCase {
    func test_preserveHostInjectsKeepsGraphifyWhenLaunchPresent() {
        let launch = ["CODEX_API_KEY": "x", "PATH": "/usr/bin"]
        let request = [
            "RC_GRAPHIFY_ENABLED": "1",
            "RC_GRAPHIFY_GRAPH_JSON": "/tmp/g.json",
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            "PATH": "/old"
        ]
        let merged = AgentHostEnvironmentMerge.preserveHostInjects(launch: launch, request: request)
        XCTAssertEqual(merged["RC_GRAPHIFY_ENABLED"], "1")
        XCTAssertEqual(merged["RC_GRAPHIFY_GRAPH_JSON"], "/tmp/g.json")
        XCTAssertEqual(merged["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertEqual(merged["CODEX_API_KEY"], "x")
        XCTAssertEqual(merged["PATH"], "/usr/bin", "launch provider PATH should win")
    }

    func test_preserveHostInjectsKeepsRemoteCodeMCPAuthorityWhenLaunchPresent() {
        // WHY: Managed Bot and Agent App MCPs must receive the host-authoritative
        // active run context even when Auto supplies a provider launch environment.
        let launch = [
            "CODEX_API_KEY": "x",
            "PATH": "/usr/bin",
            "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH": "/stale/socket",
            "RC_REMOTE_CODE_DELEGATION_CAPABILITY": "stale-capability",
            "RC_REMOTE_CODE_BOT_TURN_CONTEXT": "stale-turn-context",
            "GROK_SUBAGENTS_MAX_DEPTH": "9",
        ]
        let request = [
            "RC_REMOTE_CODE_BOT_ID": "bot-id",
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": "/tmp/support",
            "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": "thread-id",
            "RC_REMOTE_CODE_ROOT_RUN_ID": "run-id",
            "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH": "/tmp/active/socket",
            "RC_REMOTE_CODE_DELEGATION_CAPABILITY": "active-capability",
            "RC_REMOTE_CODE_BOT_TURN_CONTEXT": "current-turn-context",
            "GROK_SUBAGENTS_MAX_DEPTH": "2",
            "PATH": "/request-path",
        ]

        let merged = AgentHostEnvironmentMerge.preserveHostInjects(launch: launch, request: request)

        XCTAssertEqual(merged["RC_REMOTE_CODE_BOT_ID"], "bot-id")
        XCTAssertEqual(merged["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"], "/tmp/support")
        XCTAssertEqual(merged["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"], "thread-id")
        XCTAssertEqual(merged["RC_REMOTE_CODE_ROOT_RUN_ID"], "run-id")
        XCTAssertEqual(merged["RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH"], "/tmp/active/socket")
        XCTAssertEqual(merged["RC_REMOTE_CODE_DELEGATION_CAPABILITY"], "active-capability")
        XCTAssertEqual(merged["RC_REMOTE_CODE_BOT_TURN_CONTEXT"], "current-turn-context")
        XCTAssertEqual(merged["GROK_SUBAGENTS_MAX_DEPTH"], "2", "the request's nesting ceiling must beat launch config")
        XCTAssertEqual(merged["CODEX_API_KEY"], "x")
        XCTAssertEqual(merged["PATH"], "/usr/bin", "launch provider PATH should win")
    }

    func test_preserveHostInjectsWithoutLaunchUsesRequest() {
        let request = ["RC_GRAPHIFY_ENABLED": "1", "FOO": "bar"]
        let merged = AgentHostEnvironmentMerge.preserveHostInjects(launch: nil, request: request)
        XCTAssertEqual(merged, request)
    }

    func test_preserveHostInjectsStripsStaleHostInjectsFromLaunchWhenRequestInactive() {
        // WHY: Auto must not resurrect host authority from a prior path when the
        // current request does not carry the corresponding host injects.
        let launch = [
            "CODEX_API_KEY": "x",
            "RC_GRAPHIFY_ENABLED": "1",
            "RC_GRAPHIFY_GRAPH_JSON": "/stale/g.json",
            "RC_REMOTE_CODE_BOT_ID": "stale-bot",
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": "/stale/support",
            "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": "stale-thread",
            "RC_REMOTE_CODE_ROOT_RUN_ID": "stale-run",
            "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH": "/stale/socket",
            "RC_REMOTE_CODE_DELEGATION_CAPABILITY": "stale-capability",
            "RC_REMOTE_CODE_BOT_TURN_CONTEXT": "stale-turn-context",
            "GROK_SUBAGENTS_MAX_DEPTH": "2",
        ]
        let request = ["PATH": "/usr/bin"] // no host Graphify injects
        let merged = AgentHostEnvironmentMerge.preserveHostInjects(launch: launch, request: request)
        XCTAssertNil(merged["RC_GRAPHIFY_ENABLED"])
        XCTAssertNil(merged["RC_GRAPHIFY_GRAPH_JSON"])
        XCTAssertNil(merged["RC_REMOTE_CODE_BOT_ID"])
        XCTAssertNil(merged["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"])
        XCTAssertNil(merged["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"])
        XCTAssertNil(merged["RC_REMOTE_CODE_ROOT_RUN_ID"])
        XCTAssertNil(merged["RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH"])
        XCTAssertNil(merged["RC_REMOTE_CODE_DELEGATION_CAPABILITY"])
        XCTAssertNil(merged["RC_REMOTE_CODE_BOT_TURN_CONTEXT"])
        XCTAssertNil(merged["GROK_SUBAGENTS_MAX_DEPTH"], "a stale nesting ceiling must never reach the provider")
        XCTAssertEqual(merged["CODEX_API_KEY"], "x")
    }
}
