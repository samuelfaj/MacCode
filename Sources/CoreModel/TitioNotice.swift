import CryptoKit
import Foundation

// Titio notices: host events (run outcomes, approvals, Bot questions, pet
// alerts…) that the host turns into deterministic Titio messages without an
// LLM run. Each notice is one durable ledger row keyed by its source, so a
// replay or a second producer can never post it twice.

/// What happened. Raw values are stored in `titio_notices.kind`.
public enum TitioNoticeKind: String, Codable, CaseIterable, Sendable {
    case runCompleted
    case runFailed
    case runInterrupted
    case botReply
    case approval
    case userInput
    case manualAction
    case botQuestion
    case botBlocked
    case scheduledFailed
    case gitFailed
    case gitCompleted
    case scriptFailed
    case scriptCompleted
    case transferFailed
    case transferCompleted
    case providerUpdateFailed
    case sshDisconnected
    case fileConflict
    case serverListenerFailed
    case notificationsDenied
    case external

    /// Default urgency for the kind (spec §2).
    public var defaultUrgency: TitioNoticeUrgency {
        switch self {
        case .approval, .userInput, .manualAction, .botQuestion:
            return .decision
        case .runFailed, .runInterrupted, .botBlocked, .scheduledFailed, .gitFailed,
             .scriptFailed, .transferFailed, .providerUpdateFailed, .sshDisconnected,
             .fileConflict, .serverListenerFailed:
            return .alert
        case .runCompleted, .botReply, .gitCompleted, .scriptCompleted, .transferCompleted,
             .notificationsDenied, .external:
            return .info
        }
    }

    /// Something went wrong. Failures lead digests and use the failure openers.
    public var isFailure: Bool {
        switch self {
        case .runFailed, .runInterrupted, .botBlocked, .scheduledFailed, .gitFailed,
             .scriptFailed, .transferFailed, .providerUpdateFailed, .sshDisconnected,
             .serverListenerFailed:
            return true
        default:
            return false
        }
    }

    /// Stateful alerts wait `TitioNoticeTiming.flapHold` before posting, so a
    /// reconnect or resolve inside the window drops the notice (resolution `flap`).
    public var usesFlapHold: Bool {
        switch self {
        case .sshDisconnected, .fileConflict, .serverListenerFailed: return true
        default: return false
        }
    }
}

/// How fast the notice posts (§4). Raw values are stored in `titio_notices.urgency`.
public enum TitioNoticeUrgency: String, Codable, CaseIterable, Sendable {
    case decision
    case alert
    case info
}

/// Ledger row state (§3).
public enum TitioNoticeState: String, Codable, CaseIterable, Sendable {
    case pending
    case posted
    case acting
    case awaitingReply = "awaiting_reply"
    case resolved
    case dropped
}

/// Why a row left the open states (§3).
public enum TitioNoticeResolution: String, Codable, CaseIterable, Sendable {
    case approved
    case approvedSession = "approved_session"
    case declined
    case answered
    case forwarded
    case acknowledged
    case retried
    case elsewhere
    case expired
    case failed
    /// The host stopped after claiming; an external effect cannot be ruled out.
    case unknownEffect = "unknown_effect"
    case flap
    /// The user cleared the notice's message from the inbox (`bot.notice.clear`).
    case cleared
}

/// Ids of the thing the notice is about, captured at ingest. Stored as
/// `source_json` with snake_case keys; nil fields are omitted.
public struct TitioNoticeSource: Codable, Equatable, Sendable {
    public var threadId: String?
    public var runId: String?
    public var requestId: String?
    public var workspaceId: String?
    public var botId: String?
    public var conversationId: String?
    public var attentionItemId: String?
    public var scheduledTaskId: String?
    public var activityItemId: String?
    public var finalMessageId: String?
    public var notificationId: String?

    public init(
        threadId: String? = nil,
        runId: String? = nil,
        requestId: String? = nil,
        workspaceId: String? = nil,
        botId: String? = nil,
        conversationId: String? = nil,
        attentionItemId: String? = nil,
        scheduledTaskId: String? = nil,
        activityItemId: String? = nil,
        finalMessageId: String? = nil,
        notificationId: String? = nil
    ) {
        self.threadId = threadId
        self.runId = runId
        self.requestId = requestId
        self.workspaceId = workspaceId
        self.botId = botId
        self.conversationId = conversationId
        self.attentionItemId = attentionItemId
        self.scheduledTaskId = scheduledTaskId
        self.activityItemId = activityItemId
        self.finalMessageId = finalMessageId
        self.notificationId = notificationId
    }

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case runId = "run_id"
        case requestId = "request_id"
        case workspaceId = "workspace_id"
        case botId = "bot_id"
        case conversationId = "conversation_id"
        case attentionItemId = "attention_item_id"
        case scheduledTaskId = "scheduled_task_id"
        case activityItemId = "activity_item_id"
        case finalMessageId = "final_message_id"
        case notificationId = "notification_id"
    }
}

