import Foundation
import CoreModel
import Persistence

/// Renders the `config.toml` an in-guest Distill run reads from its own
/// `DISTILL_HOME`. Pure: the caller reads the host config and writes the result.
///
/// The guest keeps only the host's model definitions. It never gets the host's
/// MCP servers (they are Mac programs and Mac accounts), CLI, UI, Jev, session or
/// privacy settings. Its MCP servers are the in-guest desktop (linux-use), the
/// in-guest browser (@playwright/mcp on the visible Chromium) and the host
/// gateway, which the guest reaches by bearer token over `host.docker.internal`.
/// The file holds no secret: literal API keys move into the run's environment.
public enum DistillGuestConfig {
    /// linux-use tools that need its Chrome extension or a decision-model key (linux-use v1.4.0).
    static let linuxUseToolsTheGuestCannotRun = [
        "browser_open", "browser_snapshot", "browser_act", "browser_close", "browser_status", "browser_navigate",
        "browser_click", "browser_type", "browser_pointer", "browser_dialog", "browser_set_input_files",
        "browser_download", "page", "jev_decide", "run_subtask",
    ]

    public struct GatewayServer: Equatable, Sendable {
        public var name: String
        public var toolTimeoutSeconds: Int
        /// Per-tool overrides of `toolTimeoutSeconds` (Distill `tool_timeouts`).
        public var toolTimeouts: [String: Int]

        public init(name: String, toolTimeoutSeconds: Int, toolTimeouts: [String: Int] = [:]) {
            self.name = name
            self.toolTimeoutSeconds = toolTimeoutSeconds
            self.toolTimeouts = toolTimeouts
        }
    }

    public struct Rendered: Equatable, Sendable {
        public var toml: String
        /// Model credentials the run must receive as environment variables.
        public var secretEnvironment: [String: String]
        /// Host model ids left out of the guest config, each with the reason.
        public var droppedModels: [String: String]
    }

    /// Env var the gateway bearer is read from; its value is never in the file.
    public static let gatewayTokenEnvironmentKey = "RC_GUEST_GATEWAY_TOKEN"
    /// A literal host `api_key` becomes `env_key = "RC_GUEST_MODEL_KEY_<n>"`.
    public static let modelKeyEnvironmentPrefix = "RC_GUEST_MODEL_KEY_"
    /// The host as the guest sees it (bot containers add it via `--add-host`).
    public static let hostAlias = "host.docker.internal"
    /// The visible Chromium's DevTools endpoint, on the guest loopback only.
    public static let browserCDPEndpoint = "http://127.0.0.1:9222"
    public static let gatewayStartupTimeoutSeconds = 20

    /// The host MCP servers a guest run reaches through the gateway. A peer
    /// consultation (`bot_ask_peer`) waits on another bot's whole turn, so its
    /// call must outlive any one host operation.
    public static let gatewayServers: [GatewayServer] = [
        GatewayServer(
            name: BotSelfConfigCatalog.serverName,
            toolTimeoutSeconds: 900,
            toolTimeouts: [BotPeerDelegation.askTool: 86_400]
        ),
        GatewayServer(name: BotComputerCatalog.serverName, toolTimeoutSeconds: 900),
        GatewayServer(name: BotWebCatalog.serverName, toolTimeoutSeconds: 900),
    ]

    public static func gatewayURL(port: UInt16, server: String) -> String {
        "http://\(hostAlias):\(port)/mcp/\(server)"
    }

