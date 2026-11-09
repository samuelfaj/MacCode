import XCTest
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// Records every host side effect a card act asks for.
final class TitioActionRecorder: @unchecked Sendable {
    enum Call: Equatable {
        case request(AgentThreadID, String, TitioNoticeActionHooks.RequestDecision)
        case userInput(AgentThreadID, String, String)
        case bot(BotID, BotConversationID, String)
        case ackBot(BotAttentionItemID)
        case continueRun(AgentThreadID)
        case rerun(UUID)
        case ackActivity(String)
        case dismissNotification(String)
    }

    private let lock = NSLock()
    private var callsValue: [Call] = []
    private var requestOpenValue = true
    private var failureValue: String?
    private var offMainValue: [Bool] = []

    var calls: [Call] { lock.withLock { callsValue } }
    var ranOffMain: [Bool] { lock.withLock { offMainValue } }
    var requestOpen: Bool {
        get { lock.withLock { requestOpenValue } }
        set { lock.withLock { requestOpenValue = newValue } }
    }
    /// When set, every host action throws with this reason.
    var failure: String? {
        get { lock.withLock { failureValue } }
        set { lock.withLock { failureValue = newValue } }
    }

    private func record(_ call: Call) throws {
        let offMain = !Thread.isMainThread
        try lock.withLock {
            callsValue.append(call)
            offMainValue.append(offMain)
            if let failureValue { throw TitioNoticeActionError(reason: failureValue) }
        }
    }

    func hooks() -> TitioNoticeActionHooks {
        TitioNoticeActionHooks(
            isRequestOpen: { [self] _, _, _, _ in requestOpen },
            respondRequest: { [self] in try record(.request($0, $1, $2)) },
            respondUserInput: { [self] in try record(.userInput($0, $1, $2)) },
            sendBotMessage: { [self] in try record(.bot($0, $1, $2)) },
            acknowledgeBotAttention: { [self] in try record(.ackBot($0)) },
            continueRun: { [self] in try record(.continueRun($0)) },
            rerunScheduledTask: { [self] in try record(.rerun($0)) },
            acknowledgeActivity: { [self] in try record(.ackActivity($0)) },
            dismissNotification: { [self] in try record(.dismissNotification($0)) }
        )
    }
}

/// Acting on a Titio notice card (hub spec §7, §13 `TitioNoticeActTests`):
/// a tap is bound to the ledger row, the host claims it once, runs the real
/// action, and only then resolves, rewrites the card and reports honestly.
final class TitioNoticeActTests: XCTestCase {
    private struct Fixture {
        let db: SQLiteDB
        let repo: TitioNoticeRepository
        let messages: AgentMessageRepository
        let target: TitioInboxTarget
        let scheduler: ManualTitioScheduler
        let recorder: TitioHookRecorder
        let actions: TitioActionRecorder
        let center: TitioNoticeCenter
    }

    private let requestThread = AgentThreadID()

