import Foundation
import NaturalLanguage

/// Language of one Titio notice message, decided once per message at flush time.
/// `.pt` covers every Portuguese variant; the other tags are BCP-47 primary tags.
public enum TitioNoticeLanguage: String, CaseIterable, Sendable {
    case en
    case pt = "pt"
    case es = "es"
    case fr = "fr"
    case zh = "zh"
    case ar = "ar"

    /// The tag of the fixed `titio_language` setting, folded into a case;
    /// unknown or regional-only tags stay English (§1 fallback rule).
    public init(fixedTag: String) {
        self = TitioNoticeLanguage(rawValue: fixedTag.lowercased().split(separator: "-").first.map(String.init) ?? fixedTag) ?? .en
    }
}

/// What the copy needs to render one notice. Built from a ledger row or a fact.
public struct TitioNoticeRenderItem: Equatable, Sendable {
    public var key: String
    public var kind: TitioNoticeKind
    public var facts: TitioNoticeFacts
    public var actions: [TitioNoticeAction]?
    public var occurredAt: Date

    public init(key: String, kind: TitioNoticeKind, facts: TitioNoticeFacts, actions: [TitioNoticeAction]?, occurredAt: Date) {
        self.key = key
        self.kind = kind
        self.facts = facts
        self.actions = actions
        self.occurredAt = occurredAt
    }

    public init(record: TitioNoticeRecord) {
        self.init(key: record.key, kind: record.kind, facts: record.facts,
                  actions: record.actions?.map(\.action), occurredAt: record.occurredAt)
    }

    public init(fact: TitioNoticeFact) {
        self.init(key: fact.key, kind: fact.kind, facts: fact.facts, actions: fact.actions, occurredAt: fact.occurredAt)
    }
}

/// A composed Titio message.
public struct TitioNoticeComposed: Equatable, Sendable {
    /// Full message body, ending with the ```choices block when there is a card.
    public var text: String
    /// Banner / push / pet / roster body: first line, markdown stripped, max 178 chars.
    public var preview: String
    /// Labeled card options in display order; exactly the options the block shows. Nil = no card.
    public var cardOptions: [TitioNoticeCardOption]?
    /// The ledger key whose `actions_json` holds the card (the block's `notice`).
    public var cardOwnerKey: String?

    public init(text: String, preview: String, cardOptions: [TitioNoticeCardOption]?, cardOwnerKey: String?) {
        self.text = text
        self.preview = preview
        self.cardOptions = cardOptions
        self.cardOwnerKey = cardOwnerKey
    }
}

/// Where a forwarded answer went (result lines).
public enum TitioNoticeReplyTarget: Equatable, Sendable {
    case agent(workspace: String?)
    case bot(name: String?)
}

/// Titio's line after an act (§6 "Result lines").
public enum TitioNoticeResult: Equatable, Sendable {
    case approved(workspace: String?)
    case approvedSession(workspace: String?)
    case declined(workspace: String?)
    case answered(answer: String, target: TitioNoticeReplyTarget)
    case armed(target: TitioNoticeReplyTarget)
    case continued(title: String?)
    case rerun(task: String?)
    case alreadyResolved
    case failed(error: String)
}

/// Italic status line appended to the original message when its notice resolves.
public enum TitioNoticeStatus: Equatable, Sendable {
    case approved
    case declined
    case answered
    case elsewhere
    case expired
    case acknowledged
    /// continue / rerun went through (not in the spec table; see `statusLine`).
    case done
    /// The host action threw (not in the spec table; see `statusLine`).
    case failed
    case unknownEffect

    /// Stored in the `notice` block's `state`; stable across releases.
    public var wireValue: String {
        switch self {
        case .approved: return "approved"
        case .declined: return "declined"
        case .answered: return "answered"
        case .elsewhere: return "elsewhere"
        case .expired: return "expired"
        case .acknowledged: return "acknowledged"
        case .done: return "done"
        case .failed: return "failed"
        case .unknownEffect: return "unknown_effect"
        }
    }

    /// Nil for `flap` (never posted) and `cleared` (the message is gone): nothing to rewrite.
    public init?(resolution: TitioNoticeResolution) {
        switch resolution {
        case .approved, .approvedSession: self = .approved
        case .declined: self = .declined
        case .answered, .forwarded: self = .answered
        case .acknowledged: self = .acknowledged
        case .retried: self = .done
        case .elsewhere: self = .elsewhere
        case .expired: self = .expired
        case .failed: self = .failed
        case .unknownEffect: self = .unknownEffect
        case .flap, .cleared: return nil
        }
    }
}

/// The factual pt-BR / en fallback for Titio notices, plus the card labels,
/// ids, previews and formatting the voice path shares. Titio's own words come
/// from `TitioVoicePrompt` + the writer; this copy is only what posts when no
/// LLM could run. Pure: no clock, locale or database reads.
public enum TitioNoticeCopy {
    public static let bannerTitle = "Titio"
    public static let summaryMaxCharacters = 140
    public static let previewMaxCharacters = 178
    /// Minimum recognizer confidence before the user's text decides the language.
    public static let languageConfidenceThreshold = 0.8

    // MARK: Language (§1)

    /// One language for one message: the dominant language of the user's most
    /// recent message to Titio; with no usable text (none yet, too short or
    /// ambiguous), the first preferred system language, else English.
    public static func language(lastUserText: String?, preferredLanguages: [String]) -> TitioNoticeLanguage {
        if let detected = detectedLanguage(lastUserText) { return detected }
        return language(forPreferences: preferredLanguages)
    }

    /// First preferred system language we support, else English.
    public static func language(forPreferences preferredLanguages: [String]) -> TitioNoticeLanguage {
        for candidate in preferredLanguages {
            let tag = candidate.lowercased().split(separator: "-").first.map(String.init) ?? candidate
            if let language = TitioNoticeLanguage(rawValue: tag) { return language }
        }
        return .en
    }

