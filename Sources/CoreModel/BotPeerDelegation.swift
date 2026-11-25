import Foundation

/// Provider-visible contract for AI-authored Bot delegation.
///
/// RemoteCode never derives a peer prompt from the user's prose. The active
/// provider reads the complete user turn and supplies the exact focused prompt
/// to `bot_ask_peer` itself.
public enum BotPeerDelegation: Sendable {
    public enum ReplyMode: String, Codable, Sendable {
        case consult
        case replyOnly = "reply_only"
    }

    public static let listTool = "bot_list_peers"
    public static let askTool = "bot_ask_peer"
    public static let statusTool = "bot_peer_status"
    public static let cancelTool = "bot_cancel_peer"

    public static let threadEnvironmentKey = "RC_REMOTE_CODE_SUBAGENT_THREAD_ID"
    public static let runEnvironmentKey = "RC_REMOTE_CODE_ROOT_RUN_ID"
    public static let socketEnvironmentKey = "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH"
    public static let turnContextEnvironmentKey = "RC_REMOTE_CODE_BOT_TURN_CONTEXT"
    public static let capabilityEnvironmentKey = AgentDelegationCapabilityTransport.environmentKey
    public static let capabilityRPCParameterKey = "delegation_capability"
    public static let consultationIDParameterKey = "consultation_id"
    /// Idle window for `bot_ask_peer`. Peer run events restart it; silence
    /// for this long times out. This is not a wall-clock cap on a live Bot.
    public static let peerConsultationTimeout: TimeInterval = 600
    /// Space byte written on the Unix socket so the MCP child can reset its
    /// idle read deadline without completing the JSON-RPC line.
    public static let peerConsultationKeepaliveByte: UInt8 = 0x20
    public static let hostOperationTimeout: TimeInterval = RemoteCodeHostCatalog.unixClientDeadline

    public static func peerConsultationStillActive(
        now: Date = Date(),
        lastProgress: Date,
        idle: TimeInterval = peerConsultationTimeout
    ) -> Bool {
        now.timeIntervalSince(lastProgress) < idle
    }

    /// Loop guards for one delegation task: everything one user message
    /// starts, including nested consultations. They stop bugs, not volume.
    /// A live Bot is never cut by the task's age, and the user's next message
    /// starts a fresh task.
    public struct Limits: Equatable, Sendable {
        /// Last-resort ceiling on consultations admitted in one task.
        public var maxAdmissionsPerTask: Int
        /// Settled consultations that failed in a row before admission stops.
        public var maxConsecutiveFailures: Int
        /// Times one task may send the same prompt to the same Bot.
        public var maxIdenticalAsks: Int
        /// A delegated run with no event from itself or a Bot it waits on
        /// for this long is stuck and is stopped.
        public var idleTimeout: TimeInterval
        /// A delegated run that is still producing events stops here.
        public var runCeiling: TimeInterval
        public var watchdogInterval: TimeInterval

        public init(
            maxAdmissionsPerTask: Int,
            maxConsecutiveFailures: Int,
            maxIdenticalAsks: Int,
            idleTimeout: TimeInterval,
            runCeiling: TimeInterval,
            watchdogInterval: TimeInterval
        ) {
            self.maxAdmissionsPerTask = maxAdmissionsPerTask
            self.maxConsecutiveFailures = maxConsecutiveFailures
            self.maxIdenticalAsks = maxIdenticalAsks
            self.idleTimeout = idleTimeout
            self.runCeiling = runCeiling
            self.watchdogInterval = watchdogInterval
        }

        public static let standard = Limits(
            maxAdmissionsPerTask: 50,
            maxConsecutiveFailures: 3,
            maxIdenticalAsks: 3,
            idleTimeout: peerConsultationTimeout,
            runCeiling: 2 * 60 * 60,
            watchdogInterval: 15
        )
    }