    private func makeFixture(preferredLanguages: [String] = ["en-US"], installActions: Bool = true) throws -> Fixture {
        let path = NSTemporaryDirectory() + "titio-act-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: path).run()
        let store = BotStore(db: db)
        let bot = try store.create(name: "Titio", title: "", description: "", handle: "titio")
        let thread = AgentThread(title: "Notifications", provider: .distill, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let conversation = BotConversation(botID: bot.id, title: "Notifications", linkedAgentThreadID: thread.id)
        try store.upsertConversation(conversation)
        let repo = TitioNoticeRepository(db: db)
        try repo.updateInboxState { $0.conversationID = conversation.id.value.uuidString.lowercased() }
        let target = TitioInboxTarget(botID: bot.id, conversationID: conversation.id, threadID: thread.id)
        let recorder = TitioHookRecorder()
        recorder.target = target
        var hooks = recorder.hooks()
        hooks.languageInputs = { TitioNoticeLanguageInputs(lastUserText: nil, preferredLanguages: preferredLanguages) }
        let scheduler = ManualTitioScheduler()
        let center = TitioNoticeCenter(
            db: db, botStore: store, hooks: hooks, scheduler: scheduler,
            voice: FakeTitioVoice.fixture,
            now: { scheduler.now }, timeZone: TimeZone(identifier: "UTC")!
        )
        let actions = TitioActionRecorder()
        if installActions { center.installActions(actions.hooks()) }
        return Fixture(db: db, repo: repo, messages: AgentMessageRepository(db: db), target: target,
                       scheduler: scheduler, recorder: recorder, actions: actions, center: center)
    }

    private func approval(_ request: String, _ f: Fixture) -> TitioNoticeFact {
        let facts = TitioNoticeFacts(title: "Deploy", workspaceName: "api", detail: "rm -rf build", requestTitle: "run a command")
        return TitioNoticeFact(
            key: TitioNoticeIDs.threadAttention(threadId: requestThread.value.uuidString, requestId: request),
            kind: .approval,
            source: TitioNoticeSource(threadId: requestThread.value.uuidString, requestId: request),
            facts: facts,
            actions: TitioNoticeAction.defaultActions(kind: .approval, facts: facts),
            occurredAt: f.scheduler.now
        )
    }

    private func question(_ request: String, options: [String]? = nil, _ f: Fixture) -> TitioNoticeFact {
        let facts = TitioNoticeFacts(title: "Deploy", workspaceName: "api", prompt: "Which environment?", options: options)
        return TitioNoticeFact(
            key: TitioNoticeIDs.threadAttention(threadId: requestThread.value.uuidString, requestId: request),
            kind: .userInput,
            source: TitioNoticeSource(threadId: requestThread.value.uuidString, requestId: request),
            facts: facts,
            actions: TitioNoticeAction.defaultActions(kind: .userInput, facts: facts),
            occurredAt: f.scheduler.now
        )
    }

    /// Posts a decision (decisions flush at once) and returns its message id.
    private func post(_ fact: TitioNoticeFact, _ f: Fixture) async -> String {
        f.center.ingest(fact)
        await f.center.idle()
        return TitioNoticeIDs.messageID(forKey: fact.key).uuidString
    }

    private func settle(_ f: Fixture) async {
        await f.center.settleActs()
        await f.center.idle()
    }

    private func transcript(_ f: Fixture) throws -> [AgentMessage] {
        try f.messages.list(threadId: f.target.threadID)
    }

    func test_contextualReplyStaysOnCapturedQuestionAndClaimsOnce() async throws {
        let f = try makeFixture()
        let a = question("A", f)
        let aID = await post(a, f)
        let capturedQuestion = try XCTUnwrap(BotChoicesBlock.parse(transcript(f)[0].content).choices?.question)
        let focus = try XCTUnwrap(f.recorder.inbox.last?.focus)
        XCTAssertEqual(focus.messageId, aID.lowercased())
        XCTAssertEqual(focus.actionId, "reply")
        XCTAssertEqual(f.center.replyNow(messageID: aID, text: "stale answer", expectedQuestionRevision: focus.questionRevision + 1), .alreadyResolved)
        XCTAssertTrue(f.actions.calls.isEmpty)
        XCTAssertEqual(f.center.contextualReply(messageID: aID, optionIndex: 0)?["outcome"] as? String, "reply_required")
        XCTAssertNil(try f.repo.inboxState().armedReplyKey, "opening a capable composer is device-local")
        let b = question("B", f)
        let bID = await post(b, f)
        _ = f.center.contextualReply(messageID: bID, optionIndex: 0)
        async let first = Task.detached { f.center.replyNow(messageID: aID, text: "staging", expectedQuestionRevision: focus.questionRevision) }.value
        async let second = Task.detached { f.center.replyNow(messageID: aID, text: "production", expectedQuestionRevision: focus.questionRevision) }.value
        let outcomes = await [first, second]
        XCTAssertEqual(outcomes.filter { $0 == .accepted }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .alreadyResolved }.count, 1)
        await settle(f)
        XCTAssertEqual(f.actions.calls.count, 1)
        XCTAssertEqual(try f.repo.get(key: a.key)?.resolution, .answered)
        XCTAssertEqual(try f.repo.get(key: b.key)?.state, .posted)
        XCTAssertEqual(f.recorder.inbox.last?.focus?.messageId, bID.lowercased())
        let user = try XCTUnwrap(transcript(f).first { $0.role == .user })
        XCTAssertEqual(AgentReplyQuote.parse(user.content)?.excerpt, capturedQuestion)
    }

    // MARK: §13 act cases

