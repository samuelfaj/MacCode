import XCTest
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// A deterministic clock + timer queue for the §4 windows. `advance` fires
/// due timers in time order and lets the center drain after each one, so a
/// timer armed while handling another is honoured in the same advance.
final class ManualTitioScheduler: TitioNoticeScheduling, @unchecked Sendable {
    final class Timer: TitioNoticeTimer, @unchecked Sendable {
        let fireAt: TimeInterval
        let work: @Sendable () -> Void
        private let lock = NSLock()
        private var cancelledValue = false
        var cancelled: Bool { lock.withLock { cancelledValue } }
        init(fireAt: TimeInterval, work: @escaping @Sendable () -> Void) {
            self.fireAt = fireAt
            self.work = work
        }
        func cancel() { lock.withLock { cancelledValue = true } }
    }

    let start: Date
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    private var timers: [Timer] = []

    init(start: Date = Date(timeIntervalSince1970: 1_792_094_460)) { self.start = start }

    var now: Date { lock.withLock { start.addingTimeInterval(offset) } }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> TitioNoticeTimer {
        lock.withLock {
            let timer = Timer(fireAt: offset + max(0, delay), work: work)
            timers.append(timer)
            return timer
        }
    }

    /// Live (not cancelled) timers, for assertions.
    var pendingTimerCount: Int { lock.withLock { timers.filter { !$0.cancelled }.count } }

    func advance(by seconds: TimeInterval, center: TitioNoticeCenter) async {
        // Commands sent before this call are handled at the current time first.
        await center.idle()
        let target = lock.withLock { offset + seconds }
        while true {
            let next: Timer? = lock.withLock {
                timers.removeAll { $0.cancelled }
                guard let due = timers.filter({ $0.fireAt <= target }).min(by: { $0.fireAt < $1.fireAt }) else { return nil }
                timers.removeAll { $0 === due }
                offset = max(offset, due.fireAt)
                return due
            }
            guard let next else { break }
            next.work()
            await center.idle()
        }
        lock.withLock { offset = target }
        await center.idle()
    }
}

/// Records every hook call the center makes.
final class TitioHookRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bannersValue: [RemoteCodeNotificationContent] = []
    private var pushesValue: [RemoteCodeNotificationContent] = []
    private var postedValue: [TitioNoticePostedMessage] = []
    private var inboxValue: [TitioInboxSnapshot] = []
    private var speechValue: [TitioNoticeSpeech] = []
    private var offMainValue: [Bool] = []
    private var removedValue: [[AgentMessageID]] = []
    var target: TitioInboxTarget?
    var titioRunActive = false
    var viewing = false
    var focusedSuccess = false
    var pushAccepted = true
    var resolveCalls = 0

    var banners: [RemoteCodeNotificationContent] { lock.withLock { bannersValue } }
    var pushes: [RemoteCodeNotificationContent] { lock.withLock { pushesValue } }
    var posted: [TitioNoticePostedMessage] { lock.withLock { postedValue } }
    var inbox: [TitioInboxSnapshot] { lock.withLock { inboxValue } }
    var speech: [TitioNoticeSpeech] { lock.withLock { speechValue } }
    var postedOffMain: [Bool] { lock.withLock { offMainValue } }
    var removed: [[AgentMessageID]] { lock.withLock { removedValue } }

    func hooks(profileID: String? = "profile-1") -> TitioNoticeHooks {
        TitioNoticeHooks(
            resolveInbox: { [self] _ in lock.withLock { resolveCalls += 1; return target } },
            isInboxViewed: { [self] _ in lock.withLock { viewing } },
            isTitioRunActive: { [self] _ in lock.withLock { titioRunActive } },
            languageInputs: { TitioNoticeLanguageInputs(lastUserText: nil, preferredLanguages: ["en-US"]) },
            messagePosted: { [self] posted in
                let offMain = !Thread.isMainThread
                lock.withLock { postedValue.append(posted); offMainValue.append(offMain) }
            },
            inboxChanged: { [self] snapshot in lock.withLock { inboxValue.append(snapshot) } },
            messagesRemoved: { [self] _, ids in lock.withLock { removedValue.append(ids) } },
            postBanner: { [self] content in lock.withLock { bannersValue.append(content) } },
            deliverPush: { [self] content in lock.withLock { pushesValue.append(content); return pushAccepted } },
            pushBinding: { TitioNoticePushBinding(profileID: profileID, hostID: "host-1") },
            isFocusedSuccess: { [self] _ in lock.withLock { focusedSuccess } }
        )
    }

    func recordSpeech(_ speech: TitioNoticeSpeech) { lock.withLock { speechValue.append(speech) } }
}

final class TitioNoticeCenterTests: XCTestCase {
    private struct Fixture {
        let db: SQLiteDB
        let repo: TitioNoticeRepository
        let messages: AgentMessageRepository
        let store: BotStore
        let target: TitioInboxTarget
        let scheduler: ManualTitioScheduler
        let recorder: TitioHookRecorder
        let center: TitioNoticeCenter
    }

    private func makeFixture(available: Bool = true, profileID: String? = "profile-1") throws -> Fixture {
        let path = NSTemporaryDirectory() + "titio-center-" + UUID().uuidString
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
        recorder.target = available ? target : nil
        let scheduler = ManualTitioScheduler()
        let center = TitioNoticeCenter(
            db: db,
            botStore: store,
            hooks: recorder.hooks(profileID: profileID),
            scheduler: scheduler,
            voice: FakeTitioVoice.fixture,
            now: { scheduler.now },
            timeZone: TimeZone(identifier: "UTC")!
        )
        center.setOnSpeech { recorder.recordSpeech($0) }
        return Fixture(db: db, repo: repo, messages: AgentMessageRepository(db: db), store: store,
                       target: target, scheduler: scheduler, recorder: recorder, center: center)
    }

