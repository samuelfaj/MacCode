import Foundation

// Titio's voice: every user-visible notice, digest, result line and status
// line is written by ONE non-agentic call on Titio's own provider/model (no
// tools, one turn). This file is the pure part: the language setting, the
// prompts (facts + persona + style + language), the writer seam and the
// output checks. Running a provider CLI lives in AgentRuntime.

// MARK: - Language setting

/// `AppSettings.titioLanguage` (wire key `titio_language`): `auto` or a
/// BCP-47 tag.
public enum TitioLanguageSetting {
    public static let automatic = "auto"
    public static let wireKey = "titio_language"

    public struct Choice: Equatable, Sendable, Identifiable {
        public let tag: String
        public let label: String
        public var id: String { tag }
    }

    /// The options of the Settings picker (Mac and iOS). Every supported
    /// language ships a label in its own language, so the picker is readable
    /// no matter which language the app itself runs in.
    public static let choices: [Choice] = [
        Choice(tag: automatic, label: "Automatic (your language)"),
        Choice(tag: "en", label: "English"),
        Choice(tag: "pt-BR", label: "Português (Brasil)"),
        Choice(tag: "es", label: "Español"),
        Choice(tag: "ar", label: "العربية"),
        Choice(tag: "fr", label: "Français"),
        Choice(tag: "zh-Hans", label: "简体中文"),
        Choice(tag: "zh-Hant", label: "繁體中文"),
    ]

    /// The picker options, plus `current` when it is a tag set elsewhere
    /// (e.g. `settings.set` from a paired device) so the picker can show it.
    public static func choices(including current: String) -> [Choice] {
        guard let tag = normalized(current), !choices.contains(where: { $0.tag.caseInsensitiveCompare(tag) == .orderedSame }) else {
            return choices
        }
        return choices + [Choice(tag: tag, label: TitioVoiceLanguage.name(tag))]
    }

    private static let bcp47 = try! NSRegularExpression(
        pattern: #"^[A-Za-z]{2,3}(-[A-Za-z]{4})?(-(?:[A-Za-z]{2}|[0-9]{3}))?(-(?:[A-Za-z0-9]{5,8}|[0-9][A-Za-z0-9]{3}))*$"#
    )

    /// `auto` (any case) or a well-formed BCP-47 tag, trimmed; nil otherwise.
    public static func normalized(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.lowercased() == automatic { return automatic }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard value.count <= 35, bcp47.firstMatch(in: value, range: range) != nil else { return nil }
        // Canonical case ("PT-br" → "pt-BR"), so the picker and prompts match.
        return value.split(separator: "-").enumerated().map { index, part -> String in
            if index == 0 { return part.lowercased() }
            if part.count == 4, part.allSatisfy(\.isLetter) { return part.prefix(1).uppercased() + part.dropFirst().lowercased() }
            if part.count == 2 { return part.uppercased() }
            return part.lowercased()
        }.joined(separator: "-")
    }

    /// A supported language for the rare factual fallback (no LLM ran): a
    /// fixed `pt*` setting is Portuguese, any other fixed tag its language
    /// when supported and English otherwise; `auto` follows the user's
    /// recent Titio messages, then the device's preferred languages.
    public static func fallbackLanguage(
        setting: String,
        recentUserTexts: [String],
        cardLabels: Set<String>,
        preferredLanguages: [String]
    ) -> TitioNoticeLanguage {
        let tag = normalized(setting) ?? automatic
        guard tag == automatic else { return TitioNoticeLanguage(fixedTag: tag) }
        return TitioNoticeCopy.language(
            recentUserTexts: recentUserTexts, excluding: cardLabels, preferredLanguages: preferredLanguages
        )
    }

    /// What the writer is told about language: the fixed tag, or "write the
    /// way the user writes" with up to `maxExamples` of their own texts.
    public static func voiceLanguage(
        setting: String,
        recentUserTexts: [String],
        cardLabels: Set<String>,
        preferredLanguages: [String]
    ) -> TitioVoiceLanguage {
        let tag = normalized(setting) ?? automatic
        if tag != automatic { return .fixed(tag: tag) }
        let examples = recentUserTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !cardLabels.contains($0) }
            .prefix(TitioVoiceLanguage.maxExamples)
            .map { String($0.prefix(300)) }
        return .matchUser(examples: Array(examples), fallbackTag: preferredLanguages.first ?? "en")
    }
}