    func test_approveRespondsOnceRewritesTheCardAndPostsTheResultLine() async throws {
        // WHY: "Aprovar" must reach exactly that thread's exact request once,
        // and the card must stop offering a decision that already happened.
        let f = try makeFixture()
        let fact = approval("Q1", f)
        let messageID = await post(fact, f)

        let outcome = await f.center.act(messageID: messageID.lowercased(), optionIndex: 0)
        XCTAssertEqual(outcome, .accepted, "accepted right after the claim; the result line reports the end")
        await settle(f)

        XCTAssertEqual(f.actions.calls, [.request(requestThread, "Q1", .approve)])
        XCTAssertEqual(f.actions.ranOffMain, [true], "host actions are awaited off the MainActor")
        let row = try XCTUnwrap(f.repo.get(key: fact.key))
        XCTAssertEqual(row.state, .resolved)
        XCTAssertEqual(row.resolution, .approved)
        let rows = try transcript(f)
        XCTAssertEqual(rows.map(\.role), [.assistant, .user, .assistant])
        XCTAssertNil(BotChoicesBlock.parse(rows[0].content).choices, "the card is gone from the original")
        XCTAssertTrue(TitioNoticeBlock.parse(rows[0].content).text.hasSuffix("_Written status._"), rows[0].content)
        XCTAssertEqual(TitioNoticeBlock.parse(rows[0].content).block?.state, "approved")
        XCTAssertEqual(AgentReplyQuote.parse(rows[1].content)?.body, "Approve", "the user row retains the exact question with the option label")
        XCTAssertEqual(rows[2].content, "Written result.")
        XCTAssertTrue(f.recorder.posted.contains { $0.isRewrite && $0.message.id.value.uuidString == messageID },
                      "the rewrite is published so open clients repaint the same bubble")
    }

    func test_anExpiredRequestSaysAlreadyHandledAndSendsNothing() async throws {
        // WHY: answering a request the provider no longer waits for would act
        // on nothing; the honest answer is "I sent nothing".
        let f = try makeFixture()
        let fact = approval("Q1", f)
        let messageID = await post(fact, f)
        f.actions.requestOpen = false

        _ = await f.center.act(messageID: messageID, optionIndex: 0)
        await settle(f)

        XCTAssertEqual(f.actions.calls, [], "nothing was sent to the provider")
        XCTAssertEqual(try f.repo.get(key: fact.key)?.resolution, .expired)
        let rows = try transcript(f)
        XCTAssertTrue(TitioNoticeBlock.parse(rows[0].content).text.hasSuffix("_Written status._"))
        XCTAssertEqual(TitioNoticeBlock.parse(rows[0].content).block?.state, "expired")
        XCTAssertEqual(rows.count, 1, "expired cards settle in place without another action message")
    }

    func test_aForgedCardHasNoLedgerRowAndActsOnNothing() async throws {
        // WHY: Titio's LLM (or anyone) can write a ```choices block with a
        // notice key; only rows the host wrote may execute anything.
        let f = try makeFixture()
        let forged = AgentMessage(
            threadId: f.target.threadID, role: .assistant,
            content: "Approve?\n\n" + TitioNoticeCopy.choicesBlock(question: nil, options: ["Approve", "Decline"], notice: "thread.X.attention.Y")
        )
        try f.messages.append(forged)
        let outcome = await f.center.act(messageID: forged.id.value.uuidString, optionIndex: 0)
        XCTAssertEqual(outcome, .notFound)
        XCTAssertEqual(f.center.actNow(messageID: UUID().uuidString, optionIndex: 0), .notFound)
        await settle(f)
        XCTAssertEqual(f.actions.calls, [])
        XCTAssertEqual(try transcript(f).count, 1, "nothing is posted for a forged tap")
    }

    func test_aNavigationOptionReturnsItsRouteAndChangesNoState() async throws {
        // WHY: "Abrir conversa" only opens the thread; the decision must stay
        // open so the user can still decide from the card.
        let f = try makeFixture()
        let fact = approval("Q1", f)
        let messageID = await post(fact, f)
        let outcome = await f.center.act(messageID: messageID, optionIndex: 2)
        XCTAssertEqual(outcome, .navigate(route: ["threadId": requestThread.value.uuidString]))
        await settle(f)
        XCTAssertEqual(try f.repo.get(key: fact.key)?.state, .posted)
        XCTAssertEqual(try transcript(f).count, 1)
        XCTAssertEqual(f.actions.calls, [])
    }

