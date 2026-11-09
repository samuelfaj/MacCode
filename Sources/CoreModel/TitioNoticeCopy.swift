import Foundation
import NaturalLanguage

/// Language of one Titio notice message, decided once per message at flush time.
public enum TitioNoticeLanguage: String, CaseIterable, Sendable {
    case ptBR = "pt-BR"
    case en
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

    // MARK: Language (§16)

    /// pt-BR or en for one message: the dominant language of the user's most
    /// recent message to Titio; with no usable text (none yet, too short or
    /// ambiguous), the first preferred system language (`pt*` → pt-BR, else en).
    public static func language(lastUserText: String?, preferredLanguages: [String]) -> TitioNoticeLanguage {
        if let detected = detectedLanguage(lastUserText) { return detected }
        return preferredLanguages.first?.lowercased().hasPrefix("pt") == true ? .ptBR : .en
    }

    /// The §16 rule over the user's recent Titio messages, newest first: the
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

    /// pt-BR / en when the recognizer is confident, else nil.
    public static func detectedLanguage(_ text: String?) -> TitioNoticeLanguage? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.portuguese, .english]
        recognizer.processString(String(text.prefix(2_000)))
        guard let best = recognizer.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }),
              best.value >= languageConfidenceThreshold else { return nil }
        if best.key.rawValue.hasPrefix("pt") { return .ptBR }
        if best.key.rawValue.hasPrefix("en") { return .en }
        return nil
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
        let pt = language == .ptBR
        let ordered = digestOrder(items)
        var lines: [String] = []
        let maxBullets = TitioNoticeTiming.digestMaxBullets
        lines += ordered.prefix(maxBullets).map { "• " + digestLine($0, language: language) }
        if ordered.count > maxBullets {
            let extra = ordered.count - maxBullets
            lines.append(pt ? "+\(extra) mais na Atividade" : "+\(extra) more in Activity")
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
                TitioNoticeCardOption(label: pt ? "Abrir \(name)" : "Open \(name)", action: open),
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
        let pt = language == .ptBR
        let shown = ordered.prefix(2).map { "\(digestTitle($0, language: language)): \(digestState($0.kind, language: language))" }
        let extra = ordered.count - shown.count
        let head = pt ? "\(ordered.count) novidades — " : "\(ordered.count) updates — "
        return clip(head + shown.joined(separator: " · ") + (extra > 0 ? " +\(extra)" : ""), max: previewMaxCharacters)
    }

    /// The fallback text for one notice, without any choices block: one
    /// minimal factual sentence from the facts (no opener, no interjection,
    /// no clipped summary). Titio's real words come from the voice writer;
    /// this is only posted when no LLM could run (`titio.voice.fallback`).
    public static func body(for item: TitioNoticeRenderItem, language: TitioNoticeLanguage, timeZone: TimeZone = .current) -> String {
        let pt = language == .ptBR
        let f = item.facts
        let title = clean(f.title, max: 120)
        let ws = clean(f.workspaceName, max: 80)
        let bot = clean(f.botName, max: 80)
        let detail = clean(f.detail, max: 200)
        let duration = f.durationMs.map { self.duration(ms: $0, language: language) }
        let wsPt = ws.map { " do **\($0)**" } ?? ""
        let wsNoPt = ws.map { " no **\($0)**" } ?? ""
        let wsEn = ws.map { " in **\($0)**" } ?? ""
        // The agent's own first sentence says what happened; without it a notice only says that something did.
        let saidTail = summarySentence(f.summary).map { ": " + $0 + (".!?…".contains($0.last ?? " ") ? "" : ".") } ?? "."

        switch item.kind {
        case .runCompleted:
            if pt {
                let subject = title.map { "A tarefa **\($0)**" } ?? "Uma tarefa"
                return "\(subject)\(wsPt) foi concluída\(duration.map { " em \($0)" } ?? "")" + saidTail
            }
            let subject = title.map { "**\($0)**" } ?? "A task"
            return "\(subject)\(wsEn) is done\(duration.map { " in \($0)" } ?? "")" + saidTail

        case .runFailed:
            if pt { return "\(title.map { "A tarefa **\($0)**" } ?? "Uma tarefa")\(wsPt) falhou" + saidTail }
            return "\(title.map { "**\($0)**" } ?? "A task")\(wsEn) failed" + saidTail

        case .runInterrupted:
            if pt { return "\(title.map { "A tarefa **\($0)**" } ?? "Uma tarefa")\(wsPt) foi interrompida." }
            return "\(title.map { "**\($0)**" } ?? "A task")\(wsEn) was interrupted."

        case .botReply:
            if pt { return "\(bot.map { "O **\($0)**" } ?? "Um Bot") respondeu\(wsNoPt)" + saidTail }
            return "\(bot.map { "**\($0)**" } ?? "A Bot") replied\(wsEn)" + saidTail

        case .approval:
            let verb = approvalVerb(kind: f.requestKind, requestTitle: f.requestTitle, language: language)
            let code = approvalSnippet(f.detail).map { $0.replacingOccurrences(of: "`", with: "'") }
            let codePart = code.map { " (`\($0)`)" } ?? ""
            if pt {
                return "O agente\(title.map { " de **\($0)**" } ?? "")\(wsNoPt) quer \(verb)\(codePart)."
            }
            return "The agent\(title.map { " on **\($0)**" } ?? "")\(wsEn) wants to \(verb)\(codePart)."

        case .userInput:
            let prompt = clean(f.prompt, max: 200)
            let subject = pt
                ? "O agente\(title.map { " de **\($0)**" } ?? "")\(wsNoPt)"
                : "The agent\(title.map { " on **\($0)**" } ?? "")\(wsEn)"
            switch f.userInputShape {
            case .options, .freeText:
                if pt { return subject + (prompt.map { " perguntou: *\($0)*" } ?? " fez uma pergunta.") }
                return subject + (prompt.map { " asks: *\($0)*" } ?? " has a question.")
            case .secret, .multiQuestion:
                let secret = f.userInputShape == .secret
                if pt {
                    return "\(subject) precisa de \(secret ? "um segredo" : "algumas respostas"), que só dá para responder na conversa."
                }
                return "\(subject) needs \(secret ? "a secret" : "a few answers"), which can only be answered in the thread."
            }

        case .manualAction:
            let who = bot ?? title
            if pt {
                return "\(who.map { "O **\($0)**" } ?? "O agente") está esperando você fazer algo no Mac\(detail.map { ": \($0)" } ?? "")."
            }
            return "\(who.map { "**\($0)**" } ?? "The agent") is waiting for you to do something on the Mac\(detail.map { ": \($0)" } ?? "")."

        case .botQuestion:
            if pt { return "\(bot.map { "O **\($0)**" } ?? "Um Bot") precisa de você" + (detail.map { ": *\($0)*" } ?? ".") }
            return "\(bot.map { "**\($0)**" } ?? "A Bot") needs you" + (detail.map { ": *\($0)*" } ?? ".")

        case .botBlocked:
            if pt { return "\(bot.map { "O **\($0)**" } ?? "Um Bot") travou\(detail.map { ": \($0)" } ?? "")." }
            return "\(bot.map { "**\($0)**" } ?? "A Bot") got stuck\(detail.map { ": \($0)" } ?? "")."

        case .scheduledFailed:
            let time = clock(item.occurredAt, language: language, timeZone: timeZone)
            if pt { return "A rotina\(title.map { " **\($0)**" } ?? "")\(wsPt) falhou às \(time)." }
            return "Scheduled task\(title.map { " **\($0)**" } ?? "")\(wsEn) failed at \(time)."

        case .gitFailed:
            if pt { return "O `git push`\(wsPt) falhou\(f.exitCode.map { " (código \($0))" } ?? "")." }
            return "`git push`\(wsEn) failed\(f.exitCode.map { " (exit \($0))" } ?? "")."

        case .gitCompleted:
            if pt { return "O push\(wsPt) foi feito." }
            return "The push\(wsEn) went through."

        case .scriptFailed:
            if pt {
                return "O script\(title.map { " **\($0)**" } ?? "")\(wsPt) " + (f.exitCode.map { "saiu com código \($0)." } ?? "falhou.")
            }
            return "\(title.map { "Script **\($0)**" } ?? "A script")\(wsEn) " + (f.exitCode.map { "exited with code \($0)." } ?? "failed.")

        case .scriptCompleted:
            if pt { return "O script\(title.map { " **\($0)**" } ?? "")\(wsPt) terminou bem." }
            return "\(title.map { "Script **\($0)**" } ?? "A script")\(wsEn) finished fine."

        case .transferFailed, .transferCompleted:
            let failed = item.kind == .transferFailed
            if pt { return "A transferência SSH\(title.map { " **\($0)**" } ?? "") \(failed ? "falhou" : "terminou")." }
            return "\(title.map { "SSH transfer **\($0)**" } ?? "An SSH transfer") \(failed ? "failed" : "finished")."

        case .sshDisconnected:
            if pt { return "A sessão SSH\(title.map { " **\($0)**" } ?? "") caiu sem você pedir." }
            return "\(title.map { "SSH session **\($0)**" } ?? "An SSH session") dropped unexpectedly."

        case .fileConflict:
            if pt { return "\(title.map { "**\($0)**" } ?? "Um arquivo") foi alterado fora do editor enquanto você editava." }
            return "\(title.map { "**\($0)**" } ?? "A file") changed outside the editor while you were editing."

        case .serverListenerFailed:
            if pt {
                return "O servidor do MacCode não conseguiu abrir a porta\(f.port.map { " \($0)" } ?? ""), então o iPhone pode não conectar."
            }
            return "MacCode's server could not open \(f.port.map { "port \($0)" } ?? "its port"), so your iPhone may not connect."

        case .providerUpdateFailed:
            if pt { return "A atualização\(title.map { " do **\($0)**" } ?? "") falhou." }
            return "The \(title.map { "**\($0)** " } ?? "")update failed."

        case .notificationsDenied:
            return pt
                ? "As notificações do sistema estão desligadas para o MacCode, então eu só aviso por aqui e no pet."
                : "System notifications are off for MacCode, so I'll only tell you here and from the pet."

        case .external:
            let body = clean(f.body, max: 300)
            switch (title, body) {
            case let (title?, body?): return "**\(title)**\n\(body)"
            case let (title?, nil): return "**\(title)**"
            case let (nil, body?): return body
            case (nil, nil): return pt ? "Chegou um aviso." : "A notice arrived."
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
        let pt = language == .ptBR
        switch action {
        case .approve: return pt ? "Aprovar" : "Approve"
        case .approveSession: return pt ? "Aprovar nesta sessão" : "Approve for session"
        case .decline: return pt ? "Recusar" : "Decline"
        case let .providerOption(_, text): return text
        case let .botOption(text): return text
        case .continue: return pt ? "Continuar" : "Continue"
        case .rerun: return pt ? "Rodar de novo" : "Run again"
        case .ack: return pt ? "Entendi" : "Got it"
        case .replyHere: return pt ? "Responder aqui" : "Reply here"
        case .openThread: return pt ? "Abrir conversa" : "Open conversation"
        case .openBot: return pt ? "Abrir conversa" : "Open conversation"
        case .openActivity: return pt ? "Ver na Atividade" : "View in Activity"
        case .openAllActivity: return pt ? "Ver tudo na Atividade" : "See all in Activity"
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
        let pt = language == .ptBR
        let f = item.facts
        let picksAnOption = item.actions?.contains {
            if case .providerOption = $0 { return true }
            if case .botOption = $0 { return true }
            return false
        } ?? false
        let generic = picksAnOption ? (pt ? "Qual opção?" : "Which option?") : (pt ? "O que deseja fazer?" : "What should I do?")
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
        let pt = language == .ptBR
        switch kind {
        case "commandExecution", "exec":
            return pt ? "rodar um comando" : "run a command"
        case "fileChange", "applyPatch":
            return pt ? "alterar arquivos" : "change files"
        case "fileRead":
            return pt ? "ler um arquivo" : "read a file"
        case "authTokensRefresh":
            return pt ? "renovar o acesso" : "refresh its sign-in"
        case "toolUserInput", "dynamic":
            if let tool = clean(requestTitle, max: 40), !tool.contains(" ") {
                return pt ? "usar a ferramenta \(tool)" : "use the \(tool) tool"
            }
            return pt ? "usar uma ferramenta" : "use a tool"
        default:
            return pt ? "executar uma ação" : "take an action"
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
        let pt = language == .ptBR
        switch item.kind {
        case .runCompleted, .runFailed, .runInterrupted: return pt ? "tarefa" : "task"
        case .botReply, .botQuestion, .botBlocked: return "Bot"
        case .approval, .userInput, .manualAction: return pt ? "pedido" : "request"
        case .scheduledFailed: return pt ? "rotina" : "scheduled task"
        case .gitFailed, .gitCompleted: return "git push"
        case .scriptFailed, .scriptCompleted: return "script"
        case .transferFailed, .transferCompleted: return pt ? "transferência SSH" : "SSH transfer"
        case .sshDisconnected: return pt ? "sessão SSH" : "SSH session"
        case .fileConflict: return pt ? "arquivo" : "file"
        case .serverListenerFailed: return pt ? "servidor" : "server"
        case .providerUpdateFailed: return pt ? "atualização" : "update"
        case .notificationsDenied: return pt ? "notificações" : "notifications"
        case .external: return pt ? "aviso" : "notice"
        }
    }

    static func digestState(_ kind: TitioNoticeKind, language: TitioNoticeLanguage) -> String {
        let pt = language == .ptBR
        switch kind {
        case .runCompleted: return pt ? "concluída" : "done"
        case .runInterrupted: return pt ? "interrompida" : "interrupted"
        case .approval, .userInput, .manualAction, .botQuestion, .fileConflict: return pt ? "precisa de você" : "needs you"
        case .botReply: return pt ? "respondeu" : "replied"
        case .external: return pt ? "aviso" : "notice"
        default: return kind.isFailure ? (pt ? "falhou" : "failed") : "ok"
        }
    }

    // MARK: Result and status lines

    public static func resultLine(_ result: TitioNoticeResult, language: TitioNoticeLanguage) -> String {
        let pt = language == .ptBR
        func ws(_ value: String?, _ ptPrefix: String) -> String {
            guard let value = clean(value, max: 80) else { return "" }
            return pt ? " \(ptPrefix) **\(value)**" : " in **\(value)**"
        }
        func target(_ target: TitioNoticeReplyTarget) -> String {
            switch target {
            case let .agent(workspace):
                return (pt ? "o agente" : "the agent") + ws(workspace, "do")
            case let .bot(name):
                guard let name = clean(name, max: 80) else { return pt ? "o Bot" : "the Bot" }
                return pt ? "o **\(name)**" : "**\(name)**"
            }
        }
        switch result {
        case let .approved(workspace):
            return pt ? "Aprovei\(ws(workspace, "no"))." : "Approved\(ws(workspace, "no"))."
        case let .approvedSession(workspace):
            return pt ? "Aprovei para esta sessão\(ws(workspace, "no"))." : "Approved for this session\(ws(workspace, "no"))."
        case let .declined(workspace):
            return pt ? "Recusei e o agente\(ws(workspace, "do")) foi avisado." : "Declined, and the agent\(ws(workspace, "do")) was told."
        case let .answered(answer, to):
            let quoted = clean(answer, max: summaryMaxCharacters) ?? ""
            return pt ? "Repassei “\(quoted)” para \(target(to))." : "Passed “\(quoted)” to \(target(to))."
        case let .armed(to):
            return pt ? "Eu repasso sua próxima mensagem para \(target(to))." : "I'll pass your next message to \(target(to))."
        case let .continued(title):
            let name = clean(title, max: 120).map { "**\($0)**" }
            return pt ? "Pedi para continuar \(name ?? "a tarefa")." : "Asked \(name ?? "the task") to continue."
        case let .rerun(task):
            let name = clean(task, max: 120).map { "**\($0)**" }
            return pt ? "Rodando \(name ?? "a rotina") de novo." : "Running \(name ?? "the scheduled task") again."
        case .alreadyResolved:
            return pt ? "Isso já tinha sido resolvido ou expirou; não enviei nada." : "That was already handled or expired; I sent nothing."
        case let .failed(error):
            let reason = clean(error, max: 200) ?? (pt ? "erro desconhecido" : "unknown error")
            return pt ? "Não consegui enviar: \(reason). Abra a conversa para decidir por lá." : "I couldn't send it: \(reason). Open the thread to decide there."
        }
    }

    /// `done` and `failed` are not in the spec's status table; they cover
    /// continue/rerun and a host action that threw, so a resolved card never
    /// keeps a stale block.
    public static func statusLine(_ status: TitioNoticeStatus, language: TitioNoticeLanguage, at date: Date, timeZone: TimeZone = .current) -> String {
        let pt = language == .ptBR
        let time = clock(date, language: language, timeZone: timeZone)
        switch status {
        case .approved: return pt ? "_Aprovado por você às \(time)._" : "_Approved by you at \(time)._"
        case .declined: return pt ? "_Recusado às \(time)._" : "_Declined at \(time)._"
        case .answered: return pt ? "_Respondido às \(time)._" : "_Answered at \(time)._"
        case .elsewhere: return pt ? "_Resolvido em outro lugar._" : "_Handled elsewhere._"
        case .expired: return pt ? "_Expirou._" : "_Expired._"
        case .acknowledged: return pt ? "_Visto._" : "_Seen._"
        case .done: return pt ? "_Feito às \(time)._" : "_Done at \(time)._"
        case .failed: return pt ? "_Não deu certo; abra a conversa._" : "_Didn't go through; open the thread._"
        case .unknownEffect: return pt ? "_Resultado não confirmado; confira a origem antes de tentar novamente._" : "_Outcome unconfirmed; check the source before trying again._"
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
        language == .ptBR ? "Notificações" : "Notifications"
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
            return language == .ptBR ? number.replacingOccurrences(of: ".", with: ",") + " s" : number + "s"
        }
        let minutes = Int((Double(ms) / 60_000).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// pt "HH:mm", en "h:mm a".
    public static func clock(_ date: Date, language: TitioNoticeLanguage, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .ptBR ? "pt_BR" : "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = language == .ptBR ? "HH:mm" : "h:mm a"
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