    public static func render(
        hostConfig: String,
        gatewayPort: UInt16,
        servers: [GatewayServer] = gatewayServers,
        hostEnvironment: [String: String]
    ) -> Rendered {
        let tables = parse(hostConfig)
        let dropped = droppedGroups(tables)

        var secrets: [String: String] = [:]
        var excluded: Set<String> = []
        var keyCount = 0
        var out = "# Written by RemoteCode before every in-guest run; edits are overwritten.\n"
        for table in tables {
            guard let header = table.header, let group = Group(path: table.path),
                  dropped[group] == nil else { continue }
            out += "\n\(header)\n"
            let literalKey = table.entries.first { $0.key == ["api_key"] }
                .flatMap { plainStringValue($0.text) }
                .flatMap { $0.isEmpty ? nil : $0 }
            for entry in table.entries {
                guard let key = entry.key else { continue }
                switch key {
                case ["api_key"]:
                    guard let literalKey else { continue }
                    keyCount += 1
                    let name = "\(modelKeyEnvironmentPrefix)\(keyCount)"
                    secrets[name] = literalKey
                    out += "env_key = \(quoted(name))\n"
                case ["env_key"]:
                    // A literal api_key wins over env_key in Distill and now
                    // is this table's env_key; TOML forbids a second one.
                    guard literalKey == nil else { continue }
                    for name in quotedStrings(entry.text) where isEnvironmentName(name) {
                        excluded.insert(name)
                        if let value = hostEnvironment[name], !value.isEmpty { secrets[name] = value }
                    }
                    out += entry.text + "\n"
                case ["base_url"], ["api_base_url"]:
                    out += rewritingLoopbackHost(entry.text) + "\n"
                default:
                    out += entry.text + "\n"
                }
            }
        }

        excluded.formUnion(secrets.keys)
        excluded.insert(gatewayTokenEnvironmentKey)
        // The agent's shell commands (and whatever they install) do not need
        // model keys or the gateway bearer: only Distill itself reads them.
        out += "\n[shell_environment_policy]\n"
        out += "exclude = \(array(excluded.sorted()))\n"

        out += "\n[mcp_servers.linux-use]\n"
        out += "command = \"python3\"\n"
        out += "args = \(array([BotComputerGuestSpec.linuxUseServerPath]))\n"
        out += "env = { DISPLAY = \":1\" }\n"

        // linux-use's browser tools need its Chrome extension, and jev_decide and run_subtask a
        // decision-model key; the guest has neither, so an agent offered them only gets failures.
        out += "\n[disabled_mcp_tools]\n"
        out += "linux-use = \(array(linuxUseToolsTheGuestCannotRun))\n"

        out += "\n[mcp_servers.playwright]\n"
        out += "command = \"playwright-mcp\"\n"
        out += "args = \(array(["--cdp-endpoint", browserCDPEndpoint]))\n"

        for server in servers {
            out += "\n[mcp_servers.\(server.name)]\n"
            out += "url = \(quoted(gatewayURL(port: gatewayPort, server: server.name)))\n"
            out += "bearer_token_env_var = \(quoted(gatewayTokenEnvironmentKey))\n"
            out += "startup_timeout_sec = \(gatewayStartupTimeoutSeconds)\n"
            out += "tool_timeout_sec = \(server.toolTimeoutSeconds)\n"
            if !server.toolTimeouts.isEmpty {
                let pairs = server.toolTimeouts.sorted { $0.key < $1.key }
                    .map { "\($0.key) = \($0.value)" }.joined(separator: ", ")
                out += "tool_timeouts = { \(pairs) }\n"
            }
        }

        var droppedModels: [String: String] = [:]
        for (group, reason) in dropped {
            if case .model(let id) = group { droppedModels[id] = reason }
        }
        return Rendered(toml: out, secretEnvironment: secrets, droppedModels: droppedModels)
    }

    /// `[models] default` of a host config.
    static func defaultModel(hostConfig: String) -> String? {
        parse(hostConfig).first { $0.path == ["models"] }?
            .entries.first { $0.key == ["default"] }
            .flatMap { stringValue($0.text) }
    }

    /// The `base_url` of a host `[model.<id>]` table and whether the table
    /// names its own key; nil when the config defines no such model.
    static func modelEndpoint(id: String, hostConfig: String) -> (baseURL: String?, hasOwnKey: Bool)? {
        guard let table = parse(hostConfig).first(where: { $0.path == ["model", id] }) else { return nil }
        let baseURL = table.entries.first { $0.key == ["base_url"] }.flatMap { stringValue($0.text) }
        let hasOwnKey = table.entries.contains { $0.key == ["api_key"] || $0.key == ["env_key"] }
        return (baseURL, hasOwnKey)
    }

    // MARK: - Which tables survive

    private enum Group: Hashable {
        case models
        case subagentModels
        case model(String)
        case provider(String)

        /// Nil for every table the guest does not get.
        init?(path: [String]) {
            if path == ["models"] { self = .models }
            else if path == ["subagents", "models"] { self = .subagentModels }
            else if path.count >= 2, path[0] == "model" { self = .model(path[1]) }
            else if path.count >= 2, path[0] == "model_providers" { self = .provider(path[1]) }
            else { return nil }
        }
    }

    /// Keys that run a host program, use a host login helper or carry
    /// credentials the guest cannot get without putting them in the file.
    private static let unsupportedKeys: Set<String> = [
        "auth", "auth_provider", "command", "extra_headers", "env_http_headers",
        "headers", "query_params",
    ]