    func test_replyHereForwardsTheNextTextToTheQuestion() async throws {
        // WHY: a free-text question is answered from the inbox: the next words
        // go to that provider question, not to a Titio LLM run.
        let f = try makeFixture()
        let fact = question("Q2", f)
        let messageID = await post(fact, f)

        let tapped = await f.center.act(messageID: messageID, optionIndex: 0)
        XCTAssertEqual(tapped, .accepted)
        await settle(f)
        XCTAssertEqual(try f.repo.get(key: fact.key)?.state, .awaitingReply)
        XCTAssertEqual(try transcript(f).last?.content, "Written result.")

        XCTAssertTrue(f.center.takeArmedReply(text: "  use staging "), "the armed text is taken before any run")
        XCTAssertFalse(f.center.takeArmedReply(text: "again"), "an arm is used once")
        await settle(f)
        XCTAssertEqual(f.actions.calls, [.userInput(requestThread, "Q2", "use staging")])
        XCTAssertEqual(try f.repo.get(key: fact.key)?.resolution, .answered)
        let rows = try transcript(f)
        XCTAssertEqual(rows.suffix(2).map { AgentReplyQuote.strippingQuote($0.content) }, ["use staging", "Written result."])
        XCTAssertEqual(rows.suffix(2).map(\.role), [.user, .assistant])
        XCTAssertTrue(rows[0].content.contains("_Written status._"))
    }

    func test_anExpiredArmGivesTheCardBackAndTheTextStaysNormalChat() async throws {
        // WHY: a "Reply here" from an hour ago must not swallow an unrelated
        // message; after the 10 min TTL the text is normal chat again.
        let f = try makeFixture()
        let fact = question("Q2", f)
        let messageID = await post(fact, f)
        _ = await f.center.act(messageID: messageID, optionIndex: 0)
        await settle(f)

        await f.scheduler.advance(by: TitioNoticeTiming.armedReplyTTL + 1, center: f.center)
        XCTAssertFalse(f.center.takeArmedReply(text: "what changed today?"))
        await settle(f)
        XCTAssertEqual(f.actions.calls, [])
        XCTAssertEqual(try f.repo.get(key: fact.key)?.state, .posted, "the card is tappable again")
        XCTAssertNil(try f.repo.inboxState().armedReplyKey)
    }

    func test_anotherTapClearsTheArm() async throws {
        // WHY: tapping a different card means the user moved on; the next text
        // must not go to the old question.
        let f = try makeFixture()
        let armed = question("Q2", f)
        let armedMessage = await post(armed, f)
        _ = await f.center.act(messageID: armedMessage, optionIndex: 0)
        await settle(f)
        let other = approval("Q3", f)
        let otherMessage = await post(other, f)
        let tapped = await f.center.act(messageID: otherMessage, optionIndex: 1)
        XCTAssertEqual(tapped, .accepted)
        await settle(f)
        XCTAssertFalse(f.center.takeArmedReply(text: "hello"))
        XCTAssertEqual(try f.repo.get(key: armed.key)?.state, .posted)
        XCTAssertEqual(f.actions.calls, [.request(requestThread, "Q3", .decline)])
        XCTAssertEqual(try transcript(f).last?.content, "Written result.")
    }

    func test_aBotOptionLandsInThatBotsConversationAndAcksItsAttention() async throws {
        // WHY: answering a Bot from Titio's inbox must reach that Bot's own
        // conversation and clear its needs-you item, never Titio's chat.
        let f = try makeFixture()
        let bot = BotID()
        let conversation = BotConversationID()
        let item = BotAttentionItemID()
        let facts = TitioNoticeFacts(botName: "Scout", detail: "Ship the release?", options: ["Ship it", "Wait"])
        let fact = TitioNoticeFact(
            key: TitioNoticeIDs.botAttention(itemId: item.value.uuidString),
            kind: .botQuestion,
            source: TitioNoticeSource(
                botId: bot.value.uuidString.lowercased(),
                conversationId: conversation.value.uuidString.lowercased(),
                attentionItemId: item.value.uuidString.lowercased()
            ),
            facts: facts,
            actions: TitioNoticeAction.defaultActions(kind: .botQuestion, facts: facts),
            occurredAt: f.scheduler.now
        )
        let messageID = await post(fact, f)
        let capturedQuestion = try XCTUnwrap(BotChoicesBlock.parse(transcript(f)[0].content).choices?.question)
        let tapped = await f.center.act(messageID: messageID, optionIndex: 0)
        XCTAssertEqual(tapped, .accepted)
        await settle(f)
        XCTAssertEqual(f.actions.calls, [.bot(bot, conversation, AgentReplyQuote.compose(excerpt: capturedQuestion, text: "Ship it")), .ackBot(item)])
        XCTAssertEqual(try f.repo.get(key: fact.key)?.resolution, .forwarded)
        XCTAssertEqual(try transcript(f).last?.content, "Written result.")
    }

