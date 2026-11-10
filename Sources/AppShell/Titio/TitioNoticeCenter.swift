import CoreModel
import Foundation
import os
import Persistence
import SocketServer

private let titioNoticeLog = Logger(subsystem: "io.remotecode.app", category: "titio-notices")

// MARK: - Seams

/// A cancellable timer from `TitioNoticeScheduling`.
public protocol TitioNoticeTimer: AnyObject, Sendable {
    func cancel()
}

/// Timer seam: production uses `DispatchTitioNoticeScheduler`; tests inject a
/// manual clock so the §4 windows are deterministic.
public protocol TitioNoticeScheduling: Sendable {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> TitioNoticeTimer
}

private final class DispatchTitioNoticeTimer: TitioNoticeTimer, @unchecked Sendable {
    private let item: DispatchWorkItem
    init(item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

public struct DispatchTitioNoticeScheduler: TitioNoticeScheduling {
    public init() {}

    public func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> TitioNoticeTimer {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return DispatchTitioNoticeTimer(item: item)
    }
}

/// Titio, its Notifications conversation and that conversation's thread.
public struct TitioInboxTarget: Equatable, Sendable {
    public var botID: BotID
    public var conversationID: BotConversationID
    public var threadID: AgentThreadID

    public init(botID: BotID, conversationID: BotConversationID, threadID: AgentThreadID) {
        self.botID = botID
        self.conversationID = conversationID
        self.threadID = threadID
    }
}

/// The legacy banner (and push) a hook would have posted. Decisions and
/// alerts that cannot post as a Titio message within
/// `TitioNoticeTiming.legacyFallbackAfter` post it instead (fail loud, §3.6).
public struct TitioNoticeLegacyDelivery: Sendable {
    public var content: RemoteCodeNotificationContent
    public var pushes: Bool

    public init(content: RemoteCodeNotificationContent, pushes: Bool) {
        self.content = content
        self.pushes = pushes
    }
}

/// What the pet speech bubble shows for a new notice (stage 4 renders it).
public struct TitioNoticeSpeech: Equatable, Sendable {
    public static let maxCharacters = 90
    public var text: String
    public var urgency: TitioNoticeUrgency
    public var messageID: AgentMessageID
    public var botID: BotID
    public var conversationID: BotConversationID
}

/// The inputs of the §16 language rule.
public struct TitioNoticeLanguageInputs: Sendable {
    /// The user's recent Titio messages, newest first.
    public var recentUserTexts: [String]
    /// Labels of recent cards: a tap is stored as a user row with its label.
    public var cardLabels: Set<String>
    public var preferredLanguages: [String]

    public init(lastUserText: String?, preferredLanguages: [String]) {
        self.init(recentUserTexts: lastUserText.map { [$0] } ?? [], cardLabels: [], preferredLanguages: preferredLanguages)
    }

    public init(recentUserTexts: [String], cardLabels: Set<String>, preferredLanguages: [String]) {
        self.recentUserTexts = recentUserTexts
        self.cardLabels = cardLabels
        self.preferredLanguages = preferredLanguages
    }
}

/// Push binding for the §8 data map. `profileID` comes from
/// `BotAttentionPushBindingStore.unique(hostID:)`.
public struct TitioNoticePushBinding: Sendable, Equatable {
    public var profileID: String?
    public var hostID: String?

    public init(profileID: String?, hostID: String?) {
        self.profileID = profileID
        self.hostID = hostID
    }
}

/// The inbox counters every post publishes (`titio_inbox`, §8).
public struct TitioInboxSnapshot: Equatable, Sendable {
    public var botID: BotID
    public var conversationID: BotConversationID
    public var threadID: AgentThreadID
    public var unreadCount: Int
    public var openDecisions: Int
    public var lastPreview: String?
    public var lastAt: Date?
    public var focus: TitioLiveActivityFocus? = nil

    /// The `titio_inbox` wire object (`bot.updated`, later `bot.list`).
    public var wireObject: JSONValue {
        var object: [String: JSONValue] = [
            "conversation_id": .string(conversationID.value.uuidString.lowercased()),
            "thread_id": .string(threadID.value.uuidString.lowercased()),
            "unread_count": .number(Double(unreadCount)),
            "open_decisions": .number(Double(openDecisions)),
        ]
        object["last_preview"] = lastPreview.map(JSONValue.string) ?? .null
        // Epoch seconds, like every other `*_at` on the Bot wire: iOS reads
        // `last_at` as a number, and a string there hid the roster preview.
        object["last_at"] = lastAt.map { .number($0.timeIntervalSince1970) } ?? .null
        return .object(object)
    }

    /// The same object for the authority's Foundation dictionaries (`bot.list`).
    public var foundationObject: [String: Any] {
        [
            "conversation_id": conversationID.value.uuidString.lowercased(),
            "thread_id": threadID.value.uuidString.lowercased(),
            "unread_count": unreadCount,
            "open_decisions": openDecisions,
            "last_preview": lastPreview ?? NSNull(),
            "last_at": lastAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
        ]
    }
}

/// One written (or rewritten) inbox message, after its commit.
public struct TitioNoticePostedMessage: Sendable {
    public var message: AgentMessage
    public var bodyRevision: Int
    public var target: TitioInboxTarget
    /// The conversation row as persisted with its new unread/attention state.
    public var conversation: BotConversation?
    public var isRewrite: Bool
}

/// The outcome of `TitioNoticeCenter.act` (§7). Navigation is answered by the
/// center itself; consequential actions go to the installed executor.
public enum TitioNoticeActOutcome: Equatable, Sendable {
    /// No ledger row owns this message (e.g. a card an LLM wrote itself).
    case notFound
    /// The option index is outside the stored card.
    case invalidOption
    /// A navigation option: the route is the push userInfo shape, so clients
    /// reuse `AppDelegate.routeFromNotification` / iOS `routeIntent(from:)`.
    case navigate(route: [String: String])
    /// The notice was already resolved or claimed.
    case alreadyResolved
    /// Claimed and started; Titio's result message reports the outcome.
    case accepted
    /// No executor is installed for consequential actions yet.
    case unsupported
}

extension TitioNoticeActOutcome {
    /// The `outcome` string of a `bot.notice.act` receipt (§7).
    public var wireName: String {
        switch self {
        case .notFound: return "not_found"
        case .invalidOption: return "invalid_option"
        case .navigate: return "navigate"
        case .alreadyResolved: return "already_resolved"
        case .accepted: return "accepted"
        case .unsupported: return "unsupported"
        }
    }

    /// The navigation route, for `navigate` only.
    public var route: [String: String]? {
        if case .navigate(let route) = self { return route }
        return nil
    }
}

/// The outcome of `bot.notice.clear` / the Mac clear button (contract §3).
public enum TitioNoticeClearOutcome: Equatable, Sendable {
    /// The message was (or is being) removed from the inbox thread.
    case cleared(threadID: AgentThreadID)
    /// Not an assistant message of Titio's Notifications inbox thread.
    case invalid
}

/// The host side effects of a consequential card action (§7 step 4). The
/// center claims the row, writes the transcript rows and the resolution;
/// these only talk to the host. Production wiring is
/// `AppContext.makeTitioNoticeActionHooks`; tests pass fakes. Until they are
/// installed the center answers `.unsupported` and never claims a row it
/// cannot execute.
public struct TitioNoticeActionHooks: Sendable {
    public enum RequestDecision: Equatable, Sendable { case approve, approveForSession, decline }
    public enum RequestKind: Equatable, Sendable { case approval, userInput }

    /// The provider request still waits for an answer (false: it expired or
    /// was answered elsewhere, so nothing is sent).
    public var isRequestOpen: @Sendable (AgentThreadID, String, RequestKind, String?) -> Bool
    /// `respondAgentRequest(thread:requestId:response:)`.
    public var respondRequest: @Sendable (AgentThreadID, String, RequestDecision) async throws -> Void
    /// `respondAgentUserInput(thread:requestId:text:)`.
    public var respondUserInput: @Sendable (AgentThreadID, String, String) async throws -> Void
    /// `enqueueHostMessage` into that Bot's own conversation.
    public var sendBotMessage: @Sendable (BotID, BotConversationID, String) async throws -> Void
    /// `botStore.acknowledgeAttention` plus `bots.attention.changed`.
    public var acknowledgeBotAttention: @Sendable (BotAttentionItemID) async throws -> Void
    /// `continueAgentRun(thread:)`.
    public var continueRun: @Sendable (AgentThreadID) async throws -> Void
    /// `ScheduledTaskRuntime.runNow(taskID:)`.
    public var rerunScheduledTask: @Sendable (UUID) async throws -> Void
    /// The Activity acknowledge path (`ActivityService.acknowledge`).
    public var acknowledgeActivity: @Sendable (String) async throws -> Void
    /// `notification.dismiss` for an external notice's notification row
    /// (`bot.notice.clear`).
    public var dismissNotification: @Sendable (String) async throws -> Void
    /// Marks these Activity items viewed (`activity.set_viewed`), best effort.
    public var markActivityViewed: @Sendable ([String]) async -> Void

    public init(
        isRequestOpen: @escaping @Sendable (AgentThreadID, String, RequestKind, String?) -> Bool,
        respondRequest: @escaping @Sendable (AgentThreadID, String, RequestDecision) async throws -> Void,
        respondUserInput: @escaping @Sendable (AgentThreadID, String, String) async throws -> Void,
        sendBotMessage: @escaping @Sendable (BotID, BotConversationID, String) async throws -> Void,
        acknowledgeBotAttention: @escaping @Sendable (BotAttentionItemID) async throws -> Void,
        continueRun: @escaping @Sendable (AgentThreadID) async throws -> Void,
        rerunScheduledTask: @escaping @Sendable (UUID) async throws -> Void,
        acknowledgeActivity: @escaping @Sendable (String) async throws -> Void,
        dismissNotification: @escaping @Sendable (String) async throws -> Void = { _ in },
        markActivityViewed: @escaping @Sendable ([String]) async -> Void = { _ in }
    ) {
        self.isRequestOpen = isRequestOpen
        self.respondRequest = respondRequest
        self.respondUserInput = respondUserInput
        self.sendBotMessage = sendBotMessage
        self.acknowledgeBotAttention = acknowledgeBotAttention
        self.continueRun = continueRun
        self.rerunScheduledTask = rerunScheduledTask
        self.acknowledgeActivity = acknowledgeActivity
        self.dismissNotification = dismissNotification
        self.markActivityViewed = markActivityViewed
    }
}

/// An action the host could not run: its text is the honest reason in the
/// "I couldn't send it" result line.
struct TitioNoticeActionError: LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

/// The "Reply here" arm as mirrored in memory (no SQLite on the send path).
struct TitioNoticeArm: Equatable, Sendable {
    var key: String
    var armedAt: Date
}

/// An open card as mirrored in memory for the old-iOS text intercept.
struct TitioNoticeOpenCard: Equatable, Sendable {
    var messageID: String
    var key: String
    var options: [TitioNoticeCardOption]
}

/// Every side effect outside the ledger. Production wiring lives in
/// `AppContext.makeTitioNoticeHooks`; tests pass fakes.
public struct TitioNoticeHooks: Sendable {
    /// Ensures Titio, its inbox conversation and thread. Nil while one of them
    /// cannot be created (the rows stay pending and retry with backoff).
    public var resolveInbox: @Sendable (TitioNoticeLanguage) async -> TitioInboxTarget?
    /// The Mac desk shows the inbox and its window is key.
    public var isInboxViewed: @Sendable (TitioInboxTarget) async -> Bool
    /// A Titio run is active in the inbox thread (info waits, §4).
    public var isTitioRunActive: @Sendable (TitioInboxTarget) -> Bool
    public var languageInputs: @Sendable () -> TitioNoticeLanguageInputs
    /// `agent.message.appended`, the desk repaint and the peer projection.
    public var messagePosted: @Sendable (TitioNoticePostedMessage) async -> Void
    /// `bot.updated` for Titio with `titio_inbox`.
    public var inboxChanged: @Sendable (TitioInboxSnapshot) async -> Void
    /// A cleared message left the inbox thread: `agent.messages.removed`,
    /// the desk caches and every open Agent App on that thread.
    public var messagesRemoved: @Sendable (TitioInboxTarget, [AgentMessageID]) async -> Void
    /// Mac banner (`SystemNotifier.post`).
    public var postBanner: @Sendable (RemoteCodeNotificationContent) -> Void
    /// True once the relay accepts the push, or no phone target requires one.
    public var deliverPush: @Sendable (RemoteCodeNotificationContent) async -> Bool
    public var pushBinding: @Sendable () -> TitioNoticePushBinding
    /// Workspace display name for pet/terminal events (MainActor state).
    public var workspaceName: @Sendable (WorkspaceID) async -> String?
    /// A successful pet/terminal event whose destination the user is looking
    /// at (`PetAttentionFocusPolicy`): no notice (§2). Failures never are.
    public var isFocusedSuccess: @Sendable (EventBus.Event) async -> Bool
    /// Reuses canonical run/request projection for durable source observations.
    public var observeAgentEvent: @Sendable (EventBus.Event) async -> Bool

    public init(
        resolveInbox: @escaping @Sendable (TitioNoticeLanguage) async -> TitioInboxTarget?,
        isInboxViewed: @escaping @Sendable (TitioInboxTarget) async -> Bool = { _ in false },
        isTitioRunActive: @escaping @Sendable (TitioInboxTarget) -> Bool = { _ in false },
        languageInputs: @escaping @Sendable () -> TitioNoticeLanguageInputs = {
            TitioNoticeLanguageInputs(lastUserText: nil, preferredLanguages: Locale.preferredLanguages)
        },
        messagePosted: @escaping @Sendable (TitioNoticePostedMessage) async -> Void = { _ in },
        inboxChanged: @escaping @Sendable (TitioInboxSnapshot) async -> Void = { _ in },
        messagesRemoved: @escaping @Sendable (TitioInboxTarget, [AgentMessageID]) async -> Void = { _, _ in },
        postBanner: @escaping @Sendable (RemoteCodeNotificationContent) -> Void = { _ in },
        deliverPush: @escaping @Sendable (RemoteCodeNotificationContent) async -> Bool = { _ in true },
        pushBinding: @escaping @Sendable () -> TitioNoticePushBinding = { TitioNoticePushBinding(profileID: nil, hostID: nil) },
        workspaceName: @escaping @Sendable (WorkspaceID) async -> String? = { _ in nil },
        isFocusedSuccess: @escaping @Sendable (EventBus.Event) async -> Bool = { _ in false },
        observeAgentEvent: @escaping @Sendable (EventBus.Event) async -> Bool = { _ in true }
    ) {
        self.resolveInbox = resolveInbox
        self.isInboxViewed = isInboxViewed
        self.isTitioRunActive = isTitioRunActive
        self.languageInputs = languageInputs
        self.messagePosted = messagePosted
        self.inboxChanged = inboxChanged
        self.messagesRemoved = messagesRemoved
        self.postBanner = postBanner
        self.deliverPush = deliverPush
        self.pushBinding = pushBinding
        self.workspaceName = workspaceName
        self.isFocusedSuccess = isFocusedSuccess
        self.observeAgentEvent = observeAgentEvent
    }
}

// MARK: - Center

/// Titio's notice hub (hub spec §3–§6): ledger ingest, the urgency scheduler,
/// one-transaction flush into the inbox conversation, post-commit fan-out
/// (event, desk, `bot.updated`, banner, push, pet speech), startup catch-up,
/// backoff with the legacy fallback, source resolution and retention.
///
/// Every command runs in arrival order on this actor (a single consumer of an
/// `AsyncStream`), so a resolution can never overtake the ingest it resolves,
/// and the ledger's SQLite work never runs on the MainActor. Only the hooks
/// hop to the MainActor (desk repaint, inbox resolution, pet).
public actor TitioNoticeCenter {
    enum Command {
        case ingest(TitioNoticeFact, TitioNoticeLegacyDelivery?)
        case sourceResolved(String, TitioNoticeResolution)
        case startup
        case timer(TimerID)
        case markRead
        case directReply(DirectReply)
        case botAttentionChanged
        case petEvent(EventBus.Event)
        case refreshMirrors
        case expireArm(String)
        case voiced(VoiceCompletion)
        case pushFinished(identifier: String, keys: [String], accepted: Bool)
        case clear(AgentMessageID)
        case barrier(CheckedContinuation<Void, Never>)
    }

    /// The notice rows one voice call writes for, captured before the call.
    struct VoicePlan: Sendable {
        var keys: [String]
        var catchUp: Bool
        var language: TitioNoticeLanguage
    }

    /// A finished voice call, applied on this actor in command order. A nil
    /// text means the writer could not deliver; it never becomes canned speech.
    enum VoiceCompletion: Sendable {
        case notice(VoicePlan, TitioVoiceReply?)
        case resultLine(text: String?)
        case statusLine(messageID: AgentMessageID, text: String?)
    }

    enum TimerID: Hashable {
        case info(UInt64)
        case flap(String, UInt64)
        case retry(UInt64)
        case fallback(String, UInt64)
        case attention(UInt64)
    }

    struct DirectReply: Sendable {
        var botID: BotID
        var conversationID: BotConversationID
        var runID: AgentRunID
        var text: String
        var messageID: AgentMessageID?
    }

    // Dependencies
    private let repo: TitioNoticeRepository
    private let observations: TitioNoticeObservationRepository
    private let messageRepo: AgentMessageRepository
    private let threadRepo: AgentThreadRepository
    private let settingsStore: SettingsStore
    private let botStore: BotStore
    private let hooks: TitioNoticeHooks
    private let scheduler: TitioNoticeScheduling
    /// Titio's writer (nil: notices stay pending).
    private let voice: TitioVoiceWriting?
    private let voiceTiming: TitioVoiceTiming
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private nonisolated let continuation: AsyncStream<Command>.Continuation
    private nonisolated let startedBox = TitioNoticeLockedBox(false)
    private nonisolated let speechBox = TitioNoticeLockedBox<(@Sendable (TitioNoticeSpeech) -> Void)?>(nil)
    private nonisolated let actionsBox = TitioNoticeLockedBox<TitioNoticeActionHooks?>(nil)
    /// In-memory mirrors of ledger state that MainActor send paths read
    /// without SQLite: the live "Reply here" arm, the open cards and the
    /// `titio_inbox` snapshot. Refreshed on this actor after every mutation.
    private nonisolated let voiceStarts = TitioNoticeLockedBox<[Date]>([])
    private nonisolated let armBox = TitioNoticeLockedBox<TitioNoticeArm?>(nil)
    /// Arms a send already took: a stale refresh must not hand them out again.
    private nonisolated let takenArmKeys = TitioNoticeLockedBox<Set<String>>([])
    private nonisolated let openCardsBox = TitioNoticeLockedBox<[TitioNoticeOpenCard]>([])
    private nonisolated let snapshotBox = TitioNoticeLockedBox<TitioInboxSnapshot?>(nil)
    /// Running act executions, so tests (and teardown) can wait for them.
    private nonisolated let actTasks = TitioNoticeLockedBox<[UUID: Task<Void, Never>]>([:])
    /// Running voice calls, so `idle()` (tests, teardown) can wait for them.
    private nonisolated let voiceTasks = TitioNoticeLockedBox<[UUID: Task<Void, Never>]>([:])
    /// Voice calls started and not yet applied on this actor (a call that
    /// returned has left `voiceTasks` before its `.voiced` command runs).
    private nonisolated let voiceInFlight = TitioNoticeLockedBox(0)
    private nonisolated let eventSubscription = TitioNoticeLockedBox<UUID?>(nil)

    // Scheduler state (actor-isolated)
    private var pushTasks: [String: Task<Void, Never>] = [:]
    private var cachedTarget: TitioInboxTarget?
    private var infoKeys: [String] = []
    private var infoFirstAt: Date?
    private var infoGeneration: UInt64 = 0
    private var infoTimer: TitioNoticeTimer?
    private var holdStartedAt: Date?
    private var flapTimers: [String: (UInt64, TitioNoticeTimer)] = [:]
    private var retryAttempt = 0
    private var retryGeneration: UInt64 = 0
    private var retryTimer: TitioNoticeTimer?
    private var legacy: [String: TitioNoticeLegacyDelivery] = [:]
    private var fallbackTimers: [String: (UInt64, TitioNoticeTimer)] = [:]
    private var fallbackPosted = Set<String>()
    private var attentionGeneration: UInt64 = 0
    private var attentionTimer: TitioNoticeTimer?
    private var timerSerial: UInt64 = 0
    /// Act transcript rows get strictly increasing timestamps so the user row
    /// always sorts before its result line.
    private var lastActMessageAt: Date?
    /// Pending rows whose message the voice is writing. They stay `pending`
    /// in the ledger (a restart writes them again); this only stops a second
    /// flush from starting a second call for them.
    private var composing = Set<String>()

    /// The events that re-run the bot-attention projector (§5).
    static let botAttentionEventKinds: Set<String> = ["bots.attention.changed", "bot.attention.updated"]
    /// Debounce for the bot-attention projector (§5).
    static let attentionDebounce: TimeInterval = 0.15
    /// While a Titio run holds info, re-check this often (capped by `titioRunHold`).
    static let holdPollInterval: TimeInterval = 2

    public init(
        db: SQLiteDB,
        botStore: BotStore,
        hooks: TitioNoticeHooks,
        scheduler: TitioNoticeScheduling = DispatchTitioNoticeScheduler(),
        voice: TitioVoiceWriting? = nil,
        voiceTiming: TitioVoiceTiming = .production,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.repo = TitioNoticeRepository(db: db)
        self.observations = TitioNoticeObservationRepository(db: db)
        self.messageRepo = AgentMessageRepository(db: db)
        self.threadRepo = AgentThreadRepository(db: db)
        self.settingsStore = SettingsStore(db: db)
        self.botStore = botStore
        self.hooks = hooks
        self.scheduler = scheduler
        self.voice = voice
        self.voiceTiming = voiceTiming
        self.now = now
        self.timeZone = timeZone
        var made: AsyncStream<Command>.Continuation!
        let stream = AsyncStream<Command>(bufferingPolicy: .unbounded) { made = $0 }
        self.continuation = made
        Task { [weak self] in
            for await command in stream {
                guard let self else { return }
                await self.handle(command)
            }
        }
    }

    deinit {
        continuation.finish()
        if let id = eventSubscription.value { EventBus.shared.unsubscribe(id) }
    }

    // MARK: Public entry points (nonisolated, ordered)

    /// The §5 hook gate: the hub delivers only once started (app launch) and
    /// while the kill switch is on. Otherwise every hook keeps today's code.
    public nonisolated func isEnabled(_ settings: AppSettings) -> Bool {
        startedBox.value && settings.titioNotificationsEnabled
    }

    public nonisolated var isStarted: Bool { startedBox.value }

    /// Starts delivery: catch-up flush, banner re-post, retention, and the
    /// EventBus subscriptions (pet/terminal events, bot attention).
    public nonisolated func start(subscribeToEvents: Bool = true) {
        guard startedBox.exchange(true) == false else { return }
        if subscribeToEvents {
            let kinds = PetController.potentialProjectionKinds.union(Self.botAttentionEventKinds).union(TitioNoticeObservationRepository.eventKinds)
            let id = EventBus.shared.subscribeFromCurrent { [weak self] event in
                guard kinds.contains(event.kind) else { return }
                self?.handleEvent(event)
            }.id
            eventSubscription.value = id
        }
        continuation.yield(.startup)
        continuation.yield(.botAttentionChanged)
    }

    public nonisolated func ingest(_ fact: TitioNoticeFact, legacy: TitioNoticeLegacyDelivery? = nil) {
        // Durably observe before returning to the producer. Delivery and voice
        // remain asynchronous; a quit in that gap is recovered by startup.
        do { _ = try repo.ingest(fact) }
        catch {
            titioNoticeLog.error("titio.notice.intake_failed key=\(fact.key, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
        continuation.yield(.ingest(fact, legacy))
    }

    /// The source resolved on its own (§6): a pending row is dropped (a
    /// flap-held alert as `flap`); a posted row is resolved and its message
    /// rewritten in place with a status line (no new message).
    public nonisolated func sourceResolved(key: String, reason: TitioNoticeResolution = .elsewhere) {
        continuation.yield(.sourceResolved(key, reason))
    }

    /// Titio's own reply: only a direct banner/push (title "Titio", body =
    /// first line of the reply), never a notice (§2).
    public nonisolated func postDirectReplyBanner(
        botID: BotID,
        conversationID: BotConversationID,
        runID: AgentRunID,
        text: String,
        messageID: AgentMessageID?
    ) {
        continuation.yield(.directReply(DirectReply(
            botID: botID, conversationID: conversationID, runID: runID, text: text, messageID: messageID
        )))
    }

    /// The inbox was opened on the Mac: unread count to 0, conversation read.
    public nonisolated func markInboxRead() {
        continuation.yield(.markRead)
    }

    /// Pet speech dispatch (stage 4 wires the pet).
    public nonisolated func setOnSpeech(_ handler: (@Sendable (TitioNoticeSpeech) -> Void)?) {
        speechBox.value = handler
    }

    /// Installs the host side effects of card actions (§7). Without them a
    /// consequential tap answers `.unsupported` and claims nothing.
    public nonisolated func installActions(_ actions: TitioNoticeActionHooks?) {
        actionsBox.value = actions
    }

    /// The `titio_inbox` object as last published (`bot.list`), read without SQLite.
    public nonisolated var inboxSnapshot: TitioInboxSnapshot? { snapshotBox.value }

    nonisolated func handleEvent(_ event: EventBus.Event) {
        if Self.botAttentionEventKinds.contains(event.kind) {
            continuation.yield(.botAttentionChanged)
        } else {
            do {
                try observations.record(seq: event.seq, kind: event.kind,
                    payloadJSON: EventBus.encodePayloadForPersistence(event.payload), occurredAt: event.ts)
            } catch {
                titioNoticeLog.error("titio.notice.observation_failed seq=\(event.seq) error=\(String(describing: error), privacy: .public)")
            }
            continuation.yield(.petEvent(event))
        }
    }

    /// Waits until every command sent before this call has been handled,
    /// including the voice calls they started and what those posted.
    public func idle() async {
        while true {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                continuation.yield(.barrier(waiter))
            }
            if voiceInFlight.value == 0 && pushTasks.isEmpty { return }
            // The next barrier applies whatever these calls yield.
            for task in voiceTasks.value.values { await task.value }
            for task in pushTasks.values { await task.value }
        }
    }

    /// Waits for the commands sent so far, but not for voice calls still
    /// running (tests that hold a writer mid-call).
    func commandsDrained() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            continuation.yield(.barrier(waiter))
        }
    }

    /// A card tap on the Mac (§7). Runs the shared claim off the MainActor
    /// (on this actor); see `actNow`.
    public func act(messageID: String, optionIndex: Int) async -> TitioNoticeActOutcome {
        actNow(messageID: messageID, optionIndex: optionIndex)
    }

    /// The Mac clear button (contract §3). Runs the removal on this actor
    /// and answers once it is done.
    public func clear(messageID: String) async -> TitioNoticeClearOutcome {
        guard let (id, thread) = validateClear(messageID) else { return .invalid }
        await performClear(id)
        return .cleared(threadID: thread)
    }

    /// `bot.notice.clear` (off the MainActor, under the authority lock):
    /// checks the message right away and queues the removal in command
    /// order, so it can never overtake a post or rewrite of that message.
    public nonisolated func clearNow(messageID: String) -> TitioNoticeClearOutcome {
        guard let (id, thread) = validateClear(messageID) else { return .invalid }
        continuation.yield(.clear(id))
        return .cleared(threadID: thread)
    }

    /// Only an assistant message of the Notifications inbox thread clears.
    private nonisolated func validateClear(_ raw: String) -> (AgentMessageID, AgentThreadID)? {
        guard let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let inbox = inboxThreadID(),
              let message = (try? messageRepo.get(id: AgentMessageID(uuid))) ?? nil,
              message.threadId == inbox, message.role == .assistant else { return nil }
        return (message.id, inbox)
    }

    private nonisolated func inboxThreadID() -> AgentThreadID? {
        if let snapshot = snapshotBox.value { return snapshot.threadID }
        guard let raw = (try? repo.inboxState())?.conversationID, let uuid = UUID(uuidString: raw),
              let conversation = (try? botStore.conversation(id: BotConversationID(uuid))) ?? nil else { return nil }
        return conversation.linkedAgentThreadID
    }

    // MARK: Command handling

    private func handle(_ command: Command) async {
        switch command {
        case .ingest(let fact, let legacyDelivery):
            await handleIngest(fact, legacy: legacyDelivery)
        case .sourceResolved(let key, let reason):
            await handleSourceResolved(key: key, reason: reason)
        case .startup:
            await handleStartup()
        case .timer(let id):
            await handleTimer(id)
        case .markRead:
            await handleMarkRead()
        case .directReply(let reply):
            await handleDirectReply(reply)
        case .botAttentionChanged:
            scheduleAttentionPass()
        case .petEvent(let event):
            if await handleObservedEvent(event) {
                do { try observations.acknowledge(seq: event.seq, at: now()) }
                catch { titioNoticeLog.error("titio.notice.observation_checkpoint_failed seq=\(event.seq)") }
            }
        case .refreshMirrors:
            refreshMirrors()
        case .expireArm(let key):
            handleExpireArm(key)
        case .voiced(let completion):
            await handleVoiced(completion)
        case .pushFinished(let identifier, let keys, let accepted):
            pushTasks[identifier] = nil
            if accepted {
                markBanner(keys: keys)
            } else {
                keys.forEach { fallbackPosted.remove($0) }
                scheduleRetry()
            }
        case .clear(let messageID):
            await performClear(messageID)
        case .barrier(let waiter):
            waiter.resume()
        }
    }

    /// The kill switch, read where every producer converges (§0.5): hooks,
    /// pet/terminal events, the bot-attention projector, startup and retries.
    private func hubEnabled() -> Bool {
        settingsStore.load().titioNotificationsEnabled
    }

    @discardableResult
    private func handleIngest(_ fact: TitioNoticeFact, legacy legacyDelivery: TitioNoticeLegacyDelivery?) async -> Bool {
        // Kill switch off (a hook raced the toggle): today's banner, as is.
        guard hubEnabled() else {
            if let legacyDelivery { await postLegacy(key: fact.key, legacyDelivery, reason: "disabled") }
            return false
        }
        await expireSupersededRequests(by: fact)
        let record: TitioNoticeRecord?
        do {
            record = try repo.ingest(fact)
        } catch {
            titioNoticeLog.error("titio.notice.ingest_failed key=\(fact.key, privacy: .public) error=\(String(describing: error), privacy: .public)")
            if let legacyDelivery { await postLegacy(key: fact.key, legacyDelivery, reason: "ingest_failed") }
            return false
        }
        // A replay or a second producer of an already posted notice is a no-op.
        guard let record, record.state == .pending else { return true }
        if let legacyDelivery, record.urgency != .info { legacy[record.key] = legacyDelivery }
        switch record.urgency {
        case .decision:
            await flushInfo(force: true)
            _ = await flush(keys: [record.key], catchUp: false)
        case .alert:
            if record.kind.usesFlapHold {
                armFlapHold(key: record.key)
            } else {
                _ = await flush(keys: [record.key], catchUp: false)
            }
        case .info:
            if !infoKeys.contains(record.key) { infoKeys.append(record.key) }
            if infoFirstAt == nil { infoFirstAt = now() }
            armInfoWindow()
        }
        return true
    }

    private func handleTimer(_ id: TimerID) async {
        switch id {
        case .info(let generation):
            guard generation == infoGeneration else { return }
            await flushInfo(force: false)
        case .flap(let key, let generation):
            guard flapTimers[key]?.0 == generation else { return }
            flapTimers[key] = nil
            _ = await flush(keys: [key], catchUp: false)
        case .retry(let generation):
            guard generation == retryGeneration else { return }
            retryTimer = nil
            await retryPending()
        case .fallback(let key, let generation):
            guard fallbackTimers[key]?.0 == generation else { return }
            fallbackTimers[key] = nil
            guard let row = try? repo.get(key: key), row.state == .pending,
                  let delivery = legacy[key] else { return }
            await postLegacy(key: key, delivery, reason: "fallback")
        case .attention(let generation):
            guard generation == attentionGeneration else { return }
            attentionTimer = nil
            await runAttentionPass()
        }
    }

    // MARK: Scheduling (§4)

    private func nextSerial() -> UInt64 {
        timerSerial &+= 1
        return timerSerial
    }

    private func schedule(_ delay: TimeInterval, _ id: TimerID) -> TitioNoticeTimer {
        let continuation = continuation
        return scheduler.schedule(after: delay) { continuation.yield(.timer(id)) }
    }

    /// One global sliding window: each info item pushes the flush to
    /// `infoWindow` from now, never past `infoMaxWait` from the first item.
    private func armInfoWindow() {
        guard let first = infoFirstAt else { return }
        let current = now()
        let deadline = min(current.addingTimeInterval(TitioNoticeTiming.infoWindow),
                           first.addingTimeInterval(TitioNoticeTiming.infoMaxWait))
        infoTimer?.cancel()
        infoGeneration = nextSerial()
        infoTimer = schedule(max(0, deadline.timeIntervalSince(current)), .info(infoGeneration))
    }

    private func armFlapHold(key: String) {
        flapTimers[key]?.1.cancel()
        let generation = nextSerial()
        flapTimers[key] = (generation, schedule(TitioNoticeTiming.flapHold, .flap(key, generation)))
    }

    /// Flushes the pending info batch. Unless forced (a decision is about to
    /// post), info waits up to `titioRunHold` while a Titio run is active.
    private func flushInfo(force: Bool) async {
        guard !infoKeys.isEmpty else { return }
        if !force, let target = cachedTarget, hooks.isTitioRunActive(target) {
            let current = now()
            let started = holdStartedAt ?? current
            holdStartedAt = started
            let remaining = TitioNoticeTiming.titioRunHold - current.timeIntervalSince(started)
            if remaining > 0 {
                infoTimer?.cancel()
                infoGeneration = nextSerial()
                infoTimer = schedule(min(Self.holdPollInterval, remaining), .info(infoGeneration))
                return
            }
        }
        holdStartedAt = nil
        let keys = infoKeys
        infoKeys = []
        infoFirstAt = nil
        infoTimer?.cancel()
        infoTimer = nil
        infoGeneration = nextSerial()
        _ = await flush(keys: keys, catchUp: false)
    }

    // MARK: Flush (§3 steps 3–4)

    /// The Settings choice (`titioLanguage`), read fresh: another store
    /// instance (Settings window, `settings.set`) may have written it.
    private func languageSetting() -> String {
        settingsStore.reload().titioLanguage
    }

    /// Locale for host metadata; conversational text comes from the writer.
    private func language() -> TitioNoticeLanguage {
        let inputs = hooks.languageInputs()
        return TitioLanguageSetting.fallbackLanguage(
            setting: languageSetting(),
            recentUserTexts: inputs.recentUserTexts,
            cardLabels: inputs.cardLabels,
            preferredLanguages: inputs.preferredLanguages
        )
    }

    /// What the writer is told about language (setting or the user's texts).
    private func voiceLanguage() -> TitioVoiceLanguage {
        let inputs = hooks.languageInputs()
        return TitioLanguageSetting.voiceLanguage(
            setting: languageSetting(),
            recentUserTexts: inputs.recentUserTexts,
            cardLabels: inputs.cardLabels,
            preferredLanguages: inputs.preferredLanguages
        )
    }

    /// The cached inbox target if its conversation still links the same
    /// thread; otherwise resolves it again (recreating a deleted inbox).
    private func target(language: TitioNoticeLanguage) async -> TitioInboxTarget? {
        if let cachedTarget,
           let conversation = try? botStore.conversation(id: cachedTarget.conversationID),
           conversation.linkedAgentThreadID == cachedTarget.threadID {
            return cachedTarget
        }
        let previous = cachedTarget
        cachedTarget = nil
        let resolved = await hooks.resolveInbox(language)
        cachedTarget = resolved
        // A recreated inbox (the old conversation was deleted) took the old
        // cards with it: settle their rows so no phantom decision stays open.
        if let previous, let resolved, previous.threadID != resolved.threadID {
            reconcileOrphanedCards(at: now())
        }
        return resolved
    }

    /// Posts `keys` (those still pending) as one message. With a writer,
    /// Titio's text is written first, off this actor, and the message is
    /// committed when it returns (`handleVoiced`); the rows stay `pending`
    /// meanwhile, so a restart writes them again and the deterministic
    /// message id keeps a retry from ever posting twice. Returns false when
    /// the inbox is unavailable or the read failed (rows stay pending).
    @discardableResult
    private func flush(keys requested: [String], catchUp: Bool) async -> Bool {
        let keys = requested.filter { !composing.contains($0) }
        guard !keys.isEmpty else { return true }
        if keys.count > 32 {
            var succeeded = true
            for start in stride(from: 0, to: keys.count, by: 32) {
                let batch = Array(keys[start..<min(start + 32, keys.count)])
                if !(await flush(keys: batch, catchUp: catchUp)) { succeeded = false }
            }
            return succeeded
        }
        let language = language()
        guard let target = await target(language: language) else {
            titioNoticeLog.info("titio.notice.inbox_unavailable keys=\(keys.count, privacy: .public)")
            armFallbacks(keys)
            scheduleRetry()
            return false
        }
        let rows: [TitioNoticeRecord]
        do {
            rows = try repo.pendingRows(keys: keys)
        } catch {
            titioNoticeLog.error("titio.notice.flush_failed keys=\(keys.count, privacy: .public) error=\(String(describing: error), privacy: .public)")
            armFallbacks(keys)
            scheduleRetry()
            return false
        }
        guard !rows.isEmpty else { return true }
        let interrupting = rows.filter(allowsInterruption)
        if !interrupting.isEmpty, interrupting.count != rows.count {
            let allowed = Set(interrupting.map(\.key))
            let first = await flush(keys: interrupting.map(\.key), catchUp: catchUp)
            let second = await flush(keys: rows.filter { !allowed.contains($0.key) }.map(\.key), catchUp: catchUp)
            return first && second
        }
        // Facts and actionable questions must never wait for a model. The same
        // durable message/card identity is used whether synthesis is available.
        if rows.contains(where: { $0.urgency != .info }) || voice == nil {
            return await commit(keys: keys, catchUp: catchUp, target: target, language: language, reply: nil)
        }
        guard let writer = voice else { return false }
        startNoticeVoice(rows: rows, catchUp: catchUp, target: target, language: language, writer: writer)
        return true
    }

    /// One writer call for `rows` (a digest is one call for the batch).
    private func startNoticeVoice(
        rows: [TitioNoticeRecord],
        catchUp: Bool,
        target: TitioInboxTarget,
        language: TitioNoticeLanguage,
        writer: TitioVoiceWriting
    ) {
        let keys = rows.map(\.key)
        composing.formUnion(keys)
        let items = rows.map(TitioNoticeRenderItem.init(record:))
        let cardOptions = TitioNoticeCopy.composeBatch(items, language: language, catchUp: catchUp, timeZone: timeZone)?.cardOptions
        let sensitive = items.contains { $0.kind.isLockScreenSensitive }
        let wordsCard = TitioVoicePrompt.needsCardWording(cardOptions)
        let expectsJSON = wordsCard || sensitive
        let optionCount = wordsCard ? cardOptions?.count : nil
        let forbidden = TitioVoicePrompt.lockScreenForbidden(items)
        let request = TitioVoiceRequest(
            purpose: items.count > 1 ? .digest : .notice,
            prompt: TitioVoicePrompt.notice(items, cardOptions: cardOptions, catchUp: catchUp,
                                            language: voiceLanguage(), timeZone: timeZone),
            threadID: target.threadID,
            expectsJSON: expectsJSON
        )
        let parse: @Sendable (String) -> TitioVoiceReply? = { raw in
            let reply = expectsJSON
                ? TitioVoiceOutput.parseCard(raw, optionCount: optionCount, forbidden: forbidden, requiresNotification: sensitive)
                : TitioVoiceOutput.sanitize(raw).map { TitioVoiceReply(message: $0) }
            if let options = cardOptions, let labels = reply?.labels {
                let merged = zip(options, labels).map { $0.action.keepsLabelVerbatim ? $0.label ?? $1 : $1 }
                guard Set(merged).count == merged.count else { return nil }
            }
            return reply
        }
        let urgent = rows.contains { $0.urgency != .info }
        let plan = VoicePlan(keys: keys, catchUp: catchUp, language: language)
        spawnVoice(
            request, writer: writer,
            deadline: urgent ? voiceTiming.urgentDeadline : voiceTiming.infoDeadline,
            accept: { parse($0) != nil }
        ) { raw in
            .notice(plan, raw.flatMap(parse))
        }
    }

    /// Runs one writer call off this actor (retries and deadline inside
    /// `TitioVoiceRunner`) and hands the result back as a command.
    private nonisolated func spawnVoice(
        _ request: TitioVoiceRequest,
        writer: TitioVoiceWriting,
        deadline: TimeInterval,
        accept: @escaping @Sendable (String) -> Bool,
        complete: @escaping @Sendable (String?) -> VoiceCompletion
    ) {
        let current = now()
        let admitted = voiceStarts.mutate { starts in
            starts.removeAll { current.timeIntervalSince($0) >= 60 }
            guard starts.count < 12 else { return false }
            starts.append(current)
            return true
        }
        guard admitted else {
            voiceInFlight.mutate { $0 += 1 }
            continuation.yield(.voiced(complete(nil)))
            return
        }
        let id = UUID()
        let tasks = voiceTasks
        let timing = voiceTiming
        let continuation = continuation
        voiceInFlight.mutate { $0 += 1 }
        tasks.mutate { running in
            running[id] = Task.detached(priority: .utility) {
                let (outcome, raw) = await TitioVoiceRunner.run(
                    request, writer: writer, timing: timing, deadline: deadline, accept: accept
                )
                if case .fallback(let reason) = outcome {
                    titioNoticeLog.error("titio.voice.fallback purpose=\(request.purpose.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
                }
                continuation.yield(.voiced(complete(raw)))
                tasks.mutate { $0[id] = nil }
            }
        }
    }

    private func handleVoiced(_ completion: VoiceCompletion) async {
        defer { voiceInFlight.mutate { $0 -= 1 } }
        switch completion {
        case .notice(let plan, let reply):
            composing.subtract(plan.keys)
            guard let target = await target(language: plan.language) else {
                titioNoticeLog.info("titio.notice.inbox_unavailable keys=\(plan.keys.count, privacy: .public)")
                armFallbacks(plan.keys)
                scheduleRetry()
                return
            }
            _ = await commit(keys: plan.keys, catchUp: plan.catchUp, target: target, language: plan.language,
                             reply: reply, voicedKeys: Set(plan.keys))
        case .resultLine(let text):
            if let text { await appendActMessage(role: .assistant, text: text) }
        case .statusLine(let messageID, let text):
            if let text { await applyStatusLine(messageID: messageID, line: Self.italicStatus(text)) }
        }
    }

    /// The one-transaction post (§3 step 3): re-reads which rows are still
    /// pending, writes the generated message and marks them posted. When rows resolved while the
    /// voice wrote (`voicedKeys` differs), nothing is written and the rest is
    /// written again: the text must not mention a notice that is gone.
    @discardableResult
    private func commit(
        keys: [String],
        catchUp: Bool,
        target: TitioInboxTarget,
        language: TitioNoticeLanguage,
        reply: TitioVoiceReply?,
        voicedKeys: Set<String>? = nil
    ) async -> Bool {
        let viewing = await hooks.isInboxViewed(target)
        let postedAt = now()
        var written: AgentMessage?
        var bannerText = ""
        var revoice: [String] = []
        let result: TitioNoticeFlushResult?
        do {
            result = try repo.flush(keys: keys, postedAt: postedAt) { rows in
                if let voicedKeys, Set(rows.map(\.key)) != voicedKeys {
                    revoice = rows.map(\.key)
                    return nil
                }
                let items = rows.map(TitioNoticeRenderItem.init(record:))
                guard let fallback = TitioNoticeCopy.composeBatch(items, language: language, catchUp: catchUp, timeZone: timeZone) else {
                    return nil
                }
                let composed = reply.map { Self.composed(fallback: fallback, reply: $0) } ?? fallback
                let uuid = rows.count == 1
                    ? TitioNoticeIDs.messageID(forKey: rows[0].key)
                    : TitioNoticeIDs.digestMessageID(forKeys: rows.map(\.key))
                let message = AgentMessage(
                    id: AgentMessageID(uuid),
                    threadId: target.threadID,
                    role: .assistant,
                    content: rows.count == 1
                        ? composed.text + "\n\n" + TitioNoticeBlock.render(key: rows[0].key, kind: rows[0].kind.rawValue, source: TitioNoticeCopy.sourceLabels(rows[0].facts), state: "open")
                        : composed.text,
                    createdAt: postedAt
                )
                try messageRepo.append(message)
                written = message
                bannerText = reply.map { Self.bannerText(items: items, reply: $0) }
                    ?? TitioNoticeCopy.bannerBody(items, language: language, catchUp: catchUp, timeZone: timeZone)
                return TitioNoticePosting(
                    messageID: uuid.uuidString,
                    batchID: rows.count > 1 ? uuid.uuidString : nil,
                    cardOwnerKey: composed.cardOwnerKey,
                    cardOptions: composed.cardOptions,
                    preview: composed.preview,
                    countsAsUnread: !viewing,
                    notificationLine: bannerText
                )
            }
        } catch {
            titioNoticeLog.error("titio.notice.flush_failed keys=\(keys.count, privacy: .public) error=\(String(describing: error), privacy: .public)")
            cachedTarget = nil
            armFallbacks(keys)
            scheduleRetry()
            return false
        }
        if !revoice.isEmpty {
            titioNoticeLog.info("titio.voice.rewrite_after_resolution keys=\(revoice.count, privacy: .public)")
            return await flush(keys: revoice, catchUp: catchUp)
        }
        retryAttempt = 0
        guard let result, let message = written else { return true }
        for record in result.records {
            legacy[record.key] = nil
            fallbackTimers.removeValue(forKey: record.key)?.1.cancel()
            fallbackPosted.remove(record.key)
        }
        await fanOut(result, message: message, bannerText: bannerText, target: target, viewing: viewing)
        refreshMirrors()
        return true
    }

    /// Titio's text with the host's own card appended (labels may be the
    /// writer's translation, but every action stays the ledger's). Template
    /// prose is never displayed; the writer supplies every conversational field.
    static func composed(fallback: TitioNoticeComposed, reply: TitioVoiceReply) -> TitioNoticeComposed {
        var text = reply.message
        var options = fallback.cardOptions
        if let defaults = fallback.cardOptions, let owner = fallback.cardOwnerKey {
            if let labels = reply.labels, labels.count == defaults.count {
                let merged = zip(defaults, labels).map { option, label in
                    option.action.keepsLabelVerbatim ? option : TitioNoticeCardOption(label: label, action: option.action)
                }
                // Labels must stay distinct, or `option_index` would not map 1:1.
                if Set(merged.compactMap(\.label)).count == merged.count { options = merged }
            }
            text += "\n\n" + TitioNoticeCopy.choicesBlock(
                question: BotChoicesBlock.parse(fallback.text).choices?.question ?? reply.question,
                options: (options ?? defaults).compactMap(\.label), notice: owner,
                source: BotChoicesBlock.parse(fallback.text).choices?.source ?? [:],
                canReply: defaults.contains(where: { $0.action == .replyHere })
            )
        }
        return TitioNoticeComposed(
            text: text,
            preview: TitioNoticeCopy.preview(reply.message),
            cardOptions: options,
            cardOwnerKey: fallback.cardOwnerKey
        )
    }

    /// Banner / push body: the first sentence of Titio's text, except for
    /// approvals and questions, whose lock-screen line is the writer's
    /// checked `notification` line.
    static func bannerText(
        items: [TitioNoticeRenderItem],
        reply: TitioVoiceReply
    ) -> String {
        if items.contains(where: { $0.kind.isLockScreenSensitive }) {
            return reply.notificationLine ?? ""
        }
        return TitioVoiceOutput.firstSentence(reply.message)
    }

    static func italicStatus(_ line: String) -> String {
        line.contains("_") || line.contains("*") ? line : "_\(line)_"
    }

    /// Post-commit effects, in the §3 step 4 order.
    private func fanOut(_ result: TitioNoticeFlushResult, message: AgentMessage, bannerText: String, target: TitioInboxTarget, viewing: Bool) async {
        let revision = ((try? messageRepo.bodyRevision(id: message.id)) ?? nil) ?? 1
        let openDecisions = (try? repo.openDecisionCount()) ?? 0
        let conversation = persistConversation(target: target, viewing: viewing, openDecisions: openDecisions, at: message.createdAt)
        await hooks.messagePosted(TitioNoticePostedMessage(
            message: message, bodyRevision: revision, target: target, conversation: conversation, isRewrite: false
        ))
        await publishInbox(target: target, fallback: snapshot(target: target, inbox: result.inbox, openDecisions: openDecisions))
        let keys = result.records.map(\.key)
        // `pet.notifications.denied` is in-app only: no banner, no push. A
        // row whose legacy banner/push already went out (`banner_at` set by
        // the fail-loud fallback, even before a restart) is not announced a
        // second time when the inbox recovers.
        if !result.records.allSatisfy({ $0.kind == .notificationsDenied }),
           result.records.contains(where: { $0.bannerAt == nil }) {
            let identifier = result.records.count == 1
                ? result.records[0].key
                : TitioNoticeIDs.digestBannerIdentifier(messageID: message.id.value)
            deliver(identifier: identifier, text: bannerText, message: message, target: target,
                    noticeKey: result.posting.cardOwnerKey ?? (result.records.count == 1 ? result.records[0].key : nil),
                    records: result.records)
        } else {
            markBanner(keys: keys)
        }
        if result.records.allSatisfy(allowsInterruption), let speak = speechBox.value {
            let urgency: TitioNoticeUrgency = result.records.contains { $0.urgency == .decision } ? .decision
                : result.records.contains { $0.urgency == .alert } ? .alert : .info
            speak(TitioNoticeSpeech(
                text: Self.clip(result.posting.preview, max: TitioNoticeSpeech.maxCharacters),
                urgency: urgency,
                messageID: message.id,
                botID: target.botID,
                conversationID: target.conversationID
            ))
        }
    }

    private func allowsInterruption(_ row: TitioNoticeRecord) -> Bool {
        guard row.facts.interruptionSuppressed != true else { return false }
        if let id = row.source.botId.flatMap(UUID.init(uuidString:)).map(BotID.init),
           let bot = try? botStore.get(id: id), !bot.notificationsEnabled { return false }
        return RemoteCodeNotificationContent.AgentAppPushPolicy.allowsNotification(
            isAction: row.urgency != .info, workspaceId: row.source.workspaceId, settings: settingsStore.load()
        )
    }

    /// Banner + push with the same identifier (the relay deduplicates re-posts).
    private func deliver(
        identifier: String,
        text: String,
        message: AgentMessage,
        target: TitioInboxTarget,
        noticeKey: String?,
        records: [TitioNoticeRecord]
    ) {
        guard records.allSatisfy(allowsInterruption) else {
            markBanner(keys: records.map(\.key))
            return
        }
        let canReply = records.count == 1 && records[0].actions?.contains(where: { $0.action == .replyHere }) == true
        let binding = hooks.pushBinding()
        let legacyKeys = Self.legacyRouteKeys(records)
        let conversation = target.conversationID.value.uuidString.lowercased()
        let messageID = message.id.value.uuidString.lowercased()
        let bot = target.botID.value.uuidString.lowercased()
        let bannerInfo = RemoteCodeNotificationContent.titioNoticeUserInfo(
            botID: bot, conversationID: conversation, messageID: messageID, noticeKey: noticeKey,
            identifier: identifier, profileID: binding.profileID, hostID: binding.hostID,
            legacy: legacyKeys, includeBotIdWithoutProfile: true, canReply: canReply
        )
        let pushInfo = RemoteCodeNotificationContent.titioNoticeUserInfo(
            botID: bot, conversationID: conversation, messageID: messageID, noticeKey: noticeKey,
            identifier: identifier, profileID: binding.profileID, hostID: binding.hostID,
            legacy: legacyKeys, canReply: canReply
        )
        hooks.postBanner(RemoteCodeNotificationContent.titioNotice(identifier: identifier, body: text, userInfo: bannerInfo, canReply: canReply))
        let push = RemoteCodeNotificationContent.titioNotice(identifier: identifier, body: text, userInfo: pushInfo, canReply: canReply)
        deliverPush(push, keys: records.map(\.key))
    }

    private func markBanner(keys: [String]) {
        do { try repo.markBanner(keys: keys, at: now()) } catch {
            titioNoticeLog.error("titio.notice.mark_banner_failed error=\(String(describing: error), privacy: .public)")
            scheduleRetry()
        }
    }

    /// The committed notice is the retry record; failed sends keep banner_at unset.
    private func deliverPush(_ content: RemoteCodeNotificationContent, keys: [String]) {
        guard pushTasks[content.identifier] == nil else { return }
        let send = hooks.deliverPush
        let continuation = self.continuation
        pushTasks[content.identifier] = Task {
            let accepted = await send(content)
            continuation.yield(.pushFinished(identifier: content.identifier, keys: keys, accepted: accepted))
        }
    }

    /// Writes the inbox conversation's unread/attention state off the MainActor
    /// (§8): unread unless viewed; needs-attention while decisions are open.
    private func persistConversation(target: TitioInboxTarget, viewing: Bool, openDecisions: Int, at date: Date) -> BotConversation? {
        guard var conversation = try? botStore.conversation(id: target.conversationID) else { return nil }
        conversation.unread = !viewing
        if openDecisions > 0 {
            conversation.attentionState = .needsAttention
        } else {
            conversation.attentionState = viewing ? .none : .unreadActivity
        }
        conversation.updatedAt = date
        do {
            try botStore.upsertConversation(conversation)
        } catch {
            titioNoticeLog.error("titio.notice.conversation_update_failed error=\(String(describing: error), privacy: .public)")
        }
        return conversation
    }

    private func snapshot(target: TitioInboxTarget, inbox: TitioInboxState, openDecisions: Int) -> TitioInboxSnapshot {
        var value = TitioInboxSnapshot(
            botID: target.botID,
            conversationID: target.conversationID,
            threadID: target.threadID,
            unreadCount: inbox.unreadCount,
            openDecisions: openDecisions,
            lastPreview: inbox.lastPreview,
            lastAt: inbox.lastAt
        )
        if openDecisions > 0 {
            for row in (try? repo.openCards()) ?? [] where row.urgency == .decision {
                if let actions = actionsBox.value, !isSourceRequestOpen(row, actions: actions) { continue }
                guard let raw = row.messageID, let uuid = UUID(uuidString: raw),
                      let message = try? messageRepo.get(id: AgentMessageID(uuid)),
                      message.threadId == target.threadID,
                      let revision = try? messageRepo.bodyRevision(id: message.id) else { continue }
                value.focus = TitioLiveActivityFocus(
                    botId: target.botID.value.uuidString.lowercased(),
                    conversationId: target.conversationID.value.uuidString.lowercased(),
                    messageId: uuid.uuidString.lowercased(),
                    actionId: row.actions?.contains(where: { $0.action == .replyHere }) == true ? "reply" : "review",
                    questionRevision: revision)
                break
            }
        }
        return value
    }

    // MARK: Failure handling (§3 step 6)

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let backoff = TitioNoticeTiming.retryBackoff
        let delay = backoff[min(retryAttempt, backoff.count - 1)]
        retryAttempt += 1
        retryGeneration = nextSerial()
        retryTimer = schedule(delay, .retry(retryGeneration))
    }

    /// Decisions and alerts due now that cannot post get the legacy
    /// banner/push after `legacyFallbackAfter` (once per key).
    private func armFallbacks(_ keys: [String]) {
        for key in keys where legacy[key] != nil && fallbackTimers[key] == nil && !fallbackPosted.contains(key) {
            let generation = nextSerial()
            fallbackTimers[key] = (generation, schedule(TitioNoticeTiming.legacyFallbackAfter, .fallback(key, generation)))
        }
    }

    private func postLegacy(key: String, _ delivery: TitioNoticeLegacyDelivery, reason: String) async {
        guard fallbackPosted.insert(key).inserted else { return }
        if let row = try? repo.get(key: key), !allowsInterruption(row) {
            markBanner(keys: [key])
            return
        }
        titioNoticeLog.error("titio.notice.fallback key=\(key, privacy: .public) reason=\(reason, privacy: .public)")
        hooks.postBanner(delivery.content)
        if delivery.pushes {
            deliverPush(delivery.content, keys: [key])
        } else {
            markBanner(keys: [key])
        }
    }

    /// Retries every pending row: decisions one by one (each keeps its card),
    /// the rest as one batch. Info rows in the live window stay there.
    private func retryPending() async {
        guard hubEnabled() else { return }
        await replayObservations()
        if !(await warmTarget()) { return }
        await repostMissingBanners(now: now())
        guard let pending = try? repo.listPending() else { scheduleRetry(); return }
        let waiting = Set(infoKeys).union(flapTimers.keys)
        await flushPendingRows(pending.filter { !waiting.contains($0.key) }, catchUp: false)
    }

    /// Decisions and alerts one message each (each keeps its own card and
    /// its one-tap action); info rows as one batch, with the catch-up opener
    /// at startup. Stops at the first failed flush (a retry is scheduled).
    private func flushPendingRows(_ rows: [TitioNoticeRecord], catchUp: Bool) async {
        for row in rows where row.urgency != .info {
            guard await flush(keys: [row.key], catchUp: false) else { return }
        }
        let info = rows.filter { $0.urgency == .info }.map(\.key)
        if !info.isEmpty { _ = await flush(keys: info, catchUp: catchUp && info.count >= 2) }
    }

    /// Binds an inbox that already exists (so opening it marks it read and
    /// the desk knows it) without creating one. False while it exists but
    /// cannot be resolved yet; a retry is then scheduled.
    private func warmTarget() async -> Bool {
        guard cachedTarget == nil,
              let existing = try? repo.inboxState(), existing.conversationID != nil else { return true }
        if await target(language: language()) != nil { return true }
        scheduleRetry()
        return false
    }

    // MARK: Startup (§3 steps 5, 7)

    private func replayObservations() async {
        do {
            while true {
                let rows = try observations.pending()
                guard !rows.isEmpty else { return }
                for row in rows {
                    guard let data = row.payloadJSON.data(using: .utf8), let payload = JSONValue.decode(from: data) else {
                        throw SQLiteError.execute("Invalid Titio observation \(row.seq)")
                    }
                    let event = EventBus.Event(seq: row.seq, kind: row.kind, payload: payload, ts: row.occurredAt)
                    guard await handleObservedEvent(event) else { scheduleRetry(); return }
                    try observations.acknowledge(seq: row.seq, at: now())
                }
            }
        } catch {
            titioNoticeLog.error("titio.notice.replay_failed error=\(String(describing: error), privacy: .public)")
            scheduleRetry()
        }
    }

    private func handleStartup() async {
        let current = now()
        do {
            let pruned = try repo.prune(endedBefore: current.addingTimeInterval(-TitioNoticeTiming.retention))
            if pruned > 0 { titioNoticeLog.info("titio.notice.pruned count=\(pruned, privacy: .public)") }
        } catch {
            titioNoticeLog.error("titio.notice.prune_failed error=\(String(describing: error), privacy: .public)")
        }
        defer { refreshMirrorsAfterStartup(now: current) }
        // Settle what no live task owns first, so a dead request is neither
        // re-announced nor posted below.
        await reconcileAfterRestart(at: current)
        await enrichOpenCardSources()
        if hubEnabled() { await replayObservations() }
        do { try observations.pruneProcessed(before: current.addingTimeInterval(-TitioNoticeTiming.retention)) }
        catch { titioNoticeLog.error("titio.notice.observation_prune_failed") }
        await repostMissingBanners(now: current)
        guard hubEnabled(), let pending = try? repo.listPending(), !pending.isEmpty else {
            _ = await warmTarget()
            return
        }
        await flushPendingRows(pending, catchUp: true)
        if pending.count == 500 { scheduleRetry() }
    }

    /// Upgrade host-owned open cards in place; retain their exact question,
    /// options and body so replies still refer to the same displayed request.
    private func enrichOpenCardSources() async {
        for row in (try? repo.openCards()) ?? [] {
            guard let raw = row.messageID, let uuid = UUID(uuidString: raw),
                  let message = try? messageRepo.get(id: AgentMessageID(uuid)),
                  let start = message.content.range(of: "```choices\n"),
                  let end = message.content.range(of: "\n```", range: start.upperBound..<message.content.endIndex),
                  let data = String(message.content[start.upperBound..<end.lowerBound]).data(using: .utf8),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["notice"] as? String == row.key else { continue }
            var facts = row.facts
            if let rawThread = row.source.threadId, let id = UUID(uuidString: rawThread),
               let thread = try? threadRepo.get(id: AgentThreadID(id)) {
                if facts.title == nil { facts.title = thread.title }
                if facts.workspaceName == nil, let workspace = thread.workspaceId {
                    facts.workspaceName = await hooks.workspaceName(workspace)
                }
            }
            if facts.workspaceName == nil, let workspace = row.source.workspaceId.flatMap(UUID.init(uuidString:)) {
                facts.workspaceName = await hooks.workspaceName(WorkspaceID(workspace))
            }
            if facts.botName == nil, let botID = row.source.botId.flatMap(UUID.init(uuidString:)),
               let bot = try? botStore.get(id: BotID(botID)) { facts.botName = bot.name }
            let labels = TitioNoticeCopy.sourceLabels(facts)
            let canReply = row.actions?.contains(where: { $0.action == .replyHere }) == true
            guard object["source"] as? [String: String] != labels || (object["can_reply"] as? Bool ?? false) != canReply else { continue }
            if !labels.isEmpty { object["source"] = labels }
            object["can_reply"] = canReply
            guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let json = String(data: encoded, encoding: .utf8) else { continue }
            var text = message.content
            text.replaceSubrange(start.upperBound..<end.lowerBound, with: json)
            await writeRewrite(message, text: text, language: language(), key: row.key)
        }
    }

    /// No act task, provider callback or inbox message survives a quit or
    /// crash the way the ledger does, so startup settles what they owned:
    /// 1. `acting` rows (the app stopped mid-act): back to `posted` so the
    ///    card works again, or `expired` when their request is gone;
    /// 2. open or not-yet-posted approval/input rows whose provider callback
    ///    is no longer pending (launch marks every open callback stale):
    ///    `expired` (a pending one is dropped), so the inbox never shows a
    ///    decision nobody can answer;
    /// 3. open rows whose message is gone: `expired` (nothing to rewrite).
    private func reconcileAfterRestart(at current: Date) async {
        let actions = actionsBox.value
        for row in (try? repo.rows(inStates: [.acting])) ?? [] {
            if let actions, !isSourceRequestOpen(row, actions: actions) {
                if let resolved = try? repo.resolve(key: row.key, resolution: .expired, at: current) {
                    await rewrite(resolved, at: current)
                }
            } else {
                // The process died between claim and receipt. The external effect
                // cannot be proven absent, so never make it executable again.
                if let resolved = try? repo.resolve(key: row.key, resolution: .unknownEffect, at: current) {
                    await rewrite(resolved, at: current)
                }
            }
        }
        if let actions {
            for row in (try? repo.rows(inStates: [.pending, .posted, .awaitingReply])) ?? [] where !isSourceRequestOpen(row, actions: actions) {
                if case .resolved(let record)? = try? repo.resolveFromSource(key: row.key, resolution: .expired, at: current) {
                    await rewrite(record, at: current)
                }
            }
        }
        reconcileOrphanedCards(at: current)
    }

    /// True unless the row is an approval/input whose provider request is
    /// known to be closed.
    private nonisolated func isSourceRequestOpen(_ row: TitioNoticeRecord, actions: TitioNoticeActionHooks) -> Bool {
        let kind: TitioNoticeActionHooks.RequestKind
        switch row.kind {
        case .approval: kind = .approval
        case .userInput: kind = .userInput
        default: return true
        }
        guard let request = requestTarget(row) else { return true }
        return actions.isRequestOpen(request.thread, request.id, kind, row.source.runId)
    }

    /// Open rows whose message no longer exists (transcript retention before
    /// open notices were kept, or a deleted inbox conversation): the card is
    /// gone, so the decision must not keep the inbox in needs-attention.
    private func reconcileOrphanedCards(at current: Date) {
        for row in (try? repo.rows(inStates: [.posted, .awaitingReply])) ?? [] {
            guard let raw = row.messageID, let uuid = UUID(uuidString: raw),
                  ((try? messageRepo.get(id: AgentMessageID(uuid))) ?? nil) == nil else { continue }
            titioNoticeLog.info("titio.notice.orphaned key=\(row.key, privacy: .public)")
            _ = try? repo.resolveFromSource(key: row.key, resolution: .expired, at: current)
        }
    }

    /// A crash between commit and banner: re-post with the same identifier
    /// (the relay and `SystemNotifier` deduplicate), never a second message.
    private func repostMissingBanners(now current: Date) async {
        guard let rows = try? repo.rowsNeedingBannerRepost(now: current), !rows.isEmpty else { return }
        let grouped = Dictionary(grouping: rows) { $0.messageID ?? "" }
        for (messageID, records) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let uuid = UUID(uuidString: messageID) else { continue }
            let keys = records.map(\.key)
            guard records.contains(where: { $0.state == .posted || $0.state == .awaitingReply }) else {
                markBanner(keys: keys)
                continue
            }
            guard !records.allSatisfy({ $0.kind == .notificationsDenied }),
                  let message = try? messageRepo.get(id: AgentMessageID(uuid)),
                  let target = await target(language: language()),
                  message.threadId == target.threadID else { continue }
            let allInBatch = (try? repo.notices(messageID: messageID)) ?? records
            let identifier = allInBatch.count == 1 ? allInBatch[0].key : TitioNoticeIDs.digestBannerIdentifier(messageID: uuid)
            let owner = allInBatch.first { $0.actions != nil }?.key ?? (allInBatch.count == 1 ? allInBatch[0].key : nil)
            let items = allInBatch.map(TitioNoticeRenderItem.init(record:))
            let sentence = TitioVoiceOutput.firstSentence(TitioNoticeBlock.visibleText(message.content))
            let text = items.contains(where: { $0.kind.isLockScreenSensitive })
                ? allInBatch.compactMap(\.facts.generatedNotificationLine).first : sentence
            // Old notices without generated redacted copy remain in the inbox;
            // never replace it with canned speech or expose their private text.
            guard let text, !text.isEmpty else { continue }
            deliver(identifier: identifier, text: text, message: message, target: target,
                    noticeKey: owner, records: allInBatch)
        }
    }