/// Real fields the copy may print. Templates never print anything else, so a
/// missing field drops its segment instead of inventing text (§0.3).
/// Stored as `facts_json` with snake_case keys; nil fields are omitted, so a
/// later ingest merges only the fields it actually knows.
public struct TitioNoticeFacts: Codable, Equatable, Sendable {
    /// Thread / task / script / transfer / SSH session / file / provider / notice title.
    public var title: String?
    public var workspaceName: String?
    public var botName: String?
    /// `agent_run_results.summary` (or the Bot's reply); printed as its first line, max 140 chars.
    public var summary: String?
    /// Request detail (command, manual-action detail, Bot question, block reason).
    public var detail: String?
    /// Provider request title for approvals (a provider label such as
    /// "Command approval" or a tool name; never put in a verb slot).
    public var requestTitle: String?
    /// `AssistantRequestKind` raw value of an approval (commandExecution,
    /// fileChange…): the copy turns it into a localized verb phrase.
    public var requestKind: String?
    /// The provider's question text for user input.
    public var prompt: String?
    /// External notification body.
    public var body: String?
    public var exitCode: Int?
    public var durationMs: Int?
    public var port: Int?
    /// Provider options (user input) or the Bot's own choices (Bot question).
    public var options: [String]?
    public var isSecret: Bool?
    public var questionCount: Int?
    /// Generated, checked lock-screen copy, retained for crash recovery.
    public var generatedNotificationLine: String?
    /// Observation survives focus/mute; only interruption is suppressed.
    public var interruptionSuppressed: Bool?

    public init(
        title: String? = nil,
        workspaceName: String? = nil,
        botName: String? = nil,
        summary: String? = nil,
        detail: String? = nil,
        requestTitle: String? = nil,
        requestKind: String? = nil,
        prompt: String? = nil,
        body: String? = nil,
        exitCode: Int? = nil,
        durationMs: Int? = nil,
        port: Int? = nil,
        options: [String]? = nil,
        isSecret: Bool? = nil,
        questionCount: Int? = nil
    ) {
        self.title = title
        self.workspaceName = workspaceName
        self.botName = botName
        self.summary = summary
        self.detail = detail
        self.requestTitle = requestTitle
        self.requestKind = requestKind
        self.prompt = prompt
        self.body = body
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.port = port
        self.options = options
        self.isSecret = isSecret
        self.questionCount = questionCount
    }

    enum CodingKeys: String, CodingKey {
        case title
        case workspaceName = "workspace_name"
        case botName = "bot_name"
        case summary
        case detail
        case requestTitle = "request_title"
        case requestKind = "request_kind"
        case prompt
        case body
        case exitCode = "exit_code"
        case durationMs = "duration_ms"
        case port
        case options
        case isSecret = "is_secret"
        case questionCount = "question_count"
        case generatedNotificationLine = "generated_notification_line"
        case interruptionSuppressed = "interruption_suppressed"
    }

    /// Which user-input card applies (§2): secret or multi-question → no card,
    /// ≥2 options → option card, otherwise free text.
    public enum UserInputShape: Equatable, Sendable { case options, freeText, secret, multiQuestion }

    public var userInputShape: UserInputShape {
        if isSecret == true { return .secret }
        if (questionCount ?? 1) > 1 { return .multiQuestion }
        return TitioNoticeFacts.cleanOptions(options).count >= 2 ? .options : .freeText
    }

    /// Trimmed, non-empty, de-duplicated options in order.
    public static func cleanOptions(_ options: [String]?) -> [String] {
        var seen = Set<String>()
        return (options ?? []).compactMap { raw in
            let option = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !option.isEmpty, seen.insert(option).inserted else { return nil }
            return option
        }
    }
}

/// What a card option does. Only the ledger holds these: a tap sends
/// `(message_id, option_index)` and the host executes the stored action (§7).
public enum TitioNoticeAction: Codable, Equatable, Hashable, Sendable {
    case approve
    case approveSession
    case decline
    /// Answer a provider user-input question with option `index` (`text` is sent).
    case providerOption(index: Int, text: String)
    /// Send `text` into the source Bot's own conversation.
    case botOption(text: String)
    case `continue`
    case rerun
    case ack
    case replyHere
    case openThread
    case openBot
    case openActivity
    case openAllActivity