    private func completion(_ run: String, title: String = "Build", at scheduler: ManualTitioScheduler) -> TitioNoticeFact {
        TitioNoticeFact(
            key: TitioNoticeIDs.runOutcome(runId: run, outcome: .completed),
            kind: .runCompleted,
            source: TitioNoticeSource(threadId: "T-\(run)", runId: run, workspaceId: "W"),
            facts: TitioNoticeFacts(title: title, workspaceName: "api", summary: "All green"),
            occurredAt: scheduler.now
        )
    }

    private func approval(_ request: String, at scheduler: ManualTitioScheduler) -> TitioNoticeFact {
        let facts = TitioNoticeFacts(title: "Deploy", workspaceName: "api", detail: "rm -rf build", requestTitle: "run a command")
        return TitioNoticeFact(
            key: TitioNoticeIDs.threadAttention(threadId: "T", requestId: request),
            kind: .approval,
            source: TitioNoticeSource(threadId: "T", requestId: request),
            facts: facts,
            actions: TitioNoticeAction.defaultActions(kind: .approval, facts: facts),
            occurredAt: scheduler.now
        )
    }

    private func legacy(_ identifier: String) -> TitioNoticeLegacyDelivery {
        TitioNoticeLegacyDelivery(
            content: RemoteCodeNotificationContent(
                identifier: identifier, title: "Action needed", body: "A run needs your attention.",
                categoryIdentifier: RemoteCodeNotificationContent.threadUpdateCategoryIdentifier,
                threadIdentifier: "T", userInfo: ["threadId": "T"], soundEnabled: true
            ),
            pushes: true
        )
    }

