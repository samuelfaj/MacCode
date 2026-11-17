import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime

/// The guest config is what an in-guest bot agent can see and reach. These
/// tests pin that it gets the user's models (reachable from the guest) and the
/// guest's own tools, and never the Mac's MCP servers, host paths or secrets.
final class DistillGuestConfigTests: XCTestCase {
    /// Same shape as a real host `~/.distill/config.toml`, with fake secrets.
    private let hostConfig = #"""
    disabled_mcp_servers = [
        "computer-use",
        "slack",
    ]

    [cli]
    installer = "internal"
    auto_update = true

    [marketplace]
    official_marketplace_auto_installed = true

    [[marketplace.sources]]
    name = "xAI Official"
    git = "https://github.com/xai-org/plugin-marketplace.git"

    [ui]
    permission_mode = "always-approve"

    [mcp_servers.playwright]
    command = "/Users/me/.nvm/versions/node/v24/bin/npx"
    args = ["@playwright/mcp@latest"]

    [mcp_servers.linear]
    url = "https://mcp.linear.app/mcp"

    [mcp_servers.linear.headers]
    Authorization = "Bearer lin_SECRET_HEADER"

    [models]
    default = "claude/claude-opus-5-5"
    worker = ""

    [session]
    auto_compact_threshold_percent = 75

    [model.qwen38-omlx]
    model = "incoai/Qwen3.8-27B-Splash"
    base_url = "http://127.0.0.1:8000/v1"
    api_key = "sk-local-SECRET_ONE"
    description = """
    Local Splash server.
    [not-a-table] stays inside the string
    """
    context_window = 131072

    [[model.qwen38-omlx.reasoning_efforts]]
    id = "none"
    value = "none"

    [model."glm-5.3"]
    model = "glm-5.3"
    model_provider = "zai"
    base_url = "http://localhost:8123/api/paas/v4"
    api_key = "zai-SECRET_TWO" # inline comment
    env_key = [
        "ZAI_API_KEY",
        "Z_AI_API_KEY",
    ]

    [model."deepseek-v4.1-flash"]
    model = "~deepseek/deepseek-flash-latest"
    base_url = "https://openrouter.ai/api/v1"
    env_key = "OPENROUTER_API_KEY"

    [model.ipv6-local]
    base_url = "http://[::1]:9000/v1"
    api_key = ""

    [model.lookalike]
    base_url = "http://localhostnews.example/v1"

    [model.helper]
    base_url = "https://gateway.example/v1"
    auth_provider = "corp"

    [model.tokenizer]
    base_url = "https://example.com/v1"
    tokenizer_path = "/Users/me/tokenizer.json"

    [model.headers]
    base_url = "https://example.com/v1"

    [model.headers.extra_headers]
    X-Key = "SECRET_THREE"

    [model.via-corp]
    model_provider = "corp-gw"

    [model_providers.zai]
    base_url = "https://api.z.ai/api/paas/v4"
    api_key = "zai-SECRET_FOUR"
    env_key = "ZAI_API_KEY"

    [model_providers.corp-gw]
    base_url = "https://corp.example/v1"
    command = "/usr/local/bin/corp-token"

    [privacy]
    privacy_banner_acked = "2026-08-13T14:14:42Z"

    [shell_environment_policy]
    exclude = ["JEV_API_KEY"]

    [jev]
    api_key_env = "JEV_API_KEY"

    [jev.local]
    effort = "auto"

    [subagents.models]
    plan = "chatgpt/gpt-6.1-sol"