    /// The §1 rule over the user's recent Titio messages, newest first: the
    /// first one the recognizer is confident about decides. Card taps are
    /// stored as user rows with the option's label ("Got it", "PostgreSQL"),
    /// so texts equal to a card label are skipped, and a short ambiguous reply
    /// ("ok") never flips the language: the walk goes back to an older,
    /// confident message before falling back to the system language.
    public static func language(
        recentUserTexts: [String],
        excluding cardLabels: Set<String> = [],
        preferredLanguages: [String]
    ) -> TitioNoticeLanguage {
        for text in recentUserTexts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cardLabels.contains(trimmed) else { continue }
            if let detected = detectedLanguage(trimmed) { return detected }
        }
        return language(lastUserText: nil, preferredLanguages: preferredLanguages)
    }

    /// A supported language when the recognizer is confident, else nil.
    public static func detectedLanguage(_ text: String?) -> TitioNoticeLanguage? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .portuguese, .spanish, .french, .simplifiedChinese, .traditionalChinese, .arabic]
        recognizer.processString(String(text.prefix(2_000)))
        guard let best = recognizer.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }),
              best.value >= languageConfidenceThreshold else { return nil }
        let raw = best.key.rawValue
        if raw.hasPrefix("pt") { return .pt }
        if raw.hasPrefix("zh") { return .zh }
        return TitioNoticeLanguage(rawValue: raw.split(separator: "-").first.map(String.init) ?? raw)
    }

    // MARK: Compose

    /// One notice as its own message.
    public static func compose(_ item: TitioNoticeRenderItem, language: TitioNoticeLanguage, timeZone: TimeZone = .current) -> TitioNoticeComposed {
        let body = body(for: item, language: language, timeZone: timeZone)
        let itemPreview = singlePreview(item, body: body)
        guard let actions = item.actions else {
            return TitioNoticeComposed(text: body, preview: itemPreview, cardOptions: nil, cardOwnerKey: nil)
        }
        let options = labeledOptions(actions, language: language, botName: clean(item.facts.botName, max: 80))
        guard options.count >= 2 else {
            return TitioNoticeComposed(text: body, preview: itemPreview, cardOptions: nil, cardOwnerKey: nil)
        }
        // "Open conversation / Got it" answers no question; only a real choice gets one.
        let asksSomething = options.contains { !$0.action.isNavigation && $0.action != .ack }
        let question = asksSomething ? cardQuestion(for: item, language: language) : nil
        let block = choicesBlock(question: question, options: options.compactMap(\.label), notice: item.key, source: sourceLabels(item.facts), canReply: actions.contains(.replyHere))
        return TitioNoticeComposed(text: body + "\n\n" + block, preview: itemPreview,
                                   cardOptions: options, cardOwnerKey: item.key)
    }

    static func t(_ language: TitioNoticeLanguage, _ strings: [TitioNoticeLanguage: String]) -> String {
        strings[language] ?? strings[.en] ?? ""
    }

    /// The roster / pet preview of one notice: its first line, except an
    /// external notice, whose caller-written body is on line 2 and would be
    /// lost ("Build: All 300 tests passed", not just "New notice: Build").
    static func singlePreview(_ item: TitioNoticeRenderItem, body: String) -> String {
        guard item.kind == .external else { return preview(body) }
        return externalHeadline(item.facts) ?? preview(body)
    }

    private static func externalHeadline(_ facts: TitioNoticeFacts) -> String? {
        let title = clean(facts.title, max: 120)
        let text = clean(facts.body, max: 300)
        switch (title, text) {
        case let (title?, text?): return clip("\(title): \(text)", max: previewMaxCharacters)
        case let (nil, text?): return clip(text, max: previewMaxCharacters)
        case let (title?, nil): return clip(title, max: previewMaxCharacters)
        case (nil, nil): return nil
        }
    }

    /// The banner and push body (§8/§9) for a flushed message. It goes to the
    /// relay, APNs and the lock screen, so it never carries the request
    /// detail (a command or tool input can hold a secret), the run summary
    /// (the agent's last message) or the question text: those stay in the
    /// inbox message, which only syncs over the paired channel. An external
    /// notice keeps the caller's own title and body, as today's banner did.
    public static func bannerBody(_ items: [TitioNoticeRenderItem], language: TitioNoticeLanguage, catchUp: Bool = false, timeZone: TimeZone = .current) -> String {
        guard items.count == 1, let item = items.first else {
            return composeBatch(items, language: language, catchUp: catchUp, timeZone: timeZone)?.preview ?? ""
        }
        if item.kind == .external { return singlePreview(item, body: body(for: item, language: language, timeZone: timeZone)) }
        var redacted = item
        redacted.facts.detail = nil
        redacted.facts.summary = nil
        redacted.facts.prompt = nil
        redacted.facts.options = nil
        return preview(body(for: redacted, language: language, timeZone: timeZone))
    }

    /// The fallback for a flushed batch: one item uses its single sentence; two
    /// or more become a plain digest (failures first, then by time; at most
    /// `digestMaxBullets` bullets), with no opener. `catchUp` only matters to
    /// the voice prompt. Nil for an empty batch.
    public static func composeBatch(_ items: [TitioNoticeRenderItem], language: TitioNoticeLanguage, catchUp: Bool = false, timeZone: TimeZone = .current) -> TitioNoticeComposed? {
        guard let first = items.first else { return nil }
        if items.count == 1 { return compose(first, language: language, timeZone: timeZone) }
        let ordered = digestOrder(items)
        var lines: [String] = []
        let maxBullets = TitioNoticeTiming.digestMaxBullets
        lines += ordered.prefix(maxBullets).map { "• " + digestLine($0, language: language) }
        if ordered.count > maxBullets {
            let extra = ordered.count - maxBullets
            lines.append(t(language, [.pt: "+\(extra) mais na Atividade", .en: "+\(extra) more in Activity", .es: "+\(extra) más en Actividad", .fr: "+\(extra) de plus dans Activité", .ar: "+\(extra) أخرى في النشاط", .zh: "活动里还有 \(extra) 条"]))
        }
        let firstFailure = ordered.first { $0.kind.isFailure }
        var cardOptions: [TitioNoticeCardOption]?
        if let firstFailure {
            let name = digestTitle(firstFailure, language: language)
            let open: TitioNoticeAction
            switch firstFailure.kind {
            case .runFailed, .runInterrupted: open = .openThread
            case .botBlocked: open = .openBot
            default: open = .openActivity
            }
            cardOptions = [
                TitioNoticeCardOption(label: t(language, [.pt: "Abrir \(name)", .en: "Open \(name)", .es: "Abrir \(name)", .fr: "Ouvrir \(name)", .ar: "فتح \(name)", .zh: "打开 \(name)"]), action: open),
                TitioNoticeCardOption(label: label(for: .openAllActivity, language: language), action: .openAllActivity),
            ]
        }
        let body = lines.joined(separator: "\n")
        let headline = digestHeadline(ordered, language: language)
        guard let cardOptions, let owner = firstFailure else {
            return TitioNoticeComposed(text: body, preview: headline, cardOptions: nil, cardOwnerKey: nil)
        }
        let block = choicesBlock(question: nil, options: cardOptions.compactMap(\.label), notice: owner.key)
        return TitioNoticeComposed(text: body + "\n\n" + block, preview: headline, cardOptions: cardOptions, cardOwnerKey: owner.key)
    }

    /// One line that says what a digest holds (banner, push, pet, roster):
    /// "3 novidades — Fix login: falhou · Deploy: concluída +1".
    static func digestHeadline(_ ordered: [TitioNoticeRenderItem], language: TitioNoticeLanguage) -> String {
        let shown = ordered.prefix(2).map { "\(digestTitle($0, language: language)): \(digestState($0.kind, language: language))" }
        let extra = ordered.count - shown.count
        let head = t(language, [.pt: "\(ordered.count) novidades — ", .en: "\(ordered.count) updates — ", .es: "\(ordered.count) novedades —", .fr: "\(ordered.count) mises à jour —", .ar: "\(ordered.count) تحديثات —", .zh: "\(ordered.count) 条更新 —"])
        return clip(head + shown.joined(separator: " · ") + (extra > 0 ? " +\(extra)" : ""), max: previewMaxCharacters)
    }

    /// The fallback text for one notice, without any choices block: one
    /// minimal factual sentence from the facts (no opener, no interjection,
    /// no clipped summary). Titio's real words come from the voice writer;
    /// this is only posted when no LLM could run (`titio.voice.fallback`).
    public static func body(for item: TitioNoticeRenderItem, language: TitioNoticeLanguage, timeZone: TimeZone = .current) -> String {
        let f = item.facts
        let title = clean(f.title, max: 120)
        let ws = clean(f.workspaceName, max: 80)
        let bot = clean(f.botName, max: 80)
        let detail = clean(f.detail, max: 200)
        let duration = f.durationMs.map { self.duration(ms: $0, language: language) }
        let wsPt = ws.map { " do **\($0)**" } ?? ""
        let wsNoPt = ws.map { " no **\($0)**" } ?? ""
        let wsEn = ws.map { " in **\($0)**" } ?? ""
        let wsEs = ws.map { " en **\($0)**" } ?? ""
        let wsFr = ws.map { " dans **\($0)**" } ?? ""
        let wsAr = ws.map { " في **\($0)**" } ?? ""
        let wsZh = ws.map { "（**\($0)**）" } ?? ""
        // The agent's own first sentence says what happened; without it a notice only says that something did.
        let saidTail = summarySentence(f.summary).map { ": " + $0 + (".!?…".contains($0.last ?? " ") ? "" : ".") } ?? "."

        switch item.kind {
        case .runCompleted:
            return t(language, [
                .pt: "\(title.map { "A tarefa **\($0)**" } ?? "Uma tarefa")\(wsPt) foi concluída\(duration.map { " em \($0)" } ?? "")" + saidTail,
                .en: "\(title.map { "**\($0)**" } ?? "A task")\(wsEn) is done\(duration.map { " in \($0)" } ?? "")" + saidTail,
                .es: "\(title.map { "La tarea **\($0)**" } ?? "Una tarea")\(wsEs) se completó\(duration.map { " en \($0)" } ?? "")" + saidTail,
                .fr: "\(title.map { "La tâche **\($0)**" } ?? "Une tâche")\(wsFr) est terminée\(duration.map { " en \($0)" } ?? "")" + saidTail,
                .ar: "\(title.map { "المهمة **\($0)**" } ?? "مهمة")\(wsAr) اكتملت\(duration.map { " في \($0)" } ?? "")" + saidTail,
                .zh: "\(title.map { "任务 **\($0)**" } ?? "一个任务")\(wsZh)已完成\(duration.map { "，用时 \($0)" } ?? "")" + saidTail,
            ])

        case .runFailed:
            return t(language, [
                .pt: "\(title.map { "A tarefa **\($0)**" } ?? "Uma tarefa")\(wsPt) falhou" + saidTail,
                .en: "\(title.map { "**\($0)**" } ?? "A task")\(wsEn) failed" + saidTail,
                .es: "\(title.map { "La tarea **\($0)**" } ?? "Una tarea")\(wsEs) falló" + saidTail,
                .fr: "\(title.map { "La tâche **\($0)**" } ?? "Une tâche")\(wsFr) a échoué" + saidTail,
                .ar: "\(title.map { "المهمة **\($0)**" } ?? "مهمة")\(wsAr) فشلت" + saidTail,
                .zh: "\(title.map { "任务 **\($0)**" } ?? "一个任务")\(wsZh)失败" + saidTail,
            ])

        case .runInterrupted:
            return t(language, [
                .pt: "\(title.map { "A tarefa **\($0)**" } ?? "Uma tarefa")\(wsPt) foi interrompida.",
                .en: "\(title.map { "**\($0)**" } ?? "A task")\(wsEn) was interrupted.",
                .es: "\(title.map { "La tarea **\($0)**" } ?? "Una tarea")\(wsEs) se interrumpió.",
                .fr: "\(title.map { "La tâche **\($0)**" } ?? "Une tâche")\(wsFr) a été interrompue.",
                .ar: "\(title.map { "المهمة **\($0)**" } ?? "مهمة")\(wsAr) قُوطعت.",
                .zh: "\(title.map { "任务 **\($0)**" } ?? "一个任务")\(wsZh)被中断。",
            ])

        case .botReply:
            return t(language, [
                .pt: "\(bot.map { "O **\($0)**" } ?? "Um Bot") respondeu\(wsNoPt)" + saidTail,
                .en: "\(bot.map { "**\($0)**" } ?? "A Bot") replied\(wsEn)" + saidTail,
                .es: "\(bot.map { "El **\($0)**" } ?? "Un Bot") respondió\(wsEs)" + saidTail,
                .fr: "\(bot.map { "Le **\($0)**" } ?? "Un Bot") a répondu\(wsFr)" + saidTail,
                .ar: "\(bot.map { "**\($0)**" } ?? "أحد الـ Bots") ردّ\(wsAr)" + saidTail,
                .zh: "\(bot.map { "**\($0)**" } ?? "一个 Bot")回复了\(wsZh)" + saidTail,
            ])

        case .approval:
            let verb = approvalVerb(kind: f.requestKind, requestTitle: f.requestTitle, language: language)
            let code = approvalSnippet(f.detail).map { $0.replacingOccurrences(of: "`", with: "'") }
            let codePart = code.map { " (`\($0)`)" } ?? ""
            return t(language, [
                .pt: "O agente\(title.map { " de **\($0)**" } ?? "")\(wsNoPt) quer \(verb)\(codePart).",
                .en: "The agent\(title.map { " on **\($0)**" } ?? "")\(wsEn) wants to \(verb)\(codePart).",
                .es: "El agente\(title.map { " de **\($0)**" } ?? "")\(wsEs) quiere \(verb)\(codePart).",
                .fr: "L'agent\(title.map { " de **\($0)**" } ?? "")\(wsFr) veut \(verb)\(codePart).",
                .ar: "الوكيل\(title.map { " في **\($0)**" } ?? "")\(wsAr) يريد \(verb)\(codePart).",
                .zh: "代理\(title.map { "（**\($0)**）" } ?? "")\(wsZh)想要\(verb)\(codePart)。",
            ])

        case .userInput:
            let prompt = clean(f.prompt, max: 200)
            let subject = t(language, [
                .pt: "O agente\(title.map { " de **\($0)**" } ?? "")\(wsNoPt)",
                .en: "The agent\(title.map { " on **\($0)**" } ?? "")\(wsEn)",
                .es: "El agente\(title.map { " de **\($0)**" } ?? "")\(wsEs)",
                .fr: "L'agent\(title.map { " de **\($0)**" } ?? "")\(wsFr)",
                .ar: "الوكيل\(title.map { " في **\($0)**" } ?? "")\(wsAr)",
                .zh: "代理\(title.map { "（**\($0)**）" } ?? "")\(wsZh)",
            ])
            switch f.userInputShape {
            case .options, .freeText:
                return t(language, [
                    .pt: subject + (prompt.map { " perguntou: *\($0)*" } ?? " fez uma pergunta."),
                    .en: subject + (prompt.map { " asks: *\($0)*" } ?? " has a question."),
                    .es: subject + (prompt.map { " pregunta: *\($0)*" } ?? " tiene una pregunta."),
                    .fr: subject + (prompt.map { " demande : *\($0)*" } ?? " a une question."),
                    .ar: subject + (prompt.map { " يسأل: *\($0)*" } ?? " لديه سؤال."),
                    .zh: subject + (prompt.map { "问：*\($0)*" } ?? "有一个问题。"),
                ])
            case .secret, .multiQuestion:
                let secret = f.userInputShape == .secret
                return t(language, [
                    .pt: "\(subject) precisa de \(secret ? "um segredo" : "algumas respostas"), que só dá para responder na conversa.",
                    .en: "\(subject) needs \(secret ? "a secret" : "a few answers"), which can only be answered in the thread.",
                    .es: "\(subject) necesita \(secret ? "un secreto" : "algunas respuestas"), que solo se pueden dar en la conversación.",
                    .fr: "\(subject) a besoin de \(secret ? "un secret" : "quelques réponses"), qui ne peuvent être données que dans la conversation.",
                    .ar: "\(subject) يحتاج إلى \(secret ? "سر" : "بعض الإجابات")، ولا يمكن الإجابة إلا في المحادثة.",
                    .zh: "\(subject)需要\(secret ? "一个密钥" : "几条回答")，只能在对话中作答。",
                ])
            }

        case .manualAction:
            let who = bot ?? title
            return t(language, [
                .pt: "\(who.map { "O **\($0)**" } ?? "O agente") está esperando você fazer algo no Mac\(detail.map { ": \($0)" } ?? "").",
                .en: "\(who.map { "**\($0)**" } ?? "The agent") is waiting for you to do something on the Mac\(detail.map { ": \($0)" } ?? "").",
                .es: "\(who.map { "El **\($0)**" } ?? "El agente") está esperando que hagas algo en el Mac\(detail.map { ": \($0)" } ?? "").",
                .fr: "\(who.map { "Le **\($0)**" } ?? "L'agent") attend que vous fassiez quelque chose sur le Mac\(detail.map { " : \($0)" } ?? "").",
                .ar: "\(who.map { "**\($0)**" } ?? "الوكيل") ينتظر منك إجراءً على الـ Mac\(detail.map { ": \($0)" } ?? "").",
                .zh: "\(who.map { "**\($0)**" } ?? "代理")正在等你完成 Mac 上的一步操作\(detail.map { "：\($0)" } ?? "").",
            ])

        case .botQuestion:
            return t(language, [
                .pt: "\(bot.map { "O **\($0)**" } ?? "Um Bot") precisa de você" + (detail.map { ": *\($0)*" } ?? "."),
                .en: "\(bot.map { "**\($0)**" } ?? "A Bot") needs you" + (detail.map { ": *\($0)*" } ?? "."),
                .es: "\(bot.map { "El **\($0)**" } ?? "Un Bot") te necesita" + (detail.map { ": *\($0)*" } ?? "."),
                .fr: "\(bot.map { "Le **\($0)**" } ?? "Un Bot") a besoin de vous" + (detail.map { " : *\($0)*" } ?? "."),
                .ar: "\(bot.map { "**\($0)**" } ?? "أحد الـ Bots") يحتاج إليك" + (detail.map { ": *\($0)*" } ?? "."),
                .zh: "\(bot.map { "**\($0)**" } ?? "一个 Bot")需要你" + (detail.map { "：*\($0)*" } ?? "。"),
            ])

        case .botBlocked:
            return t(language, [
                .pt: "\(bot.map { "O **\($0)**" } ?? "Um Bot") travou\(detail.map { ": \($0)" } ?? "").",
                .en: "\(bot.map { "**\($0)**" } ?? "A Bot") got stuck\(detail.map { ": \($0)" } ?? "").",
                .es: "\(bot.map { "El **\($0)**" } ?? "Un Bot") se bloqueó\(detail.map { ": \($0)" } ?? "").",
                .fr: "\(bot.map { "Le **\($0)**" } ?? "Un Bot") s'est bloqué\(detail.map { " : \($0)" } ?? "").",
                .ar: "\(bot.map { "**\($0)**" } ?? "أحد الـ Bots") تعطّل\(detail.map { ": \($0)" } ?? "").",
                .zh: "\(bot.map { "**\($0)**" } ?? "一个 Bot")卡住了\(detail.map { "：\($0)" } ?? "").",
            ])

        case .scheduledFailed:
            let time = clock(item.occurredAt, language: language, timeZone: timeZone)
            return t(language, [
                .pt: "A rotina\(title.map { " **\($0)**" } ?? "")\(wsPt) falhou às \(time).",
                .en: "Scheduled task\(title.map { " **\($0)**" } ?? "")\(wsEn) failed at \(time).",
                .es: "La rutina\(title.map { " **\($0)**" } ?? "")\(wsEs) falló a las \(time).",
                .fr: "La tâche planifiée\(title.map { " **\($0)**" } ?? "")\(wsFr) a échoué à \(time).",
                .ar: "المهمة المجدولة\(title.map { " **\($0)**" } ?? "")\(wsAr) فشلت في \(time).",
                .zh: "定时任务\(title.map { " **\($0)**" } ?? "")\(wsZh)在 \(time) 失败。",
            ])

        case .gitFailed:
            return t(language, [
                .pt: "O `git push`\(wsPt) falhou\(f.exitCode.map { " (código \($0))" } ?? "").",
                .en: "`git push`\(wsEn) failed\(f.exitCode.map { " (exit \($0))" } ?? "").",
                .es: "`git push`\(wsEs) falló\(f.exitCode.map { " (código \($0))" } ?? "").",
                .fr: "`git push`\(wsFr) a échoué\(f.exitCode.map { " (code \($0))" } ?? "").",
                .ar: "`git push`\(wsAr) فشل\(f.exitCode.map { " (الرمز \($0))" } ?? "").",
                .zh: "`git push`\(wsZh)失败\(f.exitCode.map { "（退出码 \($0)）" } ?? "").",
            ])

        case .gitCompleted:
            return t(language, [
                .pt: "O push\(wsPt) foi feito.",
                .en: "The push\(wsEn) went through.",
                .es: "Se hizo el push\(wsEs).",
                .fr: "Le push\(wsFr) est passé.",
                .ar: "تم الدفع\(wsAr).",
                .zh: "推送\(wsZh)已完成。",
            ])

        case .scriptFailed:
            return t(language, [
                .pt: "O script\(title.map { " **\($0)**" } ?? "")\(wsPt) " + (f.exitCode.map { "saiu com código \($0)." } ?? "falhou."),
                .en: "\(title.map { "Script **\($0)**" } ?? "A script")\(wsEn) " + (f.exitCode.map { "exited with code \($0)." } ?? "failed."),
                .es: "\(title.map { "El script **\($0)**" } ?? "Un script")\(wsEs) " + (f.exitCode.map { "salió con código \($0)." } ?? "falló."),
                .fr: "\(title.map { "Le script **\($0)**" } ?? "Un script")\(wsFr) " + (f.exitCode.map { "s'est terminé avec le code \($0)." } ?? "a échoué."),
                .ar: "\(title.map { "السكربت **\($0)**" } ?? "سكربت")\(wsAr) " + (f.exitCode.map { "خرج بالرمز \($0)." } ?? "فشل."),
                .zh: "\(title.map { "脚本 **\($0)**" } ?? "一个脚本")\(wsZh)" + (f.exitCode.map { "以退出码 \($0) 结束。" } ?? "失败。"),
            ])

        case .scriptCompleted:
            return t(language, [
                .pt: "O script\(title.map { " **\($0)**" } ?? "")\(wsPt) terminou bem.",
                .en: "\(title.map { "Script **\($0)**" } ?? "A script")\(wsEn) finished fine.",
                .es: "\(title.map { "El script **\($0)**" } ?? "Un script")\(wsEs) terminó bien.",
                .fr: "\(title.map { "Le script **\($0)**" } ?? "Un script")\(wsFr) s'est bien terminé.",
                .ar: "\(title.map { "السكربت **\($0)**" } ?? "سكربت")\(wsAr) انتهى بنجاح.",
                .zh: "\(title.map { "脚本 **\($0)**" } ?? "一个脚本")\(wsZh)正常结束。",
            ])

        case .transferFailed, .transferCompleted:
            let failed = item.kind == .transferFailed
            return t(language, [
                .pt: "A transferência SSH\(title.map { " **\($0)**" } ?? "") \(failed ? "falhou" : "terminou").",
                .en: "\(title.map { "SSH transfer **\($0)**" } ?? "An SSH transfer") \(failed ? "failed" : "finished").",
                .es: "\(title.map { "La transferencia SSH **\($0)**" } ?? "Una transferencia SSH")\(wsEs) \(failed ? "falló" : "terminó").",
                .fr: "\(title.map { "Le transfert SSH **\($0)**" } ?? "Un transfert SSH")\(wsFr) \(failed ? "a échoué" : "s'est terminé").",
                .ar: "\(title.map { "نقل SSH **\($0)**" } ?? "نقل SSH")\(wsAr) \(failed ? "فشل" : "اكتمل").",
                .zh: "\(title.map { "SSH 传输 **\($0)**" } ?? "一次 SSH 传输")\(wsZh)\(failed ? "失败" : "已完成")。",
            ])

        case .sshDisconnected:
            return t(language, [
                .pt: "A sessão SSH\(title.map { " **\($0)**" } ?? "") caiu sem você pedir.",
                .en: "\(title.map { "SSH session **\($0)**" } ?? "An SSH session") dropped unexpectedly.",
                .es: "La sesión SSH\(title.map { " **\($0)**" } ?? "")\(wsEs) se cayó sin que lo pidieras.",
                .fr: "La session SSH\(title.map { " **\($0)**" } ?? "")\(wsFr) s'est interrompue sans que vous le demandiez.",
                .ar: "جلسة SSH\(title.map { " **\($0)**" } ?? "")\(wsAr) انقطعت دون طلبك.",
                .zh: "SSH 会话\(title.map { " **\($0)**" } ?? "")\(wsZh)意外断开。",
            ])

        case .fileConflict:
            return t(language, [
                .pt: "\(title.map { "**\($0)**" } ?? "Um arquivo") foi alterado fora do editor enquanto você editava.",
                .en: "\(title.map { "**\($0)**" } ?? "A file") changed outside the editor while you were editing.",
                .es: "\(title.map { "**\($0)**" } ?? "Un archivo") cambió fuera del editor mientras lo editabas.",
                .fr: "\(title.map { "**\($0)**" } ?? "Un fichier") a changé en dehors de l'éditeur pendant que vous l'éditiez.",
                .ar: "\(title.map { "**\($0)**" } ?? "ملف") تغيّر خارج المحرر أثناء تحريرك.",
                .zh: "\(title.map { "**\($0)**" } ?? "一个文件")在编辑期间被编辑器外改动。",
            ])

        case .serverListenerFailed:
            return t(language, [
                .pt: "O servidor do MacCode não conseguiu abrir a porta\(f.port.map { " \($0)" } ?? ""), então o iPhone pode não conectar.",
                .en: "MacCode's server could not open \(f.port.map { "port \($0)" } ?? "its port"), so your iPhone may not connect.",
                .es: "El servidor de MacCode no pudo abrir \(f.port.map { "el puerto \($0)" } ?? "su puerto"), así que tu iPhone podría no conectar.",
                .fr: "Le serveur de MacCode n'a pas pu ouvrir \(f.port.map { "le port \($0)" } ?? "son port"), donc votre iPhone pourrait ne pas se connecter.",
                .ar: "لم يتمكن خادم MacCode من فتح \(f.port.map { "المنفذ \($0)" } ?? "منفذه")، لذا قد لا يتصل الـ iPhone.",
                .zh: "MacCode 服务器无法打开\(f.port.map { "端口 \($0)" } ?? "其端口")，iPhone 可能无法连接。",
            ])

        case .providerUpdateFailed:
            return t(language, [
                .pt: "A atualização\(title.map { " do **\($0)**" } ?? "") falhou.",
                .en: "The \(title.map { "**\($0)** " } ?? "")update failed.",
                .es: "La actualización\(title.map { " de **\($0)**" } ?? "") falló.",
                .fr: "La mise à jour\(title.map { " de **\($0)**" } ?? "") a échoué.",
                .ar: "فشل التحديث\(title.map { " الخاص بـ **\($0)**" } ?? "").",
                .zh: "\(title.map { "**\($0)** " } ?? "")更新失败。",
            ])

        case .notificationsDenied:
            return t(language, [
                .pt: "As notificações do sistema estão desligadas para o MacCode, então eu só aviso por aqui e no pet.",
                .en: "System notifications are off for MacCode, so I'll only tell you here and from the pet.",
                .es: "Las notificaciones del sistema están desactivadas para MacCode, así que solo te aviso aquí y desde el pet.",
                .fr: "Les notifications système sont désactivées pour MacCode, je ne vous préviendrai donc qu'ici et depuis le pet.",
                .ar: "إشعارات النظام متوقفة لـ MacCode، لذا سأنبهك هنا وفي pet فقط.",
                .zh: "MacCode 的系统通知已关闭，所以我只在这里和 pet 里通知你。",
            ])

        case .external:
            let body = clean(f.body, max: 300)
            switch (title, body) {
            case let (title?, body?): return "**\(title)**\n\(body)"
            case let (title?, nil): return "**\(title)**"
            case let (nil, body?): return body
            case (nil, nil): return t(language, [.pt: "Chegou um aviso.", .en: "A notice arrived.", .es: "Llegó un aviso.", .fr: "Une notification est arrivée.", .ar: "وصل إشعار.", .zh: "收到一条通知。"])
            }
        }
    }

    /// The first sentence of a run summary as plain text, so a fallback names the result without cutting Markdown.
    static func summarySentence(_ summary: String?) -> String? {
        guard let summary else { return nil }
        let sentence = TitioVoiceOutput.firstSentence(BackgroundAwaitContinuation.strippingAwaitingMarker(summary), maxCharacters: 160)
        return sentence.isEmpty ? nil : sentence
    }

    // MARK: Card

    /// Card option label (§6 "Card option labels"). Provider and Bot options show their own text.
    public static func label(for action: TitioNoticeAction, language: TitioNoticeLanguage, botName: String? = nil) -> String {
        switch action {
        case .approve: return t(language, [.pt: "Aprovar", .en: "Approve", .es: "Aprobar", .fr: "Approuver", .ar: "موافقة", .zh: "批准"])
        case .approveSession: return t(language, [.pt: "Aprovar nesta sessão", .en: "Approve for session", .es: "Aprobar para esta sesión", .fr: "Approuver pour la session", .ar: "موافقة لهذه الجلسة", .zh: "本次会话内批准"])
        case .decline: return t(language, [.pt: "Recusar", .en: "Decline", .es: "Rechazar", .fr: "Refuser", .ar: "رفض", .zh: "拒绝"])
        case let .providerOption(_, text): return text
        case let .botOption(text): return text
        case .continue: return t(language, [.pt: "Continuar", .en: "Continue", .es: "Continuar", .fr: "Continuer", .ar: "متابعة", .zh: "继续"])
        case .rerun: return t(language, [.pt: "Rodar de novo", .en: "Run again", .es: "Ejecutar de nuevo", .fr: "Relancer", .ar: "تشغيل مجددًا", .zh: "重新运行"])
        case .ack: return t(language, [.pt: "Entendi", .en: "Got it", .es: "Entendido", .fr: "Compris", .ar: "فهمت", .zh: "知道了"])
        case .replyHere: return t(language, [.pt: "Responder aqui", .en: "Reply here", .es: "Responder aquí", .fr: "Répondre ici", .ar: "الرد هنا", .zh: "在此回复"])
        case .openThread: return t(language, [.pt: "Abrir conversa", .en: "Open conversation", .es: "Abrir conversación", .fr: "Ouvrir la conversation", .ar: "فتح المحادثة", .zh: "打开对话"])
        case .openBot: return t(language, [.pt: "Abrir conversa", .en: "Open conversation", .es: "Abrir conversación", .fr: "Ouvrir la conversation", .ar: "فتح المحادثة", .zh: "打开对话"])
        case .openActivity: return t(language, [.pt: "Ver na Atividade", .en: "View in Activity", .es: "Ver en Actividad", .fr: "Voir dans Activité", .ar: "عرض في النشاط", .zh: "在活动中查看"])
        case .openAllActivity: return t(language, [.pt: "Ver tudo na Atividade", .en: "See all in Activity", .es: "Ver todo en Actividad", .fr: "Tout voir dans Activité", .ar: "عرض الكل في النشاط", .zh: "在活动中查看全部"])
        }
    }

    /// Labels in display order, trimmed and de-duplicated exactly like
    /// `BotChoicesBlock.parse`, so `option_index` on the card maps 1:1 to the stored action.
    public static func labeledOptions(_ actions: [TitioNoticeAction], language: TitioNoticeLanguage, botName: String?) -> [TitioNoticeCardOption] {
        var seen = Set<String>()
        var result: [TitioNoticeCardOption] = []
        for action in actions {
            let text = label(for: action, language: language, botName: botName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            result.append(TitioNoticeCardOption(label: text, action: action))
            if result.count == BotChoicesBlock.maximumOptions { break }
        }
        return result
    }

    public static func sourceLabels(_ facts: TitioNoticeFacts) -> [String: String] {
        ["workspace": facts.workspaceName, "bot": facts.botName, "conversation": facts.title]
            .compactMapValues { $0 }
    }

    /// The ```choices fence with `{"question","options","notice"}` (sorted keys, one line).
    public static func choicesBlock(question: String?, options: [String], notice: String, source: [String: String] = [:], canReply: Bool = false) -> String {
        var object: [String: Any] = ["options": options, "notice": notice]
        if let question { object["question"] = question }
        if !source.isEmpty { object["source"] = source }
        if canReply { object["can_reply"] = true }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return "```choices\n" + (String(data: data, encoding: .utf8) ?? "{}") + "\n```"
    }

    /// Cards stack at the bottom of the inbox, away from their messages, so
    /// each one names its subject: "elephant · Fix login: rodar um comando
    /// (npm install)?" instead of a generic "O que deseja fazer?" that two
    /// pending approvals would share.
    static func cardQuestion(for item: TitioNoticeRenderItem, language: TitioNoticeLanguage) -> String {
        let f = item.facts
        let picksAnOption = item.actions?.contains {
            if case .providerOption = $0 { return true }
            if case .botOption = $0 { return true }
            return false
        } ?? false
        let generic = picksAnOption ? t(language, [.pt: "Qual opção?", .en: "Which option?", .es: "¿Qué opción?", .fr: "Quelle option ?", .ar: "أي خيار؟", .zh: "选哪个？"]) : t(language, [.pt: "O que deseja fazer?", .en: "What should I do?", .es: "¿Qué hago?", .fr: "Que dois-je faire ?", .ar: "ماذا أفعل؟", .zh: "我该怎么做？"])
        let named: String?
        switch item.kind {
        case .botQuestion, .botBlocked, .manualAction:
            named = clean(f.botName, max: 60) ?? clean(f.title, max: 60)
        default:
            named = clean(f.title, max: 60)
        }
        let subject = [clean(f.workspaceName, max: 40), named].compactMap { $0 }.joined(separator: " · ")
        let ask: String
        switch item.kind {
        case .approval:
            let verb = approvalVerb(kind: f.requestKind, requestTitle: f.requestTitle, language: language)
            ask = verb + (approvalSnippet(f.detail).map { " (\(clip($0, max: 60)))" } ?? "") + "?"
        case .userInput, .botQuestion:
            ask = (f.prompt ?? f.detail)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? generic
        default:
            ask = generic
        }
        guard !subject.isEmpty else { return ask }
        return "\(subject): \(ask)"
    }

    /// What the agent wants to do, as a verb phrase from the request kind.
    /// Provider titles ("Command approval", "Bash") are labels, not verbs, so
    /// they never fill the verb slot; a tool name only names the tool.
    static func approvalVerb(kind: String?, requestTitle: String?, language: TitioNoticeLanguage) -> String {
        switch kind {
        case "commandExecution", "exec":
            return t(language, [.pt: "rodar um comando", .en: "run a command", .es: "ejecutar un comando", .fr: "exécuter une commande", .ar: "تنفيذ أمر", .zh: "执行命令"])
        case "fileChange", "applyPatch":
            return t(language, [.pt: "alterar arquivos", .en: "change files", .es: "cambiar archivos", .fr: "modifier des fichiers", .ar: "تعديل ملفات", .zh: "修改文件"])
        case "fileRead":
            return t(language, [.pt: "ler um arquivo", .en: "read a file", .es: "leer un archivo", .fr: "lire un fichier", .ar: "قراءة ملف", .zh: "读取文件"])
        case "authTokensRefresh":
            return t(language, [.pt: "renovar o acesso", .en: "refresh its sign-in", .es: "renovar su acceso", .fr: "renouveler sa connexion", .ar: "تجديد تسجيل الدخول", .zh: "刷新登录"])
        case "toolUserInput", "dynamic":
            if let tool = clean(requestTitle, max: 40), !tool.contains(" ") {
                return t(language, [.pt: "usar a ferramenta \(tool)", .en: "use the \(tool) tool", .es: "usar la herramienta \(tool)", .fr: "utiliser l'outil \(tool)", .ar: "استخدام أداة \(tool)", .zh: "使用 \(tool) 工具"])
            }
            return t(language, [.pt: "usar uma ferramenta", .en: "use a tool", .es: "usar una herramienta", .fr: "utiliser un outil", .ar: "استخدام أداة", .zh: "使用工具"])
        default:
            return t(language, [.pt: "executar uma ação", .en: "take an action", .es: "ejecutar una acción", .fr: "effectuer une action", .ar: "تنفيذ إجراء", .zh: "执行操作"])
        }
    }

    /// The command or path an approval is about, never a raw JSON dump: a
    /// tool-input JSON object yields its `command` (or path/url/pattern).
    static func approvalSnippet(_ detail: String?) -> String? {
        guard let raw = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("{") {
            guard let data = raw.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            for key in ["command", "cmd", "file_path", "path", "url", "pattern"] {
                if let text = object[key] as? String { return clean(text, max: 200) }
                if let parts = object[key] as? [String] { return clean(parts.joined(separator: " "), max: 200) }
            }
            return nil
        }
        return clean(raw, max: 200)
    }

    // MARK: Digest

    /// Failures first, then the rest; each group by `occurredAt` (key breaks ties).
    public static func digestOrder(_ items: [TitioNoticeRenderItem]) -> [TitioNoticeRenderItem] {
        let byTime: (TitioNoticeRenderItem, TitioNoticeRenderItem) -> Bool = {
            $0.occurredAt == $1.occurredAt ? $0.key < $1.key : $0.occurredAt < $1.occurredAt
        }
        return items.filter { $0.kind.isFailure }.sorted(by: byTime) + items.filter { !$0.kind.isFailure }.sorted(by: byTime)
    }

    /// `**{workspace}** · {title}: {state}{ ({duration})}`.
    public static func digestLine(_ item: TitioNoticeRenderItem, language: TitioNoticeLanguage) -> String {
        let ws = clean(item.facts.workspaceName, max: 80).map { "**\($0)** · " } ?? ""
        let duration = item.facts.durationMs.map { " (\(self.duration(ms: $0, language: language)))" } ?? ""
        // An external notice keeps the caller's own words, not a bare "ok".
        if item.kind == .external, let body = clean(item.facts.body, max: 80) {
            return "\(ws)\(digestTitle(item, language: language)): “\(body)”"
        }
        return "\(ws)\(digestTitle(item, language: language)): \(digestState(item.kind, language: language))\(duration)"
    }

    static func digestTitle(_ item: TitioNoticeRenderItem, language: TitioNoticeLanguage) -> String {
        let f = item.facts
        let named: String?
        switch item.kind {
        case .botReply, .botQuestion, .botBlocked, .manualAction:
            named = clean(f.botName, max: 80) ?? clean(f.title, max: 120)
        default:
            named = clean(f.title, max: 120)
        }
        if let named { return named }
        switch item.kind {
        case .runCompleted, .runFailed, .runInterrupted: return t(language, [.pt: "tarefa", .en: "task", .es: "tarea", .fr: "tâche", .ar: "مهمة", .zh: "任务"])
        case .botReply, .botQuestion, .botBlocked: return "Bot"
        case .approval, .userInput, .manualAction: return t(language, [.pt: "pedido", .en: "request", .es: "solicitud", .fr: "demande", .ar: "طلب", .zh: "请求"])
        case .scheduledFailed: return t(language, [.pt: "rotina", .en: "scheduled task", .es: "tarea programada", .fr: "tâche planifiée", .ar: "مهمة مجدولة", .zh: "定时任务"])
        case .gitFailed, .gitCompleted: return "git push"
        case .scriptFailed, .scriptCompleted: return "script"
        case .transferFailed, .transferCompleted: return t(language, [.pt: "transferência SSH", .en: "SSH transfer", .es: "transferencia SSH", .fr: "transfert SSH", .ar: "نقل SSH", .zh: "SSH 传输"])
        case .sshDisconnected: return t(language, [.pt: "sessão SSH", .en: "SSH session", .es: "sesión SSH", .fr: "session SSH", .ar: "جلسة SSH", .zh: "SSH 会话"])
        case .fileConflict: return t(language, [.pt: "arquivo", .en: "file", .es: "archivo", .fr: "fichier", .ar: "ملف", .zh: "文件"])
        case .serverListenerFailed: return t(language, [.pt: "servidor", .en: "server", .es: "servidor", .fr: "serveur", .ar: "الخادم", .zh: "服务器"])
        case .providerUpdateFailed: return t(language, [.pt: "atualização", .en: "update", .es: "actualización", .fr: "mise à jour", .ar: "تحديث", .zh: "更新"])
        case .notificationsDenied: return t(language, [.pt: "notificações", .en: "notifications", .es: "notificaciones", .fr: "notifications", .ar: "إشعارات", .zh: "通知"])
        case .external: return t(language, [.pt: "aviso", .en: "notice", .es: "aviso", .fr: "notification", .ar: "إشعار", .zh: "通知"])
        }
    }

    static func digestState(_ kind: TitioNoticeKind, language: TitioNoticeLanguage) -> String {
        switch kind {
        case .runCompleted: return t(language, [.pt: "concluída", .en: "done", .es: "completada", .fr: "terminée", .ar: "مكتملة", .zh: "已完成"])
        case .runInterrupted: return t(language, [.pt: "interrompida", .en: "interrupted", .es: "interrumpida", .fr: "interrompue", .ar: "مقاطعة", .zh: "已中断"])
        case .approval, .userInput, .manualAction, .botQuestion, .fileConflict: return t(language, [.pt: "precisa de você", .en: "needs you", .es: "te necesita", .fr: "a besoin de vous", .ar: "يحتاج إليك", .zh: "需要你"])
        case .botReply: return t(language, [.pt: "respondeu", .en: "replied", .es: "respondió", .fr: "a répondu", .ar: "ردّ", .zh: "已回复"])
        case .external: return t(language, [.pt: "aviso", .en: "notice", .es: "aviso", .fr: "notification", .ar: "إشعار", .zh: "通知"])
        default: return kind.isFailure ? (t(language, [.pt: "falhou", .en: "failed", .es: "falló", .fr: "a échoué", .ar: "فشل", .zh: "失败"])) : "ok"
        }
    }

    // MARK: Result and status lines

    public static func resultLine(_ result: TitioNoticeResult, language: TitioNoticeLanguage) -> String {
        func ws(_ value: String?, _ ptPrefix: String) -> String {
            guard let value = clean(value, max: 80) else { return "" }
            return t(language, [.pt: " \(ptPrefix) **\(value)**", .en: " in **\(value)**", .es: " en **\(value)**", .fr: " dans **\(value)**", .ar: " في **\(value)**", .zh: "（**\(value)**）"])
        }
        func target(_ target: TitioNoticeReplyTarget) -> String {
            switch target {
            case let .agent(workspace):
                return t(language, [.pt: "o agente", .en: "the agent", .es: "el agente", .fr: "l'agent", .ar: "الوكيل", .zh: "代理"]) + ws(workspace, "do")
            case let .bot(name):
                guard let name = clean(name, max: 80) else { return t(language, [.pt: "o Bot", .en: "the Bot", .es: "el Bot", .fr: "le Bot", .ar: "الـ Bot", .zh: "该 Bot"]) }
                return t(language, [.pt: "o **\(name)**", .en: "**\(name)**", .es: "el **\(name)**", .fr: "le **\(name)**", .ar: "**\(name)**", .zh: "**\(name)**"])
            }
        }
        switch result {
        case let .approved(workspace):
            return t(language, [.pt: "Aprovei\(ws(workspace, "no")).", .en: "Approved\(ws(workspace, "no")).", .es: "Aprobé\(ws(workspace, "en")).", .fr: "Approuvé\(ws(workspace, "dans")).", .ar: "تمت الموافقة\(ws(workspace, "في")).", .zh: "已批准\(ws(workspace, "于"))."])
        case let .approvedSession(workspace):
            return t(language, [.pt: "Aprovei para esta sessão\(ws(workspace, "no")).", .en: "Approved for this session\(ws(workspace, "no")).", .es: "Aprobé para esta sesión\(ws(workspace, "en")).", .fr: "Approuvé pour cette session\(ws(workspace, "dans")).", .ar: "تمت الموافقة لهذه الجلسة\(ws(workspace, "في")).", .zh: "已批准本次会话\(ws(workspace, "于"))."])
        case let .declined(workspace):
            return t(language, [.pt: "Recusei e o agente\(ws(workspace, "do")) foi avisado.", .en: "Declined, and the agent\(ws(workspace, "do")) was told.", .es: "Rechacé y se avisó al agente\(ws(workspace, "en")).", .fr: "Refusé, et l'agent\(ws(workspace, "dans")) a été prévenu.", .ar: "رفضت وأُبلغ الوكيل\(ws(workspace, "في")).", .zh: "已拒绝，并已通知代理\(ws(workspace, "于"))."])
        case let .answered(answer, to):
            let quoted = clean(answer, max: summaryMaxCharacters) ?? ""
            return t(language, [.pt: "Repassei “\(quoted)” para \(target(to)).", .en: "Passed “\(quoted)” to \(target(to)).", .es: "Pasé «\(quoted)» a \(target(to)).", .fr: "J'ai transmis « \(quoted) » à \(target(to)).", .ar: "نقلت «\(quoted)» إلى \(target(to)).", .zh: "已把“\(quoted)”转给\(target(to))。"])
        case let .armed(to):
            return t(language, [.pt: "Eu repasso sua próxima mensagem para \(target(to)).", .en: "I'll pass your next message to \(target(to)).", .es: "Pasaré tu próximo mensaje a \(target(to)).", .fr: "Je transmettrai votre prochain message à \(target(to)).", .ar: "سأنقل رسالتك التالية إلى \(target(to)).", .zh: "我会把你下一条消息转给\(target(to))。"])
        case let .continued(title):
            let name = clean(title, max: 120).map { "**\($0)**" }
            return t(language, [.pt: "Pedi para continuar \(name ?? "a tarefa").", .en: "Asked \(name ?? "the task") to continue.", .es: "Pedí que continuara \(name ?? "la tarea").", .fr: "J'ai demandé à \(name ?? "la tâche") de continuer.", .ar: "طلبت من \(name ?? "المهمة") المتابعة.", .zh: "已请求继续 \(name ?? "该任务")。"])
        case let .rerun(task):
            let name = clean(task, max: 120).map { "**\($0)**" }
            return t(language, [.pt: "Rodando \(name ?? "a rotina") de novo.", .en: "Running \(name ?? "the scheduled task") again.", .es: "Ejecutando \(name ?? "la tarea programada") de nuevo.", .fr: "Relance de \(name ?? "la tâche planifiée").", .ar: "أعيد تشغيل \(name ?? "المهمة المجدولة").", .zh: "正在重新运行 \(name ?? "该定时任务")。"])
        case .alreadyResolved:
            return t(language, [.pt: "Isso já tinha sido resolvido ou expirou; não enviei nada.", .en: "That was already handled or expired; I sent nothing.", .es: "Eso ya se resolvió o expiró; no envié nada.", .fr: "C'était déjà traité ou expiré ; je n'ai rien envoyé.", .ar: "تم التعامل معه أو انتهت صلاحيته؛ لم أرسل شيئًا.", .zh: "该事项已处理或已过期，我没有发送任何内容。"])
        case let .failed(error):
            let reason = clean(error, max: 200) ?? t(language, [.pt: "erro desconhecido", .en: "unknown error", .es: "error desconocido", .fr: "erreur inconnue", .ar: "خطأ غير معروف", .zh: "未知错误"])
            return t(language, [.pt: "Não consegui enviar: \(reason). Abra a conversa para decidir por lá.", .en: "I couldn't send it: \(reason). Open the thread to decide there.", .es: "No pude enviarlo: \(reason). Abre la conversación para decidir allí.", .fr: "Je n'ai pas pu l'envoyer : \(reason). Ouvrez la conversation pour décider là-bas.", .ar: "لم أتمكن من الإرسال: \(reason). افتح المحادثة لتقرر هناك.", .zh: "发送失败：\(reason)。打开对话在那里决定。"])
        }
    }

    /// `done` and `failed` are not in the spec's status table; they cover
    /// continue/rerun and a host action that threw, so a resolved card never
    /// keeps a stale block.
    public static func statusLine(_ status: TitioNoticeStatus, language: TitioNoticeLanguage, at date: Date, timeZone: TimeZone = .current) -> String {
        let time = clock(date, language: language, timeZone: timeZone)
        switch status {
        case .approved: return t(language, [.pt: "_Aprovado por você às \(time)._", .en: "_Approved by you at \(time)._", .es: "_Aprobado por ti a las \(time)._ ", .fr: "_Approuvé par vous à \(time)._ ", .ar: "_تمت الموافقة منك في \(time)._ ", .zh: "_你已在 \(time) 批准。_ "])
        case .declined: return t(language, [.pt: "_Recusado às \(time)._", .en: "_Declined at \(time)._", .es: "_Rechazado a las \(time)._ ", .fr: "_Refusé à \(time)._ ", .ar: "_رُفض في \(time)._ ", .zh: "_已在 \(time) 拒绝。_ "])
        case .answered: return t(language, [.pt: "_Respondido às \(time)._", .en: "_Answered at \(time)._", .es: "_Respondido a las \(time)._ ", .fr: "_Répondu à \(time)._ ", .ar: "_تم الرد في \(time)._ ", .zh: "_已在 \(time) 回复。_ "])
        case .elsewhere: return t(language, [.pt: "_Resolvido em outro lugar._", .en: "_Handled elsewhere._", .es: "_Resuelto en otro lugar._ ", .fr: "_Traité ailleurs._ ", .ar: "_تم التعامل معه في مكان آخر._ ", .zh: "_已在别处处理。_ "])
        case .expired: return t(language, [.pt: "_Expirou._", .en: "_Expired._", .es: "_Expiró._ ", .fr: "_Expiré._ ", .ar: "_انتهت الصلاحية._ ", .zh: "_已过期。_ "])
        case .acknowledged: return t(language, [.pt: "_Visto._", .en: "_Seen._", .es: "_Visto._ ", .fr: "_Vu._ ", .ar: "_تمت الرؤية._ ", .zh: "_已查看。_ "])
        case .done: return t(language, [.pt: "_Feito às \(time)._", .en: "_Done at \(time)._", .es: "_Hecho a las \(time)._ ", .fr: "_Fait à \(time)._ ", .ar: "_تم في \(time)._ ", .zh: "_已在 \(time) 完成。_ "])
        case .failed: return t(language, [.pt: "_Não deu certo; abra a conversa._", .en: "_Didn't go through; open the thread._", .es: "_No funcionó; abre la conversación._ ", .fr: "_N'a pas abouti ; ouvrez la conversation._ ", .ar: "_لم ينجح؛ افتح المحادثة._ ", .zh: "_未成功；打开对话。_ "])
        case .unknownEffect: return t(language, [.pt: "_Resultado não confirmado; confira a origem antes de tentar novamente._", .en: "_Outcome unconfirmed; check the source before trying again._", .es: "_Resultado sin confirmar; revisa el origen antes de reintentar._ ", .fr: "_Résultat non confirmé ; vérifiez la source avant de réessayer._ ", .ar: "_النتيجة غير مؤكدة؛ تحقق من المصدر قبل المحاولة مجددًا._ ", .zh: "_结果未确认；重试前请核对来源。_ "])
        }
    }

    /// The original message with its ```choices block removed and the status
    /// line appended (nil: the card is only removed; the voice adds the line).
    /// The ```notice block, when present, stays last, after the status line.
    public static func resolvedText(original: String, statusLine: String?) -> String {
        let notice = TitioNoticeBlock.parse(original)
        let parsed = BotChoicesBlock.parse(notice.text)
        var base = trimmedTrailing(parsed.choices != nil ? parsed.text : notice.text)
        if let statusLine, !statusLine.isEmpty, !base.hasSuffix(statusLine) {
            base += "\n\n" + statusLine
        }
        guard let block = notice.block else { return base }
        let fence = TitioNoticeBlock.render(key: block.key, kind: block.kind, source: block.source, state: block.state)
        return base.isEmpty ? fence : base + "\n\n" + fence
    }

    // MARK: Misc copy

    /// The dedicated inbox conversation title.
    public static func inboxTitle(language: TitioNoticeLanguage) -> String {
        t(language, [.pt: "Notificações", .en: "Notifications", .es: "Notificaciones", .fr: "Notifications", .ar: "الإشعارات", .zh: "通知"])
    }

    /// Titio's own replies get only this banner: title "Titio", body = first line of the reply.
    public static func directReplyBanner(replyText: String) -> (title: String, body: String) {
        (bannerTitle, preview(replyText))
    }

    /// The first visible line as plain text (`MarkdownPlainText`), max 178 chars.
    public static func preview(_ text: String) -> String {
        MarkdownPlainText.firstLine(text, maxCharacters: previewMaxCharacters)
    }

    // MARK: Formatting

    /// pt "10,4 s" / "2 min"; en "10.4s" / "2 min"; an hour or more is "1 h 5 min".
    public static func duration(ms: Int, language: TitioNoticeLanguage) -> String {
        let tenths = (Double(max(0, ms)) / 100).rounded()
        if tenths < 600 {
            var number = String(format: "%.1f", tenths / 10)
            if number.hasSuffix(".0") { number.removeLast(2) }
            // Commons use a decimal comma; Arabic and Chinese spell the unit out
            // (es/fr "10,4 s", ar "10.4 ث", zh "10.4 秒").
            switch language {
            case .pt, .es, .fr: return number.replacingOccurrences(of: ".", with: ",") + " s"
            case .ar: return number + " ث"
            case .zh: return number + " 秒"
            case .en: return number + "s"
            }
        }
        let minutes = Int((Double(ms) / 60_000).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// pt "HH:mm", en "h:mm a".
    public static func clock(_ date: Date, language: TitioNoticeLanguage, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .en ? "en_US_POSIX" : "pt_BR")
        formatter.timeZone = timeZone
        // Only English reads a 12-hour clock; the other supported languages use 24-hour time.
        formatter.dateFormat = language == .en ? "h:mm a" : "HH:mm"
        return formatter.string(from: date)
    }

    /// One line (newlines and runs of spaces collapsed), trimmed, clipped; nil when empty.
    /// Keeping facts on one line also stops a fact from forging a ```choices fence.
    static func clean(_ value: String?, max: Int) -> String? {
        guard let value else { return nil }
        let flat = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return flat.isEmpty ? nil : clip(flat, max: max)
    }

    static func clip(_ text: String, max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max - 1)) + "…"
    }

    private static func trimmedTrailing(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }
}