    private static func droppedGroups(_ tables: [Table]) -> [Group: String] {
        var dropped: [Group: String] = [:]
        var providerOf: [String: String] = [:]
        for table in tables {
            guard let group = Group(path: table.path) else { continue }
            let id: String
            switch group {
            case .model(let value), .provider(let value): id = value
            case .models, .subagentModels: continue
            }
            if table.path.count > 2, table.path[2] != "reasoning_efforts" {
                dropped[group] = dropped[group] ?? "unsupported table \(table.path[2])"
            }
            for entry in table.entries {
                guard let first = entry.key?.first else { continue }
                let value = valueText(entry.text)
                if unsupportedKeys.contains(first) {
                    dropped[group] = dropped[group] ?? "unsupported key \(first)"
                } else if value.hasPrefix("\"/") || value.hasPrefix("'/")
                            || value.hasPrefix("\"~/") || value.hasPrefix("'~/") {
                    dropped[group] = dropped[group] ?? "host path in \(first)"
                } else if first == "api_key", plainStringValue(entry.text) == nil {
                    dropped[group] = dropped[group] ?? "api_key is not a plain one-line string"
                } else if case .model = group, entry.key == ["model_provider"],
                          let provider = stringValue(entry.text) {
                    providerOf[id] = provider
                }
            }
        }
        for (model, provider) in providerOf {
            if let reason = dropped[.provider(provider)], dropped[.model(model)] == nil {
                dropped[.model(model)] = "model provider \(provider) dropped (\(reason))"
            }
        }
        return dropped
    }

    // MARK: - Line-based TOML reading (the app has no TOML parser)

    private struct Entry {
        /// Dotted key path; nil for comments and blank lines.
        var key: [String]?
        /// The whole entry, continuation lines of a multi-line value included.
        var text: String
    }

    private struct Table {
        /// The header line as written; nil for the root table.
        var header: String?
        var path: [String]
        var entries: [Entry]
    }

    private static func parse(_ text: String) -> [Table] {
        var tables = [Table(header: nil, path: [], entries: [])]
        var open: (entry: Entry, state: ValueState)?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if var current = open {
                current.entry.text += "\n" + line
                scan(Substring(line), state: &current.state)
                if current.state.isClosed {
                    tables[tables.count - 1].entries.append(current.entry)
                    open = nil
                } else {
                    open = current
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                tables[tables.count - 1].entries.append(Entry(key: nil, text: line))
                continue
            }
            if trimmed.hasPrefix("[") {
                let isArray = trimmed.hasPrefix("[[")
                let inner = trimmed.dropFirst(isArray ? 2 : 1)
                let close = closingBracket(in: inner) ?? inner.endIndex
                tables.append(Table(header: trimmed, path: keyPath(inner[..<close]), entries: []))
                continue
            }
            guard let equals = equalsIndex(in: Substring(trimmed)) else {
                tables[tables.count - 1].entries.append(Entry(key: nil, text: line))
                continue
            }
            let entry = Entry(key: keyPath(trimmed[..<equals]), text: line)
            var state = ValueState()
            scan(trimmed[trimmed.index(after: equals)...], state: &state)
            if state.isClosed {
                tables[tables.count - 1].entries.append(entry)
            } else {
                open = (entry, state)
            }
        }
        if let current = open { tables[tables.count - 1].entries.append(current.entry) }
        return tables
    }

    /// Tracks whether a value continues on the next line: an open `[`/`{`
    /// or an open triple-quoted string.
    private struct ValueState {
        var depth = 0
        var multiline: String?
        var isClosed: Bool { depth <= 0 && multiline == nil }
    }