/// The language instruction of one prompt.
public enum TitioVoiceLanguage: Equatable, Sendable {
    public static let maxExamples = 5

    /// The Settings choice.
    case fixed(tag: String)
    /// `auto`: the language of the user's own recent texts (newest first);
    /// with none, `fallbackTag` (the Mac's preferred language).
    case matchUser(examples: [String], fallbackTag: String)

    public var instruction: String {
        switch self {
        case .fixed(let tag):
            return "Write in \(Self.name(tag)) (\(tag)), whatever language the facts are in."
        case .matchUser(let examples, let fallbackTag):
            guard !examples.isEmpty else {
                return "Write in \(Self.name(fallbackTag)) (\(fallbackTag)), the language of the user's Mac."
            }
            let quoted = examples.map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
            return """
            Write in the same language (and the same regional variant) the user writes in. \
            These are the user's most recent messages to you, newest first:
            \(quoted)
            """
        }
    }

    static func name(_ tag: String) -> String {
        Locale(identifier: "en_US").localizedString(forIdentifier: tag) ?? tag
    }
}

// MARK: - Writer seam

public enum TitioVoicePurpose: String, Sendable, Equatable {
    case notice
    case digest
    case result
    case status
}

/// One non-agentic completion request.
public struct TitioVoiceRequest: Sendable, Equatable {
    public var purpose: TitioVoicePurpose
    public var prompt: String
    /// The thread whose provider/model/instance/run-as-user Titio runs on
    /// (the Notifications inbox thread).
    public var threadID: AgentThreadID?
    /// The prompt asks for the JSON card shape (`TitioVoiceOutput.parseCard`).
    public var expectsJSON: Bool

    public init(purpose: TitioVoicePurpose, prompt: String, threadID: AgentThreadID?, expectsJSON: Bool = false) {
        self.purpose = purpose
        self.prompt = prompt
        self.threadID = threadID
        self.expectsJSON = expectsJSON
    }
}

public enum TitioVoiceError: Error, Equatable, Sendable {
    /// No LLM can run (no provider, binary or route): retrying cannot help.
    case unavailable(String)
    /// The call ran and failed (exit status, timeout, empty output).
    case failed(String)
}

/// Writes one Titio text. Production runs Titio's provider CLI headless
/// (`TitioVoiceCLIWriter`); tests pass a fake.
public protocol TitioVoiceWriting: Sendable {
    func write(_ request: TitioVoiceRequest, timeout: TimeInterval) async throws -> String
}

/// Delays and deadlines of the voice (contract §2): retries after 1/5/30 s,
/// each call at most 45 s, decisions and alerts posted within ~60 s.
public struct TitioVoiceTiming: Sendable, Equatable {
    public var retryDelays: [TimeInterval]
    public var callTimeout: TimeInterval
    /// Decisions and alerts: return control to the notice retry queue by then.
    public var urgentDeadline: TimeInterval
    /// Info notices and digests.
    public var infoDeadline: TimeInterval
    /// Result and status lines.
    public var lineDeadline: TimeInterval

    public init(
        retryDelays: [TimeInterval] = [1, 5, 30],
        callTimeout: TimeInterval = 45,
        urgentDeadline: TimeInterval = 58,
        infoDeadline: TimeInterval = 150,
        lineDeadline: TimeInterval = 50
    ) {
        self.retryDelays = retryDelays
        self.callTimeout = callTimeout
        self.urgentDeadline = urgentDeadline
        self.infoDeadline = infoDeadline
        self.lineDeadline = lineDeadline
    }

    public static let production = TitioVoiceTiming()
}

/// A checked writer reply.
public struct TitioVoiceReply: Equatable, Sendable {
    public var message: String
    /// The card's question (decision cards).
    public var question: String?
    /// Button labels in the ledger's option order; nil keeps the default labels.
    public var labels: [String]?
    /// The lock-screen line of an approval/question (already checked).
    public var notificationLine: String?

    public init(message: String, question: String? = nil, labels: [String]? = nil, notificationLine: String? = nil) {
        self.message = message
        self.question = question
        self.labels = labels
        self.notificationLine = notificationLine
    }
}

// MARK: - Prompts