    /// Navigation actions return a route and never change ledger state.
    public var isNavigation: Bool {
        switch self {
        case .openThread, .openBot, .openActivity, .openAllActivity: return true
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey { case type, index, text }

    public var typeName: String {
        switch self {
        case .approve: return "approve"
        case .approveSession: return "approve_session"
        case .decline: return "decline"
        case .providerOption: return "provider_option"
        case .botOption: return "bot_option"
        case .continue: return "continue"
        case .rerun: return "rerun"
        case .ack: return "ack"
        case .replyHere: return "reply_here"
        case .openThread: return "open_thread"
        case .openBot: return "open_bot"
        case .openActivity: return "open_activity"
        case .openAllActivity: return "open_all_activity"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "approve": self = .approve
        case "approve_session": self = .approveSession
        case "decline": self = .decline
        case "provider_option":
            self = .providerOption(
                index: try container.decode(Int.self, forKey: .index),
                text: try container.decode(String.self, forKey: .text)
            )
        case "bot_option": self = .botOption(text: try container.decode(String.self, forKey: .text))
        case "continue": self = .continue
        case "rerun": self = .rerun
        case "ack": self = .ack
        case "reply_here": self = .replyHere
        case "open_thread": self = .openThread
        case "open_bot": self = .openBot
        case "open_activity": self = .openActivity
        case "open_all_activity": self = .openAllActivity
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown Titio notice action \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeName, forKey: .type)
        switch self {
        case let .providerOption(index, text):
            try container.encode(index, forKey: .index)
            try container.encode(text, forKey: .text)
        case let .botOption(text):
            try container.encode(text, forKey: .text)
        default:
            break
        }
    }

    /// The card a notice offers (spec §2 "Card" column), or nil for no card.
    /// Digests build their own card in `TitioNoticeCopy`.
    public static func defaultActions(kind: TitioNoticeKind, facts: TitioNoticeFacts) -> [TitioNoticeAction]? {
        switch kind {
        case .runCompleted:
            return [.openThread, .ack]
        case .botReply:
            return [.openBot, .ack]
        case .runFailed:
            return [.openThread, .ack]
        case .runInterrupted:
            return [.continue, .openThread, .ack]
        case .approval:
            // No "Approve for session" on the card: it switches the whole
            // thread to Full Access, which both Agent Apps only grant behind
            // an explicit "Allow full access" confirmation. A one-tap card
            // (or an exact-text reply) must never skip that gate.
            return [.approve, .decline, .openThread]
        case .userInput:
            switch facts.userInputShape {
            case .options:
                let options = TitioNoticeFacts.cleanOptions(facts.options).prefix(4)
                return options.enumerated().map { .providerOption(index: $0.offset, text: $0.element) } + [.openThread]
            case .freeText:
                return [.replyHere, .openThread]
            case .secret, .multiQuestion:
                return nil
            }
        case .botQuestion:
            let options = TitioNoticeFacts.cleanOptions(facts.options)
            if options.count >= 2 {
                // One slot stays for "Open <Bot>" within BotChoicesBlock.maximumOptions.
                return options.prefix(BotChoicesBlock.maximumOptions - 1).map { .botOption(text: $0) } + [.openBot]
            }
            return [.replyHere, .openBot]
        case .botBlocked:
            return [.openBot, .ack]
        case .scheduledFailed:
            return [.rerun, .openActivity]
        default:
            return nil
        }
    }
}

/// One card option as stored in `actions_json` (display order). `label` is
/// nil until the notice is posted; posting writes the label the user saw.
public struct TitioNoticeCardOption: Codable, Equatable, Sendable {
    public var label: String?
    public var action: TitioNoticeAction

    public init(label: String?, action: TitioNoticeAction) {
        self.label = label
        self.action = action
    }
}

/// One notice as a producer hands it to the ledger (`TitioNoticeRepository.ingest`).
public struct TitioNoticeFact: Equatable, Sendable {
    public var key: String
    public var kind: TitioNoticeKind
    public var urgency: TitioNoticeUrgency
    public var source: TitioNoticeSource
    public var facts: TitioNoticeFacts
    /// The card's actions in display order; nil = no card.
    public var actions: [TitioNoticeAction]?
    public var occurredAt: Date

    public init(
        key: String,
        kind: TitioNoticeKind,
        urgency: TitioNoticeUrgency? = nil,
        source: TitioNoticeSource = TitioNoticeSource(),
        facts: TitioNoticeFacts = TitioNoticeFacts(),
        actions: [TitioNoticeAction]? = nil,
        occurredAt: Date = Date()
    ) {
        self.key = key
        self.kind = kind
        self.urgency = urgency ?? kind.defaultUrgency
        self.source = source
        self.facts = facts
        self.actions = actions
        self.occurredAt = occurredAt
    }
}

/// One ledger row as read back from `titio_notices`.
public struct TitioNoticeRecord: Equatable, Sendable {
    public var key: String
    public var kind: TitioNoticeKind
    public var urgency: TitioNoticeUrgency
    public var source: TitioNoticeSource
    public var facts: TitioNoticeFacts
    public var actions: [TitioNoticeCardOption]?
    public var state: TitioNoticeState
    public var resolution: TitioNoticeResolution?
    public var messageID: String?
    public var batchID: String?
    public var occurredAt: Date
    public var postedAt: Date?
    public var bannerAt: Date?
    public var resolvedAt: Date?

    public init(
        key: String,
        kind: TitioNoticeKind,
        urgency: TitioNoticeUrgency,
        source: TitioNoticeSource,
        facts: TitioNoticeFacts,
        actions: [TitioNoticeCardOption]?,
        state: TitioNoticeState,
        resolution: TitioNoticeResolution?,
        messageID: String?,
        batchID: String?,
        occurredAt: Date,
        postedAt: Date?,
        bannerAt: Date?,
        resolvedAt: Date?
    ) {
        self.key = key
        self.kind = kind
        self.urgency = urgency
        self.source = source
        self.facts = facts
        self.actions = actions
        self.state = state
        self.resolution = resolution
        self.messageID = messageID
        self.batchID = batchID
        self.occurredAt = occurredAt
        self.postedAt = postedAt
        self.bannerAt = bannerAt
        self.resolvedAt = resolvedAt
    }
}

/// The singleton `titio_inbox_state` row.
public struct TitioInboxState: Equatable, Sendable {
    public var conversationID: String?
    public var unreadCount: Int
    public var lastPreview: String?
    public var lastAt: Date?
    public var armedReplyKey: String?
    public var armedAt: Date?

    public init(
        conversationID: String? = nil,
        unreadCount: Int = 0,
        lastPreview: String? = nil,
        lastAt: Date? = nil,
        armedReplyKey: String? = nil,
        armedAt: Date? = nil
    ) {
        self.conversationID = conversationID
        self.unreadCount = unreadCount
        self.lastPreview = lastPreview
        self.lastAt = lastAt
        self.armedReplyKey = armedReplyKey
        self.armedAt = armedAt
    }

    /// The armed "Reply here" key while it is still inside `armedReplyTTL`.
    public func liveArmedReplyKey(now: Date) -> String? {
        guard let armedReplyKey, let armedAt,
              now.timeIntervalSince(armedAt) <= TitioNoticeTiming.armedReplyTTL else { return nil }
        return armedReplyKey
    }
}

/// Batching and delivery constants (§3, §4, §7).
public enum TitioNoticeTiming {
    /// Decisions post at once, each as its own message (after flushing pending info).
    public static let decisionDelay: TimeInterval = 0
    /// Failures post at once, one message each (stateful alerts use `flapHold`).
    public static let alertDelay: TimeInterval = 0
    /// Stateful alerts wait; a resolve inside the window drops the row (`flap`).
    public static let flapHold: TimeInterval = 8
    /// One global sliding window for info notices.
    public static let infoWindow: TimeInterval = 8
    /// Hard cap from the first info item in the window.
    public static let infoMaxWait: TimeInterval = 30
    /// Info waits at most this long while a Titio run is active in the inbox thread.
    public static let titioRunHold: TimeInterval = 30
    /// Bullets shown in a digest before "+N more in Activity".
    public static let digestMaxBullets = 8
    /// Lifetime of a "Reply here" arm.
    public static let armedReplyTTL: TimeInterval = 10 * 60
    /// Retry backoff while Titio / the inbox / its thread cannot be created.
    public static let retryBackoff: [TimeInterval] = [1, 2, 4, 8, 30]
    /// Decisions and alerts not posted this long after they are due also post the legacy banner/push.
    public static let legacyFallbackAfter: TimeInterval = 5
    /// Startup re-posts banners for rows posted this recently without `banner_at`.
    public static let bannerRepostWindow: TimeInterval = 10 * 60
    /// Resolved/dropped rows older than this are pruned at startup.
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    /// Bot attention items older than this never become a notice: the first
    /// pass after an upgrade must not turn a weeks-old backlog into a burst of
    /// messages, banners and pushes (those items stay in Activity).
    public static let attentionMaxAge: TimeInterval = 24 * 60 * 60
}

/// Deterministic ids and source keys (§3).
public enum TitioNoticeIDs {
    /// Fixed RFC 4122 namespace for Titio notice message ids. Never change it:
    /// message ids must stay identical across restarts and versions.
    public static let namespace = UUID(uuidString: "CB346DB3-E797-4AD8-886B-E92520A9245E")!

    /// RFC 4122 version 5 (SHA-1, name-based) UUID.
    public static func uuidV5(namespace: UUID, name: String) -> UUID {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes.append(contentsOf: Array(name.utf8))
        var hash = Array(Insecure.SHA1.hash(data: Data(bytes)).prefix(16))
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (
            hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]
        ))
    }