    func test_resolvingElsewhereRewritesTheCardWithoutANewMessage() async throws {
        // WHY: a request answered on the thread itself must not leave a live
        // card behind, and must not post noise about it either.
        let f = try makeFixture(preferredLanguages: ["pt-BR"])
        let fact = approval("Q1", f)
        _ = await post(fact, f)
        f.center.sourceResolved(key: fact.key)
        await f.center.idle()
        let rows = try transcript(f)
        XCTAssertEqual(rows.count, 1, "no new message for an elsewhere resolution")
        XCTAssertTrue(TitioNoticeBlock.parse(rows[0].content).text.hasSuffix("_Written status._"), rows[0].content)
        XCTAssertEqual(TitioNoticeBlock.parse(rows[0].content).block?.state, "elsewhere")
        XCTAssertNil(BotChoicesBlock.parse(rows[0].content).choices)
    }

    // MARK: Claims and failures

    func test_concurrentTapsClaimOnceAndALaterTapSaysAlreadyHandled() async throws {
        // WHY: the Mac and the phone can tap the same card at once; the
        // provider must get one answer, never two.
        let f = try makeFixture()
        let fact = approval("Q1", f)
        let messageID = await post(fact, f)
        let center = f.center
        let outcomes = await withTaskGroup(of: TitioNoticeActOutcome.self) { group in
            for _ in 0..<8 { group.addTask { center.actNow(messageID: messageID, optionIndex: 0) } }
            var all: [TitioNoticeActOutcome] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        XCTAssertEqual(outcomes.filter { $0 == .accepted }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .alreadyResolved }.count, 7)
        await settle(f)
        XCTAssertEqual(f.actions.calls, [.request(requestThread, "Q1", .approve)])

        let countBefore = try transcript(f).count
        let tapped = await f.center.act(messageID: messageID, optionIndex: 1)
        XCTAssertEqual(tapped, .alreadyResolved)
        await settle(f)
        let rows = try transcript(f)
        XCTAssertEqual(rows.count, countBefore + 1)
        XCTAssertEqual(rows.last?.content, "Written result.")
        XCTAssertEqual(f.actions.calls.count, 1)
    }

    func test_aHostFailureResolvesFailedWithTheHonestReason() async throws {
        // WHY: never fake success: if the provider rejects the answer, Titio
        // says why and points to the thread.
        let f = try makeFixture()
        let fact = approval("Q1", f)
        let messageID = await post(fact, f)
        f.actions.failure = "the provider session ended"
        _ = await f.center.act(messageID: messageID, optionIndex: 0)
        await settle(f)
        XCTAssertEqual(f.actions.calls, [.request(requestThread, "Q1", .approve)])
        XCTAssertEqual(try f.repo.get(key: fact.key)?.resolution, .failed)
        let rows = try transcript(f)
        XCTAssertTrue(TitioNoticeBlock.parse(rows[0].content).text.hasSuffix("_Written status._"))
        XCTAssertEqual(TitioNoticeBlock.parse(rows[0].content).block?.state, "failed")
        XCTAssertEqual(rows.last?.content, "Written result.")
    }

    func test_withoutHostActionsATapClaimsNothing() async throws {
        // WHY: a hub that cannot execute must leave the card open, not
        // pretend it acted.
        let f = try makeFixture(installActions: false)
        let fact = approval("Q1", f)
        let messageID = await post(fact, f)
        let tapped = await f.center.act(messageID: messageID, optionIndex: 0)
        XCTAssertEqual(tapped, .unsupported)
        XCTAssertEqual(try f.repo.get(key: fact.key)?.state, .posted)
    }