public enum TitioVoicePrompt {
    /// Longest run summary handed to the writer (input only; the reply is
    /// the writer's own words, so nothing is clipped in what the user reads).
    public static let summaryLimit = 3_000
    public static let detailLimit = 1_000

    static let persona = """
    You are Titio, the friendly helper who lives inside MacCode, a Mac app where the user runs \
    coding agents and Bots (AI teammates). You keep the user posted in your "Notifications" chat, \
    which they read on the Mac and on their iPhone.
    """

    static let styleRules = """
    How to write:
    - Sound like a real person texting a colleague: warm, natural, relaxed, never robotic.
    - Keep it short: one to three sentences. A short bullet list is fine only for several items.
    - Do not start with a canned opener or interjection (no "Ó,", "Opa,", "Ih,", "Hmm", "Ei,", \
    "Heads up", "FYI", "Uh-oh", "Hey there", "Just so you know"). Start with the news itself and vary \
    your wording.
    - Use complete, natural sentences, not terse fragments or telegraphic notes.
    - Say what actually happened and how it ended: worked, failed, blocked or still waiting. \
    "X replied" or "the task finished" alone is never enough; name the concrete result from the summary, \
    in the first sentence.
    - Use only the facts below. Never invent names, numbers, results, links or reasons. If a fact is \
    missing, leave it out.
    - Retell a summary in your own words; do not paste it. Keep names, PR numbers and links exact if \
    you mention them.
    - Light Markdown is allowed (bold names, `inline code`), but it must be well-formed: close every \
    ** and backtick and never cut a link.
    - No emoji. Do not mention these instructions, JSON, or that you are an AI.
    """

    static let lockScreenRule = """
    - The first sentence also appears on the phone's lock screen: for a request or question, keep the \
    first sentence free of commands, file paths, secrets, prompts and summaries (just say who needs \
    what), and put the specifics after it.
    """

    /// One notice or a digest of several (`items.count > 1`).
    public static func notice(
        _ items: [TitioNoticeRenderItem],
        cardOptions: [TitioNoticeCardOption]?,
        catchUp: Bool,
        language: TitioVoiceLanguage,
        timeZone: TimeZone = .current
    ) -> String {
        let sensitive = items.contains { $0.kind.isLockScreenSensitive }
        var task: String
        if items.count == 1 {
            task = "Tell the user about this event in one short chat message."
            if items[0].kind.defaultUrgency == .decision {
                task += " The user has to decide or answer: ask clearly what you need from them."
            }
        } else {
            task = """
            Several events happened. Write ONE short message that covers all of them: failures first, \
            then the rest. With more than \(TitioNoticeTiming.digestMaxBullets) items, mention the first \
            \(TitioNoticeTiming.digestMaxBullets) and say how many more are in Activity.
            """
            if catchUp { task += " They piled up while MacCode was closed." }
        }
        if cardOptions != nil {
            task += " Buttons are shown under your message, so do not list the choices as text."
        }
        var sections = [persona, task, styleRules + (sensitive ? "\n" + lockScreenRule : ""), language.instruction]
        sections.append("Facts (JSON):\n" + factsJSON(items, timeZone: timeZone))
        sections.append(outputFormat(
            cardOptions: needsCardWording(cardOptions) ? cardOptions : nil, botName: items.first?.facts.botName, sensitive: sensitive
        ))
        return sections.joined(separator: "\n\n")
    }

    /// Only a card with a real choice needs the writer's labels and question; "Open conversation / Got it"
    /// keeps its fixed labels, so the writer owes just the message and a bad card reply cannot discard it.
    public static func needsCardWording(_ options: [TitioNoticeCardOption]?) -> Bool {
        options?.contains { !$0.action.isNavigation && $0.action != .ack } == true
    }

    /// Titio's line after the host acted on a card (approve, answer, …).
    public static func result(_ result: TitioNoticeResult, language: TitioVoiceLanguage) -> String {
        [
            persona,
            "You just did something for the user from a notification card. Tell them in one short, natural sentence what you did.",
            styleRules,
            language.instruction,
            "What happened (facts):\n" + resultFact(result),
            "Reply with the sentence only: no quotes, no preamble.",
        ].joined(separator: "\n\n")
    }