    private func waitForPushes(_ recorder: TitioHookRecorder, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while recorder.pushes.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func threadMessages(_ f: Fixture) throws -> [AgentMessage] {
        try f.messages.list(threadId: f.target.threadID)
    }

    // MARK: Delivery

    func test_mixedMutedInfoBatchObservesBothAndOnlyInterruptsAllowedSource() async throws {
        let f = try makeFixture()
        var muted = completion("muted", title: "Private", at: f.scheduler)
        muted.source.workspaceId = UUID().uuidString
        SettingsStore(db: f.db).update { $0.notificationMutedWorkspaceIDs = [muted.source.workspaceId!] }
        f.center.ingest(muted)
        XCTAssertNotNil(try f.repo.get(key: muted.key), "producer return already has durable observation")
        f.center.ingest(completion("allowed", title: "Public", at: f.scheduler))
        await f.scheduler.advance(by: TitioNoticeTiming.infoWindow, center: f.center)
        await waitForPushes(f.recorder, count: 1)
        XCTAssertEqual(try threadMessages(f).count, 2, "different delivery policies never share generated copy")
        XCTAssertEqual(f.recorder.banners.map(\.identifier), ["run.allowed.completed"])
        XCTAssertEqual(f.recorder.pushes.map(\.identifier), ["run.allowed.completed"])
        XCTAssertEqual(f.recorder.speech.count, 1)
        XCTAssertEqual(try f.repo.get(key: muted.key)?.state, .posted)
    }

    func test_runCompletionPostsOneMessageOneBannerOnePushWithTheRunIdentifier() async throws {
        // WHY: the key reuses today's banner identifier so the relay and
        // SystemNotifier dedupe a re-post; exactly one of each must go out.
        let f = try makeFixture()
        f.center.ingest(completion("R1", at: f.scheduler))
        await f.center.idle()
        XCTAssertTrue(try threadMessages(f).isEmpty, "info waits for the 8 s window")
        await f.scheduler.advance(by: TitioNoticeTiming.infoWindow, center: f.center)
        await waitForPushes(f.recorder, count: 1)

        let messages = try threadMessages(f)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].id.value, TitioNoticeIDs.messageID(forKey: "run.R1.completed"))
        XCTAssertEqual(messages[0].role, .assistant)
        XCTAssertTrue(TitioNoticeBlock.parse(messages[0].content).text.hasSuffix("Written notice."))
        XCTAssertEqual(f.recorder.banners.map(\.identifier), ["run.R1.completed"])
        XCTAssertEqual(f.recorder.pushes.map(\.identifier), ["run.R1.completed"])
        let banner = try XCTUnwrap(f.recorder.banners.first)
        XCTAssertEqual(banner.title, "Titio")
        XCTAssertEqual(banner.categoryIdentifier, RemoteCodeNotificationContent.titioNoticeCategoryIdentifier)
        XCTAssertEqual(banner.threadIdentifier, "bot.titio")
        XCTAssertEqual(banner.userInfo["conversationId"], f.target.conversationID.value.uuidString.lowercased())
        XCTAssertEqual(banner.userInfo["threadId"], "T-R1", "legacy keys keep old clients routing")
        XCTAssertEqual(f.recorder.pushes.first?.userInfo["profileId"], "profile-1")
        XCTAssertEqual(f.recorder.pushes.first?.userInfo["idempotencyKey"], "run.R1.completed")
        let row = try XCTUnwrap(f.repo.get(key: "run.R1.completed"))
        XCTAssertEqual(row.state, .posted)
        XCTAssertNotNil(row.bannerAt, "banner_at marks delivery so startup does not re-post")
        XCTAssertEqual(f.recorder.inbox.last?.unreadCount, 1)
        XCTAssertEqual(f.recorder.speech.count, 1, "the pet hears about the new notice")
        XCTAssertEqual(f.recorder.posted.first?.conversation?.unread, true)
        XCTAssertEqual(f.recorder.posted.first?.conversation?.attentionState, .unreadActivity)
    }

    func test_relayFailureRetriesCommittedNoticeWithoutAnotherMessage() async throws {
        let f = try makeFixture()
        f.recorder.pushAccepted = false
        f.center.ingest(completion("retry", at: f.scheduler))
        await f.scheduler.advance(by: TitioNoticeTiming.infoWindow, center: f.center)
        XCTAssertNil(try f.repo.get(key: "run.retry.completed")?.bannerAt)
        XCTAssertEqual(f.recorder.pushes.count, 1)

        f.recorder.pushAccepted = true
        await f.scheduler.advance(by: TitioNoticeTiming.retryBackoff[0], center: f.center)
        XCTAssertEqual(f.recorder.pushes.map(\.identifier), ["run.retry.completed", "run.retry.completed"])
        XCTAssertEqual(try threadMessages(f).count, 1)
        XCTAssertEqual(f.recorder.posted.count, 1)
        XCTAssertNotNil(try f.repo.get(key: "run.retry.completed")?.bannerAt)
        await f.scheduler.advance(by: 60, center: f.center)
        XCTAssertEqual(f.recorder.pushes.count, 2)
    }

    func test_resolvedDecisionIsNotPushedAgainAfterRelayFailure() async throws {
        let f = try makeFixture()
        f.recorder.pushAccepted = false
        f.center.ingest(approval("retry", at: f.scheduler))
        await f.center.idle()
        XCTAssertEqual(f.recorder.pushes.count, 1)
        f.center.sourceResolved(key: "thread.T.attention.retry")
        await f.center.idle()
        f.recorder.pushAccepted = true
        await f.scheduler.advance(by: 60, center: f.center)
        XCTAssertEqual(f.recorder.pushes.count, 1)
    }

    func test_singleNoticeWritesRawProvenanceInTheBlockWithoutAHeading() async throws {
        // WHY: the card renders provenance from the block; markdown escapes
        // belong to the old heading only and would show as stray backslashes.
        let f = try makeFixture()
        f.center.ingest(completion("R1", title: "Fix *login* → now", at: f.scheduler))
        await f.center.idle()
        await f.scheduler.advance(by: TitioNoticeTiming.infoWindow, center: f.center)
        await waitForPushes(f.recorder, count: 1)

        let content = try XCTUnwrap(try threadMessages(f).first).content
        let parsed = TitioNoticeBlock.parse(content)
        XCTAssertEqual(parsed.block?.source["conversation"], "Fix *login* → now", "labels are raw, not markdown-escaped")
        XCTAssertEqual(parsed.block?.source["workspace"], "api")
        XCTAssertEqual(parsed.block?.state, "open")
        XCTAssertFalse(parsed.text.contains(" → "), "no ws → bot → title heading")
        XCTAssertFalse(parsed.text.contains("\\*"))
    }

    func test_eightSecondWindowMergesThreeCompletionsIntoOneDigest() async throws {
        // WHY: bursts of completions must read as one message, not three pings.
        let f = try makeFixture()
        f.center.ingest(completion("R1", at: f.scheduler))
        await f.scheduler.advance(by: 3, center: f.center)
        f.center.ingest(completion("R2", title: "Lint", at: f.scheduler))
        await f.scheduler.advance(by: 3, center: f.center)
        f.center.ingest(completion("R3", title: "Docs", at: f.scheduler))
        await f.scheduler.advance(by: 7.9, center: f.center)
        XCTAssertTrue(try threadMessages(f).isEmpty, "the window slides with each arrival")
        await f.scheduler.advance(by: 0.2, center: f.center)
        await waitForPushes(f.recorder, count: 1)

        let messages = try threadMessages(f)
        XCTAssertEqual(messages.count, 1)
        let keys = ["run.R1.completed", "run.R2.completed", "run.R3.completed"]
        XCTAssertEqual(messages[0].id.value, TitioNoticeIDs.digestMessageID(forKeys: keys))
        XCTAssertEqual(messages[0].content, "Written digest.")
        let digestID = TitioNoticeIDs.digestBannerIdentifier(messageID: messages[0].id.value)
        XCTAssertEqual(f.recorder.banners.map(\.identifier), [digestID])
        XCTAssertEqual(f.recorder.pushes.map(\.identifier), [digestID], "one push per flushed message")
        XCTAssertEqual(try keys.compactMap { try f.repo.get(key: $0)?.batchID }.count, 3)
    }

    func test_thirtySecondCapHoldsUnderSteadyArrivals() async throws {
        // WHY: a steady trickle must not postpone the digest forever.
        let f = try makeFixture()
        for index in 0..<7 {
            f.center.ingest(completion("R\(index)", at: f.scheduler))
            await f.scheduler.advance(by: 5, center: f.center)
        }
        // Arrivals at 0,5,…,30: the cap fires at 30 s from the first item.
        let messages = try threadMessages(f)
        XCTAssertEqual(messages.count, 1, "exactly one digest at the 30 s cap")
        let posted = try (0..<7).compactMap { try f.repo.get(key: "run.R\($0).completed") }.filter { $0.state == .posted }
        XCTAssertEqual(posted.count, 6, "items 0…5 arrived inside the capped window")
        XCTAssertEqual(posted.first?.postedAt, f.scheduler.start.addingTimeInterval(TitioNoticeTiming.infoMaxWait))
    }

    func test_decisionAndPendingInfoBothReachTheInboxWithoutBlockingUrgentIntake() async throws {
        // Urgent intake must not wait for informational copy generation.
        let f = try makeFixture()
        f.center.ingest(completion("R1", at: f.scheduler))
        await f.scheduler.advance(by: 2, center: f.center)
        f.center.ingest(approval("Q1", at: f.scheduler), legacy: legacy("thread.T.attention.Q1"))
        await f.center.idle()

        let posted = f.recorder.posted.map(\.message.id.value)
        XCTAssertEqual(Set(posted), Set([
            TitioNoticeIDs.messageID(forKey: "run.R1.completed"),
            TitioNoticeIDs.messageID(forKey: "thread.T.attention.Q1"),
        ]))
        let decision = try XCTUnwrap(try f.repo.get(key: "thread.T.attention.Q1"))
        XCTAssertEqual(decision.state, .posted)
        XCTAssertEqual(decision.actions?.compactMap(\.label), ["Approve", "Decline", "Open conversation"])
        let text = try XCTUnwrap(f.messages.get(id: AgentMessageID(TitioNoticeIDs.messageID(forKey: "thread.T.attention.Q1"))))
        XCTAssertEqual(BotChoicesBlock.parse(text.content).choices?.notice, "thread.T.attention.Q1")
        XCTAssertEqual(f.recorder.posted.last?.conversation?.attentionState, .needsAttention)
        XCTAssertEqual(f.recorder.inbox.last?.openDecisions, 1)
        XCTAssertTrue(f.recorder.postedOffMain.allSatisfy { $0 }, "ledger and flush work never run on the main thread")
        XCTAssertEqual(f.scheduler.pendingTimerCount, 0, "no info timer is left behind")
    }

    func test_flappingSSHDisconnectInsideEightSecondsPostsNothing() async throws {
        // WHY: a reconnect inside the hold is noise; it must leave no message.
        let f = try makeFixture()
        let key = TitioNoticeIDs.petSSHDisconnect(surfaceId: "S1")
        f.center.ingest(TitioNoticeFact(key: key, kind: .sshDisconnected, facts: TitioNoticeFacts(title: "prod"), occurredAt: f.scheduler.now))
        await f.scheduler.advance(by: 5, center: f.center)
        f.center.sourceResolved(key: key)
        await f.scheduler.advance(by: 10, center: f.center)

        XCTAssertTrue(try threadMessages(f).isEmpty)
        XCTAssertTrue(f.recorder.banners.isEmpty)
        let row = try XCTUnwrap(f.repo.get(key: key))
        XCTAssertEqual(row.state, .dropped)
        XCTAssertEqual(row.resolution, .flap)
    }

    func test_heldDisconnectThatStaysDownPostsAfterEightSeconds() async throws {
        // WHY: the hold only filters flaps; a real outage must still reach the user.
        let f = try makeFixture()
        let key = TitioNoticeIDs.petSSHDisconnect(surfaceId: "S1")
        f.center.ingest(TitioNoticeFact(key: key, kind: .sshDisconnected, facts: TitioNoticeFacts(title: "prod"), occurredAt: f.scheduler.now))
        await f.scheduler.advance(by: TitioNoticeTiming.flapHold, center: f.center)
        XCTAssertEqual(try threadMessages(f).count, 1)
        XCTAssertEqual(f.recorder.banners.map(\.identifier), [key])
    }

    func test_restartAfterCrashBetweenCommitAndBannerRepostsTheBannerWithoutASecondMessage() async throws {
        // WHY: exactly-once: the message is durable, so a restart re-sends only
        // the banner, with the same identifier the relay deduplicates.
        let f = try makeFixture()
        let key = "run.R9.failed"
        let facts = TitioNoticeFacts(title: "Build", workspaceName: "api")
        try f.repo.ingest(TitioNoticeFact(key: key, kind: .runFailed, facts: facts,
                                          actions: TitioNoticeAction.defaultActions(kind: .runFailed, facts: facts),
                                          occurredAt: f.scheduler.now))
        let uuid = TitioNoticeIDs.messageID(forKey: key)
        _ = try f.repo.flush(keys: [key], postedAt: f.scheduler.now) { rows in
            try f.messages.append(AgentMessage(id: AgentMessageID(uuid), threadId: f.target.threadID, role: .assistant,
                                               content: "Uh-oh, **Build** in **api** failed.", createdAt: f.scheduler.now))
            return TitioNoticePosting(messageID: uuid.uuidString, preview: "Uh-oh")
        }
        // The process died here: no banner, no banner_at.

        f.center.start(subscribeToEvents: false)
        await f.center.idle()
        await waitForPushes(f.recorder, count: 1)

        XCTAssertEqual(try threadMessages(f).count, 1, "no duplicate message")
        XCTAssertEqual(f.recorder.banners.map(\.identifier), [key])
        XCTAssertEqual(f.recorder.pushes.map(\.identifier), [key])
        XCTAssertNotNil(try f.repo.get(key: key)?.bannerAt)
        XCTAssertTrue(f.recorder.posted.isEmpty, "a re-post is not a new message event")
    }

    func test_titioUnavailableDecisionPostsLegacyBannerWithinFiveSecondsAndStaysPending() async throws {
        // WHY: fail loud: an approval must never vanish because the inbox could
        // not be created; info may wait, decisions may not.
        let f = try makeFixture(available: false)
        let key = "thread.T.attention.Q1"
        f.center.ingest(approval("Q1", at: f.scheduler), legacy: legacy(key))
        await f.center.idle()
        XCTAssertTrue(f.recorder.banners.isEmpty)
        await f.scheduler.advance(by: TitioNoticeTiming.legacyFallbackAfter, center: f.center)
        await waitForPushes(f.recorder, count: 1)

        XCTAssertEqual(f.recorder.banners.map(\.identifier), [key])
        XCTAssertEqual(f.recorder.banners.first?.title, "Action needed", "the legacy banner, byte for byte")
        XCTAssertEqual(f.recorder.pushes.map(\.identifier), [key])
        XCTAssertEqual(try f.repo.get(key: key)?.state, .pending)
        XCTAssertGreaterThanOrEqual(f.recorder.resolveCalls, 2, "the inbox keeps retrying with backoff")

        // Titio comes back: the row posts on the next retry, and the legacy banner is not repeated.
        f.recorder.target = f.target
        await f.scheduler.advance(by: 30, center: f.center)
        XCTAssertEqual(try f.repo.get(key: key)?.state, .posted)
        XCTAssertEqual(f.recorder.banners.filter { $0.title == "Action needed" }.count, 1)
    }

    func test_scheduledFailureWithAgentRunAndTheRunFailureShareOneNotice() async throws {
        // WHY: one failure, one notice: the scheduled producer merges into the
        // run's key instead of posting a second message.
        let f = try makeFixture()
        let key = TitioNoticeIDs.scheduledFailure(scheduledRunId: "S1", agentRunId: "R1")
        XCTAssertEqual(key, TitioNoticeIDs.runOutcome(runId: "R1", outcome: .failed))
        f.center.ingest(TitioNoticeFact(key: key, kind: .runFailed, facts: TitioNoticeFacts(title: "Nightly"), occurredAt: f.scheduler.now))
        f.center.ingest(TitioNoticeFact(key: key, kind: .scheduledFailed,
                                        source: TitioNoticeSource(scheduledTaskId: "task-1"),
                                        facts: TitioNoticeFacts(title: "Nightly"), occurredAt: f.scheduler.now))
        await f.center.idle()
        await f.scheduler.advance(by: 30, center: f.center)
        XCTAssertEqual(try threadMessages(f).count, 1)
        XCTAssertEqual(f.recorder.banners.count, 1)
    }

    func test_burstOfFiftyEventsLosesAndDuplicatesNothing() async throws {
        // WHY: rapid A→B bursts (replays included) must give one row per key
        // and every key in exactly one message.
        let f = try makeFixture()
        for index in 0..<50 {
            f.center.ingest(completion("R\(index % 25)", at: f.scheduler))
        }
        await f.center.idle()
        await f.scheduler.advance(by: TitioNoticeTiming.infoWindow, center: f.center)
        let rows = try (0..<25).compactMap { try f.repo.get(key: "run.R\($0).completed") }
        XCTAssertEqual(rows.count, 25)
        XCTAssertEqual(Set(rows.compactMap(\.messageID)).count, 1, "all in one digest")
        XCTAssertEqual(try threadMessages(f).count, 1)
        XCTAssertEqual(try threadMessages(f)[0].content, "Written digest.")
    }

    func test_postedDecisionResolvedElsewhereIsRewrittenInPlaceWithoutANewMessage() async throws {
        // WHY: a request answered on the phone or in the thread must lose its
        // card (no stale approve button) and must not add noise.
        let f = try makeFixture()
        let key = "thread.T.attention.Q1"
        f.center.ingest(approval("Q1", at: f.scheduler), legacy: legacy(key))
        await f.center.idle()
        f.center.sourceResolved(key: key)
        await f.center.idle()

        let messages = try threadMessages(f)
        XCTAssertEqual(messages.count, 1)
        XCTAssertNil(BotChoicesBlock.parse(messages[0].content).choices, "the card is gone")
        XCTAssertTrue(TitioNoticeBlock.parse(messages[0].content).text.hasSuffix("_Written status._"), messages[0].content)
        XCTAssertEqual(TitioNoticeBlock.parse(messages[0].content).block?.state, "elsewhere")
        XCTAssertEqual(try f.messages.bodyRevision(id: messages[0].id), 3)
        XCTAssertEqual(f.recorder.posted.last?.isRewrite, true)
        XCTAssertEqual(f.recorder.posted.last?.bodyRevision, 3)
        XCTAssertEqual(f.recorder.banners.count, 1, "no banner for a resolution")
        XCTAssertEqual(try f.repo.get(key: key)?.state, .resolved)
        XCTAssertEqual(f.recorder.inbox.last?.openDecisions, 0)
    }

    func test_infoWaitsWhileTitioRunsButNotPastTheHold() async throws {
        // WHY: Titio answering in the inbox must not be interleaved with
        // digests, but info may wait at most 30 s for it.
        let f = try makeFixture()
        f.center.ingest(approval("Q0", at: f.scheduler))
        await f.center.idle() // binds the inbox target
        f.recorder.titioRunActive = true
        f.center.ingest(completion("R1", at: f.scheduler))
        await f.scheduler.advance(by: TitioNoticeTiming.infoWindow + 10, center: f.center)
        XCTAssertNil(try f.messages.get(id: AgentMessageID(TitioNoticeIDs.messageID(forKey: "run.R1.completed"))))
        await f.scheduler.advance(by: TitioNoticeTiming.titioRunHold, center: f.center)
        XCTAssertNotNil(try f.messages.get(id: AgentMessageID(TitioNoticeIDs.messageID(forKey: "run.R1.completed"))))
    }

    func test_notificationsDeniedIsInAppOnly() async throws {
        // WHY: the system denied banners; posting another banner or a push for
        // that fact would be pointless and loop through onDeniedPost.
        let f = try makeFixture()
        f.center.ingest(TitioNoticeFact(key: TitioNoticeIDs.notificationsDenied, kind: .notificationsDenied, occurredAt: f.scheduler.now))
        await f.scheduler.advance(by: TitioNoticeTiming.infoWindow, center: f.center)
        XCTAssertEqual(try threadMessages(f).count, 1)
        XCTAssertTrue(f.recorder.banners.isEmpty)
        XCTAssertTrue(f.recorder.pushes.isEmpty)
        XCTAssertNotNil(try f.repo.get(key: TitioNoticeIDs.notificationsDenied)?.bannerAt,
                        "marked delivered so a restart never re-posts a banner for it")
    }

    func test_viewedInboxPostDoesNotCountAsUnread() async throws {
        // WHY: a notice the user sees arrive is already read.
        let f = try makeFixture()
        f.recorder.viewing = true
        f.center.ingest(completion("R1", at: f.scheduler))
        await f.scheduler.advance(by: TitioNoticeTiming.infoWindow, center: f.center)
        XCTAssertEqual(f.recorder.inbox.last?.unreadCount, 0)
        XCTAssertEqual(f.recorder.posted.last?.conversation?.unread, false)
        XCTAssertEqual(f.recorder.posted.last?.conversation?.attentionState, BotAttentionState.none)
    }

    func test_markInboxReadZeroesUnreadAndPublishes() async throws {
        // WHY: opening the inbox on the Mac clears the roster/iOS count (§8).
        let f = try makeFixture()
        f.center.ingest(completion("R1", at: f.scheduler))
        await f.scheduler.advance(by: TitioNoticeTiming.infoWindow, center: f.center)
        XCTAssertEqual(try f.repo.inboxState().unreadCount, 1)
        f.center.markInboxRead()
        await f.center.idle()
        XCTAssertEqual(try f.repo.inboxState().unreadCount, 0)
        XCTAssertEqual(f.recorder.inbox.last?.unreadCount, 0)
        XCTAssertEqual(try f.store.conversation(id: f.target.conversationID)?.unread, false)
    }

    func test_directReplyBannerOpensTheConversationAndIsNotANotice() async throws {
        // WHY: Titio's own replies get a banner with its first line, never an
        // inbox message (that would echo the chat into itself).
        let f = try makeFixture(profileID: nil)
        let run = AgentRunID()
        f.center.postDirectReplyBanner(botID: f.target.botID, conversationID: f.target.conversationID,
                                       runID: run, text: "**Pronto!** Fiz o deploy.\nDetalhes…", messageID: nil)
        await f.center.idle()
        await waitForPushes(f.recorder, count: 1)
        XCTAssertTrue(try threadMessages(f).isEmpty)
        let banner = try XCTUnwrap(f.recorder.banners.first)
        XCTAssertEqual(banner.title, "Titio")
        XCTAssertEqual(banner.body, "Pronto! Fiz o deploy.")
        XCTAssertEqual(banner.userInfo["botId"], f.target.botID.value.uuidString.lowercased(), "the Mac banner always routes to the bot")
        XCTAssertNil(f.recorder.pushes.first?.userInfo["botId"], "no profile binding: iOS must fall back, not get a nil route")
        XCTAssertEqual(f.recorder.pushes.first?.userInfo["threadId"], f.target.threadID.value.uuidString,
                       "a reply without a unique profile must still open its exact thread")
    }

    func testDirectReplyRespectsCompletionPreferenceAndBotMute() async throws {
        let f = try makeFixture()
        let settings = SettingsStore(db: f.db)
        var value = settings.load()
        value.notificationCompletionAlertsEnabled = false
        settings.save(value)
        f.center.postDirectReplyBanner(botID: f.target.botID, conversationID: f.target.conversationID,
                                      runID: AgentRunID(), text: "Ready", messageID: nil)
        await f.center.idle()
        XCTAssertTrue(f.recorder.banners.isEmpty)
        value.notificationCompletionAlertsEnabled = true
        settings.save(value)
        _ = try f.store.updateProfile(id: f.target.botID, notificationsEnabled: false)
        f.center.postDirectReplyBanner(botID: f.target.botID, conversationID: f.target.conversationID,
                                      runID: AgentRunID(), text: "Ready", messageID: nil)
        await f.center.idle()
        XCTAssertTrue(f.recorder.banners.isEmpty)
        XCTAssertTrue(f.recorder.pushes.isEmpty)
    }

    func test_actAnswersNavigationAndUnknownMessagesWithoutChangingState() async throws {
        // WHY: a card an LLM forged has no ledger row (not_found); navigation
        // must never claim a notice.
        let f = try makeFixture()
        f.center.ingest(TitioNoticeFact(key: "run.R1.failed", kind: .runFailed,
                                        source: TitioNoticeSource(threadId: "T1", workspaceId: "W1"),
                                        facts: TitioNoticeFacts(title: "Build"),
                                        actions: [.openThread, .ack], occurredAt: f.scheduler.now))
        await f.center.idle()
        let messageID = TitioNoticeIDs.messageID(forKey: "run.R1.failed").uuidString
        let forged = await f.center.act(messageID: UUID().uuidString, optionIndex: 0)
        XCTAssertEqual(forged, .notFound)
        let navigate = await f.center.act(messageID: messageID.lowercased(), optionIndex: 0)
        XCTAssertEqual(navigate, .navigate(route: ["threadId": "T1", "workspaceId": "W1"]))
        XCTAssertEqual(try f.repo.get(key: "run.R1.failed")?.state, .posted)
        let ack = await f.center.act(messageID: messageID, optionIndex: 1)
        XCTAssertEqual(ack, .unsupported, "no executor yet: never claimed, never faked")
        XCTAssertEqual(try f.repo.get(key: "run.R1.failed")?.state, .posted)
        let outOfRange = await f.center.act(messageID: messageID, optionIndex: 9)
        XCTAssertEqual(outOfRange, .invalidOption)
    }

    func test_startupPrunesOldResolvedRowsAndCatchesUpPendingRowsInOneDigest() async throws {
        // WHY: rows that piled up while the app was closed read as one catch-up
        // digest, decisions keep their own card, and the ledger stays bounded.
        let f = try makeFixture()
        let old = f.scheduler.start.addingTimeInterval(-TitioNoticeTiming.retention - 60)
        try f.repo.ingest(TitioNoticeFact(key: "run.OLD.completed", kind: .runCompleted, occurredAt: old))
        _ = try f.repo.drop(key: "run.OLD.completed", resolution: .elsewhere, at: old)
        try f.repo.ingest(completion("R1", at: f.scheduler))
        try f.repo.ingest(completion("R2", at: f.scheduler))
        try f.repo.ingest(approval("Q1", at: f.scheduler))
        f.center.start(subscribeToEvents: false)
        await f.center.idle()

        XCTAssertNil(try f.repo.get(key: "run.OLD.completed"), "pruned after 30 days")
        let messages = try threadMessages(f)
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.contains { $0.content == "Written digest." })
        XCTAssertTrue(messages.contains { BotChoicesBlock.parse($0.content).choices?.notice == "thread.T.attention.Q1" })
    }

    func test_isEnabledNeedsStartAndTheKillSwitch() throws {
        // WHY: before launch finishes (and in unit tests that build an
        // AppContext) and with the switch off, every hook keeps today's code.
        let f = try makeFixture()
        var settings = AppSettings()
        XCTAssertFalse(f.center.isEnabled(settings), "not started")
        f.center.start(subscribeToEvents: false)
        XCTAssertTrue(f.center.isEnabled(settings))
        settings.titioNotificationsEnabled = false
        XCTAssertFalse(f.center.isEnabled(settings), "kill switch")
    }

    // MARK: Bot attention projector (pure rules)

    func test_attentionPlanRetainsMutedBotsSkipsTitioAndThreadCoveredItemsAndResolvesAcknowledged() throws {
        // WHY: a Bot failure must produce exactly one notice (from here), never
        // for Titio, and never twice when the thread's request
        // notice already covers it.
        let bot = BotDefinition(handle: "reviewer", name: "Reviewer", title: "", description: "")
        var muted = BotDefinition(handle: "muted", name: "Muted", title: "", description: "")
        muted.notificationsEnabled = false
        let titio = BotDefinition(handle: "titio", name: "Titio", title: "", description: "")
        let covered = BotConversationID()
        let coveredThread = AgentThreadID()
        let blocked = BotAttentionItem(botID: bot.id, kind: .blocked, title: "Stuck", detail: "VM down")
        let question = BotAttentionItem(botID: bot.id, conversationID: covered, kind: .question, title: "Ask")
        let mutedItem = BotAttentionItem(botID: muted.id, kind: .blocked, title: "x")
        let titioItem = BotAttentionItem(botID: titio.id, kind: .question, title: "x")
        let unread = BotAttentionItem(botID: bot.id, kind: .unread, title: "x")
        let plan = TitioNoticeCenter.attentionPlan(
            items: [blocked, question, mutedItem, titioItem, unread],
            bots: [bot.id: bot, muted.id: muted, titio.id: titio],
            openBotKeys: ["bot.attention.GONE"],
            openThreadKeys: ["thread.\(coveredThread.value.uuidString).attention.REQ"],
            linkedThread: { $0 == covered ? coveredThread : nil }
        )
        XCTAssertEqual(plan.ingest.map(\.key), [blocked, mutedItem].map { "bot.attention.\($0.id.value.uuidString)" })
        XCTAssertEqual(plan.ingest.first?.kind, .botBlocked)
        XCTAssertEqual(plan.ingest.first?.facts.detail, "VM down")
        XCTAssertEqual(plan.ingest.first?.facts.botName, "Reviewer")
        XCTAssertEqual(plan.resolved, ["bot.attention.GONE"], "acknowledged elsewhere resolves the open notice")
    }

    func test_petEventMappingCoversEveryTerminalKind() {
        // WHY: every pet/terminal event the pet records must become its notice kind.
        XCTAssertEqual(TitioNoticeCenter.noticeKind(for: .gitDelivery(.failed)), .gitFailed)
        XCTAssertEqual(TitioNoticeCenter.noticeKind(for: .gitDelivery(.succeeded)), .gitCompleted)
        XCTAssertEqual(TitioNoticeCenter.noticeKind(for: .projectScript(.failed)), .scriptFailed)
        XCTAssertEqual(TitioNoticeCenter.noticeKind(for: .sshTransfer(.succeeded)), .transferCompleted)
        XCTAssertEqual(TitioNoticeCenter.noticeKind(for: .sshUnexpectedDisconnect), .sshDisconnected)
        XCTAssertEqual(TitioNoticeCenter.noticeKind(for: .fileConflict), .fileConflict)
        XCTAssertEqual(TitioNoticeCenter.noticeKind(for: .providerUpdateFailed), .providerUpdateFailed)
        XCTAssertEqual(TitioNoticeCenter.petTitle(payload: ["name": .string("test")]), "test")
        XCTAssertEqual(TitioNoticeCenter.petTitle(payload: ["path": .string("/a/b/main.swift")]), "main.swift")
    }

    func test_focusedSuccessIsPersistedWithoutInterruptingAndFailureStillCounts() async throws {
        // WHY: a success the user is watching is noise; a failure always counts (§2).
        let f = try makeFixture()
        f.recorder.focusedSuccess = true
        let workspace = UUID().uuidString
        let ts = f.scheduler.now.timeIntervalSince1970
        f.center.handleEvent(EventBus.Event(seq: 7, kind: "git.push",
                                            payload: .object(["workspace_id": .string(workspace), "ok": .bool(true)]), ts: ts))
        f.center.handleEvent(EventBus.Event(seq: 8, kind: "git.push",
                                            payload: .object(["workspace_id": .string(workspace), "ok": .bool(false)]), ts: ts))
        await f.center.idle()
        XCTAssertEqual(try f.repo.get(key: "pet.event.7")?.facts.interruptionSuppressed, true)
        XCTAssertEqual(try f.repo.get(key: "pet.event.8")?.kind, .gitFailed)
    }

    func test_petEventFromTheBusIsIngestedWithTheSequenceKey() async throws {
        // WHY: pet events reach Titio without PetController (independent subscriber).
        let f = try makeFixture()
        let workspace = UUID().uuidString
        let event = EventBus.Event(seq: 42, kind: "git.push",
                                   payload: .object(["workspace_id": .string(workspace), "ok": .bool(false)]),
                                   ts: f.scheduler.now.timeIntervalSince1970)
        f.center.handleEvent(event)
        await f.center.idle()
        let row = try XCTUnwrap(f.repo.get(key: "pet.event.42"))
        XCTAssertEqual(row.kind, .gitFailed)
        XCTAssertEqual(row.state, .posted, "a failure is an alert: posted at once")
    }
}