    // MARK: Source resolution (§6)

    /// Resolves `key` and every open occurrence of it (`key#…`): a reconnect
    /// or a request resolution names the source, not the occurrence.
    private func handleSourceResolved(key: String, reason: TitioNoticeResolution) async {
        let occurrences = ((try? repo.openKeys(prefix: key + TitioNoticeIDs.occurrenceSeparator)) ?? []).sorted()
        var targets = [key] + occurrences
        // Upgraded cards retain their original unscoped key and message ID.
        // Only resolve that legacy row when it names this exact run.
        if key.hasPrefix("thread."), key.contains(".attention."),
           let separator = key.range(of: TitioNoticeIDs.occurrenceSeparator, options: .backwards) {
            let base = String(key[..<separator.lowerBound])
            let run = String(key[separator.upperBound...])
            if let legacy = try? repo.get(key: base),
               legacy.source.runId?.caseInsensitiveCompare(run) == .orderedSame {
                targets.append(base)
            }
        }
        for target in targets {
            await resolveOne(key: target, reason: reason)
        }
    }

    /// A new request instance supersedes an older open one with the same
    /// thread and provider id (a recycled JSON-RPC id after a restart): the
    /// old card closes as expired before the new one posts, so a tap on it
    /// can never answer the new request.
    private func expireSupersededRequests(by fact: TitioNoticeFact) async {
        guard [.approval, .userInput, .manualAction].contains(fact.kind),
              fact.key.contains(TitioNoticeIDs.occurrenceSeparator) else { return }
        let base = TitioNoticeIDs.baseKey(of: fact.key)
        let siblings = ((try? repo.openKeys(prefix: base + TitioNoticeIDs.occurrenceSeparator)) ?? [])
            .subtracting([fact.key]).sorted()
        for sibling in siblings {
            await resolveOne(key: sibling, reason: .expired)
        }
    }