    /// The short note appended under a resolved notice (its card is gone).
    public static func status(
        _ status: TitioNoticeStatus,
        at date: Date,
        language: TitioVoiceLanguage,
        timeZone: TimeZone = .current
    ) -> String {
        let time = TitioNoticeCopy.clock(date, language: .en, timeZone: timeZone)
        let fact: String
        switch status {
        case .approved: fact = "The user approved this request at \(time)."
        case .declined: fact = "The user declined this request at \(time)."
        case .answered: fact = "The user's answer was passed on at \(time)."
        case .elsewhere: fact = "This was handled somewhere else (in the thread or on another device)."
        case .expired: fact = "This expired; nothing can be done from here any more."
        case .acknowledged: fact = "The user saw this and dismissed it."
        case .done: fact = "What the user asked for was done at \(time)."
        case .failed: fact = "It did not go through; the user should open the conversation."
        case .unknownEffect: fact = "The outcome is unconfirmed after interruption; check the source before retrying. Do not say it failed or succeeded."
        }
        return [
            persona,
            "Write a very short status note (at most 8 words) that goes under an old notification whose buttons are gone.",
            language.instruction,
            "Fact: " + fact,
            "Reply with the note only: plain text, no quotes, no Markdown, no final period needed.",
        ].joined(separator: "\n\n")
    }

    /// Texts an approval/question's lock-screen line must not repeat
    /// (command, detail, prompt, options, summary).
    public static func lockScreenForbidden(_ items: [TitioNoticeRenderItem]) -> [String] {
        items.filter { $0.kind.isLockScreenSensitive }.flatMap { item -> [String] in
            let f = item.facts
            return [f.detail, TitioNoticeCopy.approvalSnippet(f.detail), f.prompt, f.summary].compactMap { $0 }
                + TitioNoticeFacts.cleanOptions(f.options)
        }
    }

    // MARK: Facts