    [goal]
    use_current_model_only = true
    """#

    private func render(env: [String: String] = ["OPENROUTER_API_KEY": "or-SECRET_FIVE"]) -> DistillGuestConfig.Rendered {
        DistillGuestConfig.render(hostConfig: hostConfig, gatewayPort: 54_321, hostEnvironment: env)
    }

    private func headers(_ toml: String) -> [String] {
        toml.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[") }
    }

    /// Table body (the lines after `header` up to the next table).
    private func body(of header: String, in toml: String) -> [String] {
        let lines = toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(of: header) else { return [] }
        return Array(lines[(start + 1)...].prefix { !$0.hasPrefix("[") }).filter { !$0.isEmpty }
    }

    /// The Mac's MCP servers are Mac programs logged in as the Mac user; the
    /// guest must never start them or inherit their headers.
    func test_hostMCPServersAndHostOnlySettingsNeverReachTheGuest() {
        let toml = render().toml
        XCTAssertEqual(headers(toml).filter { $0.hasPrefix("[mcp_servers") }, [
            "[mcp_servers.linux-use]",
            "[mcp_servers.playwright]",
            "[mcp_servers.remotecode-bot-self-config]",
            "[mcp_servers.remotecode-bot-computer]",
            "[mcp_servers.remotecode-bot-web]",
        ])
        for host in ["[cli]", "[marketplace]", "[[marketplace.sources]]", "[ui]", "[session]",
                     "[privacy]", "[jev]", "[jev.local]", "[goal]", "[mcp_servers.linear.headers]"] {
            XCTAssertFalse(toml.contains(host), host)
        }
        XCTAssertFalse(toml.contains("disabled_mcp_servers"))
        XCTAssertFalse(toml.contains("lin_SECRET_HEADER"))
        XCTAssertFalse(toml.contains("/Users/"))
        XCTAssertFalse(toml.contains("JEV_API_KEY"))
        XCTAssertEqual(headers(toml).filter { $0 == "[shell_environment_policy]" }.count, 1)
    }

    /// The user's own models (and the settings that pick them) are the point
    /// of running the agent with "your accounts".
    func test_userModelsAndModelSettingsAreKept() {
        let toml = render().toml
        for kept in ["[models]", "[model.qwen38-omlx]", "[[model.qwen38-omlx.reasoning_efforts]]",
                     "[model.\"glm-5.3\"]", "[model.\"deepseek-v4.1-flash\"]", "[model_providers.zai]",
                     "[subagents.models]"] {
            XCTAssertTrue(headers(toml).contains(kept), kept)
        }
        XCTAssertEqual(body(of: "[models]", in: toml), ["default = \"claude/claude-opus-5-5\"", "worker = \"\""])
        XCTAssertTrue(body(of: "[subagents.models]", in: toml).contains("plan = \"chatgpt/gpt-6.1-sol\""))
        // An OpenRouter alias starts with "~" but is not a home path.
        XCTAssertTrue(body(of: "[model.\"deepseek-v4.1-flash\"]", in: toml)
            .contains("model = \"~deepseek/deepseek-flash-latest\""))
    }

    /// The guest's 127.0.0.1 is the container itself: a model server on the
    /// Mac (oMLX, a local proxy) is only reachable through the host alias.
    func test_loopbackBaseURLsPointAtTheMacThroughTheHostAlias() {
        let toml = render().toml
        XCTAssertTrue(body(of: "[model.qwen38-omlx]", in: toml)
            .contains("base_url = \"http://host.docker.internal:8000/v1\""))
        XCTAssertTrue(body(of: "[model.\"glm-5.3\"]", in: toml)
            .contains("base_url = \"http://host.docker.internal:8123/api/paas/v4\""))
        XCTAssertTrue(body(of: "[model.ipv6-local]", in: toml)
            .contains("base_url = \"http://host.docker.internal:9000/v1\""))
        XCTAssertTrue(body(of: "[model.\"deepseek-v4.1-flash\"]", in: toml)
            .contains("base_url = \"https://openrouter.ai/api/v1\""))
        XCTAssertTrue(body(of: "[model.lookalike]", in: toml)
            .contains("base_url = \"http://localhostnews.example/v1\""), "only the loopback host is rewritten")
        XCTAssertFalse(toml.contains("127.0.0.1:8"))
        XCTAssertFalse(toml.contains("localhost:"))
    }

    /// The config sits on the guest-home bind and is readable by the agent and
    /// anything it runs; keys must travel only in the run's env file.
    func test_literalAPIKeysMoveToTheRunEnvironmentAndNeverReachTheFile() {
        let rendered = render()
        let toml = rendered.toml
        for secret in ["sk-local-SECRET_ONE", "zai-SECRET_TWO", "SECRET_THREE", "zai-SECRET_FOUR", "or-SECRET_FIVE"] {
            XCTAssertFalse(toml.contains(secret), secret)
        }
        XCTAssertFalse(toml.contains("api_key"))
        XCTAssertEqual(rendered.secretEnvironment["RC_GUEST_MODEL_KEY_1"], "sk-local-SECRET_ONE")
        XCTAssertEqual(rendered.secretEnvironment["RC_GUEST_MODEL_KEY_2"], "zai-SECRET_TWO")
        XCTAssertEqual(rendered.secretEnvironment["RC_GUEST_MODEL_KEY_3"], "zai-SECRET_FOUR")
        XCTAssertTrue(body(of: "[model.qwen38-omlx]", in: toml).contains("env_key = \"RC_GUEST_MODEL_KEY_1\""))
        // A literal api_key wins over env_key in Distill, so the model keeps
        // using the same key; two env_key lines would not parse.
        XCTAssertEqual(body(of: "[model.\"glm-5.3\"]", in: toml).filter { $0.hasPrefix("env_key") },
                       ["env_key = \"RC_GUEST_MODEL_KEY_2\""])
        XCTAssertFalse(toml.contains("Z_AI_API_KEY"))
        XCTAssertEqual(body(of: "[model_providers.zai]", in: toml).filter { $0.hasPrefix("env_key") },
                       ["env_key = \"RC_GUEST_MODEL_KEY_3\""])
        // An empty api_key is no key: nothing is moved and nothing is added.
        XCTAssertEqual(body(of: "[model.ipv6-local]", in: toml), ["base_url = \"http://host.docker.internal:9000/v1\""])
    }

    /// A model that names its key by env var gets that var's Mac value in the
    /// guest; a var the Mac does not have is not invented.
    func test_envKeyNamesResolveFromTheMacEnvironment() {
        let rendered = render(env: ["OPENROUTER_API_KEY": "or-SECRET_FIVE", "UNRELATED": "x"])
        XCTAssertEqual(rendered.secretEnvironment["OPENROUTER_API_KEY"], "or-SECRET_FIVE")
        XCTAssertNil(rendered.secretEnvironment["UNRELATED"])
        XCTAssertTrue(body(of: "[model.\"deepseek-v4.1-flash\"]", in: rendered.toml)
            .contains("env_key = \"OPENROUTER_API_KEY\""))
        XCTAssertNil(render(env: [:]).secretEnvironment["OPENROUTER_API_KEY"])
    }

    /// A model that needs a Mac program, a Mac file, or headers we cannot keep
    /// out of the file cannot run in the guest; it is left out and named so
    /// the run can fail with a reason instead of a broken model.
    func test_modelsTheGuestCannotRunAreDroppedAndReported() {
        let rendered = render()
        XCTAssertEqual(Set(rendered.droppedModels.keys), ["helper", "tokenizer", "headers", "via-corp"])
        XCTAssertEqual(rendered.droppedModels["helper"], "unsupported key auth_provider")
        XCTAssertEqual(rendered.droppedModels["tokenizer"], "host path in tokenizer_path")
        XCTAssertEqual(rendered.droppedModels["headers"], "unsupported table extra_headers")
        XCTAssertEqual(rendered.droppedModels["via-corp"], "model provider corp-gw dropped (unsupported key command)")
        for gone in ["[model.helper]", "[model.tokenizer]", "[model.headers]", "[model.headers.extra_headers]",
                     "[model.via-corp]", "[model_providers.corp-gw]"] {
            XCTAssertFalse(headers(rendered.toml).contains(gone), gone)
        }
    }

    /// A multi-line value is one entry: a line inside it that looks like a
    /// table header must not split the model block.
    func test_multilineValuesStayInsideTheirTable() {
        let toml = render().toml
        XCTAssertTrue(toml.contains("description = \"\"\"\nLocal Splash server.\n[not-a-table] stays inside the string\n\"\"\"\ncontext_window = 131072"))
        XCTAssertNil(render().droppedModels["qwen38-omlx"])
    }

    /// The gateway bearer is read by Distill from the env (never written in
    /// the file); a peer consultation waits on another bot's whole turn, so
    /// its call must not time out like a host operation.
    func test_gatewayServersUseTheBearerEnvVarAndAskPeerOutlivesAHostOperation() {
        let toml = render().toml
        for server in [BotSelfConfigCatalog.serverName, BotComputerCatalog.serverName, BotWebCatalog.serverName] {
            let lines = body(of: "[mcp_servers.\(server)]", in: toml)
            XCTAssertTrue(lines.contains("url = \"http://host.docker.internal:54321/mcp/\(server)\""), server)
            XCTAssertTrue(lines.contains("bearer_token_env_var = \"RC_GUEST_GATEWAY_TOKEN\""), server)
            XCTAssertTrue(lines.contains("startup_timeout_sec = 20"), server)
            XCTAssertFalse(lines.contains { $0.hasPrefix("headers") }, server)
        }
        let selfConfig = body(of: "[mcp_servers.\(BotSelfConfigCatalog.serverName)]", in: toml)
        XCTAssertTrue(selfConfig.contains("tool_timeouts = { \(BotPeerDelegation.askTool) = 86400 }"))
        let askPeer = DistillGuestConfig.gatewayServers.first { $0.name == BotSelfConfigCatalog.serverName }?
            .toolTimeouts[BotPeerDelegation.askTool] ?? 0
        XCTAssertGreaterThanOrEqual(askPeer, 86_400)
        XCTAssertGreaterThan(TimeInterval(askPeer), BotPeerDelegation.peerConsultationTimeout)
    }

    /// Desktop and browser tools run inside the guest, on the bot's own
    /// screen and the Chromium the user can watch and take over.
    func test_desktopAndBrowserToolsRunInsideTheGuest() {
        let toml = render().toml
        XCTAssertEqual(body(of: "[mcp_servers.linux-use]", in: toml), [
            "command = \"python3\"",
            "args = [\"\(BotComputerGuestSpec.linuxUseServerPath)\"]",
            "env = { DISPLAY = \":1\" }",
        ])
        XCTAssertEqual(body(of: "[mcp_servers.playwright]", in: toml), [
            "command = \"playwright-mcp\"",
            "args = [\"--cdp-endpoint\", \"http://127.0.0.1:9222\"]",
        ])
        XCTAssertFalse(toml.contains(BotBrowserCatalog.serverName), "the Mac browser relay is not used in the guest")
    }

    /// The guest has no linux-use Chrome extension and no decision-model key. The downloaded
    /// linux-use release lists those tools anyway, so Distill must hide every one of them, or the
    /// agent spends turns on calls that can only fail.
    func test_linuxUseToolsThatNeedTheExtensionOrAKeyAreDisabledInTheGuest() {
        let disabled = body(of: "[disabled_mcp_tools]", in: render().toml)
        let line = try? XCTUnwrap(disabled.first { $0.hasPrefix("linux-use = ") })
        for tool in ["browser_open", "browser_snapshot", "browser_act", "browser_close", "browser_status",
                     "browser_navigate", "browser_click", "browser_type", "browser_pointer", "browser_dialog",
                     "browser_set_input_files", "browser_download", "page", "jev_decide", "run_subtask"] {
            XCTAssertTrue(line?.contains("\"\(tool)\"") == true, "\(tool) is offered to the guest agent")
        }
        for usable in ["get_ui_tree", "click_element", "screenshot", "click", "verify_state"] {
            XCTAssertFalse(line?.contains("\"\(usable)\"") == true, "\(usable) works in the guest and must stay offered")
        }
    }

    /// The agent's shell commands (and whatever they install) do not need the
    /// model keys or the gateway bearer; only Distill itself reads them.
    func test_shellCommandsDoNotInheritModelKeysOrTheGatewayBearer() {
        let rendered = render()
        let exclude = body(of: "[shell_environment_policy]", in: rendered.toml)
        XCTAssertEqual(exclude.count, 1)
        for name in ["RC_GUEST_GATEWAY_TOKEN", "RC_GUEST_MODEL_KEY_1", "RC_GUEST_MODEL_KEY_2",
                     "RC_GUEST_MODEL_KEY_3", "OPENROUTER_API_KEY"] {
            XCTAssertTrue(exclude[0].contains("\"\(name)\""), name)
        }
    }
}