    private func resolveOne(key: String, reason: TitioNoticeResolution) async {
        flapTimers.removeValue(forKey: key)?.1.cancel()
        fallbackTimers.removeValue(forKey: key)?.1.cancel()
        infoKeys.removeAll { $0 == key }
        if infoKeys.isEmpty { infoFirstAt = nil }
        legacy[key] = nil
        let current = now()
        do {
            guard let row = try repo.get(key: key) else { return }
            if row.state == .pending {
                _ = try repo.drop(key: key, resolution: row.kind.usesFlapHold ? .flap : reason, at: current)
                return
            }
            guard case .resolved(let record) = try repo.resolveFromSource(key: key, resolution: reason, at: current) else { return }
            await rewrite(record, at: current)
            refreshMirrors()
        } catch {
            titioNoticeLog.error("titio.notice.source_resolve_failed key=\(key, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Rewrites the original message: strips its choices block and appends
    /// the status line. A digest message is rewritten only by its card owner.
    /// A message that transcript retention already removed is left removed
    /// (an upsert would resurrect it as a new row). With a writer, the card
    /// goes at once and Titio's own status note follows when it is written.
    private func rewrite(_ record: TitioNoticeRecord, at date: Date) async {
        guard let raw = record.messageID, let uuid = UUID(uuidString: raw),
              let resolution = record.resolution,
              let status = TitioNoticeStatus(resolution: resolution),
              record.batchID == nil || record.actions != nil else { return }
        let id = AgentMessageID(uuid)
        guard let original = try? messageRepo.get(id: id) else {
            titioNoticeLog.info("titio.notice.rewrite_skipped_missing key=\(record.key, privacy: .public)")
            return
        }
        let messageLanguage = TitioNoticeCopy.detectedLanguage(TitioNoticeBlock.visibleText(original.content)) ?? language()
        // Acknowledging a notice only closes its question. It must not call a
        // model to write "Seen", or turn the tap into another conversation turn.
        let writesStatus = resolution != .acknowledged
        let resolved = TitioNoticeCopy.resolvedText(
            original: original.content,
            statusLine: writesStatus ? TitioNoticeCopy.statusLine(status, language: messageLanguage, at: date, timeZone: timeZone) : nil
        )
        let text = TitioNoticeBlock.withState(resolved, state: status.wireValue)
        if text != original.content {
            await writeRewrite(original, text: text, language: messageLanguage, key: record.key)
        }
        guard writesStatus, resolution != .unknownEffect, let writer = voice else { return }
        let request = TitioVoiceRequest(
            purpose: .status,
            prompt: TitioVoicePrompt.status(status, at: date, language: voiceLanguage(), timeZone: timeZone),
            threadID: original.threadId
        )
        spawnVoice(
            request, writer: writer, deadline: voiceTiming.lineDeadline,
            accept: { TitioVoiceOutput.sanitizeLine($0, max: Self.statusLineMaxCharacters) != nil }
        ) { raw in
            .statusLine(
                messageID: id,
                text: raw.flatMap { TitioVoiceOutput.sanitizeLine($0, max: Self.statusLineMaxCharacters) }
            )
        }
    }

    static let statusLineMaxCharacters = 90

    /// Appends the status line once it is written. A message cleared in the
    /// meantime stays cleared.
    private func applyStatusLine(messageID: AgentMessageID, line: String) async {
        guard let original = try? messageRepo.get(id: messageID) else { return }
        let text = TitioNoticeCopy.resolvedText(original: original.content, statusLine: line)
        guard text != original.content else { return }
        let language = TitioNoticeCopy.detectedLanguage(TitioNoticeBlock.visibleText(original.content)) ?? language()
        await writeRewrite(original, text: text, language: language, key: nil)
    }

    /// Writes a rewritten inbox message and repaints it everywhere.
    private func writeRewrite(_ original: AgentMessage, text: String, language: TitioNoticeLanguage, key: String?) async {
        let updated = AgentMessage(
            id: original.id, threadId: original.threadId, role: original.role,
            content: text, createdAt: original.createdAt, attachments: original.attachments
        )
        do { try messageRepo.append(updated) } catch {
            titioNoticeLog.error("titio.notice.rewrite_failed key=\(key ?? "-", privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        let revision = ((try? messageRepo.bodyRevision(id: original.id)) ?? nil) ?? 1
        var resolvedTarget = cachedTarget
        if resolvedTarget == nil { resolvedTarget = await target(language: language) }
        guard let target = resolvedTarget, target.threadID == original.threadId else { return }
        let openDecisions = (try? repo.openDecisionCount()) ?? 0
        let conversation = settleAttention(target: target, openDecisions: openDecisions)
        await hooks.messagePosted(TitioNoticePostedMessage(
            message: updated, bodyRevision: revision, target: target, conversation: conversation, isRewrite: true
        ))
        await publishInbox(target: target, fallback: nil)
    }

    /// After a resolution: needs-attention clears once no decision is open.
    private func settleAttention(target: TitioInboxTarget, openDecisions: Int) -> BotConversation? {
        guard var conversation = try? botStore.conversation(id: target.conversationID) else { return nil }
        guard openDecisions == 0, conversation.attentionState == .needsAttention else { return conversation }
        conversation.attentionState = conversation.unread ? .unreadActivity : .none
        try? botStore.upsertConversation(conversation)
        return conversation
    }

    // MARK: Clear (contract §3)

    /// Deletes the message, settles every open ledger row it carries as
    /// `cleared` (acking each source: Activity for run outcomes, the Bot
    /// attention item, the notification row of an external notice; a provider
    /// request stays pending in its own thread), then updates the inbox and
    /// tells every client (`agent.messages.removed`, `bot.updated`).
    private func performClear(_ id: AgentMessageID) async {
        guard let message = (try? messageRepo.get(id: id)) ?? nil else { return }
        let at = now()
        var settled: [TitioNoticeRecord] = []
        for row in (try? repo.notices(messageID: id.value.uuidString)) ?? [] where [.posted, .awaitingReply].contains(row.state) {
            if case .resolved(let record)? = try? repo.resolveFromSource(key: row.key, resolution: .cleared, at: at) {
                settled.append(record)
            }
        }
        do {
            try messageRepo.delete(ids: [id])
        } catch {
            titioNoticeLog.error("titio.notice.clear_failed error=\(String(describing: error), privacy: .public)")
            refreshMirrors()
            return
        }
        titioNoticeLog.info("titio.notice.cleared rows=\(settled.count, privacy: .public)")
        if let actions = actionsBox.value, !settled.isEmpty {
            let rows = settled
            spawnAct { _ in await Self.acknowledgeCleared(rows, actions: actions) }
        }
        var resolvedTarget = cachedTarget
        if resolvedTarget == nil { resolvedTarget = await target(language: language()) }
        guard let target = resolvedTarget, target.threadID == message.threadId else {
            refreshMirrors()
            return
        }
        let remaining = ((try? messageRepo.listRecent(threadId: target.threadID, limit: 30)) ?? [])
            .last { $0.role == .assistant }
        let inbox = try? repo.updateInboxState { state in
            state.unreadCount = max(0, state.unreadCount - 1)
            state.lastPreview = remaining.map { TitioNoticeCopy.preview(TitioNoticeBlock.visibleText($0.content)) }
            state.lastAt = remaining?.createdAt
        }
        let openDecisions = (try? repo.openDecisionCount()) ?? 0
        _ = settleAttention(target: target, openDecisions: openDecisions)
        refreshMirrors()
        await hooks.messagesRemoved(target, [id])
        await publishInbox(target: target, fallback: inbox.map { snapshot(target: target, inbox: $0, openDecisions: openDecisions) })
    }

    /// Activity item ids behind these notices, without duplicates.
    static func activityItemIDs(_ rows: [TitioNoticeRecord]) -> [String] {
        var seen = Set<String>()
        return rows.compactMap { row -> String? in
            row.source.activityItemId
                ?? row.source.runId.map { "run:\($0.lowercased())" }
                ?? row.source.notificationId.map { "notification:\($0)" }
        }.filter { seen.insert($0).inserted }
    }

    /// Best effort: the source may already be gone; failures are logged.
    static func acknowledgeCleared(_ rows: [TitioNoticeRecord], actions: TitioNoticeActionHooks) async {
        for row in rows {
            do {
                switch row.kind {
                case .external:
                    if let id = row.source.notificationId { try await actions.dismissNotification(id) }
                case .runCompleted, .runFailed, .runInterrupted, .scheduledFailed:
                    if let item = row.source.activityItemId ?? row.source.runId.map({ "run:\($0.lowercased())" }) {
                        try await actions.acknowledgeActivity(item)
                    }
                case .botQuestion, .botBlocked:
                    if let item = row.source.attentionItemId.flatMap(UUID.init(uuidString:)).map(BotAttentionItemID.init) {
                        try await actions.acknowledgeBotAttention(item)
                    }
                default:
                    // Provider requests stay pending in their own thread; Bot
                    // replies and pet alerts have no source row to ack.
                    break
                }
            } catch {
                titioNoticeLog.info("titio.notice.clear_ack_failed key=\(row.key, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Read state (§8)

    private func handleMarkRead() async {
        if cachedTarget == nil { _ = await warmTarget() }
        guard let target = cachedTarget else { return }
        do {
            let inbox = try repo.updateInboxState { $0.unreadCount = 0 }
            let openDecisions = (try? repo.openDecisionCount()) ?? 0
            if var conversation = try botStore.conversation(id: target.conversationID) {
                conversation.unread = false
                if openDecisions == 0, conversation.attentionState != .working { conversation.attentionState = .none }
                try botStore.upsertConversation(conversation)
            }
            await publishInbox(target: target, fallback: snapshot(target: target, inbox: inbox, openDecisions: openDecisions))
            // Read in the inbox is read in Activity: the cards' source items leave Unread.
            let open = (try? repo.rows(inStates: [.posted, .acting, .awaitingReply])) ?? []
            let items = Self.activityItemIDs(open)
            if !items.isEmpty { await actionsBox.value?.markActivityViewed(items) }
        } catch {
            titioNoticeLog.error("titio.notice.mark_read_failed error=\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Direct reply banner (§2)

    private func handleDirectReply(_ reply: DirectReply) async {
        let settings = settingsStore.load()
        let conversation = try? botStore.conversation(id: reply.conversationID)
        let workspaceID = conversation?.linkedAgentThreadID.flatMap { try? threadRepo.get(id: $0)?.workspaceId }
        guard (try? botStore.get(id: reply.botID))?.notificationsEnabled != false,
              RemoteCodeNotificationContent.AgentAppPushPolicy.allowsNotification(
                isAction: false, workspaceId: workspaceID?.value.uuidString, settings: settings
              ) else { return }
        let banner = TitioNoticeCopy.directReplyBanner(replyText: reply.text)
        guard !banner.body.isEmpty else { return }
        let identifier = "titio.reply.\(reply.runID.value.uuidString)"
        let binding = hooks.pushBinding()
        let messageID = (reply.messageID?.value ?? reply.runID.value).uuidString.lowercased()
        func info(includeBot: Bool) -> [String: String] {
            RemoteCodeNotificationContent.titioNoticeUserInfo(
                botID: reply.botID.value.uuidString.lowercased(),
                conversationID: reply.conversationID.value.uuidString.lowercased(),
                messageID: messageID, noticeKey: nil, identifier: identifier,
                profileID: binding.profileID, hostID: binding.hostID,
                legacy: conversation?.linkedAgentThreadID.map { ["threadId": $0.value.uuidString] } ?? [:],
                includeBotIdWithoutProfile: includeBot
            )
        }
        hooks.postBanner(RemoteCodeNotificationContent.titioNotice(identifier: identifier, body: banner.body, userInfo: info(includeBot: true)))
        let push = RemoteCodeNotificationContent.titioNotice(identifier: identifier, body: banner.body, userInfo: info(includeBot: false))
        let deliverPush = hooks.deliverPush
        Task { await deliverPush(push) }
    }

    // MARK: Pet / terminal events (§5)

    private func handleObservedEvent(_ event: EventBus.Event) async -> Bool {
        guard event.kind.hasPrefix("agent."), event.kind != "agent.provider.updated" else {
            return await handlePetEvent(event)
        }
        if ["agent.request.resolved", "agent.user_input.resolved"].contains(event.kind),
           case .object(let payload) = event.payload,
           let thread = payload["thread_id"]?.stringValue,
           let request = payload["request_id"]?.stringValue {
            let key = payload["run_id"]?.stringValue.map {
                TitioNoticeIDs.threadAttention(threadId: thread, requestId: request, runId: $0)
            } ?? TitioNoticeIDs.threadAttention(threadId: thread, requestId: request)
            await handleSourceResolved(key: key, reason: .elsewhere)
            return true
        }
        guard hubEnabled() else { return false }
        return await hooks.observeAgentEvent(event)
    }

    private func handlePetEvent(_ event: EventBus.Event) async -> Bool {
        guard case .object(let payload) = event.payload else { return true }
        // Resolutions first: they never classify as a notice.
        if event.kind == "ssh.session.updated",
           payload["status"]?.stringValue == "connected" || payload["reason"]?.stringValue == "user_requested",
           let surface = payload["surface_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
            await handleSourceResolved(key: TitioNoticeIDs.petSSHDisconnect(surfaceId: surface.uuidString), reason: .elsewhere)
            return true
        }
        if ["files.edit.saved", "files.edit.discarded", "files.edit.closed"].contains(event.kind),
           let session = payload["session_id"]?.stringValue, !session.isEmpty {
            await handleSourceResolved(key: TitioNoticeIDs.petFileConflict(sessionId: session), reason: .elsewhere)
            return true
        }
        guard let terminal = PetTerminalNotificationRecorder.classify(event),
              let mapped = Self.noticeKind(for: terminal.kind) else { return true }
        // The same gates as every hook (§2, §0.5): the kill switch, the
        // action/completion toggles and workspace mutes. Resolutions above
        // still run, so a muted or disabled hub never leaves a stale row.
        let settings = settingsStore.load()
        guard settings.titioNotificationsEnabled else { return false }
        let key: String
        switch terminal.kind {
        case .sshUnexpectedDisconnect:
            guard let surface = terminal.surfaceID else { return true }
            // One row per occurrence: a drop after an earlier flap or
            // reconnect must post again (the source key alone is finished).
            key = TitioNoticeIDs.occurrence(
                of: TitioNoticeIDs.petSSHDisconnect(surfaceId: surface.value.uuidString), String(terminal.sequence)
            )
        case .fileConflict:
            guard let session = payload["session_id"]?.stringValue, !session.isEmpty else { return true }
            key = TitioNoticeIDs.occurrence(of: TitioNoticeIDs.petFileConflict(sessionId: session), String(terminal.sequence))
        default:
            key = TitioNoticeIDs.petEvent(sequence: terminal.sequence)
        }
        let workspaceName: String?
        if let workspace = terminal.workspaceID {
            workspaceName = await hooks.workspaceName(workspace)
        } else {
            workspaceName = nil
        }
        var facts = TitioNoticeFacts(
            title: Self.petTitle(payload: payload),
            workspaceName: workspaceName,
            exitCode: payload["exit_code"]?.intValue,
            durationMs: payload["duration_ms"]?.intValue
        )
        facts.interruptionSuppressed = !mapped.isFailure && mapped.defaultUrgency == .info
            ? await hooks.isFocusedSuccess(event) : false
        let fact = TitioNoticeFact(
            key: key,
            kind: mapped,
            source: TitioNoticeSource(workspaceId: terminal.workspaceID?.value.uuidString),
            facts: facts,
            actions: TitioNoticeAction.defaultActions(kind: mapped, facts: facts),
            occurredAt: terminal.createdAt
        )
        return await handleIngest(fact, legacy: nil)
    }

    static func noticeKind(for kind: PetTerminalNotificationKind) -> TitioNoticeKind? {
        switch kind {
        case .gitDelivery(.succeeded): return .gitCompleted
        case .gitDelivery(.failed): return .gitFailed
        case .projectScript(.succeeded): return .scriptCompleted
        case .projectScript(.failed): return .scriptFailed
        case .sshTransfer(.succeeded): return .transferCompleted
        case .sshTransfer(.failed): return .transferFailed
        case .sshUnexpectedDisconnect: return .sshDisconnected
        case .providerUpdateFailed: return .providerUpdateFailed
        case .fileConflict: return .fileConflict
        }
    }

    /// The best human name an event payload carries (script name, file,
    /// provider, transfer direction…); nil when it has none.
    static func petTitle(payload: [String: JSONValue]) -> String? {
        for key in ["name", "title", "file_name", "host"] {
            if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        if let path = payload["path"]?.stringValue, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        if let provider = payload["provider"]?.stringValue, !provider.isEmpty {
            return provider
        }
        return nil
    }

    // MARK: Bot attention projector (§5)

    private func scheduleAttentionPass() {
        attentionTimer?.cancel()
        attentionGeneration = nextSerial()
        attentionTimer = schedule(Self.attentionDebounce, .attention(attentionGeneration))
    }

    private func runAttentionPass() async {
        let items: [BotAttentionItem]
        let bots: [BotID: BotDefinition]
        let openBotKeys: Set<String>
        let openThreadKeys: Set<String>
        do {
            items = try botStore.listAttention()
            bots = Dictionary(try botStore.list(includeHidden: true).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            openBotKeys = try repo.openKeys(prefix: "bot.attention.")
            openThreadKeys = try repo.openKeys(prefix: "thread.")
        } catch {
            titioNoticeLog.error("titio.notice.attention_pass_failed error=\(String(describing: error), privacy: .public)")
            return
        }
        let plan = Self.attentionPlan(
            items: items, bots: bots, openBotKeys: openBotKeys, openThreadKeys: openThreadKeys,
            linkedThread: { [botStore] id in (try? botStore.conversation(id: id))?.linkedAgentThreadID },
            now: now()
        )
        for key in plan.resolved {
            await handleSourceResolved(key: key, reason: .elsewhere)
        }
        // Kill switch and the action toggle gate new Bot notices (§0.5, §2);
        // items acknowledged elsewhere still resolve above.
        let settings = settingsStore.load()
        guard settings.titioNotificationsEnabled else { return }
        for candidate in plan.ingest {
            var source = candidate.source
            var facts = candidate.facts
            if let conversationID = source.conversationId.flatMap(UUID.init(uuidString:)).map(BotConversationID.init),
               let conversation = try? botStore.conversation(id: conversationID) {
                facts.title = conversation.title
            }
            if let threadID = candidate.threadID, let thread = try? threadRepo.get(id: threadID) {
                source.workspaceId = thread.workspaceId?.value.uuidString
                if let workspaceID = thread.workspaceId { facts.workspaceName = await hooks.workspaceName(workspaceID) }
                if facts.title == nil { facts.title = thread.title }
                if candidate.kind == .botQuestion,
                   let message = try? messageRepo.listRecent(threadId: threadID, limit: 20)
                    .last(where: { $0.role == .assistant && $0.createdAt <= candidate.occurredAt }),
                   let choices = BotChoicesBlock.parse(message.content).choices {
                    facts.options = choices.options
                    facts.prompt = choices.question
                    source.finalMessageId = message.id.value.uuidString
                }
            }
            let fact = TitioNoticeFact(
                key: candidate.key,
                kind: candidate.kind,
                source: source,
                facts: facts,
                actions: TitioNoticeAction.defaultActions(kind: candidate.kind, facts: facts),
                occurredAt: candidate.occurredAt
            )
            await handleIngest(fact, legacy: nil)
        }
    }

    struct AttentionCandidate: Equatable {
        var key: String
        var kind: TitioNoticeKind
        var source: TitioNoticeSource
        var facts: TitioNoticeFacts
        var threadID: AgentThreadID?
        var occurredAt: Date
    }

    struct AttentionPlan: Equatable {
        var ingest: [AttentionCandidate]
        var resolved: [String]
    }

    /// Pure projector rules (§5): unacknowledged question/handoff/approval →
    /// `botQuestion`, blocked/unknownEffect → `botBlocked`; only Bots with
    /// notifications on that are not Titio; skipped when a thread request
    /// notice already covers the conversation's linked thread. Open notices
    /// whose item is gone (acknowledged elsewhere) resolve.
    static func attentionPlan(
        items: [BotAttentionItem],
        bots: [BotID: BotDefinition],
        openBotKeys: Set<String>,
        openThreadKeys: Set<String>,
        linkedThread: (BotConversationID) -> AgentThreadID?,
        now: Date = Date()
    ) -> AttentionPlan {
        var ingest: [AttentionCandidate] = []
        var live = Set<String>()
        for item in items where item.acknowledgedAt == nil {
            let kind: TitioNoticeKind
            switch item.kind {
            case .question, .handoff, .approval: kind = .botQuestion
            case .blocked, .unknownEffect: kind = .botBlocked
            case .unread: continue
            }
            let key = TitioNoticeIDs.botAttention(itemId: item.id.value.uuidString)
            live.insert(key)
            guard let bot = bots[item.botID], bot.deletedAt == nil,
                  bot.handle.lowercased() != TitioBot.handle else { continue }
            if openBotKeys.contains(key) { continue }
            let thread = item.conversationID.flatMap(linkedThread)
            if let thread {
                let prefix = "thread.\(thread.value.uuidString).attention."
                if openThreadKeys.contains(where: { $0.hasPrefix(prefix) }) { continue }
            }
            let detail = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            ingest.append(AttentionCandidate(
                key: key,
                kind: kind,
                source: TitioNoticeSource(
                    threadId: thread?.value.uuidString,
                    botId: bot.id.value.uuidString.lowercased(),
                    conversationId: item.conversationID?.value.uuidString.lowercased(),
                    attentionItemId: item.id.value.uuidString.lowercased()
                ),
                facts: TitioNoticeFacts(botName: bot.name, detail: detail.isEmpty ? item.title : detail),
                threadID: thread,
                occurredAt: item.createdAt
            ))
        }
        let resolved = openBotKeys.subtracting(live).sorted()
        return AttentionPlan(ingest: ingest, resolved: resolved)
    }

    // MARK: Acting on a card (§7)

    /// The shared act core for the Mac card and `bot.notice.act`. Runs on the
    /// caller's thread (this actor for the Mac, a detached task for the RPC),
    /// never on the MainActor:
    /// 1. look the row up by `message_id` (a forged card has none: `notFound`);
    /// 2. a navigation option answers its route and changes no state;
    /// 3. claim atomically (`posted|awaiting_reply → acting`); a lost race is
    ///    `alreadyResolved` and Titio says so;
    /// 4. execute asynchronously and answer `accepted`; Titio's result line
    ///    reports the real outcome. Nothing resolves before the host result.
    public nonisolated func actNow(messageID: String, optionIndex: Int) -> TitioNoticeActOutcome {
        let record: TitioNoticeRecord?
        do {
            record = try repo.notice(messageID: messageID.uppercased()) ?? repo.notice(messageID: messageID)
        } catch {
            titioNoticeLog.error("titio.notice.act_lookup_failed error=\(String(describing: error), privacy: .public)")
            return .notFound
        }
        guard let record, let options = record.actions else { return .notFound }
        guard options.indices.contains(optionIndex) else { return .invalidOption }
        let option = options[optionIndex]
        if option.action.isNavigation {
            return .navigate(route: Self.navigationRoute(for: option.action, record: record, binding: hooks.pushBinding()))
        }
        guard let actions = actionsBox.value else { return .unsupported }
        guard isSourceRequestOpen(record, actions: actions) else {
            continuation.yield(.sourceResolved(record.key, .expired))
            return .alreadyResolved
        }
        // Any other tap clears a live arm on another notice (§7 "Armed reply").
        let cleared: TitioNoticeArm? = armBox.mutate { arm in
            guard let current = arm else { return nil }
            arm = nil
            return current.key == record.key ? nil : current
        }
        if let cleared { _ = try? repo.disarm(key: cleared.key) }
        let claimed = (try? repo.claim(key: record.key)) ?? false
        continuation.yield(.refreshMirrors)
        guard claimed else {
            // A repeated tap while the first act runs (`acting`) is silent:
            // that act reports. A notice that already ended gets the honest line.
            if option.action != .ack, (try? repo.get(key: record.key))?.state != .acting {
                spawnAct { center in await center.reportAlreadyResolved(record) }
            }
            return .alreadyResolved
        }
        spawnAct { center in await center.runClaimedAct(record, option: option, actions: actions) }
        return .accepted
    }

    /// Capable clients capture this source card in their own composer. Merely
    /// opening that composer never changes a shared armed-reply slot.
    public nonisolated func contextualReply(messageID: String, optionIndex: Int) -> [String: Any]? {
        guard let record = try? repo.notice(messageID: messageID.uppercased()),
              let options = record.actions, options.indices.contains(optionIndex),
              options[optionIndex].action == .replyHere else { return nil }
        guard record.state == .posted || record.state == .awaitingReply else {
            return ["outcome": "already_resolved"]
        }
        let question = capturedQuestion(record)
        return ["outcome": "reply_required", "question": question]
    }

    /// The card identity, not the latest global arm, owns this reply. Claim
    /// before returning acceptance; a concurrent device cannot send it twice.
    public nonisolated func replyNow(messageID: String, text: String, expectedQuestionRevision: Int? = nil) -> TitioNoticeActOutcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 65_536 else { return .invalidOption }
        guard let record = try? repo.notice(messageID: messageID.uppercased()),
              record.actions?.contains(where: { $0.action == .replyHere }) == true else { return .notFound }
        if let expectedQuestionRevision {
            guard let uuid = UUID(uuidString: messageID),
                  (try? messageRepo.bodyRevision(id: AgentMessageID(uuid))) == expectedQuestionRevision else { return .alreadyResolved }
        }
        guard let actions = actionsBox.value else { return .unsupported }
        guard isSourceRequestOpen(record, actions: actions) else {
            continuation.yield(.sourceResolved(record.key, .expired))
            return .alreadyResolved
        }
        guard (try? repo.claim(key: record.key)) == true else { return .alreadyResolved }
        continuation.yield(.refreshMirrors)
        spawnAct { center in
            await center.appendActMessage(role: .user, text: center.quotedAnswer(text, record: record))
            let language = await center.messageLanguage(record)
            if record.kind == .botQuestion {
                await center.forwardToBot(record, text: text, actions: actions, language: language)
            } else {
                await center.answerRequest(record, text: text, actions: actions, language: language)
            }
        }
        return .accepted
    }

    private nonisolated func capturedQuestion(_ record: TitioNoticeRecord) -> String {
        if let raw = record.messageID, let uuid = UUID(uuidString: raw),
           let message = try? messageRepo.get(id: AgentMessageID(uuid)),
           let question = BotChoicesBlock.parse(message.content).choices?.question { return question }
        return record.facts.prompt ?? record.facts.detail ?? record.facts.title ?? ""
    }

    private nonisolated func quotedAnswer(_ text: String, record: TitioNoticeRecord) -> String {
        let question = capturedQuestion(record)
        guard !question.isEmpty else { return text }
        return AgentReplyQuote.compose(excerpt: question, text: text)
    }

    /// The Mac `hostReplyHandler` and the iOS inbox intercept: the next text
    /// within `armedReplyTTL` of a "Reply here" goes to the armed notice
    /// instead of a Titio run. Decided from the in-memory arm (no SQLite on
    /// the send path); true means the text was taken.
    public nonisolated func takeArmedReply(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let actions = actionsBox.value, let arm = armBox.exchange(nil) else { return false }
        guard now().timeIntervalSince(arm.armedAt) <= TitioNoticeTiming.armedReplyTTL else {
            // Expired: the card comes back and the text is a normal message.
            continuation.yield(.expireArm(arm.key))
            return false
        }
        takenArmKeys.mutate { _ = $0.insert(arm.key) }
        spawnAct { center in await center.consumeArmedReply(key: arm.key, text: trimmed, actions: actions) }
        return true
    }

    /// Old iOS builds (no `bot.notice.act`) send the option's text. It acts
    /// on that option only when it equals a consequential option of exactly
    /// one open notice; otherwise the text stays normal chat (§7).
    public nonisolated func takeOptionText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, actionsBox.value != nil else { return false }
        var matches: [(messageID: String, index: Int)] = []
        for card in openCardsBox.value {
            guard let index = card.options.firstIndex(where: {
                !$0.action.isNavigation && $0.label?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
            }) else { continue }
            matches.append((card.messageID, index))
        }
        guard matches.count == 1 else { return false }
        switch actNow(messageID: matches[0].messageID, optionIndex: matches[0].index) {
        case .accepted, .alreadyResolved: return true
        case .notFound, .invalidOption, .navigate, .unsupported: return false
        }
    }

    /// Waits for every act execution started so far (tests, teardown).
    public func settleActs() async {
        while true {
            let running = actTasks.value
            guard !running.isEmpty else { return }
            for task in running.values { await task.value }
        }
    }

    private nonisolated func spawnAct(_ work: @escaping @Sendable (TitioNoticeCenter) async -> Void) {
        let id = UUID()
        let tasks = actTasks
        // The lock is held across creation, so the task cannot remove its
        // entry before it is inserted.
        tasks.mutate { running in
            running[id] = Task { [weak self] in
                if let self { await work(self) }
                tasks.mutate { $0[id] = nil }
            }
        }
    }

    private func reportAlreadyResolved(_ record: TitioNoticeRecord) async {
        await speakResult(.alreadyResolved)
    }

    /// Titio's generated line after an act. The user's own tap row is already in.
    private func speakResult(_ result: TitioNoticeResult) async {
        guard let writer = voice else { return }
        let request = TitioVoiceRequest(
            purpose: .result,
            prompt: TitioVoicePrompt.result(result, language: voiceLanguage()),
            threadID: cachedTarget?.threadID
        )
        spawnVoice(request, writer: writer, deadline: voiceTiming.lineDeadline,
                   accept: { TitioVoiceOutput.sanitize($0) != nil }) { raw in
            .resultLine(text: raw.flatMap(TitioVoiceOutput.sanitize))
        }
    }

    /// §7 steps 4–5 for a claimed row.
    private func runClaimedAct(_ record: TitioNoticeRecord, option: TitioNoticeCardOption, actions: TitioNoticeActionHooks) async {
        let language = messageLanguage(record)
        let label = option.label ?? TitioNoticeCopy.label(for: option.action, language: language, botName: record.facts.botName)
        if option.action != .ack {
            await appendActMessage(role: .user, text: quotedAnswer(label, record: record))
        }
        let facts = record.facts
        let source = record.source
        switch option.action {
        case .approve, .approveSession, .decline:
            let decision: TitioNoticeActionHooks.RequestDecision
            let resolution: TitioNoticeResolution
            let result: TitioNoticeResult
            switch option.action {
            case .approve: decision = .approve; resolution = .approved; result = .approved(workspace: facts.workspaceName)
            case .approveSession: decision = .approveForSession; resolution = .approvedSession; result = .approvedSession(workspace: facts.workspaceName)
            default: decision = .decline; resolution = .declined; result = .declined(workspace: facts.workspaceName)
            }
            guard let request = requestTarget(record) else {
                return await finish(record, .failed, result: .failed(error: missingSourceReason(language)))
            }
            guard actions.isRequestOpen(request.thread, request.id, .approval, record.source.runId) else {
                return await finish(record, .expired, result: .alreadyResolved)
            }
            await perform(record, resolution: resolution, result: result) {
                try await actions.respondRequest(request.thread, request.id, decision)
            }
        case .providerOption(_, let text):
            await answerRequest(record, text: text, actions: actions, language: language)
        case .botOption(let text):
            await forwardToBot(record, text: text, actions: actions, language: language)
        case .continue:
            guard let thread = source.threadId.flatMap(UUID.init(uuidString:)).map(AgentThreadID.init) else {
                return await finish(record, .failed, result: .failed(error: missingSourceReason(language)))
            }
            await perform(record, resolution: .retried, result: .continued(title: facts.title)) {
                try await actions.continueRun(thread)
            }
        case .rerun:
            guard let task = source.scheduledTaskId.flatMap(UUID.init(uuidString:)) else {
                return await finish(record, .failed, result: .failed(error: missingSourceReason(language)))
            }
            await perform(record, resolution: .retried, result: .rerun(task: facts.title)) {
                try await actions.rerunScheduledTask(task)
            }
        case .ack:
            // "Entendi" dismisses the notice; the Activity/Bot acknowledge is
            // best effort (the item may already be gone) and only logged.
            do {
                if let item = source.attentionItemId.flatMap(UUID.init(uuidString:)).map(BotAttentionItemID.init) {
                    try await actions.acknowledgeBotAttention(item)
                } else if let activity = source.activityItemId ?? source.runId.map({ "run:\($0.lowercased())" }) {
                    try await actions.acknowledgeActivity(activity)
                }
            } catch {
                titioNoticeLog.info("titio.notice.ack_source_failed key=\(record.key, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
            await finish(record, .acknowledged, result: nil)
        case .replyHere:
            let armedAt = now()
            guard (try? repo.setAwaitingReply(key: record.key, at: armedAt)) == true else {
                titioNoticeLog.error("titio.notice.arm_failed key=\(record.key, privacy: .public)")
                _ = try? repo.reopen(key: record.key)
                refreshMirrors()
                return
            }
            takenArmKeys.mutate { _ = $0.remove(record.key) }
            refreshMirrors()
            await speakResult(.armed(target: replyTarget(record)))
        case .openThread, .openBot, .openActivity, .openAllActivity:
            // Navigation never claims; `actNow` answers it before the claim.
            _ = try? repo.reopen(key: record.key)
            refreshMirrors()
        }
    }

    /// The armed text (§7 "Armed reply"): the user's words land in the inbox
    /// as their own row, then go to the provider question or the Bot.
    private func consumeArmedReply(key: String, text: String, actions: TitioNoticeActionHooks) async {
        defer { takenArmKeys.mutate { _ = $0.remove(key) } }
        let record = try? repo.get(key: key)
        await appendActMessage(role: .user, text: record.map { quotedAnswer(text, record: $0) } ?? text)
        guard let record, (try? repo.claim(key: key)) == true else {
            refreshMirrors()
            await speakResult(.alreadyResolved)
            return
        }
        let language = messageLanguage(record)
        switch record.kind {
        case .botQuestion:
            await forwardToBot(record, text: text, actions: actions, language: language)
        default:
            await answerRequest(record, text: text, actions: actions, language: language)
        }
    }

    private func answerRequest(_ record: TitioNoticeRecord, text: String, actions: TitioNoticeActionHooks, language: TitioNoticeLanguage) async {
        guard let request = requestTarget(record) else {
            return await finish(record, .failed, result: .failed(error: missingSourceReason(language)))
        }
        guard actions.isRequestOpen(request.thread, request.id, .userInput, record.source.runId) else {
            return await finish(record, .expired, result: .alreadyResolved)
        }
        await perform(record, resolution: .answered,
                      result: .answered(answer: text, target: .agent(workspace: record.facts.workspaceName))) {
            try await actions.respondUserInput(request.thread, request.id, text)
        }
    }

    /// A Bot option or armed text goes into that Bot's own conversation, and
    /// its attention item is acknowledged (`bots.attention.changed`).
    private func forwardToBot(_ record: TitioNoticeRecord, text: String, actions: TitioNoticeActionHooks, language: TitioNoticeLanguage) async {
        guard let bot = record.source.botId.flatMap(UUID.init(uuidString:)).map(BotID.init),
              let conversation = record.source.conversationId.flatMap(UUID.init(uuidString:)).map(BotConversationID.init) else {
            return await finish(record, .failed, result: .failed(error: missingSourceReason(language)))
        }
        await perform(record, resolution: .forwarded,
                      result: .answered(answer: text, target: .bot(name: record.facts.botName))) {
            try await actions.sendBotMessage(bot, conversation, quotedAnswer(text, record: record))
            if let item = record.source.attentionItemId.flatMap(UUID.init(uuidString:)).map(BotAttentionItemID.init) {
                do {
                    try await actions.acknowledgeBotAttention(item)
                } catch {
                    titioNoticeLog.info("titio.notice.bot_ack_failed key=\(record.key, privacy: .public) error=\(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Runs the host action; resolves only after its real result (§7 step 5).
    private func perform(
        _ record: TitioNoticeRecord,
        resolution: TitioNoticeResolution,
        result: TitioNoticeResult,
        _ action: () async throws -> Void
    ) async {
        do {
            try await action()
        } catch {
            titioNoticeLog.error("titio.notice.act_failed key=\(record.key, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return await finish(record, .failed, result: .failed(error: Self.reason(error)))
        }
        await finish(record, resolution, result: result)
    }

    /// `acting → resolved`, the original message rewritten (choices stripped,
    /// status line), then the result line.
    private func finish(_ record: TitioNoticeRecord, _ resolution: TitioNoticeResolution, result: TitioNoticeResult?) async {
        let at = now()
        do {
            if let resolved = try repo.resolve(key: record.key, resolution: resolution, at: at) {
                await rewrite(resolved, at: at)
            } else {
                titioNoticeLog.error("titio.notice.resolve_skipped key=\(record.key, privacy: .public)")
            }
        } catch {
            titioNoticeLog.error("titio.notice.resolve_failed key=\(record.key, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
        refreshMirrors()
        if let result {
            await speakResult(result)
        }
    }

    /// A user row or result line in the inbox thread (never bumps unread: the
    /// user is acting). Assistant lines become the inbox preview.
    private func appendActMessage(role: AgentMessageRole, text: String) async {
        guard let target = await target(language: language()) else {
            titioNoticeLog.error("titio.notice.act_message_no_inbox role=\(role.rawValue, privacy: .public)")
            return
        }
        var createdAt = now()
        if let last = lastActMessageAt, createdAt <= last { createdAt = last.addingTimeInterval(0.001) }
        lastActMessageAt = createdAt
        let message = AgentMessage(id: AgentMessageID(UUID()), threadId: target.threadID, role: role, content: text, createdAt: createdAt)
        do {
            try messageRepo.append(message)
        } catch {
            titioNoticeLog.error("titio.notice.act_message_failed error=\(String(describing: error), privacy: .public)")
            return
        }
        let revision = ((try? messageRepo.bodyRevision(id: message.id)) ?? nil) ?? 1
        let conversation = try? botStore.conversation(id: target.conversationID)
        await hooks.messagePosted(TitioNoticePostedMessage(
            message: message, bodyRevision: revision, target: target, conversation: conversation, isRewrite: false
        ))
        guard role == .assistant,
              let inbox = try? repo.updateInboxState({ state in
                  if state.lastAt.map({ createdAt >= $0 }) ?? true {
                      state.lastPreview = TitioNoticeCopy.preview(TitioNoticeBlock.visibleText(text))
                      state.lastAt = createdAt
                  }
              }) else { return }
        await publishInbox(target: target, fallback: snapshot(target: target, inbox: inbox, openDecisions: (try? repo.openDecisionCount()) ?? 0))
    }

    private nonisolated func requestTarget(_ record: TitioNoticeRecord) -> (thread: AgentThreadID, id: String)? {
        guard let thread = record.source.threadId.flatMap(UUID.init(uuidString:)).map(AgentThreadID.init),
              let request = record.source.requestId, !request.isEmpty else { return nil }
        return (thread, request)
    }

    private func replyTarget(_ record: TitioNoticeRecord) -> TitioNoticeReplyTarget {
        record.kind == .botQuestion ? .bot(name: record.facts.botName) : .agent(workspace: record.facts.workspaceName)
    }

    /// Result lines speak the language of the notice they answer.
    private func messageLanguage(_ record: TitioNoticeRecord) -> TitioNoticeLanguage {
        if let raw = record.messageID, let uuid = UUID(uuidString: raw),
           let original = try? messageRepo.get(id: AgentMessageID(uuid)),
           let detected = TitioNoticeCopy.detectedLanguage(TitioNoticeBlock.visibleText(original.content)) {
            return detected
        }
        return language()
    }

    private func missingSourceReason(_ language: TitioNoticeLanguage) -> String {
        language == .pt ? "não sei mais para onde enviar" : "I no longer know where to send it"
    }

    static func reason(_ error: Error) -> String {
        if let local = error as? LocalizedError, let description = local.errorDescription, !description.isEmpty {
            return description
        }
        return String(describing: error)
    }

    // MARK: Mirrors

    /// Re-reads the arm, the open cards and the inbox snapshot into memory.
    private func refreshMirrors() {
        if let inbox = try? repo.inboxState() {
            if let key = inbox.armedReplyKey, let armedAt = inbox.armedAt, !takenArmKeys.value.contains(key),
               (try? repo.get(key: key))?.state == .awaitingReply {
                armBox.value = TitioNoticeArm(key: key, armedAt: armedAt)
            } else {
                armBox.value = nil
            }
            if let target = cachedTarget {
                snapshotBox.value = snapshot(target: target, inbox: inbox, openDecisions: (try? repo.openDecisionCount()) ?? 0)
            }
        }
        openCardsBox.value = ((try? repo.openCards()) ?? []).compactMap { row in
            guard let messageID = row.messageID, let options = row.actions else { return nil }
            return TitioNoticeOpenCard(messageID: messageID, key: row.key, options: options)
        }
    }

    /// Startup: an arm that outlived its TTL while the app was closed gives
    /// its card back.
    private func refreshMirrorsAfterStartup(now current: Date) {
        if let inbox = try? repo.inboxState(), let key = inbox.armedReplyKey,
           inbox.liveArmedReplyKey(now: current) == nil {
            _ = try? repo.disarm(key: key)
        }
        refreshMirrors()
    }

    private func handleExpireArm(_ key: String) {
        if let inbox = try? repo.inboxState(), inbox.armedReplyKey == key,
           inbox.liveArmedReplyKey(now: now()) == nil {
            _ = try? repo.disarm(key: key)
        }
        refreshMirrors()
    }

    /// Every `titio_inbox` change: the mirror for `bot.list`, then
    /// `bot.updated`. The counters are re-read right here, with no suspension
    /// between the read and the publish, so a caller that resumed after an
    /// await (a flush waiting on the desk hop while an act wrote a newer
    /// result line) can never publish an older preview over a newer one.
    private func publishInbox(target: TitioInboxTarget, fallback: TitioInboxSnapshot?) async {
        let fresh: TitioInboxSnapshot?
        if let inbox = try? repo.inboxState() {
            fresh = snapshot(target: target, inbox: inbox, openDecisions: (try? repo.openDecisionCount()) ?? 0)
        } else {
            fresh = fallback
        }
        guard let fresh else { return }
        snapshotBox.value = fresh
        await hooks.inboxChanged(fresh)
    }

    // MARK: Helpers

    /// Legacy route keys (`threadId`, `runId`…) for the push map, from the
    /// first row that has a thread (or activity) source.
    static func legacyRouteKeys(_ records: [TitioNoticeRecord]) -> [String: String] {
        guard let record = records.first(where: { $0.source.threadId != nil || $0.source.activityItemId != nil }) ?? records.first else {
            return [:]
        }
        var keys: [String: String] = [:]
        if records.count == 1 {
            keys["threadId"] = record.source.threadId
            keys["runId"] = record.source.runId
            keys["finalMessageId"] = record.source.finalMessageId
        }
        keys["workspaceId"] = record.source.workspaceId
        keys["activityItemId"] = record.source.activityItemId
        if records.count > 1 {
            keys["outcome"] = "completed"
        } else {
            switch record.kind {
            case .runCompleted, .botReply, .gitCompleted, .scriptCompleted, .transferCompleted: keys["outcome"] = "completed"
            case .approval, .userInput, .manualAction, .botQuestion, .fileConflict: keys["outcome"] = "attention"
            case .external, .notificationsDenied: break
            default: keys["outcome"] = "failed"
            }
        }
        return keys.compactMapValues { $0 }
    }

    /// The route a navigation option opens, in the push userInfo shape.
    static func navigationRoute(for action: TitioNoticeAction, record: TitioNoticeRecord, binding: TitioNoticePushBinding) -> [String: String] {
        var route: [String: String] = [:]
        switch action {
        case .openThread:
            route["threadId"] = record.source.threadId
            route["workspaceId"] = record.source.workspaceId
            route["finalMessageId"] = record.source.finalMessageId
        case .openBot:
            // The push-route shape iOS resolves (§1): a bot route needs the
            // profile, host and an attention item id, and opening it must
            // change no state. The Mac reads only botId + conversationId.
            route["botId"] = record.source.botId
            route["conversationId"] = record.source.conversationId
            route["profileId"] = binding.profileID
            route["hostId"] = binding.hostID
            route["attentionItemId"] = record.source.attentionItemId
                ?? record.source.conversationId.map { "bot.conversation.\($0)" }
            route["acknowledgeBotOnOpen"] = "false"
            route["threadId"] = record.source.threadId
        case .openActivity:
            if let item = record.source.activityItemId {
                route["activityItemId"] = item
            } else if let run = record.source.runId {
                route["activityItemId"] = "run:\(run.lowercased())"
            } else {
                route["activityDestination"] = "true"
            }
        case .openAllActivity:
            route["activityDestination"] = "true"
        default:
            break
        }
        return route.compactMapValues { $0 }
    }

    static func clip(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// A tiny lock-protected value for the center's nonisolated state.
final class TitioNoticeLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Read-modify-write under the lock.
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&stored) }
    }

    /// Sets `newValue` and returns the previous value atomically.
    func exchange(_ newValue: Value) -> Value {
        lock.withLock {
            let previous = stored
            stored = newValue
            return previous
        }
    }
}