    func test_continueRerunAndAckRunTheirHostPaths() async throws {
        // WHY: each card verb maps to exactly one existing host path.
        let f = try makeFixture()
        let run = UUID().uuidString
        let interrupted = TitioNoticeFact(
            key: TitioNoticeIDs.runOutcome(runId: run, outcome: .interrupted), kind: .runInterrupted,
            source: TitioNoticeSource(threadId: requestThread.value.uuidString, runId: run, activityItemId: "run:\(run.lowercased())"),
            facts: TitioNoticeFacts(title: "Build", workspaceName: "api"),
            actions: [.continue, .openThread, .ack], occurredAt: f.scheduler.now
        )
        let task = UUID()
        let scheduled = TitioNoticeFact(
            key: "scheduled_task_run.S1.failed", kind: .scheduledFailed,
            source: TitioNoticeSource(scheduledTaskId: task.uuidString.lowercased(), activityItemId: "scheduled-occurrence:s1"),
            facts: TitioNoticeFacts(title: "Nightly", workspaceName: "api"),
            actions: [.rerun, .openActivity], occurredAt: f.scheduler.now
        )
        let failed = TitioNoticeFact(
            key: "run.R9.failed", kind: .runFailed,
            source: TitioNoticeSource(threadId: requestThread.value.uuidString, runId: "R9", activityItemId: "run:r9"),
            facts: TitioNoticeFacts(title: "Lint"), actions: [.openThread, .ack], occurredAt: f.scheduler.now
        )
        let interruptedID = await post(interrupted, f)
        let scheduledID = await post(scheduled, f)
        let failedID = await post(failed, f)
        _ = await f.center.act(messageID: interruptedID, optionIndex: 0)
        _ = await f.center.act(messageID: scheduledID, optionIndex: 0)
        _ = await f.center.act(messageID: failedID, optionIndex: 1)
        await settle(f)
        XCTAssertEqual(Set(f.actions.calls.map { "\($0)" }), Set([
            TitioActionRecorder.Call.continueRun(requestThread), .rerun(task), .ackActivity("run:r9"),
        ].map { "\($0)" }))
        XCTAssertEqual(try f.repo.get(key: interrupted.key)?.resolution, .retried)
        XCTAssertEqual(try f.repo.get(key: scheduled.key)?.resolution, .retried)
        XCTAssertEqual(try f.repo.get(key: failed.key)?.resolution, .acknowledged)
        let texts = try transcript(f).map(\.content)
        XCTAssertEqual(texts.filter { $0 == "Written result." }.count, 2)
        XCTAssertFalse(texts.contains { $0 == "Got it" || $0.hasSuffix("_Seen._") },
                       "acknowledging only closes the question, without adding a turn or a status")
    }

    // MARK: Old iOS text intercept

    func test_oldIOSOptionTextActsOnlyWhenExactlyOneOpenNoticeOffersIt() async throws {
        // WHY: an old phone sends the option's words; acting on an ambiguous
        // label would answer the wrong request, so it then stays normal chat.
        let f = try makeFixture()
        _ = await post(approval("Q1", f), f)
        _ = await post(approval("Q2", f), f)
        XCTAssertFalse(f.center.takeOptionText("Approve"), "two open notices offer it: ambiguous")
        XCTAssertFalse(f.center.takeOptionText("Open conversation"), "navigation never matches")
        let pick = question("Q3", options: ["Staging", "Production"], f)
        _ = await post(pick, f)
        XCTAssertTrue(f.center.takeOptionText("Staging"))
        await settle(f)
        XCTAssertEqual(f.actions.calls, [.userInput(requestThread, "Q3", "Staging")])
        XCTAssertFalse(f.center.takeOptionText("what is going on?"))
    }

    func test_inboxSnapshotMirrorsTheLastPublishedInbox() async throws {
        // WHY: `bot.list` reads the inbox from memory (no SQLite on that path)
        // and must match what `bot.updated` last told the phones.
        let f = try makeFixture()
        _ = await post(approval("Q1", f), f)
        let snapshot = try XCTUnwrap(f.center.inboxSnapshot)
        XCTAssertEqual(snapshot, f.recorder.inbox.last)
        XCTAssertEqual(snapshot.openDecisions, 1)
        XCTAssertEqual(snapshot.foundationObject["unread_count"] as? Int, snapshot.unreadCount)
    }
}