    private static func scan(_ text: Substring, state: inout ValueState) {
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if let delimiter = state.multiline {
                if rest.hasPrefix(delimiter) {
                    state.multiline = nil
                    index = text.index(index, offsetBy: 3)
                } else {
                    index = text.index(index, offsetBy: delimiter == "\"\"\"" && rest.first == "\\"
                                       && rest.count > 1 ? 2 : 1)
                }
                continue
            }
            switch text[index] {
            case "#":
                return
            case "\"", "'":
                let quote = text[index]
                let triple = String(repeating: quote, count: 3)
                if rest.hasPrefix(triple) {
                    state.multiline = triple
                    index = text.index(index, offsetBy: 3)
                    continue
                }
                index = endOfString(text, openingAt: index)
                continue
            case "[", "{":
                state.depth += 1
            case "]", "}":
                state.depth -= 1
            default:
                break
            }
            index = text.index(after: index)
        }
    }

    /// Index just past the single-line string that opens at `start`.
    private static func endOfString(_ text: Substring, openingAt start: Substring.Index) -> Substring.Index {
        let quote = text[start]
        var index = text.index(after: start)
        while index < text.endIndex {
            let character = text[index]
            if character == quote { return text.index(after: index) }
            if quote == "\"", character == "\\", text.index(after: index) < text.endIndex {
                index = text.index(index, offsetBy: 2)
                continue
            }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    private static func equalsIndex(in text: Substring) -> Substring.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "=": return index
            case "\"", "'": index = endOfString(text, openingAt: index)
            default: index = text.index(after: index)
            }
        }
        return nil
    }

    private static func closingBracket(in text: Substring) -> Substring.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "]": return index
            case "\"", "'": index = endOfString(text, openingAt: index)
            default: index = text.index(after: index)
            }
        }
        return nil
    }

    /// `model."a.b".reasoning_efforts` → ["model", "a.b", "reasoning_efforts"].
    private static func keyPath(_ text: Substring) -> [String] {
        var segments: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " || text[index] == "\t" {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            if text[index] == "\"" || text[index] == "'" {
                let end = endOfString(text, openingAt: index)
                segments.append(unquote(String(text[index..<end])) ?? "")
                index = end
            } else {
                var end = index
                while end < text.endIndex, text[end] != "." { end = text.index(after: end) }
                segments.append(text[index..<end].trimmingCharacters(in: .whitespaces))
                index = end
            }
            while index < text.endIndex, text[index] != "." { index = text.index(after: index) }
            if index < text.endIndex { index = text.index(after: index) }
        }
        return segments
    }

    private static func valueText(_ entry: String) -> String {
        guard let equals = equalsIndex(in: Substring(entry)) else { return "" }
        return entry[entry.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    }

    /// The value of `key = "x"` / `key = 'x'`; nil for any other value.
    private static func stringValue(_ entry: String) -> String? {
        let value = Substring(valueText(entry))
        guard let first = value.first, first == "\"" || first == "'" else { return nil }
        return unquote(String(value[..<endOfString(value, openingAt: value.startIndex)]))
    }

    /// `stringValue` for a one-line string without escapes: the only api_key
    /// form moved to the environment byte for byte.
    private static func plainStringValue(_ entry: String) -> String? {
        let value = valueText(entry)
        guard !value.hasPrefix("\"\"\""), !value.hasPrefix("'''"), !value.contains("\\") else { return nil }
        return stringValue(entry)
    }

    /// Every single-line string in an entry's value (a string or an array of them).
    private static func quotedStrings(_ entry: String) -> [String] {
        let value = Substring(valueText(entry))
        var strings: [String] = []
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "#" { break }
            if character == "\"" || character == "'" {
                let end = endOfString(value, openingAt: index)
                if let string = unquote(String(value[index..<end])) { strings.append(string) }
                index = end
            } else {
                index = value.index(after: index)
            }
        }
        return strings
    }

    /// Strips the quotes of a one-line string; basic strings with escapes are
    /// returned undecoded only for `\"` and `\\`, which is all key names use.
    private static func unquote(_ literal: String) -> String? {
        guard literal.count >= 2, let quote = literal.first, literal.last == quote else { return nil }
        let body = String(literal.dropFirst().dropLast())
        guard quote == "\"" else { return body }
        return body.replacingOccurrences(of: "\\\\", with: "\u{0}")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\u{0}", with: "\\")
    }

    // MARK: - Writing

    private static let loopbackHost = try! NSRegularExpression(
        pattern: #"://(127\.0\.0\.1|localhost|\[::1\])(?=[:/"'?#]|$)"#,
        options: [.caseInsensitive]
    )

    /// The guest's own loopback is not the Mac's: local model servers on the
    /// Mac are reached through the host alias instead.
    static func rewritingLoopbackHost(_ line: String) -> String {
        loopbackHost.stringByReplacingMatches(
            in: line,
            range: NSRange(line.startIndex..., in: line),
            withTemplate: "://\(hostAlias)"
        )
    }

    static func isEnvironmentName(_ name: String) -> Bool {
        guard let first = name.utf8.first, first == 95 || (first >= 65 && first <= 90)
                || (first >= 97 && first <= 122) else { return false }
        return name.utf8.allSatisfy {
            $0 == 95 || ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
        }
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func array(_ values: [String]) -> String {
        "[" + values.map(quoted).joined(separator: ", ") + "]"
    }
}