    /// Case- and whitespace-insensitive identity of a peer prompt, used only
    /// to recognise the same request being resent in a loop.
    public static func normalizedPrompt(_ prompt: String) -> String {
        prompt.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Delegation rules alone. A bot run inside its Linux guest gets only
    /// these: its gateway offers the peer tools but not the `rc_*` host
    /// catalog that `providerDirective` also describes.
    public static let peerDirective = """
    RemoteCode Bot delegation: an @handle names a RemoteCode Bot, but RemoteCode never forwards or rewrites the user's text automatically. You are the primary agent: first interpret the complete user request. When a turn includes RemoteCode-resolved Bot identity metadata, use it only to know which handles are other Bots; RemoteCode has not decided the user's intent. If the request asks one of those Bots to answer, act, provide input, or participate, you MUST call `bot_ask_peer`; never answer as that Bot or simulate its reply. If the mention is merely quoted, descriptive, or negated, do not delegate. Write a new focused `prompt` containing only what that Bot needs to answer or do; do not copy unrelated remainder of the user's instruction. Choose `consult` when you must use the reply and continue reasoning or acting. For multi-Bot comparison, debate, mediation, or consensus, call `bot_ask_peer` with `consult` as often as the request requires, including repeatedly for the same or different Bots. After each real reply, author any follow-up prompt yourself and include only the prior-reply context relevant to the next Bot. You remain responsible for mediation and final synthesis. You decide the semantic routing and sequence; the host enforces bounded work and resource admission. `reply_only` is terminal: never choose it while comparison, follow-up, mediation, or synthesis remains. Choose `reply_only` only when the user's whole turn is addressed to that Bot and its reply will itself be the complete user-facing answer; RemoteCode then displays the attributed Bot reply and suppresses your duplicate final answer. After a successful consultation, `bot_get_settings` and `bot_set_settings` may operate only on the Bot consulted by this exact active run; pass the returned Bot id when the run itself belongs to another Bot. Never claim that you contacted a Bot unless the tool call succeeded.

    A successful `bot_ask_peer` returns an opaque `consultation_id`. Omit it for a clean, independent review with a new Bot conversation and thread. To follow up, use an id returned by a prior successful call or by `bot_list_peers` in this same host conversation, with the same Bot. Every new run revalidates current authority and inherits the caller's current route. Never invent an id or reuse one from another conversation. A continuation preserves the Bot transcript and starts a new peer run.

    For independent work, set `wait` to false with `consult`: the tool returns durable activity and consultation ids immediately. Observe the activity with `bot_peer_status` (optionally `wait: true`); use `bot_cancel_peer` to stop only that activity. Do not declare completion while required activities remain pending. Use a stable `operation_id` when retrying the same submission; after an uncertain transport result inspect its receipt instead of starting duplicate work. Dependent tasks must wait for their prerequisites. Parallel work must not edit the same files or drive the same browser/computer; use isolated worktrees or sequence it. Admission bounds each task (everything one user message starts) by depth, cycles, shared Bot resources, repeated identical prompts, consecutive failures, and a total ceiling; a refusal is not permission to retry in a loop.

    Inside a workspace you can consult only that workspace's Bots and general Bots; Bots of other workspaces are not available there. Use `bot_list_peers` for the exact handles you can use; never guess a handle from another workspace.

    Delegate only when the requested expertise, independent verification, or useful parallel work warrants the overhead. When the user explicitly asks for parallel work, subagents or several Bots, that request is the warrant: split the work into independent parts and start every ready part at once with `consult` and `wait: false`, then collect with `bot_peer_status`. Give each peer the objective, exact constraints, relevant source references, expected deliverable, and any prerequisite results. Preserve evidence-backed disagreement in the synthesis; do not replace verification with a vote or invent consensus. Simple requests should finish directly. Stop consulting when the user outcome is supported by evidence. Report measured usage separately from unknown provider usage; no monetary ceiling is implied by the delegation limits.
    """

    public static let providerDirective = peerDirective + "\n\n" + RemoteCodeHostCatalog.providerDirective

    /// Identity-only turn context. The host resolves exact @handles so the
    /// provider cannot mistake a peer for itself, but leaves every semantic
    /// decision and the peer prompt itself to the provider.
    public static func turnDirective(mentionedBots: [BotDefinition]) -> String? {
        var seen = Set<BotID>()
        let peers = mentionedBots.filter { seen.insert($0.id).inserted }
        guard !peers.isEmpty else { return nil }
        let identities = peers.map {
            "- @\($0.handle) is \($0.name), RemoteCode Bot id \($0.id.value.uuidString.lowercased())"
        }.joined(separator: "\n")
        return """
        RemoteCode-resolved Bot identities for this exact turn:
        \(identities)

        This is identity metadata only. RemoteCode has not interpreted the request, selected a task, extracted text, or generated a peer prompt. Interpret the complete user request yourself. If it asks a listed Bot to answer, act, provide input, or participate, call `bot_ask_peer` for that Bot and author a new focused prompt containing only what it needs. Never answer on behalf of a listed Bot. Do not delegate a mention that is merely quoted, descriptive, or negated. If you are following up on the same Bot discussion, pass the exact successful `consultation_id`; omit it when you want a clean independent review.
        """
    }

    /// Carry identity separately from the user's prompt so provider transport
    /// cannot rewrite the user's words or drop the
    /// identity context. This is metadata only; the provider owns all semantics.
    public static func environment(
        addingTurnContextTo base: [String: String],
        mentionedBots: [BotDefinition]
    ) -> [String: String] {
        var environment = base
        if let directive = turnDirective(mentionedBots: mentionedBots) {
            environment[turnContextEnvironmentKey] = directive
        } else {
            environment.removeValue(forKey: turnContextEnvironmentKey)
        }
        return environment
    }

    /// Append only host-resolved identity metadata to provider instructions.
    /// No user prose is inspected here and no peer prompt is manufactured.
    public static func appendingTurnContext(
        to directives: String,
        environment: [String: String]
    ) -> String {
        guard let context = environment[turnContextEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !context.isEmpty else {
            return directives
        }
        return directives.isEmpty ? context : directives + "\n\n" + context
    }
}