    static func factsJSON(_ items: [TitioNoticeRenderItem], timeZone: TimeZone) -> String {
        let objects = items.map { fact($0, timeZone: timeZone) }
        let value: Any = objects.count == 1 ? objects[0] : ["events": objects, "count": objects.count]
        let data = (try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func fact(_ item: TitioNoticeRenderItem, timeZone: TimeZone) -> [String: Any] {
        let f = item.facts
        var object: [String: Any] = [
            "what_happened": item.kind.voiceDescription,
            "urgency": item.kind.defaultUrgency.rawValue,
            "time": TitioNoticeCopy.clock(item.occurredAt, language: .en, timeZone: timeZone),
        ]
        func put(_ key: String, _ value: String?, limit: Int = 300) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            object[key] = value.count > limit ? String(value.prefix(limit)) + "…" : value
        }
        switch item.kind {
        case .scriptFailed, .scriptCompleted: put("script", f.title)
        case .transferFailed, .transferCompleted: put("transfer", f.title)
        case .sshDisconnected: put("ssh_session", f.title)
        case .fileConflict: put("file", f.title)
        case .providerUpdateFailed: put("provider", f.title)
        case .scheduledFailed: put("scheduled_task", f.title)
        case .external: put("notification_title", f.title)
        default: put("task_title", f.title)
        }
        put("workspace", f.workspaceName)
        put("bot", f.botName)
        put("summary", f.summary, limit: summaryLimit)
        if item.kind == .approval {
            object["the_agent_wants_to"] = TitioNoticeCopy.approvalVerb(kind: f.requestKind, requestTitle: f.requestTitle, language: .en)
            put("command_or_target", TitioNoticeCopy.approvalSnippet(f.detail))
        } else {
            put("detail", f.detail, limit: detailLimit)
        }
        put("question", f.prompt, limit: detailLimit)
        let options = TitioNoticeFacts.cleanOptions(f.options)
        if !options.isEmpty { object["question_options"] = options }
        if item.kind == .userInput {
            switch f.userInputShape {
            case .secret: object["answer_note"] = "It asks for a secret, so the user must answer in the conversation itself."
            case .multiQuestion: object["answer_note"] = "It has several questions, so the user must answer in the conversation itself."
            case .options, .freeText: break
            }
        }
        put("notification_body", f.body, limit: detailLimit)
        if let ms = f.durationMs { object["took"] = TitioNoticeCopy.duration(ms: ms, language: .en) }
        if let exit = f.exitCode { object["exit_code"] = exit }
        if let port = f.port { object["port"] = port }
        return object
    }

    static func resultFact(_ result: TitioNoticeResult) -> String {
        func ws(_ value: String?) -> String {
            guard let value = TitioNoticeCopy.clean(value, max: 80) else { return "" }
            return " in the workspace “\(value)”"
        }
        func target(_ target: TitioNoticeReplyTarget) -> String {
            switch target {
            case .agent(let workspace): return "the coding agent" + ws(workspace)
            case .bot(let name): return TitioNoticeCopy.clean(name, max: 80).map { "the Bot “\($0)”" } ?? "the Bot"
            }
        }
        switch result {
        case .approved(let workspace): return "You approved the agent's request\(ws(workspace)) for the user, once."
        case .approvedSession(let workspace): return "You approved the agent's request\(ws(workspace)) for the rest of the session."
        case .declined(let workspace): return "You declined the agent's request\(ws(workspace)); the agent was told."
        case .answered(let answer, let to):
            let quoted = TitioNoticeCopy.clean(answer, max: 300) ?? ""
            return "You passed the user's answer “\(quoted)” on to \(target(to))."
        case .armed(let to):
            return "The user tapped “Reply here”: their next message in this chat goes straight to \(target(to)). Invite them to type it."
        case .continued(let title):
            return "You asked the interrupted task\(TitioNoticeCopy.clean(title, max: 120).map { " “\($0)”" } ?? "") to continue."
        case .rerun(let task):
            return "You started the scheduled task\(TitioNoticeCopy.clean(task, max: 120).map { " “\($0)”" } ?? "") again."
        case .alreadyResolved:
            return "Nothing was sent: this request had already been handled or had expired."
        case .failed(let error):
            return "You could not send it (reason: \(TitioNoticeCopy.clean(error, max: 200) ?? "unknown")). Suggest opening the conversation to decide there."
        }
    }

    static func outputFormat(cardOptions: [TitioNoticeCardOption]?, botName: String?, sensitive: Bool) -> String {
        guard cardOptions != nil || sensitive else {
            return "Reply with the message text only: no quotes, no preamble, no sign-off."
        }
        var fields = [#""message": "<your chat message>""#]
        var lines: [String] = []
        if let cardOptions {
            fields.append(#""question": "<the short question on the buttons card, at most 80 characters>""#)
            fields.append(#""options": [<exactly \#(cardOptions.count) short button labels, in this order>]"#)
            lines.append("Button meanings, in order (write each label in the message's language; keep quoted option texts exactly as they are):")
            for (index, option) in cardOptions.enumerated() {
                lines.append("\(index + 1). \(option.action.voiceMeaning(botName: botName))")
            }
        }
        if sensitive {
            fields.append(#""notification": "<one short line for the lock screen, at most 90 characters, with no command, path, secret, prompt or summary>""#)
        }
        return (["Reply with ONLY one JSON object, no code fence:", "{" + fields.joined(separator: ", ") + "}"] + lines)
            .joined(separator: "\n")
    }
}

extension TitioNoticeKind {
    /// Requests and questions: their lock-screen text never carries specifics.
    public var isLockScreenSensitive: Bool {
        switch self {
        case .approval, .userInput, .manualAction, .botQuestion: return true
        default: return false
        }
    }

    var voiceDescription: String {
        switch self {
        case .runCompleted: return "A coding-agent task ended its turn without an error. The summary is the agent's final message: it may report success, partial progress or a problem. Read it and say which."
        case .runFailed: return "A coding-agent task failed."
        case .runInterrupted: return "A coding-agent task was interrupted before it finished; it can be continued."
        case .botReply: return "A Bot (one of the user's AI teammates) finished its turn in its own chat. The summary is what it said: it may be good news, bad news or a question. Read it and say what it did or answered and whether it worked."
        case .approval: return "A coding agent is waiting for the user's approval before it goes on."
        case .userInput: return "A coding agent asked the user a question and is waiting for the answer."
        case .manualAction: return "An agent is waiting for the user to do something by hand on the Mac."
        case .botQuestion: return "A Bot needs the user's answer or decision."
        case .botBlocked: return "A Bot got stuck and cannot go on by itself."
        case .scheduledFailed: return "A scheduled task (routine) failed."
        case .gitFailed: return "A git push failed."
        case .gitCompleted: return "A git push went through."
        case .scriptFailed: return "A project script ended with an error."
        case .scriptCompleted: return "A project script finished fine."
        case .transferFailed: return "An SSH file transfer failed."
        case .transferCompleted: return "An SSH file transfer finished."
        case .providerUpdateFailed: return "Updating an agent provider's CLI failed."
        case .sshDisconnected: return "An SSH session dropped without the user asking."
        case .fileConflict: return "A file the user is editing was changed outside the editor."
        case .serverListenerFailed: return "MacCode's local server could not open its port, so the iPhone may not connect."
        case .notificationsDenied: return "macOS notifications are off for MacCode, so Titio can only tell the user here and through the desktop pet."
        case .external: return "A notification arrived from a script or tool."
        }
    }
}

extension TitioNoticeAction {
    func voiceMeaning(botName: String?) -> String {
        let bot = TitioNoticeCopy.clean(botName, max: 60)
        switch self {
        case .approve: return "approve the request (this time only)"
        case .approveSession: return "approve for the rest of the session"
        case .decline: return "decline the request"
        case .providerOption(_, let text), .botOption(let text): return "answer “\(text)” (keep this text exactly)"
        case .continue: return "continue the task from where it stopped"
        case .rerun: return "run the scheduled task again"
        case .ack: return "dismiss it (got it)"
        case .replyHere: return "reply right here (Titio passes the next message on)"
        case .openThread: return "open the conversation"
        case .openBot: return "open \(bot ?? "the Bot")"
        case .openActivity: return "view it in Activity"
        case .openAllActivity: return "see everything in Activity"
        }
    }

    /// Provider and Bot options are the answer itself: their label stays verbatim.
    public var keepsLabelVerbatim: Bool {
        switch self {
        case .providerOption, .botOption: return true
        default: return false
        }
    }
}

// MARK: - Output checks

public enum TitioVoiceOutput {
    public static let maxMessageCharacters = 4_000
    public static let maxLabelCharacters = 40
    public static let maxQuestionCharacters = 120
    public static let maxNotificationCharacters = 120

    private static let quotePairs: [(Character, Character)] = [
        ("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("«", "»"),
    ]

    /// Trimmed text without wrapping quotes or a wrapping code fence, a
    /// "Titio:" label, or any ```choices block (only the host writes cards).
    /// Unbalanced `**` or backticks are removed so Markdown never breaks.
    /// Nil when nothing usable is left.
    public static func sanitize(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = BotChoicesBlock.parse(text)
        if parsed.choices != nil { text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        // A malformed card the writer tried anyway becomes plain code.
        text = text.replacingOccurrences(of: "```choices", with: "```text", options: .caseInsensitive)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 {
            var lines = text.components(separatedBy: "\n")
            if lines.count >= 2 {
                lines.removeFirst()
                if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
                text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        for label in ["Titio:", "**Titio:**", "Titio —"] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        text = strippingWrappingQuotes(text)
        text = balanced(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxMessageCharacters else { return nil }
        return text
    }

    /// One short plain line (status notes, labels, questions): Markdown and
    /// quotes removed, single line.
    public static func sanitizeLine(_ raw: String, max: Int) -> String? {
        guard let text = sanitize(raw) else { return nil }
        let line = MarkdownPlainText.firstLine(text)
        let unquoted = strippingWrappingQuotes(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unquoted.isEmpty, unquoted.count <= max else { return nil }
        return unquoted
    }

    /// The JSON shape of a card / lock-screen reply. `optionCount` is the
    /// ledger's option count (labels are kept only when the count matches);
    /// `forbidden` are texts the lock-screen line must not contain.
    public static func parseCard(_ raw: String, optionCount: Int?, forbidden: [String], requiresNotification: Bool = false) -> TitioVoiceReply? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8))) as? [String: Any],
              let rawMessage = object["message"] as? String,
              let message = sanitize(rawMessage) else { return nil }
        var reply = TitioVoiceReply(message: message)
        if let question = object["question"] as? String {
            reply.question = sanitizeLine(question, max: maxQuestionCharacters)
        }
        if let optionCount, let options = object["options"] as? [String], options.count == optionCount {
            let labels = options.compactMap { sanitizeLine($0, max: maxLabelCharacters) }
            if labels.count == optionCount, Set(labels).count == labels.count { reply.labels = labels }
        }
        if let line = (object["notification"] as? String).flatMap({ sanitizeLine($0, max: maxNotificationCharacters) }),
           isLockScreenSafe(line, forbidden: forbidden) {
            reply.notificationLine = line
        }
        if optionCount != nil, reply.question == nil || reply.labels == nil { return nil }
        if requiresNotification, reply.notificationLine == nil { return nil }
        return reply
    }

    /// False when `line` repeats a command, path, prompt or option: any code
    /// mark, path-like token, or a significant word of a forbidden text.
    public static func isLockScreenSafe(_ line: String, forbidden: [String]) -> Bool {
        if line.contains("`") || line.contains("/") || line.contains("~") { return false }
        let lower = line.lowercased()
        for text in forbidden {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            if lower.contains(trimmed) { return false }
            let words = trimmed.split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" }
            for word in words where word.count >= 4 && lower.contains(word) {
                return false
            }
        }
        return true
    }

    /// The first sentence of `text`, as plain text on one line (banner,
    /// push and pet body).
    public static func firstSentence(_ text: String, maxCharacters: Int = TitioNoticeCopy.previewMaxCharacters) -> String {
        let line = MarkdownPlainText.firstLine(text)
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if ".!?…。".contains(character), index >= 12 {
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                if next == " " {
                    return clip(String(characters[...index]), max: maxCharacters)
                }
            }
            index += 1
        }
        return clip(line, max: maxCharacters)
    }

    static func strippingWrappingQuotes(_ text: String) -> String {
        var value = text
        for _ in 0..<2 {
            guard let first = value.first, let last = value.last, value.count >= 2,
                  let pair = quotePairs.first(where: { $0.0 == first && $0.1 == last }) else { break }
            let inner = String(value.dropFirst().dropLast())
            // `"A" and "B"`: the quotes belong to the text, not around it.
            if inner.contains(pair.0) || inner.contains(pair.1) { break }
            value = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    /// Removes `**` when their count is odd and lone backticks when theirs
    /// is odd (outside fences), so a cut-off reply never swallows the rest.
    static func balanced(_ text: String) -> String {
        var result = text
        if result.components(separatedBy: "**").count % 2 == 0 {
            result = result.replacingOccurrences(of: "**", with: "")
        }
        let fenceFree = result.replacingOccurrences(of: "```", with: "")
        if fenceFree.filter({ $0 == "`" }).count % 2 == 1 {
            result = result.components(separatedBy: "```")
                .map { $0.replacingOccurrences(of: "`", with: "") }
                .joined(separator: "```")
        }
        return result
    }

    static func clip(_ text: String, max: Int) -> String {
        guard text.count > max, max > 1 else { return text }
        return String(text.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Retry loop

public enum TitioVoiceRunner {
    public enum Outcome: Equatable, Sendable {
        case written(String)
        /// No usable text; `reason` goes to the `titio.voice.fallback` log.
        case fallback(reason: String)
    }

    /// Calls the writer, retrying after `timing.retryDelays` until a usable
    /// text arrives or `deadline` seconds have passed. An `unavailable`
    /// writer is not retried. `accept` validates the raw text.
    public static func run(
        _ request: TitioVoiceRequest,
        writer: TitioVoiceWriting,
        timing: TitioVoiceTiming,
        deadline: TimeInterval,
        accept: (String) -> Bool = { TitioVoiceOutput.sanitize($0) != nil }
    ) async -> (outcome: Outcome, raw: String?) {
        let started = Date()
        var lastReason = "no_attempt"
        for attempt in 0...timing.retryDelays.count {
            if attempt > 0 {
                let delay = timing.retryDelays[attempt - 1]
                if Date().timeIntervalSince(started) + delay >= deadline { break }
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
            let remaining = deadline - Date().timeIntervalSince(started)
            guard remaining > 1 else { break }
            do {
                let raw = try await writer.write(request, timeout: min(timing.callTimeout, remaining))
                if accept(raw) { return (.written(raw), raw) }
                lastReason = "unusable_output"
            } catch TitioVoiceError.unavailable(let reason) {
                return (.fallback(reason: "unavailable:" + reason), nil)
            } catch {
                lastReason = "failed:" + String(describing: error)
            }
        }
        return (.fallback(reason: lastReason), nil)
    }
}