    /// Message id for a single-notice message: `UUIDv5(ns, "titio.notice:" + key)`.
    public static func messageID(forKey key: String) -> UUID {
        uuidV5(namespace: namespace, name: "titio.notice:" + key)
    }

    /// Message id for a digest: `UUIDv5(ns, "titio.digest:" + sorted(keys) joined by "\n")`.
    /// Keys never contain a newline, so different key sets cannot collide by concatenation.
    public static func digestMessageID(forKeys keys: [String]) -> UUID {
        uuidV5(namespace: namespace, name: "titio.digest:" + keys.sorted().joined(separator: "\n"))
    }

    /// Banner/push identifier for a digest message.
    public static func digestBannerIdentifier(messageID: UUID) -> String {
        "titio.digest.\(messageID.uuidString)"
    }

    // MARK: Source keys — reuse today's banner identifiers so relay idempotency
    // and `SystemNotifier.postedIdentifiers` keep working.

    public enum RunOutcome: String, Sendable { case completed, failed, interrupted }

    public static func runOutcome(runId: String, outcome: RunOutcome) -> String { "run.\(runId).\(outcome.rawValue)" }
    /// The request's base key. Resolutions use it; `sourceResolved` also
    /// resolves every occurrence (`base#…`) of it.
    public static func threadAttention(threadId: String, requestId: String) -> String { "thread.\(threadId).attention.\(requestId)" }
    /// One request instance: provider request ids are per-process JSON-RPC
    /// ids that restart after a provider or app restart, so the run id
    /// keeps a recycled id from landing on an older request's row.
    public static func threadAttention(threadId: String, requestId: String, runId: String) -> String {
        occurrence(of: threadAttention(threadId: threadId, requestId: requestId), runId)
    }