/// The §5 hook rules on a real AppContext: which run outcomes and requests
/// become notices. The center is not started here, so nothing posts; the
/// ledger shows what was ingested.
@MainActor
final class TitioNoticeHookTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        directory = NSTemporaryDirectory() + "rc-titio-hooks-\(UUID().uuidString)"
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
        directory = nil
    }

    private func makeContext() throws -> (AppContext, AppCommandRouter) {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        return (context, router)
    }

    private func linkedThread(_ context: AppContext, handle: String, notifications: Bool = true) throws -> (BotDefinition, BotConversation, AgentThread) {
        let bot = try context.botStore.create(name: handle.capitalized, title: "", description: "", handle: handle,
                                              notificationsEnabled: notifications)
        let thread = AgentThread(title: "Desk", provider: .distill, model: "m")
        try context.threadRepo.upsert(thread)
        let conversation = BotConversation(botID: bot.id, title: "Chat", linkedAgentThreadID: thread.id)
        try context.botStore.upsertConversation(conversation)
        return (bot, conversation, thread)
    }

    private func legacy() -> RemoteCodeNotificationContent {
        RemoteCodeNotificationContent(identifier: "x", title: "Thread finished", body: "Run response is ready.",
                                      categoryIdentifier: "", threadIdentifier: "", userInfo: [:], soundEnabled: false)
    }

    private func runOutcome(_ context: AppContext, thread: AgentThread, status: AgentRunStatus, finalMessageId: String? = nil) async -> (AgentRunID, Bool) {
        let run = AgentRunID()
        let facts = AppContext.titioRunFacts(runId: run, threadId: thread.id, finalMessageId: finalMessageId,
                                             db: context.db, botStore: context.botStore, runRepo: context.runRepo)
        let handled = context.ingestTitioRunOutcome(
            threadId: thread.id, runId: run, status: status, workspaceId: nil, threadTitle: thread.title,
            finalMessageId: finalMessageId, facts: facts, legacy: legacy()
        )
        await context.titioNoticeCenter.idle()
        return (run, handled)
    }

    func test_botLinkedCompletionBecomesABotReplyAndItsFailureIsLeftToTheProjector() async throws {
        // WHY: a Bot failure must produce exactly one notice; the bot-attention
        // projector owns it, so the run hook stays silent on failure.
        let (context, _) = try makeContext()
        let (_, _, thread) = try linkedThread(context, handle: "reviewer")
        let repo = TitioNoticeRepository(db: context.db)

        let (completed, handledCompleted) = await runOutcome(context, thread: thread, status: .completed)
        XCTAssertTrue(handledCompleted)
        let reply = try XCTUnwrap(repo.get(key: TitioNoticeIDs.botReply(runId: completed.value.uuidString)))
        XCTAssertEqual(reply.kind, .botReply)
        XCTAssertEqual(reply.facts.botName, "Reviewer")

        let (failed, handledFailed) = await runOutcome(context, thread: thread, status: .failed)
        XCTAssertTrue(handledFailed, "handled: today's banner must not fire either")
        XCTAssertNil(try repo.get(key: TitioNoticeIDs.runOutcome(runId: failed.value.uuidString, outcome: .failed)))
        XCTAssertTrue(try repo.listPending().allSatisfy { $0.kind == .botReply })
    }

    func test_titioLinkedCompletionIsNeverANotice() async throws {
        // WHY: Titio's own replies would echo the chat into the inbox; they get
        // only a direct reply banner.
        let (context, _) = try makeContext()
        let (_, _, thread) = try linkedThread(context, handle: "titio")
        let message = AgentMessage(threadId: thread.id, role: .assistant, content: "Feito!")
        try context.messageRepo.append(message)
        let (run, handled) = await runOutcome(context, thread: thread, status: .completed,
                                              finalMessageId: message.id.value.uuidString)
        XCTAssertTrue(handled)
        XCTAssertNil(try TitioNoticeRepository(db: context.db).get(key: TitioNoticeIDs.botReply(runId: run.value.uuidString)))
        XCTAssertTrue(try TitioNoticeRepository(db: context.db).listPending().isEmpty)

        let (_, failureHandled) = await runOutcome(context, thread: thread, status: .failed)
        XCTAssertFalse(failureHandled, "a Titio failure keeps today's banner")
    }

    func test_botWithNotificationsOffRetainsNoticeWithoutInterruption() async throws {
        // The Bot toggle controls interruption, while inbox intake remains durable.
        let (context, _) = try makeContext()
        let (_, _, thread) = try linkedThread(context, handle: "quiet", notifications: false)
        let (run, handled) = await runOutcome(context, thread: thread, status: .completed)
        XCTAssertTrue(handled)
        let row = try XCTUnwrap(TitioNoticeRepository(db: context.db).get(key: TitioNoticeIDs.botReply(runId: run.value.uuidString)))
        XCTAssertEqual(row.facts.interruptionSuppressed, true)
    }

    func test_mainThreadFailureCarriesItsCardAndActivityRoute() async throws {
        // WHY: a failure is an alert with [Open thread, Got it]; the Activity
        // item id keeps the legacy push route working.
        let (context, _) = try makeContext()
        let thread = AgentThread(title: "Build", provider: .distill, model: "m")
        try context.threadRepo.upsert(thread)
        let (run, handled) = await runOutcome(context, thread: thread, status: .failed)
        XCTAssertTrue(handled)
        let row = try XCTUnwrap(TitioNoticeRepository(db: context.db).get(
            key: TitioNoticeIDs.runOutcome(runId: run.value.uuidString, outcome: .failed)))
        XCTAssertEqual(row.kind, .runFailed)
        XCTAssertEqual(row.actions?.map(\.action), [.openThread, .ack])
        XCTAssertEqual(row.source.activityItemId, "run:\(run.value.uuidString.lowercased())")
        XCTAssertEqual(row.facts.title, "Build")
    }

    func test_requestFactsCarryTheRealRequestAndATitioThreadKeepsTheLegacyBanner() async throws {
        // WHY: today's push discarded the request title; the notice must print
        // the real one, offer only actions the provider supports, and never
        // turn a request inside Titio's own thread into a notice.
        let (context, _) = try makeContext()
        let thread = AgentThread(title: "Deploy", provider: .distill, model: "m")
        try context.threadRepo.upsert(thread)
        let facts = TitioRequestFacts(kind: .approval, legacyActionTitle: "Approve: Run command",
                                      requestTitle: "Run command", detail: "rm -rf build", allowsSessionApproval: false)
        let runID = AgentRunID()
        XCTAssertTrue(context.ingestTitioRequest(threadId: thread.id, runId: runID, requestId: "R1",
                                                 facts: facts, chrome: nil, legacy: legacy()))
        await context.titioNoticeCenter.idle()
        let key = TitioNoticeIDs.threadAttention(threadId: thread.id.value.uuidString, requestId: "R1",
                                                 runId: runID.value.uuidString)
        let row = try XCTUnwrap(TitioNoticeRepository(db: context.db).get(key: key))
        XCTAssertEqual(row.kind, .approval)
        XCTAssertEqual(row.facts.requestTitle, "Run command")
        XCTAssertEqual(row.facts.detail, "rm -rf build")
        XCTAssertEqual(row.actions?.map(\.action), [.approve, .decline, .openThread])

        let (_, _, titioThread) = try linkedThread(context, handle: "titio")
        XCTAssertFalse(context.ingestTitioRequest(threadId: titioThread.id, runId: AgentRunID(), requestId: "R2",
                                                  facts: facts, chrome: nil, legacy: legacy()))
    }
}