    /// Separates a stateful source key from one occurrence of it.
    public static let occurrenceSeparator = "#"

    /// One occurrence of a stateful source (an SSH surface that drops again,
    /// a second conflict in the same edit session, a recycled request id).
    /// A finished row never blocks a later occurrence of the same source.
    public static func occurrence(of base: String, _ occurrence: String) -> String {
        base + occurrenceSeparator + occurrence
    }

    /// The source key without its occurrence suffix.
    public static func baseKey(of key: String) -> String {
        guard let range = key.range(of: occurrenceSeparator, options: .backwards) else { return key }
        return String(key[..<range.lowerBound])
    }
    public static func botAttention(itemId: String) -> String { "bot.attention.\(itemId)" }
    public static func botReply(runId: String) -> String { "bot.reply.\(runId)" }
    /// A scheduled failure with an `agentRunID` shares the run's failure key.
    public static func scheduledFailure(scheduledRunId: String, agentRunId: String?) -> String {
        if let agentRunId, !agentRunId.isEmpty { return runOutcome(runId: agentRunId, outcome: .failed) }
        return "scheduled_task_run.\(scheduledRunId).failed"
    }
    public static func petEvent(sequence: Int64) -> String { "pet.event.\(sequence)" }
    public static func petSSHDisconnect(surfaceId: String) -> String { "pet.ssh-disconnect.\(surfaceId)" }
    public static func petFileConflict(sessionId: String) -> String { "pet.file-conflict.\(sessionId)" }
    public static func petServerListener(port: Int) -> String { "pet.server-listener.\(port)" }
    public static func externalNotification(id: String) -> String { "notification.\(id)" }
    /// Same id the pet uses today; in-app only (no banner, no push).
    public static let notificationsDenied = "pet.notifications.denied"
}
