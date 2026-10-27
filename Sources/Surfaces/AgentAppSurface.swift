import Foundation
import AppKit
import CryptoKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import CoreModel
import Persistence
import AgentRuntime
import DesignSystemKit
import os

// QA-MAC_AGENT-010: surface-side lifecycle logging (approvals, queue depth) so
// field issues and flakes are diagnosable beyond transient UI strings.
private let agentSurfaceLog = Logger(subsystem: "io.remotecode.agent", category: "surface")

/// PERF: pure id -> (turnIndex, itemIndex) index for AssistantTimelineState.turns.
///
/// Opening a long thread replays every persisted event through `timeline.apply`;
/// each `itemDelta`/`itemState` resolves its item via `mutateItem`, an O(turns x items)
/// linear scan over the whole timeline (AssistantEvents.swift mutateItem). At the
/// ~5000-event prune cap that is O(events x items) on the main actor.
///
/// This is the pure, isolation-testable structure: build from `turns`, look up an id
/// in O(1), and update on insert as items/turns are appended during replay. It mirrors
/// `mutateItem`'s "first occurrence wins" semantics so a fast-path lookup is byte-for-byte
/// equivalent to the linear scan. `nonisolated`/value-typed so it needs no MainActor.
struct TimelineItemIndex: Sendable, Equatable {
    struct Location: Sendable, Equatable {
        let turnIndex: Int
        let itemIndex: Int
    }

    private var map: [String: Location] = [:]

    /// Build from a timeline's turns. First occurrence of an id wins, matching
    /// `mutateItem`, which returns on its first match.
    init(turns: [AssistantTurnSnapshot]) {
        map.reserveCapacity(turns.reduce(0) { $0 + $1.items.count })
        for ti in turns.indices {
            for ii in turns[ti].items.indices {
                let id = turns[ti].items[ii].id
                if map[id] == nil {
                    map[id] = Location(turnIndex: ti, itemIndex: ii)
                }
            }
        }
    }

    /// O(1) location lookup. Returns nil for an unknown id (e.g. an itemDelta that
    /// arrived before its itemStarted), so the caller can buffer the delta instead
    /// of mutating the wrong item.
    func location(of id: String) -> Location? {
        map[id]
    }

    /// Record a newly appended item. First-occurrence-wins is preserved: an id
    /// already present is not overwritten.
    mutating func insert(id: String, turnIndex: Int, itemIndex: Int) {
        if map[id] == nil {
            map[id] = Location(turnIndex: turnIndex, itemIndex: itemIndex)
        }
    }
}

/// F1: the composer's live text on its OWN ObservableObject. A keystroke publishes
/// to this object (observed by the composer subtree) and NOT to AgentAppViewModel —
/// which owns the transcript (messages/timeline) and whose `body` would otherwise
/// re-evaluate the whole transcript on every keypress on a long thread.
@MainActor
public final class AgentComposerState: ObservableObject {
    @Published public var prompt: String = ""
    /// AA-13: `@Published` fires even when the value is unchanged. The editor
    /// reports the caret from both `textDidChange` and selection changes, so
    /// an identical UTF-16 offset must not republish the composer subtree.
    public var cursorOffset: Int? = nil {
        willSet {
            guard newValue != cursorOffset else { return }
            objectWillChange.send()
        }
    }
    /// PF-12: focusing the composer must not republish the 78-field Agent App VM.
    @Published public var focusTick: Int = 0
    /// Bot desks: the message the next send replies to (quote strip above the
    /// composer). Scoped to the thread it was picked in.
    @Published public var replyTarget: AgentReplyTarget?
}

/// The Bot message a composer send answers: its excerpt becomes the quote line
/// (`AgentReplyQuote`) of the sent text.
public struct AgentReplyTarget: Equatable, Sendable {
    public let threadId: AgentThreadID
    public let excerpt: String
    public let noticeMessageID: String?
    public let peerHandle: String?
    public let peerBotID: BotID?

    public init(threadId: AgentThreadID, excerpt: String, noticeMessageID: String? = nil, peerHandle: String? = nil, peerBotID: BotID? = nil) {
        self.threadId = threadId
        self.excerpt = excerpt
        self.noticeMessageID = noticeMessageID
        self.peerHandle = peerHandle
        self.peerBotID = peerBotID
    }

    public var displayExcerpt: String {
        peerHandle.map { "\(BotPeerTranscript.handleLabel($0)): \(excerpt)" } ?? excerpt
    }

    public func compose(text: String, bots: [BotDefinition] = []) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentHandle = peerBotID.flatMap { id in bots.first { $0.id == id }?.handle }
        let addressed = currentHandle.map { "\(BotPeerTranscript.handleLabel($0)) \(body)" } ?? body
        return AgentReplyQuote.compose(excerpt: displayExcerpt, text: addressed)
    }
}

/// Stream/transcript paint state on its OWN ObservableObject so token/tool storms
/// re-render the conversation column without republishing chrome, rail, or composer
/// fields on the parent `AgentAppViewModel`.
/// Coalesced scroll/collapse pulse (~30 Hz). Kept off `AgentTranscriptState`
/// so tick publishes do not rebuild the conversation column — content already
/// published when `messages` / `timeline` were assigned.
@MainActor
public final class AgentTranscriptPaintTick: ObservableObject {
    @Published public var timelineUpdateTick: Int = 0
}

@MainActor
public final class AgentTranscriptState: ObservableObject {
    @Published public var messages: [AgentMessage] = [] {
        didSet {
            if oldValue != messages {
                contentGeneration &+= 1
                messagesGeneration &+= 1
            }
            waitingBotPeerActivity = Self.hasWaitingBotPeerActivity(
                in: messages,
                threadId: selectedThreadIdForPeerFlag
            )
        }
    }
    /// AA-16: chrome busy must not walk `messages` on every tab poll.
    var waitingBotPeerActivity = false
    var selectedThreadIdForPeerFlag: AgentThreadID?

    nonisolated static func hasWaitingBotPeerActivity(
        in messages: [AgentMessage],
        threadId: AgentThreadID?
    ) -> Bool {
        guard let threadId else { return false }
        return messages.contains {
            $0.threadId == threadId
                && $0.role == .assistant
                && BotPeerTranscript.parseActivity($0.content)?.phase == .waiting
        }
    }
    @Published public var timeline = AssistantTimelineState() {
        didSet {
            if !Self.hideSetRelevantTimelineEquals(oldValue, timeline) {
                contentGeneration &+= 1
            }
        }
    }
    public let paintTick = AgentTranscriptPaintTick()
    public var timelineUpdateTick: Int {
        get { paintTick.timelineUpdateTick }
        set { paintTick.timelineUpdateTick = newValue }
    }
    /// Bumped when messages change or hide-set-relevant timeline fields change
    /// (assistant bodies / finals / work presence). Tool-body-only stream
    /// assigns still publish `timeline` for paint, but must not rehash hide-set.
    public private(set) var contentGeneration: UInt64 = 0
    /// AA-31: bumped only when `messages` actually changed, so per-message
    /// content digests can be reused across the (far more frequent) timeline
    /// content generations.
    public private(set) var messagesGeneration: UInt64 = 0

    /// Hide-set depends on persisted assistant text, live assistant item
    /// bodies, finals, and whether a turn has any work item. Growing a tool
    /// / reasoning body does not change those inputs — walking every
    /// assistant body to rebuild `hiddenPersistedAssistantContentKey` on
    /// each ~30 Hz tool delta is wasted.
    #if DEBUG
    /// How many historical turns took the item-walk path. Live stream apply
    /// CoW-copies only the active turn's `items`; walking every prior
    /// assistant body on each ~30 Hz tool delta is wasted.
    nonisolated(unsafe) static var hideSetHistoricalTurnWalksForTesting: UInt64 = 0
    #endif

    nonisolated static func hideSetRelevantTimelineEquals(
        _ lhs: AssistantTimelineState,
        _ rhs: AssistantTimelineState
    ) -> Bool {
        let left = lhs.turns
        let right = rhs.turns
        guard left.count == right.count else { return false }
        if left.isEmpty { return true }
        let last = left.count - 1
        // Live stream ticks mutate the last turn. Compare it fully, then
        // skip historical item walks when `items` still share storage.
        if !hideSetRelevantTurnEquals(left[last], right[last]) { return false }
        for index in 0..<last {
            if !hideSetRelevantHistoricalTurnEquals(left[index], right[index]) {
                return false
            }
        }
        return true
    }

    /// Historical turns are unchanged on a typical itemDelta (CoW shares
    /// their `items`). Fall back to the full item walk when storage diverges
    /// (budget eviction, a delta targeting an older item).
    nonisolated static func hideSetRelevantHistoricalTurnEquals(
        _ lhs: AssistantTurnSnapshot,
        _ rhs: AssistantTurnSnapshot
    ) -> Bool {
        guard lhs.turnId == rhs.turnId,
              lhs.finished == rhs.finished,
              lhs.finalAssistantMessage == rhs.finalAssistantMessage else {
            return false
        }
        if itemsShareStorage(lhs.items, rhs.items) { return true }
        #if DEBUG
        hideSetHistoricalTurnWalksForTesting &+= 1
        #endif
        return hideSetRelevantTurnEquals(lhs, rhs)
    }

    nonisolated static func itemsShareStorage(
        _ lhs: [AssistantItem],
        _ rhs: [AssistantItem]
    ) -> Bool {
        if lhs.isEmpty && rhs.isEmpty { return true }
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        return lhs.withUnsafeBufferPointer { leftBuf in
            rhs.withUnsafeBufferPointer { rightBuf in
                leftBuf.baseAddress == rightBuf.baseAddress
            }
        }
    }

    nonisolated static func hideSetRelevantTurnEquals(
        _ lhs: AssistantTurnSnapshot,
        _ rhs: AssistantTurnSnapshot
    ) -> Bool {
        guard lhs.turnId == rhs.turnId,
              lhs.finished == rhs.finished,
              lhs.finalAssistantMessage == rhs.finalAssistantMessage else {
            return false
        }
        var leftIndex = 0
        var rightIndex = 0
        var leftHasWork = false
        var rightHasWork = false
        while leftIndex < lhs.items.count || rightIndex < rhs.items.count {
            while leftIndex < lhs.items.count,
                  lhs.items[leftIndex].type != .assistantMessage {
                leftHasWork = true
                leftIndex += 1
            }
            while rightIndex < rhs.items.count,
                  rhs.items[rightIndex].type != .assistantMessage {
                rightHasWork = true
                rightIndex += 1
            }
            if leftIndex == lhs.items.count && rightIndex == rhs.items.count { break }
            if leftIndex == lhs.items.count || rightIndex == rhs.items.count { return false }
            // AA-26: the streaming body is compared against its own prefix on
            // every delta; `utf8.count` mismatch is O(1) and the common case, so
            // check it before the O(n) string equality.
            if lhs.items[leftIndex].id != rhs.items[rightIndex].id
                || lhs.items[leftIndex].body.utf8.count != rhs.items[rightIndex].body.utf8.count
                || lhs.items[leftIndex].body != rhs.items[rightIndex].body {
                return false
            }
            leftIndex += 1
            rightIndex += 1
        }
        return leftHasWork == rightHasWork
    }
}

/// F1: scopes @ObservedObject observation to the composer subtree. A change to the
/// composer text re-renders only this wrapper (and the `composer` it rebuilds),
/// WITHOUT invalidating the enclosing AgentAppView body that owns the transcript.
/// View-model-driven changes still reach the composer because AgentAppView re-creates
/// this wrapper (with a fresh `content`) whenever the view model publishes.
/// Owns the Now strip model for one mounted surface: starts on appear, stops on disappear.
private struct AgentNowStripHost: View {
    @StateObject private var model: AgentNowStripModel

    init(source: AgentNowStripSource, cached: AgentNowStripSnapshot?) {
        _model = StateObject(wrappedValue: AgentNowStripModel(source: source, cached: cached))
    }

    var body: some View {
        AgentNowStrip(model: model)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}

private struct ComposerReactiveScope<Content: View>: View {
    @ObservedObject var composerState: AgentComposerState
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}

/// Isolates stream/transcript invalidation to the conversation column so status
/// chrome and the thread rail do not rebuild on every token tick.
private struct TranscriptReactiveScope<Content: View>: View {
    @ObservedObject var transcriptState: AgentTranscriptState
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}

/// Observes only the coalesced paint tick so scroll/collapse can run at ~30 Hz
/// without `TranscriptReactiveScope` rebuilding the transcript.
private struct TranscriptPaintTickScope: View {
    @ObservedObject var paintTick: AgentTranscriptPaintTick
    let onTick: () -> Void
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: paintTick.timelineUpdateTick) { _ in
                onTick()
            }
    }
}

/// Thread mutations performed by the macOS UI itself (create/rename/pin/color/
/// reorder/delete/auto-title). Surfaces must stay free of SocketServer imports,
/// so the VM reports these through a dependency-free callback and the host
/// (AppCommandRouter) publishes the matching mirror events. Without this, only
/// RPC-driven mutations reached connected mirrors and mac-side thread CRUD was
/// invisible on iOS until a full thread-list refetch.
public enum AgentThreadLifecycleEvent {
    case created(AgentThread)
    case updated(AgentThread)
    case reordered(WorkspaceID, [AgentThreadID])
    case deleted([AgentThreadID])
}

/// One committed narrow `agent_threads` chrome write (status, unread or the
/// provider cursor, plus `updated_at`) that publishes no `agent.*` state
/// event of its own. The host mirrors it as one partial `agent.thread.updated`
/// so connected clients and the `agentThreads` snapshot revision see the
/// commit. A nil field means the write left that column alone.
public struct AgentThreadChromeWrite: Equatable, Sendable {
    public var threadID: AgentThreadID
    public var status: AgentRunStatus?
    public var hasUnread: Bool?
    public var providerThreadID: String?
    public var updatedAt: Date

    public init(
        threadID: AgentThreadID,
        status: AgentRunStatus? = nil,
        hasUnread: Bool? = nil,
        providerThreadID: String? = nil,
        updatedAt: Date
    ) {
        self.threadID = threadID
        self.status = status
        self.hasUnread = hasUnread
        self.providerThreadID = providerThreadID
        self.updatedAt = updatedAt
    }

    /// Folds a later write to the same thread into this one, so a loop that
    /// commits several writes can publish once with the final row values.
    public mutating func merge(_ later: AgentThreadChromeWrite) {
        status = later.status ?? status
        hasUnread = later.hasUnread ?? hasUnread
        providerThreadID = later.providerThreadID ?? providerThreadID
        updatedAt = later.updatedAt
    }
}

public enum AgentErrorRecoveryAction: String, Sendable, Equatable {
    case signIn
    case retry
    case startFresh

    public var title: String {
        switch self {
        case .signIn: return "Sign in"
        case .retry: return "Retry"
        case .startFresh: return "Start fresh"
        }
    }

    /// `[fresh-session:<reason>]`: the adapter already retired the provider
    /// session whose history the model rejected (`DistillACPFailureTaxonomy`).
    public static let freshSessionMarkerPrefix = "[fresh-session:"

    private static let freshSessionMarkerRegex = try! NSRegularExpression(
        pattern: "\\[fresh-session:[^\\]]*\\]\\s*",
        options: [.caseInsensitive]
    )

    /// Case-insensitive, like the classifier (which lowercases the message).
    public static func hasFreshSessionMarker(_ message: String) -> Bool {
        message.range(of: freshSessionMarkerPrefix, options: .caseInsensitive) != nil
    }

    /// Error text for people: the fresh-session marker is a machine tag, so it
    /// is removed. Classify on the raw message, never on this text.
    public static func displayText(_ message: String) -> String {
        guard hasFreshSessionMarker(message) else { return message }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        return freshSessionMarkerRegex.stringByReplacingMatches(
            in: message, options: [], range: range, withTemplate: ""
        )
    }

    /// Paired-client `recovery_action` for a failed run, from the same
    /// classifier the Mac error row uses. `new_session` is the classifier's
    /// Retry for a fresh-session failure: retry on the SAME thread (a bot desk
    /// keeps its conversation link); the host already started a new provider
    /// session, so the retry does not reuse the rejected history.
    public static func pairedWireValue(message: String, recoverable: Bool) -> String? {
        guard let action = AgentAppViewModel.errorRecoveryAction(message: message, recoverable: recoverable) else {
            return nil
        }
        switch action {
        case .signIn: return "sign_in"
        case .startFresh: return "start_fresh"
        case .retry: return hasFreshSessionMarker(message) ? "new_session" : "retry"
        }
    }
}

private struct BotRunUnavailableError: LocalizedError {
    var errorDescription: String? { "Bot unavailable." }
}

/// `AgentAppViewModel.lockThreadToBot` found the thread's actor already
/// locked (another device or window locked it first). Nothing was written.
public struct ThreadActorAlreadyLockedError: LocalizedError {
    public var errorDescription: String? {
        "This conversation is already assigned to another actor. Review the actor and try sending again."
    }
}

/// Opt-in hooks for hosting one fixed thread (e.g. the bot desk) in Agent App.
public struct AgentAppEmbedding {
    public let pinnedThreadId: AgentThreadID
    public let executionCwd: String?
    public let promptTransform: (@MainActor (_ text: String, _ threadId: AgentThreadID, _ runId: AgentRunID) async throws -> String)?
    public let onRunStarted: (@MainActor (AgentRunID, AgentThreadID) -> Void)?
    public let onRunFinished: (@MainActor (AgentRunID, AgentThreadID, AgentRunStatus, String?) -> Void)?
    /// Takes every composer send before any provider work (a bot group room
    /// never runs a provider). Returns the rows it wrote to the pinned thread,
    /// painted at once; a thrown error keeps the prompt and shows its text.
    public let sendInterceptor: AgentAppSendInterceptor?
    /// Composer placeholder for an intercepted surface (it names no provider).
    public let composerPlaceholder: String?
    /// Empty-conversation copy for the host surface (a bot desk or group room
    /// does not "start a new agent run"). Nil keeps the Agent App copy.
    public let emptyConversationTitle: String?
    public let emptyConversationSubtitle: String?
    /// The pinned thread's row when the host read it on this same turn, so
    /// the first paint does not read it again. Later reloads read the store.
    public let pinnedThread: AgentThread?
    /// False for a host that mounts the conversation without a composer: it must never
    /// write the thread's draft, or closing it would replace what the real chat holds.
    public let ownsComposerDraft: Bool
    /// Titio's inbox only: a tap on a card whose choices carry a `notice` key
    /// goes to the host's notice ledger by (message id, option index) instead
    /// of being sent as text (hub spec §7). Nil: every card sends its text.
    public let noticeChoiceHandler: (@MainActor (_ messageID: String, _ optionIndex: Int) -> Void)?
    /// Titio's inbox only: checked in `send()` right after `sendInterceptor`.
    /// True means the host took the text (an armed "Reply here"): the prompt
    /// clears and no run starts.
    public let hostReplyHandler: (@MainActor (_ text: String, _ threadId: AgentThreadID) throws -> Bool)?
    /// Titio's inbox only: the trailing clear button on an assistant message.
    /// The host removes it (`bot.notice.clear` semantics); false means it did
    /// not, and the row comes back.
    public let noticeClearHandler: (@MainActor (_ messageID: AgentMessageID) async -> Bool)?
    /// Titio's inbox only: the "Now" strip above the composer. Nil hides it.
    public let nowStrip: AgentNowStripSource?
    /// Last strip snapshot the host saw, painted before the first load.
    public let nowStripCached: AgentNowStripSnapshot?

    public init(
        pinnedThreadId: AgentThreadID,
        executionCwd: String? = nil,
        promptTransform: (@MainActor (_ text: String, _ threadId: AgentThreadID, _ runId: AgentRunID) async throws -> String)? = nil,
        onRunStarted: (@MainActor (AgentRunID, AgentThreadID) -> Void)? = nil,
        onRunFinished: (@MainActor (AgentRunID, AgentThreadID, AgentRunStatus, String?) -> Void)? = nil,
        sendInterceptor: AgentAppSendInterceptor? = nil,
        composerPlaceholder: String? = nil,
        emptyConversationTitle: String? = nil,
        emptyConversationSubtitle: String? = nil,
        pinnedThread: AgentThread? = nil,
        ownsComposerDraft: Bool = true,
        noticeChoiceHandler: (@MainActor (_ messageID: String, _ optionIndex: Int) -> Void)? = nil,
        hostReplyHandler: (@MainActor (_ text: String, _ threadId: AgentThreadID) throws -> Bool)? = nil,
        noticeClearHandler: (@MainActor (_ messageID: AgentMessageID) async -> Bool)? = nil,
        nowStrip: AgentNowStripSource? = nil,
        nowStripCached: AgentNowStripSnapshot? = nil
    ) {
        self.ownsComposerDraft = ownsComposerDraft
        self.noticeClearHandler = noticeClearHandler
        self.nowStrip = nowStrip
        self.nowStripCached = nowStripCached
        self.noticeChoiceHandler = noticeChoiceHandler
        self.hostReplyHandler = hostReplyHandler
        self.pinnedThreadId = pinnedThreadId
        self.executionCwd = executionCwd
        self.promptTransform = promptTransform
        self.onRunStarted = onRunStarted
        self.onRunFinished = onRunFinished
        self.sendInterceptor = sendInterceptor
        self.composerPlaceholder = composerPlaceholder
        self.emptyConversationTitle = emptyConversationTitle
        self.emptyConversationSubtitle = emptyConversationSubtitle
        self.pinnedThread = pinnedThread?.id == pinnedThreadId ? pinnedThread : nil
    }
}

/// First message page of the open thread. `pending` and `failed` both keep
/// the "No messages" placeholder off: a thread whose page has not been read,
/// or could not be read, is not an empty thread.
public enum AgentMessagePageLoadState: Equatable, Sendable {
    case idle
    case pending
    case failed(message: String)
}

public typealias AgentAppSendInterceptor = @MainActor (
    _ text: String,
    _ attachments: [AgentAttachment],
    _ threadId: AgentThreadID
) throws -> [AgentMessage]

@MainActor
public final class AgentAppViewModel: ObservableObject, AgentRunObserver {
    public let embedding: AgentAppEmbedding?
    /// A Bot desk with Verbosity Human shows only the Bot's messages: no tool,
    /// command, edit or work-log rows. The live turn keeps a "Working" line.
    @Published public var hidesToolActivity = false
    @Published public var threads: [AgentThread] = [] { didSet { filteredThreadsCache = nil } }
    @Published public var selectedThreadId: AgentThreadID?
    /// Distill `/loop` tasks of the selected thread; AppShell mirrors them from the loop store.
    @Published public var distillLoops: [DistillLoopState] = []
    public var stopDistillLoop: ((String) async throws -> Void)?
    public var dismissDistillLoop: ((String) -> Void)?
    public var resumeDistillLoop: ((String) async throws -> Void)?
    public var distillLoopSubscription: AnyCancellable?
    /// True when the selected thread is an ephemeral side chat (hidden from the
    /// rail, so the row is not available through `threads`).
    @Published public private(set) var selectedThreadIsEphemeral = false
    /// Parent thread of the selected side chat, for the parent status strip.
    @Published public private(set) var selectedThreadParentId: AgentThreadID?
    /// Transcript paint lives on `transcriptState` so stream ticks do not
    /// republish chrome/rail fields on this object. Proxies keep `vm.messages` /
    /// `vm.timeline` call sites (tests + host) working unchanged.
    public let transcriptState = AgentTranscriptState()
    public var messages: [AgentMessage] {
        get { transcriptState.messages }
        set {
            transcriptState.selectedThreadIdForPeerFlag = selectedThreadId
            transcriptState.messages = newValue
        }
    }
    public var timeline: AssistantTimelineState {
        get { transcriptState.timeline }
        set {
            transcriptState.timeline = newValue
            publishedTimelineWriteRevision &+= 1
        }
    }
    /// S-F4c: bumped by every write to `timeline`, so a cold restore that lands
    /// after a reveal can tell whether anything wrote the stand-in meanwhile.
    private var publishedTimelineWriteRevision: UInt64 = 0
    public var timelineUpdateTick: Int {
        get { transcriptState.timelineUpdateTick }
        set { transcriptState.timelineUpdateTick = newValue }
    }
    @Published public var userInputSelections: [String: Set<String>] = [:]
    @Published public var userInputDrafts: [String: String] = [:]
    public var focusTick: Int {
        get { composerState.focusTick }
        set { composerState.focusTick = newValue }
    }
    /// Number of older transcript items explicitly revealed by the reader.
    /// Reset only on conversation changes; sending preserves the reading context.
    @Published public var transcriptHistoryRevealCount: Int = 0
    @Published public var transcriptReadingStartID: String?
    /// F1: composer text lives on `composerState` so keystrokes don't republish the
    /// transcript-bearing view model. This proxy keeps every existing `vm.prompt`
    /// read/write working unchanged; because it is a computed (non-@Published)
    /// property, mutating it fires `composerState.objectWillChange`, NOT this VM's.
    public let composerState = AgentComposerState()
    public var prompt: String {
        get { composerState.prompt }
        set { composerState.prompt = newValue }
    }
    // UX-XPLAT-009: UTF-16 cursor offset reported by AgentComposerTextEditor so
    // suggestions anchor at the actual insertion point, not text.endIndex.
    // nil means "not yet reported by the editor" -- suggestions fall back to
    // the endIndex anchor so programmatic prompt mutations (tests, /clear) work.
    // Keep the public proxy so existing vm.composerCursorOffset call sites stay
    // unchanged while cursor updates publish only through composerState.
    // Equality is enforced on `AgentComposerState.cursorOffset` (AA-13).
    public var composerCursorOffset: Int? {
        get { composerState.cursorOffset }
        set { composerState.cursorOffset = newValue }
    }
    @Published public var provider: AgentProvider = .defaultProvider
    /// Live Distill compaction/model/subagent state for the selected thread's run.
    @Published public private(set) var distillLive: DistillLiveStatus?
    /// Commands Distill advertised via `available_commands_update` (kept across threads).
    @Published public private(set) var distillSlashCommands: [DistillLiveStatus.AdvertisedCommand] = []
    @Published public var providerInstanceId: String = AgentProvider.defaultProvider.rawValue
    /// macOS account that will execute the next provider process through the shared helper.
    /// Nil / current-account means no privileged trampoline.
    @Published public var runAsUser: AgentRunAsUser? = AgentRunAsUser.current()
    /// Bot (or none) that runs the selected thread; mirrors the thread row once selected.
    @Published public private(set) var selectedRunActor: RunActor = .none
    /// Where a bot-run thread executes by default; wired by the host from the bot's revision.
    public var botExecutionTargetProvider: (BotID) -> ExecutionTarget = { _ in .mac }
    /// False when the bot was deleted or no longer exists; wired by the host from the bot store.
    public var botIsAvailable: (BotID) -> Bool = { _ in true }
    /// Display name used in refusal messages; nil when unknown.
    public var botNameProvider: (BotID) -> String? = { _ in nil }
    /// Embedded desk only: opens the hand-off thread in the source thread's workspace
    /// (the desk's synthetic workspace cannot hold it). Nil hides "Continue without bot".
    public var handoffHost: ((AgentThreadID, RunActor) -> Void)?
    /// A hand-off needs a host when this VM is an embedded desk.
    public var canContinueWithoutBot: Bool { embedding == nil || handoffHost != nil }
    /// Links the workspace thread to a bot conversation (single thread, no copy) on the first bot send.
    public var botThreadLinker: (@MainActor (BotID, AgentThreadID) throws -> Void)?
    /// Compiles the bot brain into the provider prompt for a bot-run workspace thread.
    public var botPromptTransform: (@MainActor (BotID, String, AgentThreadID, AgentRunID) async throws -> String)?
    public var botRunStarted: (@MainActor (BotID, AgentRunID, AgentThreadID) -> Void)?
    /// Non-nil when another thread already holds the bot's VM.
    public var botBusyMessage: ((BotID, AgentThreadID) -> String?)?
    /// Registers a thread queued behind another thread's run on the bot's VM.
    public var botWaitForVM: ((BotID, AgentThreadID) -> Void)?
    /// Claims the bot's VM for a run about to start; returns the other thread's
    /// run when it holds the VM (nothing claimed then).
    public var botClaimVM: ((BotID, BotVMRunRegistry.Entry) -> BotVMRunRegistry.Entry?)?
    /// Frees a VM claim whose run never started.
    public var botReleaseVM: ((AgentRunID) -> Void)?
    /// Set when the last start was refused because another thread holds the bot's VM;
    /// `threadId` is the thread that start was for.
    private var botVMClaimRefusal: (botID: BotID, notice: String, threadId: AgentThreadID)?
    /// Pending Mac-execution approvals pushed by the host, per thread (reason text).
    @Published public var pendingMacExecutionByThread: [AgentThreadID: String] = [:]
    /// Approves or declines a pending Mac-execution request; wired by the host.
    public var botMacExecutionResolver: (@MainActor (AgentThreadID, Bool) async -> Void)?
    /// Returns a user-facing error when the bot VM cannot run; nil when ready. Wired by the host.
    /// The workspace is nil for a workspace-less (Bots Desk) thread: the VM only has to be up.
    public var botVMPreflight: ((BotID, String?, AgentThreadID?) async -> String?)?
    /// Starts (provisions) the bot VM; returns a user-facing error or nil. Wired by the host.
    public var botVMProvision: ((BotID) async -> String?)?
    /// Set when the VM preflight failed; drives the "VM unavailable" banner.
    @Published public var vmUnavailableBotID: BotID?
    @Published public var availableRunAsUsers: [AgentRunAsUser] = MacOSLocalUserCatalog.listEligibleUsers()
    @Published public var model: String = AgentDefaultModelSelection.builtInDefault(for: .defaultProvider)
    /// Last model the user chose per provider (new threads + provider switches).
    /// Inject a suite-backed store in tests; production uses the shared defaults.
    public var lastModelStore: AgentLastModelStore = .shared
    public let newThreadDefaultsStore: AgentNewThreadDefaultsStore?
    /// When true, unlocked snapshot refresh must not auto-rebind away from the
    /// user's explicit Source choice (including an unrunnable row for recovery).
    /// Implicit default selection stays unpinned so missing Codex can rebind.
    public var sourceSelectionUserPinned: Bool = false
    @Published public var availableModels: [AgentModelDescriptor] = []
    @Published public var providerSnapshots: [AgentProviderSnapshot] = []
    @Published public var permissionMode: AgentPermissionMode = .fullAccess
    @Published public var reasoningEffort: AgentReasoningEffort = .medium
    @Published public var reasoningModel: String?
    @Published public var distillMainEffortSelection: AgentEffortSelection = .automatic
    @Published public var distillReasoningEffortSelection: AgentEffortSelection = .automatic
    @Published public var distillExecutionMode: DistillExecutionMode = .auto
    @Published public var showingAutoRoutingSetup = false
    @Published public var serviceTier: AgentServiceTier = .auto
    @Published public private(set) var routingMode: AgentRoutingMode = .manual
    @Published public var executionMode: AgentExecutionMode = .local
    @Published public var baseBranch: String = ""
    @Published public var worktreePath: String?
    @Published public private(set) var customModelsByProvider: [AgentProvider: [String]] = [:]
    @Published public var status: AgentRunStatus = .pending
    @Published public var statusMessage: String = ""
    private static let deletedThreadDraftRecoveryMessage =
        "Thread removed; your unsent draft was kept in a fresh composer."
    /// Informational replay state is separate from statusMessage so a bounded
    /// history window cannot be presented as a provider/persistence error.
    @Published public private(set) var historyReplayNotice: String?
    public static let historyReplayNoticeText = "Showing the recent Agent history window. Earlier transcript events remain outside the hot replay budget."

    /// Never surface the hot-replay window as a user-visible banner.
    /// Partial history still loads; only the notice copy is suppressed.
    public static func replayNoticeText(isPartial: Bool) -> String? {
        _ = isPartial
        return nil
    }
    /// CLAUDE-BG-LIFECYCLE: how many CLI-owned background shells / async
    /// subagents the provider last reported as still running, from the
    /// `claude.session.snapshot` runtime event. Mirrors the Claude CLI's own
    /// `1 shell` status-line indicator, which the app previously had no
    /// equivalent of — the pending set never left the adapter. Reset on thread
    /// switch; read through `backgroundShellCount`, which also gates on a live
    /// run so a finished run cannot leave a stale count on screen.
    @Published public private(set) var liveBackgroundShellCount: Int = 0
    /// Named CLI background tasks (type + description) for the Stop strip.
    /// Gated through `visibleBackgroundTasks` so a finished run cannot keep
    /// advertising work the adapter already dropped.
    @Published public private(set) var liveBackgroundTasks: [AgentBackgroundTask] = []
    var manualActionObserver: NSObjectProtocol?
    var manualActionStateObserver: NSObjectProtocol?
    /// Durable manual-action requests; wired by the host. Setting it loads the selected thread's card.
    public var manualActionStore: ManualActionRequestStore? {
        didSet { manualActionStoreDidChange() }
    }
    /// Who drives the bot computer; tests inject an isolated instance.
    public var botComputerControl: BotComputerControl = .shared
    public var openBotScreen: ((BotID) -> Void)?
    /// Copies Mac files into the bot's VM home (~/Downloads); returns guest paths. Wired by the host.
    public var importFilesToBotComputer: ((BotID, AgentThreadID?, [URL]) throws -> [String])?
    @Published public internal(set) var botScreenControlled = false
    /// Request awaiting the user on the selected thread (open or taken).
    @Published public internal(set) var openManualAction: ManualActionRequest?
    /// Continued/declined requests of the selected thread, oldest first.
    @Published public internal(set) var resolvedManualActions: [ManualActionRequest] = []
    @Published public var currentRunId: AgentRunID?
    @Published public var hasUnreadActivity: Bool = false
    /// Provider-neutral Subagents activity derived from admission receipts +
    /// coordinator active runs. Empty until the first refresh; never invents rows.
    @Published public private(set) var subagentActivity: SubagentActivitySnapshot = .empty
    @Published public var interactionMode: AgentInteractionMode = .default
    @Published public var planNotes: String = ""
    /// C1: git branch + working-tree summary of the agent's dir, for the
    /// composer context strip ("N files changed +A −B").
    @Published public var gitBranch: String?
    @Published public var gitSummary: GitSummary?
    /// Wired by AppCommandRouter — "Review here" opens a Git/Diff surface.
    public var onReviewRequested: (() -> Void)?
    /// A3: fired when a run starts/ends so the tab + workspace chrome can
    /// show/hide a spinner (AppKit tab strip / sidebar don't observe VM).
    public var onRunStateChange: (() -> Void)?
    /// Fired when a run completes so the workspace can move up in its
    /// pinned/unpinned group.
    public var onRunCompleted: (() -> Void)?
    /// Fired when local Agent App controls persist thread run config so
    /// remote mirrors can receive the same thread metadata.
    public var onThreadConfigPersisted: ((AgentThread) -> Void)?
    /// Fired after macOS-UI thread lifecycle mutations are persisted (post
    /// repo write + reloadThreads) so the host can mirror them to remote
    /// clients. Wired by AppCommandRouter like onThreadConfigPersisted.
    public var onThreadLifecycle: ((AgentThreadLifecycleEvent) -> Void)?
    /// Fired after this VM commits a status/unread-only `agent_threads` write
    /// that no `agent.*` state event covers, so the host can mirror it.
    public var onThreadChromeWritten: ((AgentThreadChromeWrite) -> Void)?
    /// Post-commit process-global retirement for automatic cap victims. The
    /// boolean is true only when AgentRunCoordinator's native fork producer
    /// already retired its coordinator state and the host only needs queue state.
    public var retireDeletedThreadRuntime: (([AgentThreadID], Bool) -> Void)?
    /// When non-nil, Stop for LaunchAgent-owned scheduled runs is routed here
    /// (path B). Return true if the request was accepted / already terminal.
    public var stopScheduledThread: ((AgentThreadID, AgentRunID?) async -> Bool)?
    /// True when a thread has an active scheduled occurrence in SQLite even if
    /// this process's coordinator has no session (LaunchAgent owns the run).
    public var isScheduledThreadRunning: ((AgentThreadID) -> Bool)?
    /// Fired when this surface's bound (selected) thread changes, so the host
    /// can persist it into the surface descriptor metadata (`selected_thread`)
    /// for per-surface restore. nil means the surface returned to the
    /// fresh-composer state (e.g. its bound thread was deleted elsewhere).
    /// This is the per-surface binding that fixes the new-tab-clone bug:
    /// selection is owned by the surface, not auto-adopted from the workspace.
    public var onSelectedThreadChanged: ((AgentThreadID?) -> Void)?
    /// Fired only after a macOS TextEditor save is durable, so AppCommandRouter
    /// can publish the same realtime event as the mirror-driven RPC path.
    public var onPlanNotesPersisted: ((AgentThreadID, String) -> Void)?
    /// Canonical host mutation used when local selection acknowledges unread work.
    public var markThreadRead: ((AgentThreadID) throws -> Void)?
    public var onQueuedMessageEvent: ((String, AgentQueuedMessage) -> Void)?
    /// Canonical host queue mutation. Local Force must cross the same acceptance
    /// permit and durable dispatch state machine as RPC/iOS Force.
    public var forceQueuedMessage: ((AgentQueuedMessageID) async throws -> AgentMessageSendResult)?
    /// Host lifecycle gate used while destructive thread deletion awaits provider
    /// termination. AppContext owns queue draining, so the surface requests the
    /// same suppression used by mirror-driven deletion.
    public var acquireQueueDrainSuppression: ((AgentThreadID) async -> UUID)?
    public var acquireQueueDrainSuppressions: (([AgentThreadID]) async -> [(AgentThreadID, UUID)])?
    public var releaseQueueDrainSuppression: ((AgentThreadID, UUID) -> Void)?
    /// Process-local bot handoff fence spanning provider stop and relational delete.
    /// The host commits the exact retirement only after the source delete succeeds.
    public var beginBotPeerHandoffDeletion: ((Set<AgentThreadID>) -> UUID)?
    public var finishBotPeerHandoffDeletion: ((UUID, Bool) -> Void)?
    /// UX-MAC_AGENT-OPEN-SPLIT: wired by AppCommandRouter. A clicked file mention
    /// (absolute path, already resolved) opens — or reuses — a Files split panel
    /// to the right of this surface.
    public var onOpenFileInSplit: ((String) -> Void)?
    /// UX-MAC_AGENT-OPEN-SPLIT: wired by AppCommandRouter. A clicked web link
    /// opens — or reuses — a Browser split panel to the right of this surface.
    public var onOpenURLInSplit: ((URL) -> Void)?
    /// Wired by AppCommandRouter. Branches the selected thread into a new
    /// persisted child chat (optionally from a message id) and selects it.
    public var onForkInNewChat: ((String?) -> Void)?
    /// Bot desks: assistant messages offer Reply (quote + "Reply…" composer).
    public var supportsReplies = false
    /// Wired by AppCommandRouter. Creates the ephemeral side thread for the
    /// selected thread and opens it in a right split pane. The string is the
    /// optional `/side` inline first message.
    public var onRequestSideChat: ((String) -> Void)?
    /// Wired by AppCommandRouter. Asks the selected thread's live session the
    /// `/btw` side question; the host answers via `appendBtwNote`.
    public var onRequestBtw: ((String) -> Void)?
    public var providerSnapshotLoader: (() async throws -> [AgentProviderSnapshot])?
    public var modelListLoader: ((AgentProvider) async throws -> [AgentModelDescriptor])?
    public var providerLaunchConfig: ((AgentProvider, String?) -> (binary: String?, environment: [String: String]))?
    public var providerRecoveryAction: ((AgentProvider, String?) async throws -> String)?
    /// Opens the provider's interactive login command in a host-owned Terminal.
    /// The VM never executes provider authentication out of process itself.
    public var providerSignInAction: ((AgentProvider) throws -> Void)?
    /// Forces an uncached auth probe after the user completes the interactive
    /// Terminal flow. A normal snapshot load may still contain a short-lived
    /// provider-probe cache and cannot prove that login just completed.
    public var providerAuthenticationRefresher: ((AgentProvider) async -> [AgentProviderSnapshot])?
    public var pullRequestThreadPreparer: ((String, AgentProvider, String, AgentPermissionMode, AgentReasoningEffort, AgentServiceTier, AgentModelSelection?, String?) async throws -> AgentThread)?
    @Published public var providerRecoveryActionRunning = false
    @Published public var providerRecoveryStatusMessage: String?
    @Published private var dismissedProviderStatusSignature: String?
    @Published public private(set) var providerSnapshotsLoading = false
    @Published public var modelListLoading = false
    @Published public var modelListStatusMessage: String?
    /// True when the current Claude model list is the static built-in fallback
    /// (live discovery failed or was not attempted). The picker uses this to
    /// show a "using built-in defaults" hint and offer a manual refresh.
    @Published public var availableModelsAreFallback: Bool = false
    @Published public var providerSnapshotStatusMessage: String?
    private var pendingSignInProvider: AgentProvider?
    private var pendingSignInSnapshotID: String?
    @Published public private(set) var providerThreadSnapshotStatusMessage: String?
    @Published public private(set) var providerThreadSnapshotLastConfirmedAt: Date?
    @Published public var pullRequestURL: String = ""
    @Published public var pullRequestPreparing = false
    @Published public var pullRequestStatusMessage: String?
    @Published public var checkpoints: [AgentTurnCheckpointSummary] = []
    @Published public var selectedCheckpointTurnCount: Int?
    @Published public var selectedCheckpointPath: String?
    @Published public var checkpointStatusMessage: String?
    /// B3: durable, managed attachments attached to the next message.
    @Published public var attachments: [AgentAttachment] = []
    private var attachmentInputError: String?
    /// P1: tracks whether the last submitted message included attachments so
    /// retryLastPrompt can warn the user they will not be re-sent.
    @Published public var lastSentAttachmentCount: Int = 0
    public struct AttachmentRetryConfirmation: Equatable {
        public let prompt: String
        public let retryableAttachments: [AgentAttachment]
        public let unavailableAttachmentNames: [String]
    }
    @Published public private(set) var pendingAttachmentRetryConfirmation: AttachmentRetryConfirmation?
    @Published public var queuedMessages: [AgentQueuedMessage] = []
    @Published public var queueStatusMessage: String?
    private var queueStatusByThread: [AgentThreadID: String] = [:]
    @Published public var editingQueuedMessage: AgentQueuedMessage?
    @Published public var queuedMessageDraft: String = ""
    /// When the active run started — drives the "Working for Xs" line.
    @Published public var runStartedAt: Date?
    /// Thread whose turn is being prepared: transcript load, preflight,
    /// provider spawn — all before a run id
    /// exists to track. Without this the transcript sits silent for seconds
    /// after the user bubble appears, which read as the app having hung.
    /// Drives the "Loading…" line; `workingStatus` takes over the instant the
    /// run is tracked. Thread-scoped so switching tabs mid-prepare cannot show
    /// a sibling thread as loading.
    /// Thread whose turn is being prepared for the *selected* thread UI (Loading…).
    /// Backed by `preparingRunThreads` so multi-thread prep is not a singleton race.
    @Published public private(set) var preparingRunThreadId: AgentThreadID?
    /// S5: all threads currently in surface preparation (preflight).
    /// Stop/Escape must target the selected/owning thread, not a single global slot.
    private var preparingRunThreads: Set<AgentThreadID> = []
    /// S5: generation-owned surface preparation (accept → preflight →
    /// coordinator start). Stop/Escape applies `.stopRequested` so a late
    /// claim cannot call `coordinator.startRun`.
    private var surfacePreparationStates: [AgentThreadID: ProviderPreparationState] = [:]
    /// Generation that currently owns prep for each thread.
    /// A superseded/cancelled prep must not clear a newer generation's marker.
    private var preparingRunGeneration: [AgentThreadID: UInt64] = [:]
    /// Run identity accepted for in-flight surface preparation (Stop abandon cleanup).
    private var preparingRunId: [AgentThreadID: AgentRunID] = [:]
    /// UX-MAC_AGENT-009: true while the last surfaced error is recoverable, so
    /// the transcript can offer a Retry of the last prompt instead of forcing a
    /// retype. Cleared when a run starts or any non-error event arrives.
    @Published public private(set) var lastErrorRecoverable: Bool = false
    /// P2: search/filter query for the thread rail. Empty = show all threads.
    @Published public var threadSearchQuery: String = "" { didSet { if oldValue != threadSearchQuery { filteredThreadsCache = nil } } }
    /// UX-MAC_AGENT-STOP: true between the user clicking Stop and the run
    /// actually reaching a terminal state. Prevents repeated Stop clicks and
    /// shows a "Stopping..." label so the user knows the interrupt was sent.
    @Published public var isStopping: Bool = false
    /// UX-MAC_AGENT-CONTINUE: true when the selected thread was interrupted by
    /// an app relaunch and has a recoverable provider session. Drives the inline
    /// Continue action. Cleared when a run starts or the selected thread changes.
    @Published public private(set) var selectedThreadHasRecoverableContext: Bool = false
    /// The UI holds only a bounded recent message page. Older durable messages
    /// remain in SQLite and are intentionally outside the hot screen-memory set.
    @Published public private(set) var messageHistoryIsPartial = false
    /// Read state of the open thread's first message page. Goes `pending` on a
    /// thread switch and on Retry only: a same-thread reload keeps the current
    /// value so an empty thread's placeholder does not blink.
    @Published public private(set) var messagePageLoadState: AgentMessagePageLoadState = .idle
    /// True while an older-page keyset load is in flight (UI disable / spinner).
    /// Derived from `loadingOlderGeneration != 0` for ownership-safe clears.
    @Published public private(set) var isLoadingOlderMessages = false
    @Published public private(set) var messageScrollTarget: AgentChatTimelineScrollTarget?
    /// How the last `send()` ended. Read by `sendNoticeReply`; reset before each send.
    enum SendOutcome: Equatable { case none, accepted, queued, failed }
    private(set) var lastSendOutcome: SendOutcome = .none
    /// Monotonic owner token for the active older-page load (0 = idle).
    /// Stale Tasks must not clear a newer load's flag (SSHRemoteView pattern).
    private var loadingOlderGeneration: UInt64 = 0
    /// After the user sends a follow-up (including a queued one), ignore
    /// `activePlanUpdated` events from the prior turn so the stale checklist
    /// cannot reappear under the new user bubble. Cleared when the next run
    /// actually starts and may publish a fresh plan.
    private var suppressStaleActivePlanUpdates = false

    public let workspaceID: WorkspaceID
    public let cwd: String
    public let coordinator: AgentRunCoordinator
    public let threadRepo: AgentThreadRepository
    public let messageRepo: AgentMessageRepository
    public let draftRepo: AgentThreadDraftRepository?
    public let attachmentStore: AgentAttachmentStore?
    public let queuedMessageRepo: AgentQueuedMessageRepository?
    public let providerSessionRepo: ProviderSessionRuntimeRepository?
    public let pendingCallbackRepo: ProviderPendingCallbackRepository?
    // PERF: rehydratePendingCallbacks allocated JSONDecoder on every thread
    // switch / timeline rehydrate. MainActor VM — share one decoder (codecs are
    // not thread-safe; isolation keeps access serial).
    private let pendingCallbackDecoder = JSONDecoder()
    public let proposedPlanRepo: AgentProposedPlanRepository?
    public let checkpointRepo: AgentTurnCheckpointRepository?
    public let promptHistoryStore: PromptHistoryStore?
    public let customModelStore: AgentCustomModelStore?
    public let planNotesStore: PlanNotesStore?
    private let orchestrationRuntime: AgentOrchestrationRuntime
    private var subagentRefreshGeneration: UInt64 = 0
    private var subagentRefreshTask: Task<Void, Never>?
    /// A refresh asked for while one is loading; the loader runs once more after it.
    private var subagentRefreshPending = false
    private var titleRepairGeneration: UInt64 = 0
    private var titleRepairTask: Task<Void, Never>?
    private var pruneGeneration: UInt64 = 0
    private var pruneTask: Task<Void, Never>?
    private var publishedSubagentActivityThreadId: AgentThreadID?
    #if DEBUG
    let titleRepairStoreIOProbeForTesting = ActivityReceiptsThreadProbe()
    #endif
    private var promptHistory: [String] = []
    private var promptHistoryCursor: Int?
    private var terminalRunIds = Set<AgentRunID>()
    private var timelineUpdateTickTask: Task<Void, Never>?
    // UX-XPLAT-DELETE-UNDO: drops the transient delete snapshot when the undo
    // window lapses. Cancelled on a new delete, on undo, or on teardown.
    private var threadDeletionUndoExpiryTask: Task<Void, Never>?
    // UX-XPLAT-REVERT-UNDO: drops the transient checkpoint-revert undo toast when
    // the undo window lapses. Cancelled on a new revert, on undo, or on teardown.
    private var checkpointRevertUndoExpiryTask: Task<Void, Never>?
    private var messageHistoryLoadTask: Task<Void, Never>?
    private var olderMessageLoadTask: Task<Void, Never>?
    private var messageRevealGeneration: UInt64 = 0
    private var olderMessageLoadFailure: String?
    private var botPeerReconciliationTask: Task<Void, Never>?
    /// Waiting peer markup polls at 5s. Tests override this (keep the field writable).
    var botPeerReconciliationIntervalNanoseconds: UInt64 = 5_000_000_000
    /// PERF: tracks thread ids whose placeholder titles have already been repaired
    /// so reloadThreads never issues a full messageRepo.list for the same thread twice.
    private var repairedThreadIds: Set<AgentThreadID> = []
    /// Programmatic loads and mirror updates also trigger SwiftUI's onChange.
    /// Consume the matching callback once so they never echo as a second save.
    private var ignoredPlanNotesSave: (threadId: AgentThreadID, notes: String)?
    /// Last notes value known for a thread (hydrated read or local save).
    /// A thread switch repoints the editor from this cache before the open
    /// bundle lands: the leaving thread's notes must never paint on the newly
    /// selected thread, and a DB read on the click turn is forbidden.
    private var planNotesByThread: [AgentThreadID: String] = [:]

    // Monotonic ticket for user callback actions (approval responses, user-input
    // answers). respondToPendingRequest resolves async; this seq lets its failure
    // path detect a newer callback action and avoid clobbering the more-recent
    // visible error, restoring the pre-async most-recent-action-wins ordering.
    private var callbackActionSeq: UInt64 = 0

    // PERF-MAC_AGENT-009: cache thread->workspace membership so didChangeStatus
    // does not issue a DB read per status event of every thread. Populated on
    // every reloadThreads() call; threads from other workspaces arrive via the
    // coordinator's multi-workspace broadcast but are filtered out cheaply here.
    private var threadWorkspaceCache: [AgentThreadID: WorkspaceID] = [:]

    /// Cache-first workspace membership for coordinator/event fan-out.
    /// A miss probes `workspace_id` only — never the 26-column + routing `get`.
    private func resolvedWorkspaceID(for threadId: AgentThreadID) -> WorkspaceID? {
        resolvedWorkspaceID(for: threadId, retainingForeignProbe: true)
    }

    /// `retainingForeignProbe: false` keeps another workspace's thread from
    /// entering this surface's caches; an already-learned membership is still
    /// reused, and a local hit is always cached.
    private func resolvedWorkspaceID(
        for threadId: AgentThreadID,
        retainingForeignProbe: Bool
    ) -> WorkspaceID? {
        if let embedding {
            // Pinned surface owns exactly one thread, whatever its workspace row says.
            return threadId == embedding.pinnedThreadId ? workspaceID : nil
        }
        if let cached = threadWorkspaceCache[threadId] {
            return cached
        }
        let workspaceID = try? threadRepo.workspaceId(of: threadId)
        if let workspaceID, retainingForeignProbe || workspaceID == self.workspaceID {
            threadWorkspaceCache[threadId] = workspaceID
        }
        return workspaceID
    }

    #if DEBUG
    /// Test seam for the partial-failure boundary after cap enforcement.
    private var reloadThreadListForTesting: (() throws -> [AgentThread])?
    #endif

    // PERF-MAC_AGENT-010: batch streaming events into one main-actor hop per
    // tick. Fast token streams produce thousands of events/sec; without batching
    // every event allocates an independent Task, each of which pays the Swift
    // concurrency scheduler overhead. Accumulate events here (protected by a
    // lock for nonisolated callers) and drain the whole buffer in one hop when
    // the first event of each tick schedules the flush Task.
    private let streamEventBatch = StreamEventBatch()
    /// Serializes off-MainActor stream apply so concurrent flushes cannot reorder.
    private var streamApplyInFlight = false
    /// Monotonic count of stream quanta committed to the painted timeline, and
    /// of quanta dropped by an open-path generation bump. The thread-open bundle
    /// uses both to detect stream activity that happened while the bundle was
    /// gathered off-main (perf AA-02) and re-read the durable window so nothing
    /// observed during the gather is lost.
    private var streamQuantumCommits: UInt64 = 0
    private var streamQuantumDrops: UInt64 = 0
    /// Set when append tried to flush while an apply was already running.
    private var streamFlushNeeded = false
    /// Counts applied stream events since the last aggregate hot-text budget walk.
    private var streamAggregateBudgetOps = 0
    /// Bumped when `enforceAggregateHotTextBudget` actually walks. Transcript
    /// rematerialize uses this to take the full dictionary path after eviction
    /// that does not change `transcriptSignature`.
    private(set) var aggregateHotTextBudgetGeneration: UInt64 = 0
    /// Bumped on dispose / thread switch so stale detached applies drop their commit.
    private var streamApplyGeneration: UInt64 = 0
    /// True when the hot UI event queue refused at least one already-durable
    /// stream event. Cleared after a durable replay rebuilds the live timeline.
    private var streamUIBackpressured = false

    // QA-MAC_AGENT-CLOCK: injectable clock so "Working for Xs" elapsed math
    // and adaptive-sidebar debounce timestamps are deterministically testable.
    // Default is real wall time; tests inject a fixed/advancing fake clock via
    // setClockForTests(_:). @MainActor isolation serialises all reads/writes.
    private var clock: @Sendable () -> Date = { Date() }

    /// Returns the current instant from the injected clock.
    /// Used by the view for elapsed-time and debounce calculations so tests
    /// can control "now" without racing against wall time.
    public func currentTime() -> Date { clock() }

    /// QA-MAC_AGENT-CLOCK: inject a fixed or advancing clock so time-dependent
    /// view logic is deterministic. Must not be called in production code.
    public func setClockForTests(_ clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    public init(
        workspaceID: WorkspaceID,
        cwd: String,
        coordinator: AgentRunCoordinator,
        threadRepo: AgentThreadRepository,
        messageRepo: AgentMessageRepository,
        draftRepo: AgentThreadDraftRepository? = nil,
        attachmentStore: AgentAttachmentStore? = nil,
        queuedMessageRepo: AgentQueuedMessageRepository? = nil,
        providerSessionRepo: ProviderSessionRuntimeRepository? = nil,
        pendingCallbackRepo: ProviderPendingCallbackRepository? = nil,
        proposedPlanRepo: AgentProposedPlanRepository? = nil,
        checkpointRepo: AgentTurnCheckpointRepository? = nil,
        promptHistoryStore: PromptHistoryStore? = nil,
        customModelStore: AgentCustomModelStore? = nil,
        planNotesStore: PlanNotesStore? = nil,
        initialThreadId: AgentThreadID? = nil,
        sideThreadId: AgentThreadID? = nil,
        lastModelStore: AgentLastModelStore = .shared,
        initialRoutingMode: AgentRoutingMode = .manual,
        newThreadDefaultsStore: AgentNewThreadDefaultsStore? = nil,
        orchestrationRuntime: AgentOrchestrationRuntime = AgentOrchestrationRuntime(),
        embedding: AgentAppEmbedding? = nil
    ) {
        self.embedding = embedding
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.coordinator = coordinator
        self.threadRepo = threadRepo
        self.messageRepo = messageRepo
        self.draftRepo = draftRepo
        self.attachmentStore = attachmentStore
        self.queuedMessageRepo = queuedMessageRepo
        self.providerSessionRepo = providerSessionRepo
        self.pendingCallbackRepo = pendingCallbackRepo
        self.proposedPlanRepo = proposedPlanRepo
        self.checkpointRepo = checkpointRepo
        self.promptHistoryStore = promptHistoryStore
        self.customModelStore = customModelStore
        self.planNotesStore = planNotesStore
        self.lastModelStore = lastModelStore
        self.routingMode = initialRoutingMode
        self.newThreadDefaultsStore = newThreadDefaultsStore
        self.orchestrationRuntime = orchestrationRuntime
        self.promptHistory = promptHistoryStore?.load(workspaceID: workspaceID) ?? []
        self.promptHistoryStore?.onWriteError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.statusMessage = Self.promptHistoryWriteErrorMessage(error)
            }
        }
        reloadCustomModels()
        self.coordinator.addObserver(self)
        if let embedding {
            reloadPinnedThread(seeded: embedding.pinnedThread)
            applyNewThreadDefaultsFromRailIfNeeded()
            selectThread(embedding.pinnedThreadId)
            return
        }
        // Side chat: bind to the ephemeral thread explicitly. It is hidden from
        // the rail (agent.thread.list excludes ephemeral rows), so the normal
        // initialThreadId path below would never select it.
        if let sideThreadId {
            selectThread(sideThreadId)
        }
        // XCTest: same-stack rail load so selectThread(initial) sees rows.
        // Production: first cap+list off MainActor so opening a tab does not hitch.
        let pendingInitialThreadId = initialThreadId
        if Self.isRunningUnitTests {
            reloadThreadsImmediate()
            applyNewThreadDefaultsFromRailIfNeeded()
            if let pendingInitialThreadId, threads.contains(where: { $0.id == pendingInitialThreadId }) {
                selectThread(pendingInitialThreadId)
            } else {
                publishInterestedThreadId(selectedThreadId)
            }
        } else {
            publishInterestedThreadId(nil)
            // A restored tab opens its thread only after the rail read: until
            // then that thread's page is unread, not empty.
            if pendingInitialThreadId != nil { messagePageLoadState = .pending }
            Task { @MainActor [weak self] in
                guard let self, !self.isDisposed else { return }
                let snapshot = await self.loadRailSnapshotOffMainActor()
                self.applyRailSnapshot(snapshot)
                self.applyNewThreadDefaultsFromRailIfNeeded()
                if let pendingInitialThreadId,
                   self.threads.contains(where: { $0.id == pendingInitialThreadId }) {
                    self.selectThread(pendingInitialThreadId)
                } else {
                    self.publishInterestedThreadId(self.selectedThreadId)
                }
                // The restored thread did not open, so nothing is being read.
                // A thread the user opened meanwhile owns its own page state.
                if self.selectedThreadId == nil { self.messagePageLoadState = .idle }
            }
        }
        loadGitBranch()
        AgentWorkspaceRailReloadCoordinator.shared.register(self)
    }

    private func applyNewThreadDefaultsFromRailIfNeeded() {
        guard let newThreadDefaultsStore else { return }
        if let saved = newThreadDefaultsStore.load() {
            restoreNewThreadDefaults(saved)
        } else if let latest = threads
            .filter({ $0.provider.isSelectable })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            let routing = latest.effectiveRoutingConfiguration
            restoreNewThreadDefaults(AgentNewThreadDefaults(
                routingMode: routing.mode,
                runAsUser: latest.runAsUser,
                provider: routing.manualSelection.provider,
                providerInstanceId: routing.manualProviderInstanceId ?? routing.manualSelection.provider.rawValue,
                model: routing.manualSelection.effectiveModel,
                reasoningEffort: routing.manualSelection.reasoningEffort,
                distillMainEffortSelection: routing.manualSelection.distillMainEffortSelection,
                distillReasoningEffortSelection: routing.manualSelection.distillReasoningEffortSelection
            ))
            rememberNewThreadDefaults()
        }
    }

    public func reloadCustomModels() {
        guard let customModelStore else { return }
        var next: [AgentProvider: [String]] = [:]
        for provider in AgentProvider.allCases {
            next[provider] = customModelStore.list(provider: provider)
        }
        customModelsByProvider = next
    }

    public func loadGitBranch() {
        guard embedding == nil else { return }
        AgentGitHeaderLoader.shared.load(cwd: cwd, owner: self) { [weak self] header in
            guard let self, !self.isDisposed else { return }
            let summary = header.summary.isGitRepo ? header.summary : nil
            // Unchanged values still fire objectWillChange and rebuild the view.
            if self.gitBranch != header.branch { self.gitBranch = header.branch }
            if self.gitSummary != summary { self.gitSummary = summary }
        }
    }

    /// `summary` already reads the branch. `GitDiff.branches` repeated isGit
    /// and rev-parse and listed every local ref only for `.current`; this keeps
    /// its detached-HEAD rule ("HEAD" means no branch). 5 git spawns, not 8.
    /// `nil` when git timed out: the header keeps what it showed.
    nonisolated static func loadGitHeader(cwd: String) -> (branch: String?, summary: GitSummary)? {
        guard let summary = GitDiff.summary(in: cwd) else { return nil }
        return (summary.branch == "HEAD" ? nil : summary.branch, summary)
    }

    // PERF-MAC_AGENT-008: per-finish git refresh shelled out a subprocess every
    // completion; when several threads finish together this multiplied. Coalesce
    // bursts into a single refresh after a short trailing delay.
    private var pendingGitRefresh: Task<Void, Never>?
    private var providerSnapshotLoadCount = 0
    /// When the last successful `loadProviderSnapshots` finished. Used with
    /// `ModelListTTLDecision` so send/auto-admit reuses a fresh catalog instead
    /// of re-probing on every keystroke-to-send.
    private var providerSnapshotsLoadedAt: Date?

    public func loadGitBranchThrottled() {
        guard pendingGitRefresh == nil else { return }
        pendingGitRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.pendingGitRefresh = nil
            self.loadGitBranch()
        }
    }

    /// Maps an in-flight run back to its thread so a completion can mark
    /// the right thread unread even after the user navigated away (B6).
    private var runThreads: [AgentRunID: AgentThreadID] = [:] {
        didSet {
            // A newly tracked run can make the selected thread a badge-poll target.
            if runThreads.count > oldValue.count {
                subagentPollCoordinator?.subagentPollTargetMayBeLive()
            }
        }
    }

    /// Set by `AgentWorkspaceRailReloadCoordinator.register`; the shared badge
    /// poll stops while no surface is live and is re-armed through this.
    weak var subagentPollCoordinator: AgentWorkspaceRailReloadCoordinator?

    /// Cross-thread mirror of `selectedThreadId` so nonisolated stream delivery
    /// can drop events for other surfaces without a MainActor hop. Updated on
    /// every select/clear and on dispose. Lives in a lock-backed box so it is
    /// not MainActor-isolated like the rest of the view-model.
    private let interestedThread = InterestedThreadBox()

    /// Coalesces reloadThreads fan-out when many Agent App tabs share a workspace
    /// and each receives the same coordinator status/finish broadcast.
    private var pendingThreadReloadTask: Task<Void, Never>?

    /// Set by `dispose()` when the hosting surface closes so late coordinator
    /// callbacks become no-ops even if a weak observer slot is briefly live.
    private var isDisposed = false

    /// PF-10: hidden Agent App tabs keep reducing the stream but must not
    /// publish at 30 Hz, tick, or reload savings/rail until they are visible.
    private var surfaceVisibility: AgentVisibilityState = .visible
    private var latestHiddenTimeline: AssistantTimelineState? {
        didSet {
            hiddenTimelineRevision &+= 1
            // A live tree always supersedes an archived one.
            if latestHiddenTimeline != nil { hiddenTimelineArchive = nil }
        }
    }
    /// S-F4c: cold-state session for this tab. Its generation moves on every
    /// hide and reveal, so a reclaim armed for an earlier hide is rejected.
    private var visibilitySession = AgentVisibilitySession()
    /// S-F4c: the tab's tree compacted by `reclaimHiddenState`. At most one of
    /// it and `latestHiddenTimeline` is set. It stays the tab's tree until an
    /// off-main restore lands (`restoreColdTimelineOffMain`); writers that
    /// would extend it (stream flush, scheduled poll) wait for that restore.
    private var hiddenTimelineArchive: Data? {
        didSet { hiddenTimelineArchiveGeneration &+= 1 }
    }
    private var hiddenTimelineArchiveGeneration: UInt64 = 0
    private var hiddenTimelineRevision: UInt64 = 0
    private var hiddenReclaimTask: Task<Void, Never>?
    private var coldRestoreTask: Task<Void, Never>?
    /// Set when a reveal is waiting on a cold restore: the `timeline` write
    /// revision at reveal. A restore that finds it moved does not overwrite.
    private var coldRevealTimelineRevision: UInt64?
    /// Stream events stayed batched because the tree was archived; the
    /// restore flushes them onto the restored tree.
    private var coldRestoreFlushPending = false
    var hiddenReclaimDelayForTesting: Duration = .seconds(30)
    /// Below this the archive saves little and restore cost is not worth it.
    var hiddenArchiveMinimumHotTextBytes = 1 << 20
    var beforeHiddenArchiveCommitForTesting: (() async -> Void)?
    var beforeMessageRevealLookupForTesting: (() async -> Void)?
    var hiddenTimelineIsArchivedForTesting: Bool { hiddenTimelineArchive != nil }
    var coldRestoreIsInFlightForTesting: Bool { coldRestoreTask != nil }
    var visibilitySessionForTesting: AgentVisibilitySession { visibilitySession }
    #if DEBUG
    func setHiddenTimelineArchiveForTesting(_ archive: Data) {
        latestHiddenTimeline = nil
        hiddenTimelineArchive = archive
    }
    #endif
    private var hiddenTimelineThreadId: AgentThreadID?
    private var hiddenTimelineOpenGeneration: UInt64 = 0
    private var lastHiddenTimelinePublishAt: Date?
    private(set) var hiddenTimelinePublishCountForTesting = 0
    private(set) var timelineTickScheduleCountForTesting = 0
    var hiddenTimelinePublishIntervalForTesting: TimeInterval = 1
    var nowForTesting: () -> Date = { Date() }
    public var isHiddenFromSurface: Bool { surfaceVisibility == .hidden }

    func setVisibility(_ visibility: AgentVisibilityState) {
        guard !isDisposed else { return }
        let previous = surfaceVisibility
        surfaceVisibility = visibility
        if visibility == .hidden {
            // A repeated hide would stash the already-emptied published
            // timeline over the real hidden one (or its archive).
            guard previous != .hidden else { return }
            timelineUpdateTickTask?.cancel()
            timelineUpdateTickTask = nil
            hiddenTimelineThreadId = selectedThreadId
            hiddenTimelineOpenGeneration = selectThreadOpenGeneration
            // A reveal still waiting on its cold restore left the archive as
            // the tree; the published stand-in is empty and must not replace it.
            if hiddenTimelineArchive == nil {
                latestHiddenTimeline = timeline
            }
            coldRevealTimelineRevision = nil
            timeline = AssistantTimelineState()
            lastHiddenTimelinePublishAt = nil
            hiddenTimelinePublishCountForTesting = 0
            visibilitySession = AgentVisibilityColdState.didBecomeHidden(
                session: visibilitySession,
                checkpoint: AgentPresentationCheckpoint(
                    selectedThreadId: selectedThreadId?.value.uuidString
                )
            )
            scheduleHiddenReclaim()
            return
        }
        guard previous == .hidden else { return }
        hiddenReclaimTask?.cancel()
        hiddenReclaimTask = nil
        visibilitySession = AgentVisibilityColdState.beginReveal(session: visibilitySession)
        let sameOpen = hiddenTimelineThreadId == selectedThreadId
            && hiddenTimelineOpenGeneration == selectThreadOpenGeneration
        if sameOpen, let latestHiddenTimeline {
            timeline = latestHiddenTimeline
        }
        hiddenTimelineThreadId = nil
        latestHiddenTimeline = nil
        if !sameOpen { hiddenTimelineArchive = nil }
        lastHiddenTimelinePublishAt = nil
        if hiddenTimelineArchive != nil {
            // The reveal publishes now (durable messages, chrome); the archived
            // tree decodes off-main and lands in one publish. The session stays
            // `.restoring` until then.
            coldRevealTimelineRevision = publishedTimelineWriteRevision
            restoreColdTimelineOffMain()
        } else {
            completeVisibilityReveal()
        }
        guard sameOpen else { return }
        objectWillChange.send()
        scheduleReloadThreads()
    }

    private func scheduleHiddenReclaim() {
        hiddenReclaimTask?.cancel()
        let generation = visibilitySession.generation
        let delay = hiddenReclaimDelayForTesting
        hiddenReclaimTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reclaimHiddenState(generation: generation)
        }
    }

    func reclaimHiddenStateForTesting() async {
        await reclaimHiddenState(generation: visibilitySession.generation)
    }

    /// S-F4c: a tab that stayed hidden drops the painted caches of threads
    /// with no live run (a later switch takes the normal full open), and
    /// compacts the selected thread's hidden tree into an exact archive.
    /// Encoding runs off-main; the result commits only if this hide is still
    /// current and nothing wrote the hidden tree meanwhile.
    func reclaimHiddenState(generation: UInt64) async {
        guard !isDisposed,
              surfaceVisibility == .hidden,
              visibilitySession.generation == generation else { return }
        let live = Set(runThreads.values)
        for id in Array(paintedTimelineByThread.keys) where !live.contains(id) {
            paintedTimelineByThread.removeValue(forKey: id)
            paintedTimelineOrder.removeAll { $0 == id }
        }
        let selectedIsLive = selectedThreadId.map { live.contains($0) } ?? false
        guard let snapshot = latestHiddenTimeline,
              !selectedIsLive,
              currentRunId == nil,
              scheduledLivePollTask == nil else { return }
        let revision = hiddenTimelineRevision
        let minimumBytes = hiddenArchiveMinimumHotTextBytes
        let archive = (try? await Task.detached(priority: .utility) { () throws -> Data? in
            guard snapshot.aggregateHotTextByteCount >= minimumBytes else { return nil }
            return try AgentColdTimelineArchive.archive(snapshot)
        }.value) ?? nil
        await beforeHiddenArchiveCommitForTesting?()
        guard let archive,
              !isDisposed,
              surfaceVisibility == .hidden,
              visibilitySession.generation == generation,
              hiddenTimelineRevision == revision else { return }
        latestHiddenTimeline = nil
        hiddenTimelineArchive = archive
    }

    /// The cold-state session tracks hide/reveal generations only: this tab
    /// keeps no durable stream sequence, so the checkpoint sequences stay 0
    /// and `appliedThroughSequence: 0` always meets their floor. Selection
    /// staleness is checked by `hiddenTimelineThreadId` + open generation.
    private func completeVisibilityReveal() {
        if let revealed = AgentVisibilityColdState.completeReveal(
            session: visibilitySession,
            expectedGeneration: visibilitySession.generation,
            appliedThroughSequence: 0
        ) {
            visibilitySession = revealed
        }
    }

    /// Decodes the archived tree off-main. Only the task holding
    /// `coldRestoreTask` clears it; its result applies only if the same
    /// archive is still the tab's tree.
    private func restoreColdTimelineOffMain() {
        guard coldRestoreTask == nil, let archive = hiddenTimelineArchive else { return }
        let token = hiddenTimelineArchiveGeneration
        coldRestoreTask = Task { @MainActor [weak self] in
            let restored = await Task.detached(priority: .userInitiated) {
                Result { try AgentColdTimelineArchive.restore(archive) }
            }.value
            guard let self, !self.isDisposed else { return }
            self.coldRestoreTask = nil
            self.finishColdRestore(restored, token: token)
            if self.coldRestoreFlushPending {
                self.coldRestoreFlushPending = false
                self.flushStreamEvents()
            }
        }
    }

    func waitForColdRestoreForTesting() async {
        while let task = coldRestoreTask { await task.value }
    }

    private func finishColdRestore(_ restored: Result<AssistantTimelineState, Error>, token: UInt64) {
        guard hiddenTimelineArchive != nil, hiddenTimelineArchiveGeneration == token else {
            // A newer archive replaced this one while it decoded.
            if hiddenTimelineArchive != nil, coldRevealTimelineRevision != nil || coldRestoreFlushPending {
                restoreColdTimelineOffMain()
            }
            return
        }
        let timelineState: AssistantTimelineState
        switch restored {
        case .success(let value):
            timelineState = value
        case .failure(let error):
            NSLog("[AgentOpen] cold timeline restore failed, reopening the thread: %@", "\(error)")
            reopenSelectedThreadAfterColdRestoreFailure()
            return
        }
        if surfaceVisibility == .hidden {
            latestHiddenTimeline = timelineState
            // The thaw left the tab hot; let it compact again once idle.
            scheduleHiddenReclaim()
            return
        }
        guard let revision = coldRevealTimelineRevision, revision == publishedTimelineWriteRevision else {
            // Something wrote the empty stand-in after reveal; the archive can
            // no longer be merged exactly, so take the normal full open.
            reopenSelectedThreadAfterColdRestoreFailure()
            return
        }
        hiddenTimelineArchive = nil
        coldRevealTimelineRevision = nil
        timeline = timelineState
        completeVisibilityReveal()
        objectWillChange.send()
    }

    /// The archive cannot be shown: drop it and take the normal full open of
    /// the selected thread (off-main bundle), never a main-thread replay.
    private func reopenSelectedThreadAfterColdRestoreFailure() {
        hiddenTimelineArchive = nil
        latestHiddenTimeline = nil
        // A hidden tab then reveals the reopened `timeline` (not sameOpen).
        hiddenTimelineThreadId = nil
        if coldRevealTimelineRevision != nil {
            coldRevealTimelineRevision = nil
            completeVisibilityReveal()
        }
        guard let id = selectedThreadId,
              let thread = threads.first(where: { $0.id == id }) ?? (try? threadRepo.get(id: id)) else { return }
        selectThreadOpenGeneration &+= 1
        timeline = AssistantTimelineState()
        scheduleSelectThreadHydration(
            thread: thread,
            markRead: false,
            openGeneration: selectThreadOpenGeneration,
            probeExistence: false
        )
    }

    /// A thread switch makes the archive another thread's tree.
    private func dropColdTimelineArchive() {
        guard hiddenTimelineArchive != nil else { return }
        hiddenTimelineArchive = nil
        if coldRevealTimelineRevision != nil {
            coldRevealTimelineRevision = nil
            completeVisibilityReveal()
        }
    }

    private func publishInterestedThreadId(_ id: AgentThreadID?) {
        interestedThread.set(id)
    }

    nonisolated private func currentInterestedThreadId() -> AgentThreadID? {
        interestedThread.get()
    }

    /// Debounced thread-list refresh. Many open Agent Apps in one workspace each
    /// observe every run status change; without coalescing, N tabs each hit the
    /// DB on the main actor for the same event and the UI freezes under load.
    func scheduleReloadThreads(delayMilliseconds: UInt64 = 50) {
        guard !isDisposed else { return }
        guard surfaceVisibility != .hidden else { return }
        guard pendingThreadReloadTask == nil else { return }
        pendingThreadReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard let self, !Task.isCancelled, !self.isDisposed else { return }
            self.pendingThreadReloadTask = nil
            self.reloadThreads()
        }
    }

    /// Release coordinator observation and cancel in-flight UI work when the
    /// tab closes. Without this, multi-tab sessions keep routing stream batches
    /// onto closed VMs until ARC collects the weak observer.
    public func dispose() {
        guard !isDisposed else { return }
        if let selectedThreadId { persistComposerDraft(for: selectedThreadId) }
        isDisposed = true
        hiddenReclaimTask?.cancel()
        hiddenReclaimTask = nil
        coldRestoreTask?.cancel()
        coldRestoreTask = nil
        hiddenTimelineArchive = nil
        paintedTimelineByThread.removeAll()
        paintedTimelineOrder.removeAll()
        AgentWorkspaceRailReloadCoordinator.shared.unregister(self)
        stopScheduledLivePoll()
        pendingGitRefresh?.cancel()
        pendingGitRefresh = nil
        pendingThreadReloadTask?.cancel()
        pendingThreadReloadTask = nil
        timelineUpdateTickTask?.cancel()
        timelineUpdateTickTask = nil
        softReselectDurableTask?.cancel()
        softReselectDurableTask = nil
        threadDeletionUndoExpiryTask?.cancel()
        threadDeletionUndoExpiryTask = nil
        checkpointRevertUndoExpiryTask?.cancel()
        checkpointRevertUndoExpiryTask = nil
        messageHistoryLoadTask?.cancel()
        messageHistoryLoadTask = nil
        botPeerReconciliationTask?.cancel()
        botPeerReconciliationTask = nil
        cancelOlderMessageLoad()
        if let manualActionObserver {
            NotificationCenter.default.removeObserver(manualActionObserver)
            self.manualActionObserver = nil
        }
        if let manualActionStateObserver {
            NotificationCenter.default.removeObserver(manualActionStateObserver)
            self.manualActionStateObserver = nil
        }
        subagentRefreshTask?.cancel()
        subagentRefreshTask = nil
        subagentRefreshPending = false
        subagentRefreshGeneration &+= 1
        titleRepairTask?.cancel()
        titleRepairTask = nil
        titleRepairGeneration &+= 1
        pruneTask?.cancel()
        pruneTask = nil
        pruneGeneration &+= 1
        streamApplyGeneration &+= 1
        streamAggregateBudgetOps = 0
        streamApplyInFlight = false
        streamFlushNeeded = false
        _ = streamEventBatch.drain()
        streamUIBackpressured = false
        publishInterestedThreadId(nil)
        coordinator.removeObserver(self)
        // Drop the heavy transcript payload so closed tabs free memory promptly.
        messages = []
        messageHistoryIsPartial = false
        timeline = AssistantTimelineState()
    }

    /// Used by the multi-surface rail reload hub (EventBus fan-out).
    var isDisposedForReloadCoordination: Bool { isDisposed }

    /// Cap + list off MainActor so multi-tab EventBus storms do not block UI.
    func loadRailSnapshotOffMainActor() async -> AgentWorkspaceRailReloadCoordinator.RailSnapshot {
        let repo = threadRepo
        let coordinator = coordinator
        let workspaceID = workspaceID
        #if DEBUG
        let listOverride = reloadThreadListForTesting
        #endif
        return await Task.detached(priority: .userInitiated) {
            _ = coordinator.reconcileStaleActiveOwnershipWithDurableState()
            // Cheap COUNT first: skip the prune transaction when under cap.
            // When over cap, enforce BEFORE list so a fallible list cannot leave
            // committed victims alive without the rail learning their IDs.
            var pruned: [AgentThreadID] = []
            do {
                let count = try repo.count(workspaceId: workspaceID)
                if count > AgentThreadRepository.maxThreadsPerWorkspace {
                    pruned = try repo.enforceWorkspaceThreadLimit(workspaceId: workspaceID)
                }
                let listed: [AgentThread]
                #if DEBUG
                if let listOverride {
                    listed = try listOverride()
                } else {
                    listed = try repo.list(workspaceId: workspaceID)
                }
                #else
                listed = try repo.list(workspaceId: workspaceID)
                #endif
                return AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                    workspaceID: workspaceID,
                    threads: listed,
                    prunedThreadIDs: pruned
                )
            } catch {
                return AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                    workspaceID: workspaceID,
                    threads: [],
                    prunedThreadIDs: pruned,
                    errorDescription: String(describing: error)
                )
            }
        }.value
    }

    /// Applies a coalesced rail snapshot produced once per workspace debounce window.
    func applyRailSnapshot(_ snapshot: AgentWorkspaceRailReloadCoordinator.RailSnapshot) {
        guard !isDisposed, snapshot.workspaceID == workspaceID else { return }
        // Committed cap victims always leave the rail — even when the subsequent
        // list fails (partial-failure contract).
        if !snapshot.prunedThreadIDs.isEmpty {
            retireCommittedThreadPrunes(snapshot.prunedThreadIDs)
            applyAuthoritativeThreadDeletions(Set(snapshot.prunedThreadIDs))
            onThreadLifecycle?(.deleted(snapshot.prunedThreadIDs))
        }
        if let errorDescription = snapshot.errorDescription {
            let reloadFailure = "Could not reload threads: \(errorDescription)"
            if statusMessage.contains(Self.deletedThreadDraftRecoveryMessage) {
                statusMessage = "\(Self.deletedThreadDraftRecoveryMessage) \(reloadFailure)"
            } else {
                statusMessage = reloadFailure
            }
            if !snapshot.prunedThreadIDs.isEmpty {
                let knownLocalThreadIDs = Set(threads.map(\.id)).union(
                    threadWorkspaceCache.compactMap { id, workspace in
                        workspace == workspaceID ? id : nil
                    }
                )
                let missing = knownLocalThreadIDs.intersection(snapshot.prunedThreadIDs)
                evictThreadCaches(missing)
                threads.removeAll { snapshot.prunedThreadIDs.contains($0.id) }
                recoverDeletedSelectionIfNeeded(missing)
                pruneStaleRunThreadProjections()
                refreshSubagentActivity()
            }
            return
        }
        let knownLocalThreadIDs = Set(threads.map(\.id)).union(
            threadWorkspaceCache.compactMap { id, workspace in
                workspace == workspaceID ? id : nil
            }
        )
        let missingKnownThreadIDs = knownLocalThreadIDs.subtracting(snapshot.threads.map(\.id))
        evictThreadCaches(missingKnownThreadIDs)
        threads = snapshot.threads
        recoverDeletedSelectionIfNeeded(missingKnownThreadIDs)
        pruneStaleRunThreadProjections()
        if isStopping,
           let selectedThreadId,
           trackedRunId(for: selectedThreadId) == nil,
           isScheduledThreadRunning?(selectedThreadId) != true {
            isStopping = false
        }
        for t in threads {
            if let wid = t.workspaceId {
                threadWorkspaceCache[t.id] = wid
            }
        }
        repairPlaceholderThreadTitles()
        if let sel = selectedThreadId, !threads.contains(where: { $0.id == sel }) {
            recoverDeletedSelectionIfNeeded([sel])
        }
        refreshSubagentActivity()
    }

    /// Unit tests need a same-stack rail snapshot; production must never block
    /// MainActor on cap+list against a multi-GB SQLite file.
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Embedded surfaces list only their pinned thread.
    private func reloadPinnedThread(seeded: AgentThread? = nil) {
        guard let embedding else { return }
        guard let thread = seeded ?? (try? threadRepo.get(id: embedding.pinnedThreadId)) else { return }
        threads = [thread]
        threadWorkspaceCache[thread.id] = thread.workspaceId ?? workspaceID
    }

    public func reloadThreads() {
        guard !isDisposed else { return }
        if embedding != nil {
            reloadPinnedThread()
            return
        }
        if Self.isRunningUnitTests {
            reloadThreadsImmediate()
            return
        }
        // Production: always leave MainActor for cap+list via the workspace hub.
        AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(workspaceID: workspaceID)
    }

    /// Immediate rail reload (init + XCTest). Cap+list stay on the caller thread.
    private func reloadThreadsImmediate() {
        _ = coordinator.reconcileStaleActiveOwnershipWithDurableState()
        let knownLocalThreadIDs = Set(threads.map(\.id)).union(
            threadWorkspaceCache.compactMap { id, workspace in
                workspace == workspaceID ? id : nil
            }
        )
        var prunedThreadIDs: [AgentThreadID] = []
        do {
            // Same under-cap short-circuit as production off-main rail loads:
            // COUNT → optional enforce → list (enforce before fallible list).
            let count = try threadRepo.count(workspaceId: workspaceID)
            if count > AgentThreadRepository.maxThreadsPerWorkspace {
                prunedThreadIDs = try threadRepo.enforceWorkspaceThreadLimit(workspaceId: workspaceID)
            }
            let reloadedThreads: [AgentThread]
            #if DEBUG
            if let reloadThreadListForTesting {
                reloadedThreads = try reloadThreadListForTesting()
            } else {
                reloadedThreads = try threadRepo.list(workspaceId: workspaceID)
            }
            #else
            reloadedThreads = try threadRepo.list(workspaceId: workspaceID)
            #endif
            let snapshot = AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                workspaceID: workspaceID,
                threads: reloadedThreads,
                prunedThreadIDs: prunedThreadIDs
            )
            applyRailSnapshotPreservingKnownLocals(snapshot, knownLocalThreadIDs: knownLocalThreadIDs)
        } catch {
            applyRailSnapshotPreservingKnownLocals(
                AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                    workspaceID: workspaceID,
                    threads: [],
                    prunedThreadIDs: prunedThreadIDs,
                    errorDescription: String(describing: error)
                ),
                knownLocalThreadIDs: knownLocalThreadIDs
            )
        }
    }

    private func applyRailSnapshotPreservingKnownLocals(
        _ snapshot: AgentWorkspaceRailReloadCoordinator.RailSnapshot,
        knownLocalThreadIDs: Set<AgentThreadID>
    ) {
        guard !isDisposed, snapshot.workspaceID == workspaceID else { return }
        if !snapshot.prunedThreadIDs.isEmpty {
            retireCommittedThreadPrunes(snapshot.prunedThreadIDs)
            applyAuthoritativeThreadDeletions(Set(snapshot.prunedThreadIDs))
            onThreadLifecycle?(.deleted(snapshot.prunedThreadIDs))
        }
        if let errorDescription = snapshot.errorDescription {
            let reloadFailure = "Could not reload threads: \(errorDescription)"
            if statusMessage.contains(Self.deletedThreadDraftRecoveryMessage) {
                statusMessage = "\(Self.deletedThreadDraftRecoveryMessage) \(reloadFailure)"
            } else {
                statusMessage = reloadFailure
            }
            if !snapshot.prunedThreadIDs.isEmpty {
                let missing = knownLocalThreadIDs.intersection(snapshot.prunedThreadIDs)
                evictThreadCaches(missing)
                threads.removeAll { snapshot.prunedThreadIDs.contains($0.id) }
                recoverDeletedSelectionIfNeeded(missing)
                pruneStaleRunThreadProjections()
                refreshSubagentActivity()
            }
            return
        }
        let missingKnownThreadIDs = knownLocalThreadIDs.subtracting(snapshot.threads.map(\.id))
        evictThreadCaches(missingKnownThreadIDs)
        threads = snapshot.threads
        recoverDeletedSelectionIfNeeded(missingKnownThreadIDs)
        pruneStaleRunThreadProjections()
        if isStopping,
           let selectedThreadId,
           trackedRunId(for: selectedThreadId) == nil,
           isScheduledThreadRunning?(selectedThreadId) != true {
            isStopping = false
        }
        for t in threads {
            if let wid = t.workspaceId {
                threadWorkspaceCache[t.id] = wid
            }
        }
        repairPlaceholderThreadTitles()
        if let sel = selectedThreadId, !threads.contains(where: { $0.id == sel }) {
            recoverDeletedSelectionIfNeeded([sel])
        }
        refreshSubagentActivity()
    }

    /// Rebuild Subagents snapshot from persisted admission receipts and the
    /// coordinator's current active-run set. Fail open to empty on read errors.
    ///
    /// Scoped to the selected thread plus parent-chain descendants (middleware
    /// nested Agent App workers). Sibling threads without a parent link are
    /// excluded so the badge never aggregates the whole workspace.
    ///
    /// Prefer `loadSubagentActivitySnapshotOffMainActor` for the 2s poll so SQLite
    /// + JSON decode never sit on the main thread (hang_breach under multi-thread).
    public func refreshSubagentActivity() {
        guard !isDisposed else { return }
        guard let threadId = selectedThreadId else {
            publishedSubagentActivityThreadId = nil
            applySubagentActivity(.empty)
            return
        }
        // Selection or rail reload may land on a running thread.
        subagentPollCoordinator?.subagentPollTargetMayBeLive()
        // Switching threads must drop the previous thread's badge immediately.
        // The receipt load stays off-main (freeze-class hang_breach).
        if publishedSubagentActivityThreadId != threadId {
            applySubagentActivity(.empty)
            publishedSubagentActivityThreadId = threadId
        }
        // Off-main JSON/SQLite. The previous MainActor `loadSubagentActivitySnapshotSync`
        // path is the freeze-class hang_breach (CPU diag: applyRailSnapshot → receipts).
        let generation = subagentRefreshGeneration &+ 1
        subagentRefreshGeneration = generation
        // Single flight: the detached receipt read cannot be cancelled, so
        // restarting it on every rail reload stacked reads on the receipt lock
        // (Notifications thread hang). Coalesce into one trailing rerun.
        guard subagentRefreshTask == nil else {
            subagentRefreshPending = true
            return
        }
        subagentRefreshTask = Task { @MainActor [weak self] in
            var threadId = threadId
            var generation = generation
            while let self, !Task.isCancelled {
                self.subagentRefreshPending = false
                let snapshot = await self.loadSubagentActivitySnapshotsOffMainActor(
                    for: [threadId],
                    persistLifecycleReconciliation: true
                )[threadId] ?? .empty
                guard !Task.isCancelled else { return }
                if self.subagentRefreshGeneration == generation {
                    self.applySubagentActivity(snapshot, loadedFor: threadId)
                }
                guard self.subagentRefreshPending, let next = self.selectedThreadId else {
                    self.subagentRefreshTask = nil
                    return
                }
                threadId = next
                generation = self.subagentRefreshGeneration
            }
        }
    }

    #if DEBUG
    public func awaitSubagentActivityRefreshForTesting() async {
        await subagentRefreshTask?.value
    }

    public func awaitTitleRepairForTesting() async {
        await titleRepairTask?.value
    }

    public func awaitPruneStaleRunProjectionsForTesting() async {
        await pruneTask?.value
    }

    func seedRunThreadProjectionForTesting(runId: AgentRunID, threadId: AgentThreadID) {
        runThreads[runId] = threadId
    }

    func trackedRunIdForTesting(_ threadId: AgentThreadID) -> AgentRunID? {
        trackedRunId(for: threadId)
    }

    /// Resume-gated hook so tests can mutate the thread after apply schedules
    /// repair but before firstUserMessage / persist.
    var titleRepairBeforeFetchForTesting: (@Sendable () async -> Void)?

    /// Resume-gated hook so tests can start a live run after prune is scheduled
    /// but before durableActiveRun returns.
    var pruneBeforeDurableLookupForTesting: (@Sendable () async -> Void)?

    func clearRunThreadProjectionsForTesting() {
        runThreads.removeAll()
    }
    #endif

    /// Apply a precomputed snapshot on the main actor (poll completion path).
    public func applySubagentActivity(_ next: SubagentActivitySnapshot) {
        guard !isDisposed else { return }
        guard Self.shouldPublishSubagentActivity(current: subagentActivity, next: next) else { return }
        subagentActivity = next
        publishedSubagentActivityThreadId = selectedThreadId
        if next.isLive {
            subagentPollCoordinator?.subagentPollTargetMayBeLive()
        }
    }

    /// Apply a poll result only while the thread that produced it is still selected.
    public func applySubagentActivity(
        _ next: SubagentActivitySnapshot,
        loadedFor threadId: AgentThreadID
    ) {
        guard selectedThreadId == threadId else { return }
        applySubagentActivity(next)
    }

    /// Off-main badge load used by the shared 2s poll. Read-only reconciliation
    /// (no lifecycle write lock) so multi-thread sessions do not stall UI.
    func loadSubagentActivitySnapshotOffMainActor(
        for threadId: AgentThreadID
    ) async -> SubagentActivitySnapshot {
        await loadSubagentActivitySnapshotsOffMainActor(for: [threadId])[threadId] ?? .empty
    }

    /// Loads every visible workspace badge from one receipt-store scan. A poll
    /// round used to repeat the same JSON scan once per restored workspace.
    func loadSubagentActivitySnapshotsOffMainActor(
        for threadIds: [AgentThreadID],
        persistLifecycleReconciliation: Bool = false
    ) async -> [AgentThreadID: SubagentActivitySnapshot] {
        guard !isDisposed else { return [:] }
        let uniqueThreadIds = Array(Set(threadIds))
        guard !uniqueThreadIds.isEmpty else { return [:] }
        let orchestrationRuntime = orchestrationRuntime
        let coordinator = coordinator
        let clock = clock
        let activeRunIds = Set(
            coordinator.activeThreadIdsSnapshot().compactMap { threadId in
                coordinator.activeRunId(threadId: threadId)
            }
        )
        return await Task.detached(priority: .utility) {
            let receipts = (try? orchestrationRuntime.activityReceipts(
                threadIds: Set(uniqueThreadIds),
                limit: SubagentActivityProjection.defaultReceiptFetchLimit * uniqueThreadIds.count,
                childRecordLimit: SubagentActivityProjection.defaultBadgeChildReceiptLimit,
                persistLifecycleReconciliation: persistLifecycleReconciliation
            )) ?? []
            let now = clock()
            return Dictionary(uniqueKeysWithValues: uniqueThreadIds.map { threadId in
                (
                    threadId,
                    SubagentActivityProjection.project(
                        receipts: receipts,
                        threadIds: [threadId],
                        activeRunIds: activeRunIds,
                        now: now
                    )
                )
            })
        }.value
    }

    /// Skip equal subagent snapshot reloads (soft reselect / idle poll multipass).
    nonisolated public static func shouldPublishSubagentActivity(
        current: SubagentActivitySnapshot,
        next: SubagentActivitySnapshot
    ) -> Bool {
        current != next
    }

    /// Drop surface `runThreads` entries that no longer match a live coordinator
    /// or durable active run for the same runId. Generation-safe: never clears
    /// by threadId alone (a newer run B on the same thread stays mapped).
    ///
    /// WHY: the rail spinner is driven by `trackedRunId` → `runThreads`, which
    /// can survive a missed workspace-filtered didFinish and leave "Threads · N
    /// active" after the work is done.
    private func pruneStaleRunThreadProjections() {
        let generation = pruneGeneration &+ 1
        pruneGeneration = generation
        pruneTask?.cancel()
        pruneTask = nil
        let snapshot = runThreads
        var stillMaybeLive: [(AgentRunID, AgentThreadID)] = []
        for (runId, threadId) in snapshot {
            if coordinator.activeRunId(threadId: threadId) == runId {
                continue
            }
            stillMaybeLive.append((runId, threadId))
        }
        guard !stillMaybeLive.isEmpty else { return }
        let coordinator = coordinator
        #if DEBUG
        let hold = pruneBeforeDurableLookupForTesting
        #endif
        pruneTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.pruneGeneration == generation else { return }
            #if DEBUG
            await hold?()
            #endif
            guard self.pruneGeneration == generation else { return }
            let keep: Set<AgentRunID> = await Task.detached(priority: .utility) {
                var keep = Set<AgentRunID>()
                for (runId, threadId) in stillMaybeLive {
                    if let durable = try? coordinator.durableActiveRunChrome(threadId: threadId),
                       durable.id == runId {
                        keep.insert(runId)
                    }
                }
                return keep
            }.value
            guard !Task.isCancelled else { return }
            guard self.pruneGeneration == generation else { return }
            var clearedSelected = false
            for (runId, threadId) in stillMaybeLive {
                guard !keep.contains(runId) else { continue }
                guard self.runThreads[runId] == threadId else { continue }
                if self.coordinator.activeRunId(threadId: threadId) == runId {
                    continue
                }
                self.runThreads[runId] = nil
                if self.currentRunId == runId {
                    self.currentRunId = nil
                    if self.selectedThreadId == threadId {
                        clearedSelected = true
                    }
                }
            }
            if clearedSelected, let sel = self.selectedThreadId, !self.isThreadStartingOrRunning(sel) {
                self.runStartedAt = nil
                if let durableStatus = self.threads.first(where: { $0.id == sel })?.status {
                    self.status = durableStatus
                }
                self.isStopping = false
            }
            if self.pruneGeneration == generation {
                self.pruneTask = nil
            }
        }
    }

    /// Pure helper: indices of threads that still need a placeholder-title repair.
    /// A thread is excluded when its id is in `alreadyRepaired` (already fixed this
    /// session) or when its title is not a placeholder (no repair needed).
    /// `nonisolated static` so it is testable without a MainActor context.
    nonisolated static func indicesNeedingRepair(
        in threads: [AgentThread],
        alreadyRepaired: Set<AgentThreadID>
    ) -> [Int] {
        threads.indices.filter { i in
            !alreadyRepaired.contains(threads[i].id) &&
            AgentThreadTitle.isPlaceholder(threads[i].title)
        }
    }

    private func repairPlaceholderThreadTitles() {
        let toRepair = Self.indicesNeedingRepair(in: threads, alreadyRepaired: repairedThreadIds)
        guard !toRepair.isEmpty else { return }
        let generation = titleRepairGeneration &+ 1
        titleRepairGeneration = generation
        titleRepairTask?.cancel()
        let threadIds = toRepair.map { threads[$0].id }
        let messageRepo = messageRepo
        let threadRepo = threadRepo
        #if DEBUG
        let probe = titleRepairStoreIOProbeForTesting
        let hold = titleRepairBeforeFetchForTesting
        #endif
        titleRepairTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.titleRepairGeneration == generation else { return }
            #if DEBUG
            await hold?()
            #endif
            guard self.titleRepairGeneration == generation else { return }
            struct Fetch: Sendable {
                let threadId: AgentThreadID
                let title: String?
                let errorDescription: String?
            }
            let fetched: [Fetch] = await Task.detached(priority: .utility) {
                var out: [Fetch] = []
                out.reserveCapacity(threadIds.count)
                for threadId in threadIds {
                    #if DEBUG
                    probe.recordCurrentThread()
                    #endif
                    do {
                        guard let message = try messageRepo.firstUserMessage(threadId: threadId) else {
                            out.append(Fetch(threadId: threadId, title: nil, errorDescription: nil))
                            continue
                        }
                        out.append(Fetch(
                            threadId: threadId,
                            title: AgentThreadTitle.titleFromFirstMessage(message.content),
                            errorDescription: nil
                        ))
                    } catch {
                        out.append(Fetch(
                            threadId: threadId,
                            title: nil,
                            errorDescription: String(describing: error)
                        ))
                    }
                }
                return out
            }.value
            guard !Task.isCancelled else { return }
            guard self.titleRepairGeneration == generation else { return }
            var titlesToPersist: [(AgentThreadID, String)] = []
            for item in fetched {
                if let errorDescription = item.errorDescription {
                    self.statusMessage = "Could not repair thread title: \(errorDescription)"
                    continue
                }
                self.repairedThreadIds.insert(item.threadId)
                guard let title = item.title else { continue }
                guard let index = self.threads.firstIndex(where: { $0.id == item.threadId }) else {
                    continue
                }
                guard AgentThreadTitle.isPlaceholder(self.threads[index].title) else { continue }
                self.threads[index].title = title
                titlesToPersist.append((item.threadId, title))
                self.onThreadLifecycle?(.updated(self.threads[index]))
            }
            if !titlesToPersist.isEmpty {
                await Task.detached(priority: .utility) {
                    for (threadId, title) in titlesToPersist {
                        try? threadRepo.updateTitlePreservingActivity(threadId, title: title)
                    }
                }.value
            }
            if self.titleRepairGeneration == generation {
                self.titleRepairTask = nil
            }
        }
    }

    /// IMP-MAC_AGENT-011: unsent composer state, keyed by thread and persisted
    /// so text, attachments, and interaction mode survive switching/relaunch.
    private var composerDraftsByThread: [AgentThreadID: [String: AgentThreadDraft]] = [:]
    private static let composerDraftPersistenceDelayNanoseconds: UInt64 = 250_000_000
    private var composerDraftPersistenceTask: Task<Void, Never>?
    private var pendingComposerDraftPersistenceThreadID: AgentThreadID?
    private var pendingComposerDraftPersistenceProviderInstanceID: String?
    private var providerThreadSnapshotConfirmedAtByThread: [AgentThreadID: Date] = [:]

    private func makeComposerDraft(for threadId: AgentThreadID) -> AgentThreadDraft {
        AgentThreadDraft(
            threadId: threadId,
            providerInstanceId: providerInstanceId,
            text: prompt,
            attachments: attachments,
            interactionMode: interactionMode
        )
    }

    private func cacheComposerDraft(_ draft: AgentThreadDraft) {
        composerDraftsByThread[draft.threadId, default: [:]][draft.providerInstanceId] = draft
    }

    private func persistComposerDraftToRepository(_ draft: AgentThreadDraft) {
        do {
            try draftRepo?.upsert(draft)
        } catch {
            statusMessage = "Draft save failed: \(error)"
        }
    }

    /// Debounced background saves must not block the MainActor behind the
    /// shared SQLite queue while the user keeps typing. Explicit saves
    /// (thread switch, tab close, config change) stay synchronous as the
    /// durability anchor.
    private func persistComposerDraftOffMain(_ draft: AgentThreadDraft) {
        let repo = draftRepo
        Task.detached(priority: .utility) { [weak self] in
            do {
                try repo?.upsert(draft)
            } catch {
                await self?.reportComposerDraftSaveFailure(error)
            }
        }
    }

    private func reportComposerDraftSaveFailure(_ error: Error) {
        statusMessage = "Draft save failed: \(error)"
    }

    private func cancelPendingComposerDraftPersistence() {
        composerDraftPersistenceTask?.cancel()
        composerDraftPersistenceTask = nil
        pendingComposerDraftPersistenceThreadID = nil
        pendingComposerDraftPersistenceProviderInstanceID = nil
    }

    private func cancelPendingComposerDraftPersistence(
        for threadId: AgentThreadID,
        providerInstanceId: String
    ) {
        guard pendingComposerDraftPersistenceThreadID == threadId,
              pendingComposerDraftPersistenceProviderInstanceID == providerInstanceId else {
            return
        }
        cancelPendingComposerDraftPersistence()
    }

    private func persistComposerDraft(for threadId: AgentThreadID) {
        guard embedding?.ownsComposerDraft != false else { return }
        cancelPendingComposerDraftPersistence()
        let draft = makeComposerDraft(for: threadId)
        cacheComposerDraft(draft)
        persistComposerDraftToRepository(draft)
    }

    /// Thread-switch draft stash (perf AA-04): the leaving thread's draft write
    /// no longer blocks the MainActor behind the shared SQLite queue before the
    /// first paint of the newly selected thread. The in-memory cache keeps the
    /// draft restorable if the user switches back before the write lands, and
    /// dispose() re-persists on close.
    private func stashComposerDraftOffMain(for threadId: AgentThreadID) {
        guard embedding?.ownsComposerDraft != false else { return }
        cancelPendingComposerDraftPersistence()
        let draft = makeComposerDraft(for: threadId)
        cacheComposerDraft(draft)
        persistComposerDraftOffMain(draft)
    }

    private func scheduleComposerDraftPersistence(for threadId: AgentThreadID) {
        guard embedding?.ownsComposerDraft != false else { return }
        let draft = makeComposerDraft(for: threadId)
        cacheComposerDraft(draft)
        cancelPendingComposerDraftPersistence()
        pendingComposerDraftPersistenceThreadID = draft.threadId
        pendingComposerDraftPersistenceProviderInstanceID = draft.providerInstanceId
        composerDraftPersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.composerDraftPersistenceDelayNanoseconds)
            } catch {
                return
            }
            guard let self, !self.isDisposed else { return }
            guard self.pendingComposerDraftPersistenceThreadID == draft.threadId,
                  self.pendingComposerDraftPersistenceProviderInstanceID == draft.providerInstanceId else {
                return
            }
            self.composerDraftPersistenceTask = nil
            self.pendingComposerDraftPersistenceThreadID = nil
            self.pendingComposerDraftPersistenceProviderInstanceID = nil
            self.persistComposerDraftOffMain(draft)
        }
    }

    private func restoreComposerDraft(for thread: AgentThread) {
        restoreComposerDraft(
            threadId: thread.id,
            providerInstanceId: providerInstanceId,
            fallbackInteractionMode: thread.effectiveInteractionMode
        )
    }

    private func restoreComposerDraft(
        threadId: AgentThreadID,
        providerInstanceId: String,
        fallbackInteractionMode: AgentInteractionMode
    ) {
        // Cache-first: a warm in-session draft must not pay a synchronous
        // MainActor SQLite read + attachment decode on every switch. The
        // durable row is consulted only on a cache miss (fresh VM, relaunch).
        let draft: AgentThreadDraft?
        if let cached = composerDraftsByThread[threadId]?[providerInstanceId] {
            draft = cached
        } else {
            durableComposerDraftReadCountForTesting += 1
            let durable = try? draftRepo?.get(threadId: threadId, providerInstanceId: providerInstanceId)
            draft = durable ?? nil
        }
        prompt = draft?.text ?? ""
        attachments = draft?.attachments ?? []
        interactionMode = draft?.interactionMode ?? fallbackInteractionMode
        if let draft { composerDraftsByThread[threadId, default: [:]][providerInstanceId] = draft }
    }

    private func clearComposerDraft(threadId: AgentThreadID, providerInstanceId: String) throws {
        cancelPendingComposerDraftPersistence(
            for: threadId,
            providerInstanceId: providerInstanceId
        )
        try draftRepo?.delete(threadId: threadId, providerInstanceId: providerInstanceId)
        clearComposerDraftMemory(threadId: threadId, providerInstanceId: providerInstanceId)
    }

    private func clearComposerDraftMemory(threadId: AgentThreadID, providerInstanceId: String) {
        cancelPendingComposerDraftPersistence(
            for: threadId,
            providerInstanceId: providerInstanceId
        )
        composerDraftsByThread[threadId]?.removeValue(forKey: providerInstanceId)
        if composerDraftsByThread[threadId]?.isEmpty == true {
            composerDraftsByThread.removeValue(forKey: threadId)
        }
    }

    /// Bumped on every full thread open so deferred provider-snapshot tasks for
    /// a prior open never wipe a newer selection (or the same thread re-selected soft).
    private var selectThreadOpenGeneration: UInt64 = 0
    private var selectThreadHydrationTask: Task<Void, Never>?
    private var paintedTimelineByThread: [AgentThreadID: AssistantTimelineState] = [:]
    private var paintedTimelineOrder: [AgentThreadID] = []
    /// F3: keep at most 2 painted timelines (was 3). Each entry can pin up to
    /// `aggregateHotTextByteLimit` of hot transcript; dropping one inactive slot
    /// cuts nominal inactive-cache capacity by ~33% (selected/live may still
    /// remain above the inactive bound).
    static let paintedTimelineLimit = 2
    var paintedTimelineCountForTesting: Int { paintedTimelineByThread.count }

    /// AA-07 / F3: keep at most `paintedTimelineLimit` painted timelines, plus
    /// the selected thread and any thread that still has a live run on this surface.
    private func rememberPaintedTimeline(_ id: AgentThreadID, _ timeline: AssistantTimelineState) {
        paintedTimelineByThread[id] = timeline
        paintedTimelineOrder.removeAll { $0 == id }
        paintedTimelineOrder.append(id)
        let active = Set(runThreads.values)
        while paintedTimelineByThread.count > Self.paintedTimelineLimit {
            guard let evict = paintedTimelineOrder.first(where: { candidate in
                candidate != selectedThreadId && !active.contains(candidate)
            }) else { break }
            paintedTimelineOrder.removeAll { $0 == evict }
            paintedTimelineByThread.removeValue(forKey: evict)
        }
    }

    /// X-02: run status changes used to re-list every workspace thread.
    private func applyInMemoryThreadStatus(_ threadId: AgentThreadID, status: AgentRunStatus) {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[idx].status != status else { return }
        threads[idx].status = status
        // The coordinator persists status and read state together
        // (`AgentRunCoordinator.hasUnread(for:)`), so a status-only event must
        // mirror that rule here too: without the unread half the rail keeps a
        // stale badge until the next full list, which X-02 no longer triggers.
        threads[idx].hasUnread = Self.railUnread(for: status)
        threads[idx].updatedAt = Date()
    }

    /// Read state the coordinator stores with each run status.
    nonisolated static func railUnread(for status: AgentRunStatus) -> Bool {
        switch status {
        case .completed, .failed, .interrupted: return true
        case .pending, .running, .cancelled: return false
        }
    }

    /// True when the last `selectThread` used the in-memory rail instead of a full `get`.
    private(set) var lastThreadSelectionUsedRailForTesting = false
    /// Count of durable `threadRepo.get` lookups from `selectThread` (cache misses).
    private(set) var durableThreadSelectionLookupCountForTesting = 0
    /// Count of cheap workspace-id probes used to reject stale rail rows.
    private(set) var durableThreadExistenceProbeCountForTesting = 0
    /// Durable (SQLite) draft reads issued by restoreComposerDraft. A warm
    /// in-session cache must serve restore without touching the repo.
    private(set) var durableComposerDraftReadCountForTesting = 0

    /// Cache-first thread row for selection. A rail click must not wait on
    /// `threadRepo.get` — that path compiles two statements off the DB queue
    /// on MainActor (row + routing) and can hitch behind a FULLMUTEX writer.
    nonisolated static func railThreadForSelection(
        id: AgentThreadID,
        workspaceID: WorkspaceID,
        rail: [AgentThread]
    ) -> AgentThread? {
        guard let thread = rail.first(where: { $0.id == id }) else { return nil }
        guard thread.workspaceId == workspaceID else { return nil }
        return thread
    }

    public func selectThread(_ id: AgentThreadID, markRead: Bool = true) {
        guard !isDisposed else { return }
        if let embedding, id != embedding.pinnedThreadId { return }
        let isPinned = embedding?.pinnedThreadId == id
        let selectedThread: AgentThread
        if let cached = Self.railThreadForSelection(
            id: id,
            workspaceID: workspaceID,
            rail: threads
        ) ?? (isPinned ? threads.first(where: { $0.id == id }) : nil) {
            // Rail hits publish first. Existence probe runs after the first
            // frame so a click is not blocked on SQLite.
            selectedThread = cached
            lastThreadSelectionUsedRailForTesting = true
        } else {
            lastThreadSelectionUsedRailForTesting = false
            durableThreadSelectionLookupCountForTesting += 1
            do {
                guard let persistedThread = try threadRepo.get(id: id) else {
                    if statusMessage.isEmpty {
                        statusMessage = "Could not open thread: The thread is no longer available."
                    }
                    return
                }
                selectedThread = persistedThread
            } catch {
                statusMessage = "Could not open thread: \(error)"
                return
            }
            guard isPinned || selectedThread.workspaceId == workspaceID else {
                if statusMessage.isEmpty {
                    statusMessage = "Could not open thread: The thread belongs to another workspace."
                }
                return
            }
        }
        threadWorkspaceCache[id] = selectedThread.workspaceId ?? workspaceID
        selectedThreadIsEphemeral = selectedThread.isEphemeral
        selectedThreadParentId = selectedThread.parentThreadId
        if statusMessage.contains(Self.deletedThreadDraftRecoveryMessage) {
            statusMessage = ""
        }
        historyReplayNotice = nil
        let isThreadSwitch = selectedThreadId != id
        // Same-thread re-select (rail click, host refreshAgentSurfaces, mark-read
        // fan-out) used to re-run the full open path: wipe timeline, reload
        // messages, re-fetch provider snapshot → multi-blink on an already-open
        // thread. Soft path keeps the painted transcript and only syncs chrome.
        if !isThreadSwitch {
            refreshManualAction()
            softReselectOpenThread(selectedThread, markRead: markRead)
            return
        }
        PerfSwitchMetrics.beginConversationSwitch(threadID: id.value.uuidString)
        // Full open path — only when the selected thread actually changes.
        selectThreadOpenGeneration &+= 1
        let openGeneration = selectThreadOpenGeneration
        Self.agentOpenTrace(
            "full open gen=\(openGeneration) thread=\(id.value.uuidString.prefix(8)) status=\(selectedThread.status.rawValue) markRead=\(markRead) hasUnread=\(selectedThread.hasUnread) updatedAt=\(selectedThread.updatedAt.timeIntervalSince1970)"
        )
        // IMP-MAC_AGENT-011: stash the leaving thread's draft before swapping,
        // then restore the opened thread's draft.
        if let previous = selectedThreadId {
            stashComposerDraftOffMain(for: previous)
            // A pending cold restore means `timeline` is an empty stand-in.
            if hiddenTimelineArchive == nil {
                rememberPaintedTimeline(previous, timeline)
            }
        }
        dropColdTimelineArchive()
        selectedThreadId = id
        subagentPollCoordinator?.subagentPollTargetMayBeLive()
        refreshManualAction()
        transcriptState.selectedThreadIdForPeerFlag = id
        transcriptState.waitingBotPeerActivity = AgentTranscriptState.hasWaitingBotPeerActivity(
            in: messages,
            threadId: id
        )
        PerfSwitchMetrics.markConversationFirstPublish()
        publishInterestedThreadId(id)
        providerThreadSnapshotStatusMessage = nil
        providerThreadSnapshotLastConfirmedAt = providerThreadSnapshotConfirmedAtByThread[id]
        // Per-thread provider state: the opened thread republishes its own
        // count on its next snapshot, so carrying the previous thread's
        // shell count over would advertise work that isn't this thread's.
        liveBackgroundShellCount = 0
        liveBackgroundTasks = []
        // Plan-suppression is per open thread session: do not carry a queued
        // follow-up suppress flag onto a different thread's durable plan.
        suppressStaleActivePlanUpdates = false
        // Persist the per-surface binding so app restart restores THIS surface
        // to THIS thread (not threads.first). Only fires on an actual change;
        // wired by the host after init, so restore-time selects don't re-persist.
        // PF-21: publish selection first; persist on the next main turn so the
        // click path is not blocked on workspace walk + surface.updated.
        let persistID = id
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectedThreadId == persistID else { return }
            self.onSelectedThreadChanged?(persistID)
        }
        // Thread-local queue status restore is in-memory; keep it synchronous so
        // the queue strip never carries the previous thread's lifecycle warning
        // across a switch. The queue rows themselves load with the open bundle
        // (perf AA-04).
        applyQueuedStatusForSelectedThread()
        let routing = selectedThread.effectiveRoutingConfiguration
        let manual = routing.manualSelection
        routingMode = routing.mode == .auto && manual.provider == .distill ? .manual : routing.mode
        provider = manual.provider
        providerInstanceId = routing.manualProviderInstanceId ?? manual.provider.rawValue
        runAsUser = selectedThread.runAsUser ?? AgentRunAsUser.current()
        selectedRunActor = selectedThread.actor
        model = manual.effectiveModel
        permissionMode = linkedBotVMRequiresFullAccess ? .fullAccess : selectedThread.permissionMode
        if linkedBotVMRequiresFullAccess, selectedThread.permissionMode != .fullAccess {
            setPermissionMode(.fullAccess, for: id)
        }
        reasoningEffort = manual.reasoningEffort
        reasoningModel = selectedThread.reasoningModel
        distillMainEffortSelection = manual.distillMainEffortSelection
            ?? .fixed(manual.reasoningEffort)
        distillReasoningEffortSelection = manual.distillReasoningEffortSelection ?? .automatic
        distillExecutionMode = manual.distillExecutionMode
        serviceTier = manual.serviceTier
        executionMode = selectedThread.executionMode
        baseBranch = selectedThread.baseBranch ?? gitBranch ?? "main"
        worktreePath = selectedThread.worktreePath
        status = selectedThread.status
        restoreComposerDraft(for: selectedThread)
        // Plan notes are per-thread: repoint the editor on the switch turn so the
        // leaving thread's notes cannot be read (or saved) as the opened thread's.
        // Cache miss paints empty until the open bundle's read lands.
        setPlanNotesWithoutSaving(planNotesByThread[id] ?? "", threadId: id)
        if let trackedRunId = trackedRunId(for: id) {
            // UX-XPLAT-008: the persisted run start time is read off-main by the
            // open bundle and resolved when it applies, so "Working for Xs"
            // still reflects real elapsed time after selectThread mid-run.
            // Clear the leaving thread's start time now so the gap frames never
            // paint the previous thread's elapsed time.
            // RUN-LIFECYCLE-STREAM-004: resync currentRunId to THIS thread's
            // active run. Without this, switching to an already-running
            // thread left a stale currentRunId from the previous thread, so
            // Stop could cancel the wrong thread's run.
            runStartedAt = nil
            currentRunId = trackedRunId
            stopScheduledLivePoll()
        } else if isScheduledThreadRunning?(id) == true {
            // Path B: LaunchAgent owns the provider process. This process has
            // no coordinator session, so the old branch cleared runStartedAt
            // and the UI stuck on "Working for 0s" even while tools ran.
            // Shared SQLite still has agent_runs.started_at + stream events.
            bindScheduledOwnedRun(threadId: id)
        } else {
            currentRunId = nil
            runStartedAt = nil
            stopScheduledLivePoll()
        }
        normalizeInteractionModeForSelectedProvider()
        if distillLive != nil { distillLive = nil }
        if let cachedTimeline = paintedTimelineByThread[id] {
            timeline = cachedTimeline
        } else {
            timeline = AssistantTimelineState()
        }
        messagePageLoadState = .pending
        loadAllMessages(id)
        focusTick &+= 1
        scheduleSelectThreadHydration(
            thread: selectedThread,
            markRead: markRead,
            openGeneration: openGeneration,
            probeExistence: lastThreadSelectionUsedRailForTesting
        )
    }

    func waitForSelectThreadHydrationForTesting() async {
        while let task = selectThreadHydrationTask {
            let generation = selectThreadOpenGeneration
            await task.value
            if selectThreadOpenGeneration == generation,
               selectThreadHydrationTask == nil {
                return
            }
        }
    }

    private static func waitForCommittedFrame() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func scheduleSelectThreadHydration(
        thread: AgentThread,
        markRead: Bool,
        openGeneration: UInt64,
        probeExistence: Bool
    ) {
        let id = thread.id
        selectThreadHydrationTask?.cancel()
        selectThreadHydrationTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self else { return }
            defer {
                if self.selectThreadOpenGeneration == openGeneration {
                    self.selectThreadHydrationTask = nil
                }
            }
            guard !Task.isCancelled,
                  self.selectThreadOpenGeneration == openGeneration,
                  self.selectedThreadId == id else { return }
            if probeExistence {
                do {
                    self.durableThreadExistenceProbeCountForTesting += 1
                    if self.embedding?.pinnedThreadId == id {
                        guard (try self.threadRepo.get(id: id)) != nil else {
                            if self.statusMessage.isEmpty {
                                self.statusMessage = "Could not open thread: The thread is no longer available."
                            }
                            self.retireUnbackedRailRow(id)
                            return
                        }
                    } else {
                        guard let durableWorkspace = try self.threadRepo.workspaceId(of: id) else {
                            if self.statusMessage.isEmpty {
                                self.statusMessage = "Could not open thread: The thread is no longer available."
                            }
                            // The stale rail row was already bound before this probe ran,
                            // so a missing durable row must undo the selection instead of
                            // leaving the surface open on a thread the store no longer has.
                            self.retireUnbackedRailRow(id)
                            return
                        }
                        guard durableWorkspace == self.workspaceID else {
                            if self.statusMessage.isEmpty {
                                self.statusMessage = "Could not open thread: The thread belongs to another workspace."
                            }
                            // The durable owner wins over the rail row: this surface must
                            // not stay bound to — or keep painting — another workspace's
                            // thread, and the row is stale here for the same reason.
                            self.retireUnbackedRailRow(id)
                            return
                        }
                    }
                } catch {
                    self.statusMessage = "Could not open thread: \(error)"
                    return
                }
            }
            if thread.effectiveRoutingConfiguration.mode == .auto,
               thread.effectiveRoutingConfiguration.manualSelection.provider == .distill {
                self.persistDistillManualRoutingIfNeeded(threadId: id)
            }
            await self.hydrateOpenedThread(
                thread,
                markRead: markRead,
                openGeneration: openGeneration
            )
        }
    }

    // MARK: Off-main thread open bundle (perf AA-02/AA-03/AA-04)

    /// Shared decoder for the off-main bundle path (see gatherThreadOpenBundle).
    private static let bundleCallbackDecodeLock = NSLock()
    private static let bundleCallbackDecoder = JSONDecoder()

    /// Everything a full thread open needs from SQLite + JSON decode + replay
    /// CPU, gathered in one detached pass. The open path used to run 8-10
    /// synchronous SQLite reads on the MainActor between click and first paint
    /// (including every checkpoint's full diff blobs) while the stream-persist
    /// writer held the same serial queue.
    struct AgentThreadOpenBundle: Sendable {
        var hasRecoverableContext = false
        var persistedEvents: [AssistantEvent] = []
        var hotReplayIsPartial = false
        var replayedTimeline = AssistantTimelineState()
        var errorRecoverable = false
        var durableActiveState: AgentActiveThreadState?
        var proposedPlans: [AgentProposedPlanRecord] = []
        var pendingCallbackEvents: [AssistantEvent] = []
        var checkpointSummaries: [AgentTurnCheckpointSummary] = []
        var planNotes: String?
        var planNotesFailed = false
        var queuedMessages: [AgentQueuedMessage] = []
        var runStartedAt: Date?
    }

    nonisolated static func gatherThreadOpenBundle(
        threadId: AgentThreadID,
        coordinator: AgentRunCoordinator,
        proposedPlanRepo: AgentProposedPlanRepository?,
        pendingCallbackRepo: ProviderPendingCallbackRepository?,
        checkpointRepo: AgentTurnCheckpointRepository?,
        planNotesStore: PlanNotesStore?,
        queuedMessageRepo: AgentQueuedMessageRepository?,
        includeRunStartedAt: Bool
    ) async -> AgentThreadOpenBundle {
        await Task.detached(priority: .userInitiated) {
            var bundle = AgentThreadOpenBundle()
            bundle.hasRecoverableContext = coordinator.hasRecoverableContext(threadId: threadId)
            let persistedEvents = coordinator.latestStreamEvents(threadId: threadId)
            bundle.persistedEvents = persistedEvents
            bundle.hotReplayIsPartial = coordinator.hotReplayIsPartial(threadId: threadId)
            let persistedReplay = chooseReplayEvents(persisted: persistedEvents, snapshot: nil)
            bundle.replayedTimeline = timelineByReplaying(persistedReplay)
            bundle.errorRecoverable = displayedErrorIsRecoverable(in: persistedReplay)
            bundle.durableActiveState = coordinator.durableActiveThreadState(threadId: threadId)
            if let proposedPlanRepo {
                bundle.proposedPlans = (try? proposedPlanRepo.list(threadId: threadId)) ?? []
            }
            if let pendingCallbackRepo {
                // Mirror of rehydratePendingCallbacks' decode, off-main.
                // SEP-3: share one decoder under a lock instead of allocating
                // per thread open (JSONDecoder is not thread-safe; this runs
                // in Task.detached, unlike the MainActor rehydrate path).
                let callbacks = (try? pendingCallbackRepo.listVisible(threadId: threadId)) ?? []
                var events: [AssistantEvent] = []
                for callback in callbacks {
                    guard let data = callback.payloadJSON.data(using: .utf8) else { continue }
                    switch callback.kind {
                    case .approval:
                        Self.bundleCallbackDecodeLock.lock()
                        let request = try? Self.bundleCallbackDecoder.decode(
                            AssistantPendingRequest.self, from: data
                        )
                        Self.bundleCallbackDecodeLock.unlock()
                        guard var request else { continue }
                        request.state = callback.state
                        request.resolvedAtMs = callback.resolvedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                        events.append(.requestOpened(request))
                    case .userInput:
                        Self.bundleCallbackDecodeLock.lock()
                        let userRequest = try? Self.bundleCallbackDecoder.decode(
                            AssistantUserInputRequest.self, from: data
                        )
                        Self.bundleCallbackDecodeLock.unlock()
                        guard var request = userRequest else { continue }
                        request.state = callback.state
                        request.resolvedAtMs = callback.resolvedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                        events.append(.userInputRequested(request))
                    }
                }
                bundle.pendingCallbackEvents = events
            }
            if let checkpointRepo {
                // Metadata-only (AA-03): diff blobs are fetched per selection,
                // never for the whole list on open.
                bundle.checkpointSummaries = (try? checkpointRepo.listSummaries(threadId: threadId)) ?? []
            }
            if let planNotesStore {
                do {
                    bundle.planNotes = try planNotesStore.load(threadId: threadId)
                } catch {
                    bundle.planNotes = ""
                    bundle.planNotesFailed = true
                }
            }
            if let queuedMessageRepo {
                bundle.queuedMessages = (try? queuedMessageRepo.list(threadId: threadId)) ?? []
            }
            if includeRunStartedAt {
                bundle.runStartedAt = try? coordinator.runStartedAt(threadId: threadId)
            }
            return bundle
        }.value
    }

    private func hydrateOpenedThread(
        _ selectedThread: AgentThread,
        markRead: Bool,
        openGeneration: UInt64
    ) async {
        let id = selectedThread.id
        // B6: the host owns the one throwing persistence + publication mutation.
        // Reflect success locally without re-querying; retain persisted rail state
        // when the mutation fails.
        if markRead, selectedThread.hasUnread, let markThreadRead {
            do {
                Self.agentOpenTrace("full open mark_read thread=\(id.value.uuidString.prefix(8))")
                try markThreadRead(id)
                if let idx = threads.firstIndex(where: { $0.id == id }) {
                    // Preserve rail activity time — only clear unread in memory.
                    threads[idx].hasUnread = false
                }
            } catch {
                reloadThreads()
            }
        }
        streamApplyGeneration &+= 1
        streamApplyInFlight = false
        streamFlushNeeded = false
        streamUIBackpressured = false
        streamAggregateBudgetOps = 0
        // No batch drain here: with the replay gathered off-main (perf AA-02), a
        // drained-but-unflushed event would be uncovered until the apply lands.
        // Buffered events instead flush onto the (pre- or post-apply) timeline,
        // and committed/dropped quanta are re-read from the durable window in
        // the apply-phase stability loop below.
        let streamActivityAtGatherStart = (streamQuantumCommits, streamQuantumDrops)
        // PERF (AA-02): every SQLite read, JSON decode and the replay itself now
        // run off-main in one detached pass; the MainActor applies the bundle in
        // a single publish guarded by open generation + selection.
        let bundle = await Self.gatherThreadOpenBundle(
            threadId: id,
            coordinator: coordinator,
            proposedPlanRepo: proposedPlanRepo,
            pendingCallbackRepo: pendingCallbackRepo,
            checkpointRepo: checkpointRepo,
            planNotesStore: planNotesStore,
            queuedMessageRepo: queuedMessageRepo,
            includeRunStartedAt: trackedRunId(for: id) != nil
        )
        guard !Task.isCancelled,
              selectThreadOpenGeneration == openGeneration,
              selectedThreadId == id else {
            Self.agentOpenTrace("open bundle dropped stale gen=\(openGeneration)")
            PerfSwitchMetrics.endConversationHydrate()
            return
        }
        var effective = bundle
        // Reconcile with stream activity that happened while the bundle was in
        // flight. Only quanta reduced from the pre-open timeline are dropped
        // (the generation bump); events still in the batch are NOT drained —
        // their flush applies them on top of the new timeline, which is exactly
        // where newer-than-replay events belong. Committed/dropped quanta are
        // re-read from the durable window (the coordinator persists before
        // notifying observers), looping until stable so the applied timeline is
        // never staler than what the user already saw. The final apply runs
        // synchronously on the MainActor, so nothing interleaves after the last
        // stability check.
        var stabilityAttempts = 0
        while stabilityAttempts < 3 {
            streamApplyGeneration &+= 1
            streamApplyInFlight = false
            let activityBeforeReread = (streamQuantumCommits, streamQuantumDrops)
            if activityBeforeReread != streamActivityAtGatherStart {
                Self.agentOpenTrace("open bundle re-reads durable window (stream activity during gather)")
                effective = await Self.rerefreshOpenBundleReplay(bundle: effective, threadId: id, coordinator: coordinator)
                guard !Task.isCancelled,
                      selectThreadOpenGeneration == openGeneration,
                      selectedThreadId == id else {
                    Self.agentOpenTrace("open re-replay dropped stale gen=\(openGeneration)")
                    PerfSwitchMetrics.endConversationHydrate()
                    return
                }
            }
            if (streamQuantumCommits, streamQuantumDrops) == activityBeforeReread {
                break
            }
            stabilityAttempts += 1
        }
        applyThreadOpenBundle(effective, thread: selectedThread, openGeneration: openGeneration)
    }

    /// Re-reads the durable replay window after stream events landed during the
    /// open bundle gather (perf AA-02): the durable rows are the complete,
    /// persisted record — the coordinator persists before notifying observers.
    nonisolated static func rerefreshOpenBundleReplay(
        bundle: AgentThreadOpenBundle,
        threadId: AgentThreadID,
        coordinator: AgentRunCoordinator
    ) async -> AgentThreadOpenBundle {
        var refreshed = bundle
        await Task.detached(priority: .userInitiated) {
            let events = coordinator.latestStreamEvents(threadId: threadId)
            let replay = chooseReplayEvents(persisted: events, snapshot: nil)
            refreshed.persistedEvents = events
            refreshed.replayedTimeline = timelineByReplaying(replay)
            refreshed.errorRecoverable = displayedErrorIsRecoverable(in: replay)
            refreshed.hotReplayIsPartial = coordinator.hotReplayIsPartial(threadId: threadId)
        }.value
        return refreshed
    }

    private func applyThreadOpenBundle(
        _ bundle: AgentThreadOpenBundle,
        thread selectedThread: AgentThread,
        openGeneration: UInt64
    ) {
        let id = selectedThread.id
        // UX-MAC_AGENT-CONTINUE: the newly selected thread may have been
        // interrupted by a relaunch and hold a recoverable provider session.
        selectedThreadHasRecoverableContext = bundle.hasRecoverableContext
        historyReplayNotice = bundle.hotReplayIsPartial ? Self.replayNoticeText(isPartial: true) : nil
        // PERF: open instantly from persisted events (no main-thread provider
        // round-trip). Build the first timeline off the previous published value
        // so SwiftUI sees one swap, not empty→partial apply ticks.
        // One publish of a fully-built timeline (not empty → apply-tick cascade).
        let paintedErrorBeforeOpen = timeline.error
        timeline = bundle.replayedTimeline
        // The replay read predates anything painted while it was in flight, so a
        // live error that landed during the open is strictly newer than the
        // bundle's error field (nil here when the replay window carries none).
        // Dropping it hides the run's failure and its Sign in / Retry action
        // until the next reload; the replay still wins when it has an error.
        if let paintedErrorBeforeOpen, timeline.error == nil {
            timeline.error = paintedErrorBeforeOpen
        }
        // The stream path may have displayed a NEWER error while the bundle was
        // in flight (its replay read predates that event; the re-replay loop
        // narrows but cannot fully close that window). The recoverability flag
        // must track the error actually displayed: when the painted error is
        // not the one the replay carries, the painted flag is newer — keep it.
        if paintedErrorBeforeOpen == nil || paintedErrorBeforeOpen == bundle.replayedTimeline.error {
            lastErrorRecoverable = bundle.errorRecoverable
        }
        rehydrateDurableActiveState(from: bundle.durableActiveState)
        // A pending follow-up means the user already superseded the prior Active
        // plan; keep it cleared across select/reopen until the next run starts.
        // Queued text stays in the queue UI only until drain starts the turn.
        restoreQueuedFollowupTranscriptPresentation(threadId: id)
        for record in bundle.proposedPlans {
            timeline.apply(.proposedPlan(record.plan))
        }
        for event in bundle.pendingCallbackEvents {
            timeline.apply(event)
        }
        applyCheckpointSummaries(bundle.checkpointSummaries)
        suppressPersistedFinalDuplicatedByTimeline()
        resetTimelineUpdateTick()
        applyQueuedMessagesFromOpenBundle(bundle.queuedMessages)
        if trackedRunId(for: id) != nil {
            // UX-XPLAT-008: use the host's persisted run start time so
            // "Working for Xs" reflects real elapsed time even after
            // selectThread is called mid-run (e.g. after app relaunch or
            // switching away and back). Fallback to Date() only when the
            // run record is not yet committed (race on the very first tick).
            runStartedAt = AgentAppViewModel.resolvedRunStartedAt(
                current: runStartedAt,
                persisted: bundle.runStartedAt
            )
        }
        scheduleDeferredProviderSnapshotIfNeeded(
            thread: selectedThread,
            persistedEvents: bundle.persistedEvents,
            openGeneration: openGeneration
        )
        // Do NOT auto-implement on select/reopen (pet, sidebar, restore). Opening a
        // thread is a view action — Full Access only auto-implements when a plan
        // arrives mid-stream, a run finishes with a pending plan, or the user
        // switches into full access on an already-open thread.
        // Restore persisted plan notes for the opened thread. A failed read must
        // not masquerade as absent notes and then overwrite the durable value.
        setPlanNotesWithoutSaving(bundle.planNotes ?? "", threadId: id)
        if bundle.planNotesFailed {
            // The value is unknown, not empty: never let the next switch paint
            // this failed read as the thread's cached notes.
            planNotesByThread.removeValue(forKey: id)
            statusMessage = "Could not load plan notes"
        }
        // Subagents is thread-scoped chrome: rebuild after first paint so
        // switching threads never keeps another thread's Active/Done counts.
        refreshSubagentActivity()
        rememberPaintedTimeline(id, timeline)
        Self.agentOpenTrace(
            "full open bundle applied gen=\(openGeneration) items=\(Self.renderableItemCount(bundle.persistedEvents)) turns=\(timeline.turns.count) recoverable=\(selectedThreadHasRecoverableContext)"
        )
        PerfSwitchMetrics.endConversationHydrate()
    }

    private func scheduleDeferredProviderSnapshotIfNeeded(
        thread selectedThread: AgentThread,
        persistedEvents: [AssistantEvent],
        openGeneration: UInt64
    ) {
        let id = selectedThread.id
        let persistedItemCount = Self.renderableItemCount(persistedEvents)
        let fetchSnapshot = Self.shouldFetchProviderSnapshotOnOpen(
            hasRecoverableContext: selectedThreadHasRecoverableContext,
            firstPaintItemCount: persistedItemCount,
            threadStatus: selectedThread.status
        )
        Self.agentOpenTrace(
            "full open firstPaint items=\(persistedItemCount) turns=\(timeline.turns.count) fetchSnapshot=\(fetchSnapshot) recoverable=\(selectedThreadHasRecoverableContext)"
        )
        guard fetchSnapshot else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.providerThreadSnapshotEvents(threadId: id)
                // Drop if the user switched threads OR a newer full open
                // superseded this task (soft reselect does not bump gen).
                guard self.selectedThreadId == id,
                      self.selectThreadOpenGeneration == openGeneration else {
                    Self.agentOpenTrace("deferred snapshot dropped stale gen=\(openGeneration)")
                    return
                }
                let confirmedAt = Date()
                self.providerThreadSnapshotConfirmedAtByThread[id] = confirmedAt
                self.providerThreadSnapshotLastConfirmedAt = confirmedAt
                self.providerThreadSnapshotStatusMessage = nil
                guard !snapshot.isEmpty else {
                    Self.agentOpenTrace("deferred snapshot empty thread=\(id.value.uuidString.prefix(8))")
                    return
                }
                let mergedSnapshot = self.mergePersistedContextTelemetry(
                    snapshot: snapshot,
                    persisted: persistedEvents
                )
                // Only replace the painted timeline when the provider has
                // STRICTLY more work items than local history. Equal/thinner
                // snapshots used to rebuild with a different event stream and
                // blink the same completed thread multiple times.
                let snapshotItemCount = Self.renderableItemCount(mergedSnapshot)
                let terminal = Self.isTerminalOpenStatus(selectedThread.status)
                let apply = Self.shouldApplyDeferredSnapshotReplay(
                    firstPaintItemCount: persistedItemCount,
                    deferredSnapshotItemCount: snapshotItemCount,
                    threadIsTerminal: terminal
                )
                Self.agentOpenTrace(
                    "deferred snapshot decide apply=\(apply) local=\(persistedItemCount) snap=\(snapshotItemCount) terminal=\(terminal) gen=\(openGeneration)"
                )
                guard apply else { return }
                let replayEvents = Self.chooseReplayEvents(
                    persisted: persistedEvents,
                    snapshot: mergedSnapshot
                )
                // Single atomic publish: never assign an empty intermediate timeline.
                Self.agentOpenTrace("deferred snapshot APPLY timeline rebuild gen=\(openGeneration)")
                self.timeline = Self.timelineByReplaying(replayEvents)
                self.rehydrateDurableActiveState(threadId: id)
                self.restoreQueuedFollowupTranscriptPresentation(threadId: id)
                self.rehydrateProposedPlans(threadId: id)
                self.rehydratePendingCallbacks(threadId: id)
                self.lastErrorRecoverable = Self.displayedErrorIsRecoverable(in: replayEvents)
            } catch {
                guard self.selectedThreadId == id,
                      self.selectThreadOpenGeneration == openGeneration else { return }
                let threadHasProviderContext = self.threads.first(where: { $0.id == id })?.providerThreadId?.isEmpty == false
                    || !persistedEvents.isEmpty
                guard threadHasProviderContext else { return }
                self.providerThreadSnapshotStatusMessage = Self.providerThreadSnapshotFailureMessage(
                    lastConfirmedAt: self.providerThreadSnapshotConfirmedAtByThread[id]
                )
            }
        }
    }

    /// Called by the plan sidebar whenever planNotes changes to persist the
    /// current text keyed by the active thread.
    public func savePlanNotes() {
        guard let id = selectedThreadId, let planNotesStore else { return }
        if let ignoredPlanNotesSave {
            self.ignoredPlanNotesSave = nil
            if ignoredPlanNotesSave.threadId == id, ignoredPlanNotesSave.notes == planNotes {
                return
            }
        }
        do {
            try planNotesStore.save(planNotes, threadId: id)
            planNotesByThread[id] = planNotes
            onPlanNotesPersisted?(id, planNotes)
        } catch {
            statusMessage = "Could not save plan notes: \(error)"
        }
    }

    /// Applies host-authoritative notes without re-entering the local save path
    /// when SwiftUI observes the programmatic property change.
    public func applyMirroredPlanNotes(_ notes: String, threadId: AgentThreadID) {
        guard selectedThreadId == threadId else { return }
        setPlanNotesWithoutSaving(notes, threadId: threadId)
    }

    private func setPlanNotesWithoutSaving(_ notes: String, threadId: AgentThreadID) {
        ignoredPlanNotesSave = (threadId, notes)
        planNotesByThread[threadId] = notes
        planNotes = notes
    }

    public func reloadQueuedMessages() {
        guard let selectedThreadId, let queuedMessageRepo else {
            applyQueuedMessagesReload([], for: selectedThreadId)
            return
        }
        let next = (try? queuedMessageRepo.list(threadId: selectedThreadId)) ?? []
        applyQueuedMessagesReload(next, for: selectedThreadId)
    }

    private var softReselectDurableGeneration: UInt64 = 0
    private var softReselectDurableTask: Task<Void, Never>?
    private(set) var softReselectDurableRefreshCountForTesting = 0

    /// PF-20: queue list, runStartedAt, and recoverable-context are SQLite/coordinator
    /// reads. Soft reselect used to take them on MainActor behind the writer.
    private func scheduleSoftReselectDurableRefresh(threadId: AgentThreadID) {
        guard surfaceVisibility != .hidden else { return }
        softReselectDurableGeneration &+= 1
        let generation = softReselectDurableGeneration
        let openGeneration = selectThreadOpenGeneration
        let queuedRepo = queuedMessageRepo
        let coordinator = coordinator
        softReselectDurableRefreshCountForTesting += 1
        softReselectDurableTask = Task.detached { [weak self] in
            let queued = (try? queuedRepo?.list(threadId: threadId)) ?? []
            let started = try? coordinator.runStartedAt(threadId: threadId)
            let recoverable = coordinator.hasRecoverableContext(threadId: threadId)
            await MainActor.run {
                guard let self,
                      self.softReselectDurableGeneration == generation,
                      self.selectThreadOpenGeneration == openGeneration,
                      self.selectedThreadId == threadId else { return }
                if self.provider == .distill && self.routingMode == .manual {
                    self.persistDistillManualRoutingIfNeeded(threadId: threadId)
                }
                self.applyQueuedMessagesReload(queued, for: threadId)
                let nextStarted = AgentAppViewModel.resolvedRunStartedAt(
                    current: self.runStartedAt,
                    persisted: started
                )
                if Self.shouldAssignIfChanged(current: self.runStartedAt, next: nextStarted) {
                    self.runStartedAt = nextStarted
                }
                if Self.shouldAssignIfChanged(
                    current: self.selectedThreadHasRecoverableContext,
                    next: recoverable
                ) {
                    self.selectedThreadHasRecoverableContext = recoverable
                }
            }
        }
    }

    func waitForSoftReselectDurableRefreshForTesting() async {
        await softReselectDurableTask?.value
    }

    /// Queue rows fetched off-main by the thread open bundle (perf AA-02/AA-04):
    /// the queue list no longer costs a synchronous SQLite read before the
    /// first paint.
    private func applyQueuedMessagesFromOpenBundle(_ next: [AgentQueuedMessage]) {
        applyQueuedMessagesReload(next, for: selectedThreadId)
    }

    /// In-memory thread-local queue status swap at selection time — no SQLite.
    private func applyQueuedStatusForSelectedThread() {
        let nextStatus = selectedThreadId.flatMap { queueStatusByThread[$0] }
        if queueStatusMessage != nextStatus {
            queueStatusMessage = nextStatus
        }
    }

    private func applyQueuedMessagesReload(_ next: [AgentQueuedMessage], for threadId: AgentThreadID?) {
        let nextStatus: String?
        if let threadId, let status = queueStatusByThread[threadId] {
            nextStatus = status
        } else if next.first?.durableState == .prepared {
            nextStatus = Self.preparedQueueStatusMessage
        } else {
            nextStatus = nil
        }
        // Soft reselect / host refresh re-enters here constantly. Re-assigning an
        // identical queue list republishes @Published queue chrome for no reason.
        guard Self.shouldPublishQueuedMessagesReload(
            current: queuedMessages,
            next: next,
            currentStatus: queueStatusMessage,
            nextStatus: nextStatus
        ) else { return }
        queuedMessages = next
        queueStatusMessage = nextStatus
    }

    /// Skip equal queue + status reloads (soft reselect multipass publish).
    nonisolated public static func shouldPublishQueuedMessagesReload(
        current: [AgentQueuedMessage],
        next: [AgentQueuedMessage],
        currentStatus: String?,
        nextStatus: String?
    ) -> Bool {
        current != next || currentStatus != nextStatus
    }

    private static let preparedQueueStatusMessage =
        "Start confirmation is pending. Check status before deciding whether to remove this queue record."

    private func setQueueStatus(_ message: String?, threadId: AgentThreadID) {
        if let message {
            queueStatusByThread[threadId] = message
        } else {
            queueStatusByThread.removeValue(forKey: threadId)
        }
        if selectedThreadId == threadId {
            queueStatusMessage = message
        }
    }

    public func canForceQueuedMessage(_ message: AgentQueuedMessage) -> Bool {
        true
    }

    public func queuedMessageForceLabel(_ message: AgentQueuedMessage) -> String {
        switch message.durableState ?? .queued {
        case .queued:
            return "Force"
        case .prepared:
            return "Check status"
        case .dispatched:
            return "Finish cleanup"
        }
    }

    public func queuedMessagePrimaryActionAccessibilityLabel(
        _ message: AgentQueuedMessage
    ) -> String {
        switch message.durableState ?? .queued {
        case .queued:
            return "Force queued message \(message.position) now"
        case .prepared:
            return "Check queued message \(message.position) provider status"
        case .dispatched:
            return "Finish queued message \(message.position) cleanup"
        }
    }

    public func queuedMessageDurableStatus(_ message: AgentQueuedMessage) -> String? {
        switch message.durableState ?? .queued {
        case .queued:
            return nil
        case .prepared:
            return "Provider acceptance is unresolved. The message is retained to prevent duplicate work."
        case .dispatched:
            return "Provider start was confirmed. Queue acknowledgement is being recovered."
        }
    }

    public func editQueuedMessage(_ message: AgentQueuedMessage) {
        editingQueuedMessage = message
        queuedMessageDraft = message.text
        setQueueStatus(nil, threadId: message.threadId)
    }

    public func saveQueuedMessageEdit() {
        guard let editingQueuedMessage, let queuedMessageRepo else { return }
        let text = queuedMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !editingQueuedMessage.attachments.isEmpty else { return }
        do {
            if let updated = try queuedMessageRepo.update(id: editingQueuedMessage.id, text: text, attachments: editingQueuedMessage.attachments) {
                setQueueStatus(nil, threadId: editingQueuedMessage.threadId)
                self.editingQueuedMessage = nil
                queuedMessageDraft = ""
                // Queue edits stay in the queue UI only. The transcript bubble is
                // created when the message drains and the provider turn starts.
                reloadQueuedMessages()
                onQueuedMessageEvent?(AgentQueueEventKinds.updated, updated)
            } else {
                self.editingQueuedMessage = nil
                queuedMessageDraft = ""
                reloadQueuedMessages()
                setQueueStatus("Already processing.", threadId: editingQueuedMessage.threadId)
            }
        } catch {
            setQueueStatus(
                "Queue edit failed: \(error)",
                threadId: editingQueuedMessage.threadId
            )
        }
    }

    public func forceQueuedMessageNow(_ message: AgentQueuedMessage) async {
        guard let forceQueuedMessage else {
            setQueueStatus(
                "Queue action is unavailable while the app router is not ready.",
                threadId: message.threadId
            )
            return
        }
        let statusBeforeAction = queueStatusByThread[message.threadId]
        do {
            let result = try await forceQueuedMessage(message.id)
            reloadQueuedMessages()
            if result.status == .queued {
                setQueueStatus(
                    "Stopping current run to start this now.",
                    threadId: message.threadId
                )
            } else {
                setQueueStatus(nil, threadId: message.threadId)
            }
        } catch {
            let hostStatus = queueStatusByThread[message.threadId]
            reloadQueuedMessages()
            if hostStatus != statusBeforeAction, let hostStatus {
                setQueueStatus(hostStatus, threadId: message.threadId)
                return
            }
            let prefix = message.durableState == .queued
                ? "Queue force failed"
                : "Queue status check failed"
            setQueueStatus("\(prefix): \(error)", threadId: message.threadId)
        }
    }

    public func cancelQueuedMessage(_ message: AgentQueuedMessage) {
        removeQueuedMessage(message)
    }

    public func removeQueuedMessage(_ message: AgentQueuedMessage) {
        guard let queuedMessageRepo else { return }
        do {
            let removed: AgentQueuedMessage?
            switch message.durableState ?? .queued {
            case .queued:
                removed = try queuedMessageRepo.delete(id: message.id)
            case .prepared:
                removed = try queuedMessageRepo.abandonPrepared(id: message.id)
            case .dispatched:
                setQueueStatus(
                    "Provider start was confirmed. Use Finish cleanup instead of removing this message.",
                    threadId: message.threadId
                )
                return
            }
            if let cancelled = removed {
                if editingQueuedMessage?.id == message.id {
                    editingQueuedMessage = nil
                    queuedMessageDraft = ""
                }
                // Defensive: remove any leftover in-memory mirror from older
                // builds that mirrored queued text into the transcript. Only
                // drop when not yet durable under that id (drain/start persist).
                let mirrorId = AgentMessageID(cancelled.id.value)
                if (try? messageRepo.exists(id: mirrorId)) != true,
                   let idx = messages.firstIndex(where: { $0.id == mirrorId }) {
                    messages.remove(at: idx)
                }
                if queuedMessages.count <= 1 {
                    // Last queued follow-up cancelled: allow plan events again
                    // for the still-running turn (if any).
                    suppressStaleActivePlanUpdates = false
                }
                reloadQueuedMessages()
                onQueuedMessageEvent?(AgentQueueEventKinds.cancelled, cancelled)
            } else {
                reloadQueuedMessages()
                setQueueStatus(
                    "Queue state changed before removal. Check status and try again.",
                    threadId: message.threadId
                )
            }
        } catch {
            setQueueStatus(
                "Queue removal failed: \(error)",
                threadId: message.threadId
            )
        }
    }

    /// Pure reorder helper: moves the element at `from` to `to` within `queue`.
    /// Out-of-bounds indices or a single-item queue are no-ops.
    /// Positions in returned elements are NOT updated — caller persists as needed.
    /// public: reused by AppCommandRouter's agent.message.queue.reorder RPC so
    /// the mirror path performs the same mutation as the mac drag-reorder.
    nonisolated public static func reorderQueue(
        _ queue: [AgentQueuedMessage],
        from: Int,
        to: Int
    ) -> [AgentQueuedMessage] {
        guard queue.count > 1,
              queue.indices.contains(from),
              queue.indices.contains(to),
              from != to else { return queue }
        var result = queue
        let item = result.remove(at: from)
        result.insert(item, at: to)
        return result
    }

    /// Reorders a queued message from one index to another, persisting new positions.
    public func reorderQueuedMessage(from: IndexSet, to: Int) {
        guard let queuedMessageRepo, let fromIndex = from.first else { return }
        // SwiftUI List onMove passes destination after removal; normalise to an
        // inclusive target index so the pure helper contract is simple.
        let dest = fromIndex < to ? to - 1 : to
        let reordered = AgentAppViewModel.reorderQueue(queuedMessages, from: fromIndex, to: dest)
        do {
            let now = Date()
            for (index, var message) in reordered.enumerated() {
                message.position = index + 1
                message.updatedAt = now
                try queuedMessageRepo.upsert(message)
            }
            reloadQueuedMessages()
            for queued in queuedMessages {
                onQueuedMessageEvent?(AgentQueueEventKinds.updated, queued)
            }
        } catch {
            if let selectedThreadId {
                setQueueStatus("Queue reorder failed: \(error)", threadId: selectedThreadId)
            }
        }
    }


    public func reloadCheckpoints() {
        guard let selectedThreadId, let checkpointRepo else {
            guard Self.shouldPublishCheckpointReload(
                current: checkpoints,
                next: [],
                selectedTurnCount: selectedCheckpointTurnCount
            ) else { return }
            checkpoints = []
            selectedCheckpointTurnCount = nil
            selectedCheckpointPath = nil
            return
        }
        // Metadata-only (perf AA-03): diff blobs are never read for the whole list.
        let loaded = (try? checkpointRepo.listSummaries(threadId: selectedThreadId)) ?? []
        applyCheckpointSummaries(loaded)
    }

    /// Publishes a metadata-only checkpoint list and (re)selects a checkpoint.
    private func applyCheckpointSummaries(_ loaded: [AgentTurnCheckpointSummary]) {
        let next = Array(loaded.reversed())
        // Soft reselect / host refresh re-enters here every time. Re-assigning an
        // identical list re-selected the same checkpoint and rewrote the diff
        // preview string — unnecessary @Published churn on an already-open thread.
        guard Self.shouldPublishCheckpointReload(
            current: checkpoints,
            next: next,
            selectedTurnCount: selectedCheckpointTurnCount
        ) else { return }
        checkpoints = next
        if let selected = selectedCheckpointTurnCount,
           let checkpoint = checkpoints.first(where: { $0.checkpointTurnCount == selected }) {
            selectCheckpoint(checkpoint, path: selectedCheckpointPath)
        } else if let first = checkpoints.first {
            selectCheckpoint(first, path: nil)
        } else {
            selectedCheckpointTurnCount = nil
            selectedCheckpointPath = nil
        }
    }

    /// Whether a checkpoint reload must publish. Equal lists with a still-valid
    /// selection (or both empty) skip — soft reselect must not multipass-repaint.
    nonisolated public static func shouldPublishCheckpointReload(
        current: [AgentTurnCheckpointSummary],
        next: [AgentTurnCheckpointSummary],
        selectedTurnCount: Int?
    ) -> Bool {
        if next != current { return true }
        if next.isEmpty {
            return selectedTurnCount != nil
        }
        guard let selected = selectedTurnCount else {
            // Non-empty list with no selection needs a default select.
            return true
        }
        return !next.contains(where: { $0.checkpointTurnCount == selected })
    }

    public func revealCheckpoint(checkpointTurnCount: Int, expectedRunID: AgentRunID, path: String?) async throws {
        guard let threadId = selectedThreadId, let checkpointRepo else {
            throw AgentAppSurfaceCheckpointRevealError.notFound
        }
        let generation = selectThreadOpenGeneration
        let repository = checkpointRepo
        let fetched = try await Task.detached(priority: .userInitiated) {
            try repository.get(threadId: threadId, checkpointTurnCount: checkpointTurnCount)
        }.value
        guard !Task.isCancelled, selectThreadOpenGeneration == generation, selectedThreadId == threadId else {
            throw CancellationError()
        }
        guard let fetched, fetched.runId == expectedRunID,
              path == nil || fetched.files.contains(where: { $0.path == path }) else {
            throw AgentAppSurfaceCheckpointRevealError.notFound
        }
        let summary = checkpoints.first(where: { $0.checkpointTurnCount == checkpointTurnCount && $0.runId == expectedRunID })
            ?? AgentTurnCheckpointSummary(
                threadId: fetched.threadId, runId: fetched.runId, turnId: fetched.turnId,
                checkpointTurnCount: fetched.checkpointTurnCount, checkpointRef: fetched.checkpointRef,
                status: fetched.status, files: fetched.files, completedAt: fetched.completedAt
            )
        guard summary.runId == expectedRunID else { throw AgentAppSurfaceCheckpointRevealError.notFound }
        if !checkpoints.contains(where: { $0.checkpointTurnCount == checkpointTurnCount && $0.runId == expectedRunID }) {
            checkpoints.append(summary)
        }
        selectCheckpoint(summary, path: path)
    }

    public func selectCheckpoint(_ checkpoint: AgentTurnCheckpointSummary, path: String?) {
        selectedCheckpointTurnCount = checkpoint.checkpointTurnCount
        selectedCheckpointPath = path
        checkpointStatusMessage = nil
    }

    nonisolated public static func canRevertCheckpoint(
        status: AgentTurnCheckpointStatus,
        capabilities: AgentProviderCapabilities
    ) -> Bool {
        status == .ready && capabilities.supportsRollback
    }

    public var selectedProviderCapabilities: AgentProviderCapabilities {
        selectedProviderSnapshot?.effectiveCapabilities ?? .conservative
    }

    public var supportsPlanInteractionForSelectedProvider: Bool {
        if let snapshot = selectedProviderSnapshot {
            return snapshot.interactionModes.contains(.plan)
        }
        // Startup may briefly precede snapshot discovery. Codex and Claude
        // have native Plan contracts; Grok stays fail-closed until its ACP
        // session advertises a Plan mode and discovery can surface it.
        return provider != .grok
    }

    public var planInteractionUnavailableReason: String? {
        guard !supportsPlanInteractionForSelectedProvider else { return nil }
        return "\(providerDisplayName(provider)) does not support Plan mode for this session."
    }

    public var supportedPermissionModesForSelectedProvider: [AgentPermissionMode] {
        if let snapshot = selectedProviderSnapshot {
            return snapshot.effectivePermissionModes
        }
        // Pre-discovery: Grok CLI/ACP supports the full permission set even when
        // session/new omits modes. Keep parity with Codex/Claude until a snapshot
        // narrows the negotiated subset.
        return AgentPermissionMode.allCases
    }

    public func permissionModeUnavailableReason(_ mode: AgentPermissionMode) -> String? {
        guard !supportedPermissionModesForSelectedProvider.contains(mode) else { return nil }
        return "\(providerDisplayName(provider)) does not support \(mode.displayName) for this session."
    }

    public var threadForkUnavailableReason: String? {
        guard !selectedProviderCapabilities.supportsFork else { return nil }
        return "\(providerDisplayName(provider)) does not support provider-side fork for this session."
    }

    public var checkpointRevertUnavailableReason: String? {
        guard !selectedProviderCapabilities.supportsRollback else { return nil }
        return "\(providerDisplayName(provider)) does not support provider-side rollback for this session."
    }

    public func revertSelectedCheckpoint() {
        guard let selectedThreadId, let turnCount = selectedCheckpointTurnCount else { return }
        guard selectedProviderCapabilities.supportsRollback else {
            checkpointStatusMessage = checkpointRevertUnavailableReason
            return
        }
        Task { @MainActor in
            do {
                _ = try await coordinator.revertThreadToCheckpoint(threadId: selectedThreadId, checkpointTurnCount: turnCount, cwd: cwd)
                // PERF-MAC_AGENT-006/012: revert deleted assistant rows — drop both caches.
                lastPersistedAssistantContentByThread.removeValue(forKey: selectedThreadId)
                lastPersistedFinalIdByThread.removeValue(forKey: selectedThreadId)
                checkpointStatusMessage = "Reverted to checkpoint \(turnCount)."
                loadAllMessages(selectedThreadId)
                reloadCheckpoints()
                reloadThreads()
                armCheckpointRevertUndo(CheckpointRevertUndoToast(
                    threadId: selectedThreadId,
                    cwd: cwd,
                    checkpointTurnCount: turnCount,
                    capturedAt: currentTime()
                ))
            } catch {
                checkpointStatusMessage = "Revert failed: \(error.localizedDescription)"
            }
        }
    }

    private func providerThreadSnapshotEvents(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        try await coordinator.readThread(threadId: threadId)
    }

    nonisolated public static func providerThreadSnapshotFailureMessage(lastConfirmedAt: Date?) -> String {
        let confirmed = lastConfirmedAt.map {
            $0.formatted(date: .omitted, time: .standard)
        } ?? "not yet confirmed this session"
        return "Provider snapshot unavailable. Showing persisted local state; last provider confirmation: \(confirmed)."
    }

    /// An interrupted session must remain disconnected until the user chooses
    /// Continue. Auto-recovering it for a background snapshot races the explicit
    /// resume and can create two app-server clients for one local thread.
    nonisolated public static func shouldReadProviderSnapshot(hasRecoverableContext: Bool) -> Bool {
        !hasRecoverableContext
    }

    /// Whether opening a thread should start a background provider snapshot fetch.
    /// Terminal threads that already painted local history must not — the deferred
    /// apply was the residual multipass blink after first paint had text.
    nonisolated public static func shouldFetchProviderSnapshotOnOpen(
        hasRecoverableContext: Bool,
        firstPaintItemCount: Int,
        threadStatus: AgentRunStatus
    ) -> Bool {
        guard shouldReadProviderSnapshot(hasRecoverableContext: hasRecoverableContext) else {
            return false
        }
        if firstPaintItemCount > 0, isTerminalOpenStatus(threadStatus) {
            return false
        }
        return true
    }

    nonisolated public static func isTerminalOpenStatus(_ status: AgentRunStatus) -> Bool {
        switch status {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        case .pending, .running:
            return false
        }
    }

    /// Soft reselect may skip durable message page reload when the hot list
    /// already shows this thread (avoids messages= swap flashing the open view).
    nonisolated public static func shouldReloadMessagesOnSoftReselect(
        selectedThreadId: AgentThreadID,
        messagesThreadIds: [AgentThreadID]
    ) -> Bool {
        guard !messagesThreadIds.isEmpty else { return true }
        // Any row from another thread means the list is stale for this selection.
        if messagesThreadIds.contains(where: { $0 != selectedThreadId }) { return true }
        return false
    }

    /// Soft reselect chrome: only write @Published when the value actually changes.
    /// WHY: host refresh / rail re-click re-entered soft reselect and reassigned
    /// identical provider/model/status fields, multipass-churning the open body.
    nonisolated public static func shouldAssignIfChanged<T: Equatable>(
        current: T,
        next: T
    ) -> Bool {
        current != next
    }

    /// Mark-read must clear unread without rewriting activity time (rail "now").
    nonisolated public static func applyingMarkReadPreservingActivity(_ thread: AgentThread) -> AgentThread {
        var next = thread
        next.hasUnread = false
        // Explicit: do not touch updatedAt.
        return next
    }

    /// Grep-friendly open-path diagnostics. Enable with env REMOTE_CODE_AGENT_OPEN_TRACE=1
    /// or UserDefaults remotecode.agentOpenTrace. Always cheap to call when disabled.
    nonisolated static var agentOpenTraceEnabled: Bool {
        if ProcessInfo.processInfo.environment["REMOTE_CODE_AGENT_OPEN_TRACE"] == "1" { return true }
        if UserDefaults.standard.bool(forKey: "remotecode.agentOpenTrace") { return true }
        // Default ON in DEBUG so residual multipass is attributable during smoke.
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    nonisolated static func agentOpenTrace(_ message: String) {
        guard agentOpenTraceEnabled else { return }
        NSLog("[AgentOpen] %@", message)
    }

    public func retryProviderThreadSnapshotRead() {
        guard let selectedThreadId else { return }
        selectThread(selectedThreadId, markRead: false)
    }

    private func mergePersistedContextTelemetry(snapshot: [AssistantEvent], persisted: [AssistantEvent]) -> [AssistantEvent] {
        var merged = snapshot
        if !snapshot.contains(where: { if case .tokenUsage = $0 { return true }; return false }),
           let usage = persisted.reversed().compactMap({ event -> AssistantTokenUsage? in
               if case .tokenUsage(let usage) = event { return usage }
               return nil
           }).first {
            merged.append(.tokenUsage(usage))
        }
        if !snapshot.contains(where: { if case .contextCompaction = $0 { return true }; return false }),
           let summary = persisted.reversed().compactMap({ event -> String?? in
               if case .contextCompaction(let summary) = event { return .some(summary) }
               return nil
           }).first {
            merged.append(.contextCompaction(summary: summary))
        }
        return merged
    }

    /// Pick the replay source that reconstructs MORE of the thread. The provider snapshot
    /// (Codex `thread/read`) is context-compacted: once the model auto-compacts, it drops the
    /// older turns and returns only the recent tail — so for a long thread it shows the thread
    /// "cortado". Our persisted stream events are the full local record (pruned only at ~5000).
    /// Displaying whichever is fuller means reopening a compacted thread shows 100% of its
    /// turns, while threads imported from an external provider session (no/thin persisted
    /// history) still fall back to the snapshot.
    nonisolated static func chooseReplayEvents(persisted: [AssistantEvent], snapshot: [AssistantEvent]?) -> [AssistantEvent] {
        guard let snapshot else { return persisted }
        guard renderableItemCount(persisted) <= renderableItemCount(snapshot) else { return persisted }
        return snapshotPreservingPersistedHostMetadata(snapshot, persisted: persisted)
    }

    /// Provider snapshots can be richer than local replay, but cannot recreate
    /// host-owned attestations. Pair the same turn occurrence, then the same
    /// `(id, type)` ordinal within that turn. Provider timestamps and turn IDs
    /// are adapter-local and cannot safely participate in replay identity.
    nonisolated private static func snapshotPreservingPersistedHostMetadata(
        _ snapshot: [AssistantEvent],
        persisted: [AssistantEvent]
    ) -> [AssistantEvent] {
        let providerSnapshot = snapshot.filter { event in
            if case .itemHostMetadata = event { return false }
            return true
        }
        guard persisted.contains(where: { event in
            if case .itemHostMetadata(_, _, let applied, _) = event { return applied == true }
            return false
        }) else { return providerSnapshot }
        let persistedOccurrences = replayItemOccurrences(persisted)
        let snapshotOccurrences = replayItemOccurrences(providerSnapshot)
        var insertions: [(afterEventIndex: Int, occurrenceSequence: Int, event: AssistantEvent)] = []
        var insertedOccurrenceSequences = Set<Int>()
        let fallback = renderableItemCount(persisted) > 0 ? persisted : providerSnapshot

        for (turnOrdinal, persistedTurn) in persistedOccurrences.turns.enumerated() {
            var occurrenceCountByIdentity: [String: Int] = [:]
            occurrenceCountByIdentity.reserveCapacity(persistedTurn.items.count)
            // Pre-index snapshot occurrences once per turn so attested pairing
            // stays O(items) instead of filtering the whole turn per item.
            var snapshotItemsByIdentity: [String: [ReplayItemOccurrence]] = [:]
            if snapshotOccurrences.turns.indices.contains(turnOrdinal) {
                let snapshotOccurrenceTurn = snapshotOccurrences.turns[turnOrdinal]
                snapshotItemsByIdentity.reserveCapacity(snapshotOccurrenceTurn.items.count)
                for item in snapshotOccurrenceTurn.items {
                    let identity = "\(item.id)\u{1f}\(item.type.rawValue)"
                    snapshotItemsByIdentity[identity, default: []].append(item)
                }
            }
            for persistedItem in persistedTurn.items {
                let identity = "\(persistedItem.id)\u{1f}\(persistedItem.type.rawValue)"
                let itemOrdinal = occurrenceCountByIdentity[identity, default: 0]
                occurrenceCountByIdentity[identity, default: 0] = itemOrdinal + 1
                guard persistedItem.distillApplied == true else { continue }
                guard snapshotOccurrences.turns.indices.contains(turnOrdinal) else {
                    return fallback
                }
                let snapshotOccurrenceTurn = snapshotOccurrences.turns[turnOrdinal]
                let occurrenceMatches = snapshotItemsByIdentity[identity] ?? []
                guard occurrenceMatches.indices.contains(itemOrdinal),
                      replayOccurrenceMatches(
                          persistedItem,
                          occurrenceMatches[itemOrdinal]
                      ) else {
                    // A richer snapshot is not worth losing or moving durable host
                    // truth. Keep the exact persisted replay when occurrences no
                    // longer pair or provider history changed attested bytes.
                    return fallback
                }
                let snapshotItem = occurrenceMatches[itemOrdinal]
                guard insertedOccurrenceSequences.insert(snapshotItem.sequence).inserted else {
                    return fallback
                }
                insertions.append((
                    snapshotItem.lastEventIndex,
                    snapshotItem.sequence,
                    .itemHostMetadata(
                        turnId: snapshotOccurrenceTurn.id,
                        itemId: snapshotItem.id,
                        distillApplied: true,
                        attestation: persistedItem.attestation
                    )
                ))
            }
        }

        for orphan in persistedOccurrences.orphanAttestations {
            guard let attestation = orphan.attestation,
                  attestation.isWellFormed else {
                return fallback
            }
            let candidates = snapshotOccurrences.turns.flatMap { turn in
                turn.items.filter { item in
                    item.id == orphan.itemID
                        && item.type == attestation.itemType
                        && item.matches(attestation)
                }.map { (turn, $0) }
            }
            guard candidates.count == 1, let candidate = candidates.first else {
                return fallback
            }
            guard insertedOccurrenceSequences.insert(candidate.1.sequence).inserted else {
                return fallback
            }
            insertions.append((
                candidate.1.lastEventIndex,
                candidate.1.sequence,
                .itemHostMetadata(
                    turnId: candidate.0.id,
                    itemId: candidate.1.id,
                    distillApplied: true,
                    attestation: attestation
                )
            ))
        }
        let insertionsByIndex = Dictionary(grouping: insertions, by: \.afterEventIndex)
        var merged: [AssistantEvent] = []
        merged.reserveCapacity(providerSnapshot.count + insertions.count)
        for (eventIndex, event) in providerSnapshot.enumerated() {
            merged.append(event)
            for insertion in (insertionsByIndex[eventIndex] ?? [])
                .sorted(by: { $0.occurrenceSequence < $1.occurrenceSequence }) {
                merged.append(insertion.event)
            }
        }
        return merged
    }

    nonisolated private static func replayOccurrenceMatches(
        _ persisted: ReplayItemOccurrence,
        _ snapshot: ReplayItemOccurrence
    ) -> Bool {
        if let attestation = persisted.attestation {
            return persisted.matches(attestation) && snapshot.matches(attestation)
        }
        return persisted.body.fingerprint == snapshot.body.fingerprint
            && persisted.output?.fingerprint == snapshot.output?.fingerprint
    }

    private struct ReplayItemOccurrence: Sendable {
        let sequence: Int
        var lastEventIndex: Int
        let id: String
        let type: AssistantItemType
        var body: ReplayContentFingerprintBuilder
        var output: ReplayContentFingerprintBuilder?
        var distillApplied = false
        var attestation: AssistantItemHostAttestation?

        func matches(_ attestation: AssistantItemHostAttestation) -> Bool {
            attestation.isWellFormed
                && type == attestation.itemType
                && body.fingerprint == attestation.body
                && output?.fingerprint == attestation.output
        }
    }

    private struct ReplayTurnOccurrence: Sendable {
        let id: String
        var items: [ReplayItemOccurrence] = []
    }

    private struct ReplayContentFingerprintBuilder: Sendable {
        private var hasher = SHA256()
        private(set) var byteCount = 0

        init(_ text: String = "") {
            append(text)
        }

        mutating func append(_ text: String) {
            guard !text.isEmpty else { return }
            let data = Data(text.utf8)
            byteCount += data.count
            hasher.update(data: data)
        }

        var fingerprint: AssistantContentFingerprint {
            var finalHasher = hasher
            return AssistantContentFingerprint(
                byteCount: byteCount,
                sha256: Data(finalHasher.finalize())
            )
        }
    }

    private struct ReplayHostMetadataKey: Hashable {
        let turnID: String
        let itemID: String
    }

    private struct ReplayOrphanAttestation: Sendable {
        let key: ReplayHostMetadataKey
        let attestation: AssistantItemHostAttestation?

        var itemID: String { key.itemID }
    }

    private struct ReplayOccurrenceState: Sendable {
        var turns: [ReplayTurnOccurrence] = []
        var orphanAttestations: [ReplayOrphanAttestation] = []
    }

    /// Replays content while assigning a fresh internal identity to every raw
    /// itemStarted event. The production timeline intentionally merges duplicate
    /// provider IDs for paint; replay trust must observe those occurrences first.
    nonisolated private static func replayItemOccurrences(
        _ events: [AssistantEvent]
    ) -> ReplayOccurrenceState {
        var state = ReplayOccurrenceState()
        var latestTurnIndexByID: [String: Int] = [:]
        var latestItemLocationByID: [String: (turn: Int, item: Int)] = [:]
        var nextItemSequence = 0

        func appendTurn(_ turnID: String) -> Int {
            state.turns.append(ReplayTurnOccurrence(id: turnID))
            let index = state.turns.index(before: state.turns.endIndex)
            latestTurnIndexByID[turnID] = index
            return index
        }

        for (eventIndex, event) in events.enumerated() {
            switch event {
            case .turnStarted(let turnID):
                _ = appendTurn(turnID)

            case .itemStarted(let item):
                let turnIndex = latestTurnIndexByID[item.turnId] ?? appendTurn(item.turnId)
                var occurrence = ReplayItemOccurrence(
                    sequence: nextItemSequence,
                    lastEventIndex: eventIndex,
                    id: item.id,
                    type: item.type,
                    body: ReplayContentFingerprintBuilder(item.body),
                    output: item.output.map(ReplayContentFingerprintBuilder.init)
                )
                nextItemSequence += 1
                let metadataKey = ReplayHostMetadataKey(
                    turnID: item.turnId,
                    itemID: item.id
                )
                if let pendingIndex = state.orphanAttestations.lastIndex(where: { $0.key == metadataKey }) {
                    let pending = state.orphanAttestations.remove(at: pendingIndex)
                    occurrence.distillApplied = true
                    occurrence.attestation = pending.attestation
                }
                state.turns[turnIndex].items.append(occurrence)
                latestItemLocationByID[item.id] = (
                    turn: turnIndex,
                    item: state.turns[turnIndex].items.index(before: state.turns[turnIndex].items.endIndex)
                )

            case .itemDelta(let itemID, let bodyAppend, let outputAppend, _):
                if let location = latestItemLocationByID[itemID] {
                    state.turns[location.turn].items[location.item].lastEventIndex = eventIndex
                    if let bodyAppend {
                        state.turns[location.turn].items[location.item].body.append(bodyAppend)
                    }
                    if let outputAppend {
                        if state.turns[location.turn].items[location.item].output == nil {
                            state.turns[location.turn].items[location.item].output =
                                ReplayContentFingerprintBuilder()
                        }
                        state.turns[location.turn].items[location.item].output?.append(outputAppend)
                    }
                }

            case .itemState(let itemID, _),
                 .itemProgress(let itemID, _),
                 .itemCompleted(let itemID, _):
                if let location = latestItemLocationByID[itemID] {
                    state.turns[location.turn].items[location.item].lastEventIndex = eventIndex
                }

            case .itemHostMetadata(let turnID, let itemID, let distillApplied, let attestation):
                guard distillApplied == true else { continue }
                if let turnIndex = latestTurnIndexByID[turnID],
                   let itemIndex = state.turns[turnIndex].items.lastIndex(where: { $0.id == itemID }) {
                    state.turns[turnIndex].items[itemIndex].distillApplied = true
                    state.turns[turnIndex].items[itemIndex].attestation = attestation
                } else {
                    state.orphanAttestations.append(ReplayOrphanAttestation(
                        key: ReplayHostMetadataKey(turnID: turnID, itemID: itemID),
                        attestation: attestation
                    ))
                }

            default:
                break
            }
        }
        return state
    }

    nonisolated static func renderableItemCount(_ events: [AssistantEvent]) -> Int {
        events.reduce(0) { count, event in
            if case .itemStarted = event { return count + 1 }
            return count
        }
    }

    /// Cheap paint identity for open-thread replay. Used to skip a second
    /// full timeline wipe when the deferred provider snapshot would rebuild
    /// the same content already shown from local events (blink fix).
    nonisolated static func replayPaintFingerprint(_ events: [AssistantEvent]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(events.count)
        for event in events {
            switch event {
            case .threadStarted(let threadId, let providerThreadId):
                parts.append("ts:\(threadId):\(providerThreadId ?? "")")
            case .turnStarted(let turnId):
                parts.append("t+:\(turnId)")
            case .turnCompleted(let turnId, let finalMessage):
                // Cap final so fingerprints stay cheap on huge answers.
                let final = (finalMessage ?? "").prefix(64)
                parts.append("t=:\(turnId):\(final)")
            case .itemStarted(let item):
                parts.append("i+:\(item.id):\(item.turnId):\(item.type.rawValue)")
            case .itemCompleted(let itemId, _):
                parts.append("i=:\(itemId)")
            case .itemDelta(let itemId, let bodyAppend, _, _):
                // Length-only: content growth still changes the fingerprint.
                parts.append("id:\(itemId):\(bodyAppend?.utf8.count ?? 0)")
            default:
                // Plans, usage, requests etc. change chrome but not the main
                // transcript blink path; omit for stability across rehydrate.
                continue
            }
        }
        return parts.joined(separator: "|")
    }

    /// True when the deferred snapshot path would paint the same transcript
    /// already shown from the first local open pass — skip wipe+rebuild.
    nonisolated static func shouldSkipDeferredTimelineRebuild(
        firstPaintEvents: [AssistantEvent],
        deferredChosenEvents: [AssistantEvent]
    ) -> Bool {
        // Prefer the cheap counts; fingerprint only when counts match.
        guard renderableItemCount(firstPaintEvents) == renderableItemCount(deferredChosenEvents) else {
            return false
        }
        guard firstPaintEvents.count == deferredChosenEvents.count else {
            // Same item-starts but different event stream shape → rebuild.
            // Still skip when fingerprints match (e.g. reordered telemetry only).
            return replayPaintFingerprint(firstPaintEvents) == replayPaintFingerprint(deferredChosenEvents)
        }
        return replayPaintFingerprint(firstPaintEvents) == replayPaintFingerprint(deferredChosenEvents)
    }

    /// Deferred provider snapshot may replace the first local paint only when it
    /// recovers **meaningfully** missing local history.
    ///
    /// Equal/thinner never rebuilds. When local already painted real content
    /// (≥3 item starts), require a substantial gap so +1 telemetry/itemStarted
    /// from the provider cannot blink a completed thread that already has text.
    nonisolated static func shouldApplyDeferredSnapshotReplay(
        firstPaintItemCount: Int,
        deferredSnapshotItemCount: Int
    ) -> Bool {
        shouldApplyDeferredSnapshotReplay(
            firstPaintItemCount: firstPaintItemCount,
            deferredSnapshotItemCount: deferredSnapshotItemCount,
            threadIsTerminal: false
        )
    }

    /// When the opened thread is already terminal and local history painted,
    /// never rebuild from provider snapshot — that was the multipass flash and
    /// correlated with unnecessary open work.
    nonisolated static func shouldApplyDeferredSnapshotReplay(
        firstPaintItemCount: Int,
        deferredSnapshotItemCount: Int,
        threadIsTerminal: Bool
    ) -> Bool {
        if threadIsTerminal, firstPaintItemCount > 0 {
            return false
        }
        guard deferredSnapshotItemCount > firstPaintItemCount else { return false }
        // Thin/empty local: any strictly richer snapshot is recovery.
        if firstPaintItemCount < 3 { return true }
        // Local already has a painted transcript — only rebuild when provider
        // is substantially richer (missing history), not for micro count noise.
        let minExtra = max(5, firstPaintItemCount / 5)
        return deferredSnapshotItemCount >= firstPaintItemCount + minExtra
    }

    /// Build a fully-applied timeline without intermediate @Published empties.
    nonisolated static func timelineByReplaying(_ events: [AssistantEvent]) -> AssistantTimelineState {
        var next = AssistantTimelineState()
        for event in events {
            next.apply(event, nowMs: nil)
        }
        next.enforceAggregateHotTextBudget()
        return next
    }

    /// Same-thread re-select: sync chrome/status without wiping the transcript.
    /// Host `refreshAgentSurfaces(reloadTranscriptIfSelected:)` and rail clicks
    /// re-enter here; full open was causing 2–4 full reloads of the same thread.
    private func persistDistillManualRoutingIfNeeded(threadId: AgentThreadID) {
        guard selectedThreadId == threadId,
              provider == .distill,
              routingMode == .manual else { return }
        do {
            guard let durableWorkspace = try threadRepo.workspaceId(of: threadId),
                  durableWorkspace == workspaceID,
                  let storedRouting = try threadRepo.routingConfiguration(of: threadId),
                  storedRouting.mode == .auto,
                  storedRouting.manualSelection.provider == .distill else { return }
            _ = persistThreadConfig()
        } catch {
            if statusMessage.isEmpty {
                statusMessage = "Could not repair Distill thread routing: \(error)"
            }
        }
    }

    private func softReselectOpenThread(_ selectedThread: AgentThread, markRead: Bool) {
        let id = selectedThread.id
        Self.agentOpenTrace(
            "soft reselect thread=\(id.value.uuidString.prefix(8)) markRead=\(markRead) hasUnread=\(selectedThread.hasUnread) msgs=\(messages.count) turns=\(timeline.turns.count)"
        )
        publishInterestedThreadId(id)
        scheduleSoftReselectDurableRefresh(threadId: id)
        let routing = selectedThread.effectiveRoutingConfiguration
        let manual = routing.manualSelection
        let effectiveRoutingMode = routing.mode == .auto && manual.provider == .distill ? .manual : routing.mode
        // Assign-if-changed: soft reselect re-entered on every host refresh / rail
        // re-click and re-published identical chrome (multipass SwiftUI body churn).
        if Self.shouldAssignIfChanged(current: routingMode, next: effectiveRoutingMode) {
            routingMode = effectiveRoutingMode
        }
        if Self.shouldAssignIfChanged(current: provider, next: manual.provider) {
            provider = manual.provider
        }
        let nextProviderInstanceId = routing.manualProviderInstanceId ?? manual.provider.rawValue
        if Self.shouldAssignIfChanged(current: providerInstanceId, next: nextProviderInstanceId) {
            providerInstanceId = nextProviderInstanceId
        }
        let nextRunAsUser = selectedThread.runAsUser ?? AgentRunAsUser.current()
        if Self.shouldAssignIfChanged(current: runAsUser, next: nextRunAsUser) {
            runAsUser = nextRunAsUser
        }
        if Self.shouldAssignIfChanged(current: selectedRunActor, next: selectedThread.actor) {
            selectedRunActor = selectedThread.actor
        }
        if Self.shouldAssignIfChanged(current: model, next: manual.effectiveModel) {
            model = manual.effectiveModel
        }
        let nextPermissionMode = linkedBotVMRequiresFullAccess ? .fullAccess : selectedThread.permissionMode
        if linkedBotVMRequiresFullAccess, selectedThread.permissionMode != .fullAccess {
            setPermissionMode(.fullAccess, for: id)
        } else if Self.shouldAssignIfChanged(current: permissionMode, next: nextPermissionMode) {
            permissionMode = nextPermissionMode
        }
        if Self.shouldAssignIfChanged(current: reasoningEffort, next: manual.reasoningEffort) {
            reasoningEffort = manual.reasoningEffort
        }
        if Self.shouldAssignIfChanged(current: reasoningModel, next: selectedThread.reasoningModel) {
            reasoningModel = selectedThread.reasoningModel
        }
        let nextMainEffortSelection = manual.distillMainEffortSelection ?? .fixed(manual.reasoningEffort)
        if Self.shouldAssignIfChanged(current: distillMainEffortSelection, next: nextMainEffortSelection) {
            distillMainEffortSelection = nextMainEffortSelection
        }
        let nextReasoningEffortSelection = manual.distillReasoningEffortSelection ?? .automatic
        if Self.shouldAssignIfChanged(current: distillReasoningEffortSelection, next: nextReasoningEffortSelection) {
            distillReasoningEffortSelection = nextReasoningEffortSelection
        }
        if Self.shouldAssignIfChanged(current: distillExecutionMode, next: manual.distillExecutionMode) {
            distillExecutionMode = manual.distillExecutionMode
        }
        if Self.shouldAssignIfChanged(current: serviceTier, next: manual.serviceTier) {
            serviceTier = manual.serviceTier
        }
        if Self.shouldAssignIfChanged(current: executionMode, next: selectedThread.executionMode) {
            executionMode = selectedThread.executionMode
        }
        let nextBaseBranch = selectedThread.baseBranch ?? gitBranch ?? "main"
        if Self.shouldAssignIfChanged(current: baseBranch, next: nextBaseBranch) {
            baseBranch = nextBaseBranch
        }
        if Self.shouldAssignIfChanged(current: worktreePath, next: selectedThread.worktreePath) {
            worktreePath = selectedThread.worktreePath
        }
        if Self.shouldAssignIfChanged(current: status, next: selectedThread.status) {
            status = selectedThread.status
        }
        if let trackedRunId = trackedRunId(for: id) {
            if Self.shouldAssignIfChanged(current: currentRunId, next: trackedRunId) {
                currentRunId = trackedRunId
            }
            stopScheduledLivePoll()
        } else if isScheduledThreadRunning?(id) == true {
            bindScheduledOwnedRun(threadId: id)
        } else if currentRunId != nil || runStartedAt != nil {
            // Stay idle chrome if the open view already cleared run state.
            currentRunId = nil
            runStartedAt = nil
            stopScheduledLivePoll()
        }
        normalizeInteractionModeForSelectedProvider()
        // Only invoke mark-read when unread — otherwise every soft reselect
        // (rail re-click / host refresh) forced a coalesced rail reload for no reason.
        if markRead, selectedThread.hasUnread, let markThreadRead {
            do {
                try markThreadRead(id)
                if let idx = threads.firstIndex(where: { $0.id == id }) {
                    threads[idx].hasUnread = false
                }
            } catch {
                reloadThreads()
            }
        }
        // Skip durable page reload when hot messages already belong to this thread.
        let messageThreadIds = messages.map(\.threadId)
        if Self.shouldReloadMessagesOnSoftReselect(
            selectedThreadId: id,
            messagesThreadIds: messageThreadIds
        ) {
            Self.agentOpenTrace("soft reselect loadAllMessages thread=\(id.value.uuidString.prefix(8))")
            loadAllMessages(id)
        } else {
            Self.agentOpenTrace("soft reselect skip loadAllMessages thread=\(id.value.uuidString.prefix(8))")
        }
        reloadCheckpoints()
        refreshSubagentActivity()
        // Do not bump focusTick / resetTimelineUpdateTick / re-fetch provider
        // snapshot — that re-scrolled and re-blinked an already-open thread.
    }

    private func rehydrateProposedPlans(threadId: AgentThreadID) {
        guard let proposedPlanRepo,
              let records = try? proposedPlanRepo.list(threadId: threadId) else { return }
        var next = timeline
        for record in records {
            next.apply(.proposedPlan(record.plan))
        }
        timeline = next
    }

    private func rehydratePendingCallbacks(threadId: AgentThreadID) {
        guard let pendingCallbackRepo,
              let callbacks = try? pendingCallbackRepo.listVisible(threadId: threadId) else { return }
        var next = timeline
        for callback in callbacks {
            guard let data = callback.payloadJSON.data(using: .utf8) else { continue }
            switch callback.kind {
            case .approval:
                guard var request = try? pendingCallbackDecoder.decode(
                    AssistantPendingRequest.self,
                    from: data
                ) else { continue }
                request.state = callback.state
                request.resolvedAtMs = callback.resolvedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                next.apply(.requestOpened(request))
            case .userInput:
                guard var request = try? pendingCallbackDecoder.decode(
                    AssistantUserInputRequest.self,
                    from: data
                ) else { continue }
                request.state = callback.state
                request.resolvedAtMs = callback.resolvedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                next.apply(.userInputRequested(request))
            }
        }
        timeline = next
    }

    private func rehydrateDurableActiveState(threadId: AgentThreadID) {
        // A user send superseded the prior plan until the next run starts.
        guard !suppressStaleActivePlanUpdates else { return }
        guard let state = coordinator.durableActiveThreadState(threadId: threadId),
              let activePlan = state.activePlan else { return }
        // Chat contract: never resurrect a fully completed prior checklist.
        guard !AgentAppView.activePlanIsFullyCompleted(activePlan) else { return }
        timeline.apply(.activePlanUpdated(activePlan))
    }

    /// Applies a durable active state that was gathered off-main as part of the
    /// thread open bundle (perf AA-02). The completed-checklist contract and the
    /// follow-up suppression check still run here, at apply time.
    private func rehydrateDurableActiveState(from state: AgentActiveThreadState?) {
        guard !suppressStaleActivePlanUpdates else { return }
        guard let activePlan = state?.activePlan else { return }
        // Chat contract: never resurrect a fully completed prior checklist.
        guard !AgentAppView.activePlanIsFullyCompleted(activePlan) else { return }
        timeline.apply(.activePlanUpdated(activePlan))
    }

    // MARK: Bounded message history
    /// Hot transcript body budget for the UI process. Durable history stays in
    /// SQLite; only this many UTF-8 body bytes stay resident in `messages`.
    /// (Was 96 MB — too large for huge threads; older rows load via keyset pages.)
    /// First-paint / hot UI body budget. Lower than durable retention so opening
    /// a fat thread does not re-render multi-MiB of markdown on MainActor.
    /// Was 400 KiB; 128 KiB matches memory-loop tip first-paint aggressiveness.
    nonisolated static let fullLoadBodyBudgetBytes = 128 * 1024
    /// Hot message page (newest first). Older durable rows remain outside the
    /// hot UI window (`messageHistoryIsPartial`) and load on demand via scroll.
    nonisolated static let messageHistoryPageLimit = 25

    private func loadAllMessages(_ id: AgentThreadID) {
        // SQLite access remains on the app's established DB actor, but the query is
        // keyset/row/byte bounded: opening a multi-year thread no longer scans every
        // historical shell or hydrates an unbounded array on MainActor.
        messageHistoryLoadTask?.cancel()
        // Same-thread reloads must NOT wipe the visible array first. A concurrent
        // finish/select reload used to set messages=[] and drop the optimistic
        // user-message mirror (and system notes) before the durable row existed.
        // Only clear when switching threads so the prior thread's rows do not flash.
        if messages.contains(where: { $0.threadId != id }) {
            messages = []
            messageHistoryIsPartial = false
        }
        // Invalidate any in-flight older-page load (thread switch or re-select).
        // Bumping generation makes stale Task defers no-ops; UI flag clears now.
        cancelOlderMessageLoad()
        let repository = messageRepo
        messageHistoryLoadTask = Task { @MainActor [weak self] in
            // Perf AA-10: one detached round-trip for the page and the three
            // persisted lookups (was 4 sequential detached hops + MainActor
            // returns).
            let payload = await Self.loadMessagePagePayloadOffMain(
                repository: repository,
                threadId: id
            )
            let loadedRows = payload.page?.rows ?? []
            guard let self, !Task.isCancelled, !self.isDisposed,
                  self.selectedThreadId == id else { return }
            // Every winning load resolves the page state, whatever the merge
            // below does with optimistic rows: a thrown read is a failure the
            // user sees, never an empty thread.
            if let failure = payload.failure {
                self.messagePageLoadState = .failed(message: failure)
            } else {
                self.messagePageLoadState = .idle
            }
            // Rows appended in-memory while the page was being read (system
            // notes, the send() user-message mirror) must survive the swap —
            // the page snapshot predates them. Optimistic mirrors share the
            // durable id, so id-merge collapses once the run/queue row lands.
            self.messages = Self.mergeLoadedMessagesWithInMemoryMirrors(
                loadedRows: loadedRows,
                inMemory: self.messages,
                threadId: id
            )
            self.messageHistoryIsPartial = payload.page?.hasMoreOlder ?? false
            self.ensureBotPeerReconciliation()
            // Queue rows are not transcript bubbles; only re-apply plan
            // suppression after the durable message merge.
            self.restoreQueuedFollowupTranscriptPresentation(threadId: id)
            if self.messageHistoryIsPartial {
                NSLog("[AgentApp] recent message page loaded: \(self.messages.count) rows; older durable messages remain outside the hot UI window")
            }
        }
    }

    /// Pure merge used by load completion and tests: durable page first, then any
    /// same-thread in-memory rows whose id is not already in the page.
    /// Optimistic queue/start mirrors use the durable run/queue UUID so drain
    /// and coordinator persist collapse to one row by id (not by content — two
    /// legitimate identical prompts must remain two bubbles).
    nonisolated static func mergeLoadedMessagesWithInMemoryMirrors(
        loadedRows: [AgentMessage],
        inMemory: [AgentMessage],
        threadId: AgentThreadID
    ) -> [AgentMessage] {
        // Single pass: id set plus same-thread mirrors together, no filter
        // intermediate on the message-page load path.
        var loadedIds = Set<AgentMessageID>()
        loadedIds.reserveCapacity(loadedRows.count)
        var merged = loadedRows
        for row in loadedRows {
            loadedIds.insert(row.id)
        }
        for candidate in inMemory where candidate.threadId == threadId {
            if !loadedIds.contains(candidate.id) {
                loadedIds.insert(candidate.id)
                merged.append(candidate)
            }
        }
        return merged
    }

    /// Shared UX for an outgoing user turn that is actually starting now:
    /// show the bubble, drop the previous turn's Active plan, and re-pin the
    /// transcript to the bottom. `messageId` must be the durable identity
    /// (`AgentMessageID(runId)` / `AgentMessageID(queued.id)` on drain) so later
    /// persist does not double the bubble. Mid-run queue inserts must not call
    /// this — they stay in the queue UI until the turn starts.
    private func presentOutgoingUserMessage(
        threadId: AgentThreadID,
        messageId: AgentMessageID,
        display: String,
        attachments: [AgentAttachment],
        bumpFocus: Bool = true
    ) {
        let capped = AssistantTimelineState.cappedText(display)
        timeline.clearActivePlan()
        suppressStaleActivePlanUpdates = true
        resetTimelineUpdateTick()
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            // Re-present under the stable id (e.g. resume / already mirrored).
            messages[idx] = AgentMessage(
                id: messageId,
                threadId: threadId,
                role: .user,
                content: capped,
                createdAt: messages[idx].createdAt,
                attachments: attachments
            )
        } else {
            messages.append(AgentMessage(
                id: messageId,
                threadId: threadId,
                role: .user,
                content: capped,
                attachments: attachments
            ))
            if bumpFocus { focusTick &+= 1 }
        }
    }

    /// After a durable message-page load / timeline rehydrate, re-apply the
    /// user-visible contract for pending queue rows: keep the prior Active plan
    /// cleared. Queued text itself stays out of the transcript until drain.
    private func restoreQueuedFollowupTranscriptPresentation(threadId: AgentThreadID) {
        guard queuedMessages.contains(where: { $0.threadId == threadId }) else { return }
        suppressStaleActivePlanUpdates = true
        timeline.clearActivePlan()
    }

    /// Test seam: awaits the off-main message-history page kicked off by
    /// selectThread, so tests can assert on `messages` deterministically.
    func waitForMessageHistoryLoad() async {
        await messageHistoryLoadTask?.value
    }

    func waitForOlderMessageLoad() async {
        await olderMessageLoadTask?.value
    }

    public func revealMessage(
        id: AgentMessageID,
        expectedThreadID: AgentThreadID? = nil
    ) async throws {
        messageRevealGeneration &+= 1
        let generation = messageRevealGeneration
        let selectionGeneration = selectThreadOpenGeneration
        let originallySelectedThreadID = selectedThreadId
        messageScrollTarget = nil
        await beforeMessageRevealLookupForTesting?()
        let repository = messageRepo
        let targetMessage = await Task.detached(priority: .userInitiated) {
            try? repository.get(id: id)
        }.value
        guard messageRevealGeneration == generation else {
            throw AgentAppSurfaceMessageRevealError.selectionChanged
        }
        guard let targetMessage else {
            throw AgentAppSurfaceMessageRevealError.messageNotFound(id)
        }
        guard expectedThreadID == nil || targetMessage.threadId == expectedThreadID else {
            throw AgentAppSurfaceMessageRevealError.messageNotFound(id)
        }
        guard selectThreadOpenGeneration == selectionGeneration,
              selectedThreadId == originallySelectedThreadID else {
            throw AgentAppSurfaceMessageRevealError.selectionChanged
        }

        if selectedThreadId != targetMessage.threadId {
            selectThread(targetMessage.threadId, markRead: false)
        }
        let openGeneration = selectThreadOpenGeneration
        await waitForMessageHistoryLoad()
        guard messageRevealGeneration == generation,
              selectThreadOpenGeneration == openGeneration,
              selectedThreadId == targetMessage.threadId else {
            throw AgentAppSurfaceMessageRevealError.selectionChanged
        }
        if let failure = messagePageLoadFailureMessage {
            throw AgentAppSurfaceMessageRevealError.historyLoadFailed(failure)
        }

        while !messages.contains(where: { $0.id == id }), messageHistoryIsPartial {
            let previousCount = messages.count
            if !isLoadingOlderMessages { loadOlderMessages() }
            await waitForOlderMessageLoad()
            guard messageRevealGeneration == generation,
                  selectThreadOpenGeneration == openGeneration,
                  selectedThreadId == targetMessage.threadId else {
                throw AgentAppSurfaceMessageRevealError.selectionChanged
            }
            if let failure = olderMessageLoadFailure {
                throw AgentAppSurfaceMessageRevealError.historyLoadFailed(failure)
            }
            if messages.count == previousCount { break }
        }
        guard messages.contains(where: { $0.id == id }) else {
            throw AgentAppSurfaceMessageRevealError.messageNotFound(id)
        }
        messageScrollTarget = AgentChatTimelineScrollTarget(
            anchor: "message-\(id.value.uuidString)"
        )
    }

    /// Scrolls the transcript to a loaded message (reply quote jump).
    public func scrollToMessage(_ id: AgentMessageID) {
        messageScrollTarget = AgentChatTimelineScrollTarget(anchor: "message-\(id.value.uuidString)")
    }

    /// Text of the failed-read banner; nil when the read did not fail.
    public var messagePageLoadFailureMessage: String? {
        if case .failed(let message) = messagePageLoadState { return message }
        return nil
    }

    /// Retry of the failed-read banner: reads the open thread's page again.
    public func retryMessagePageLoad() {
        guard !isDisposed, let selectedThreadId else { return }
        messagePageLoadState = .pending
        loadAllMessages(selectedThreadId)
    }

    nonisolated static func loadMessagePageOffMain(
        repository: AgentMessageRepository,
        threadId: AgentThreadID,
        before: AgentMessageCursor? = nil
    ) async -> AgentMessageBodyBudgetResult? {
        await Task.detached(priority: .userInitiated) {
            try? repository.listPageWithinBodyBudget(
                threadId: threadId,
                limit: messageHistoryPageLimit,
                before: before,
                budget: fullLoadBodyBudgetBytes,
                contentLimit: AssistantTimelineState.liveTextLimit
            )
        }.value
    }


    /// Everything `loadAllMessages` needs, gathered in ONE detached round-trip
    /// (perf AA-10: the page query and the three persisted per-message lookups
    /// used to be 4 sequential detached hops with a MainActor return each).
    struct AgentMessagePagePayload: Sendable {
        var page: AgentMessageBodyBudgetResult?
        /// Set when the read threw. A nil `page` alone cannot tell an
        /// unreadable thread from an empty one.
        var failure: String?
    }

    nonisolated static func loadMessagePagePayloadOffMain(
        repository: AgentMessageRepository,
        threadId: AgentThreadID,
        before: AgentMessageCursor? = nil
    ) async -> AgentMessagePagePayload {
        await Task.detached(priority: .userInitiated) {
            var payload = AgentMessagePagePayload()
            do {
                payload.page = try repository.listPageWithinBodyBudget(
                    threadId: threadId,
                    limit: messageHistoryPageLimit,
                    before: before,
                    budget: fullLoadBodyBudgetBytes,
                    contentLimit: AssistantTimelineState.liveTextLimit
                )
            } catch {
                payload.failure = "Could not load messages: \(error)"
            }
            return payload
        }.value
    }

    /// Pure merge: older page prepended before current hot rows (dedupe by id).
    /// WHY: keyset `before` pages must expand the hot window without dropping
    /// in-memory mirrors or reordering the newest suffix.
    nonisolated static func mergeOlderMessagePage(
        older: [AgentMessage],
        current: [AgentMessage]
    ) -> [AgentMessage] {
        guard !older.isEmpty else { return current }
        var seen = Set(current.map(\.id))
        var prefix: [AgentMessage] = []
        prefix.reserveCapacity(older.count)
        for message in older where !seen.contains(message.id) {
            seen.insert(message.id)
            prefix.append(message)
        }
        return prefix + current
    }

    /// Invalidate ownership of any in-flight older-page load and clear UI flag.
    private func cancelOlderMessageLoad() {
        loadingOlderGeneration &+= 1
        if isLoadingOlderMessages { isLoadingOlderMessages = false }
    }

    /// Load the next older keyset page into `messages` when history is partial.
    /// Durable SQLite rows remain; this only expands the hot UI window.
    ///
    /// Ownership uses a generation token (not a bare bool): only the live load
    /// may clear loading. A stale Task after thread switch / newer load is a no-op.
    public func loadOlderMessages() {
        guard !isDisposed, !isLoadingOlderMessages, messageHistoryIsPartial,
              let threadId = selectedThreadId,
              let oldest = messages.first else { return }
        loadingOlderGeneration &+= 1
        let myGeneration = loadingOlderGeneration
        isLoadingOlderMessages = true
        olderMessageLoadFailure = nil
        let repository = messageRepo
        let cursor = AgentMessageCursor(createdAt: oldest.createdAt, id: oldest.id)
        let expectedThread = threadId
        olderMessageLoadTask = Task { @MainActor [weak self] in
            defer {
                // Only the live owner clears. Stale gens leave a newer load alone.
                if let self,
                   Self.shouldClearLoadingOlderMessages(
                    myGeneration: myGeneration,
                    currentGeneration: self.loadingOlderGeneration
                   ) {
                    self.loadingOlderGeneration = 0
                    self.isLoadingOlderMessages = false
                }
            }
            let payload = await Self.loadMessagePagePayloadOffMain(
                repository: repository,
                threadId: expectedThread,
                before: cursor
            )
            guard let self, !self.isDisposed,
                  self.selectedThreadId == expectedThread,
                  Self.shouldClearLoadingOlderMessages(
                    myGeneration: myGeneration,
                    currentGeneration: self.loadingOlderGeneration
                  ) else { return }
            guard let loaded = payload.page else {
                self.olderMessageLoadFailure = payload.failure ?? "Could not load older messages"
                return
            }
            self.messages = Self.mergeOlderMessagePage(
                older: loaded.rows,
                current: self.messages
            )
            self.messageHistoryIsPartial = loaded.hasMoreOlder
            if !loaded.hasMoreOlder {
                NSLog("[AgentApp] older message pages exhausted for thread \(expectedThread.value.uuidString)")
            }
        }
    }

    /// Pure ownership gate (SSHRemoteView `shouldClearLoading` pattern).
    /// True only when this Task still owns the active older-page load.
    nonisolated static func shouldClearLoadingOlderMessages(
        myGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        myGeneration == currentGeneration && myGeneration != 0
    }

    /// Safety valve for a pathological thread: keep the NEWEST bodies in full and blank
    /// the oldest (content -> "") until total text is under `budget`. Returns the rows and
    /// how many were blanked. Pure + testable. For a normal thread nothing is blanked.
    nonisolated static func applyBodyBudget(_ rows: [AgentMessage], budget: Int = fullLoadBodyBudgetBytes) -> (rows: [AgentMessage], blanked: Int) {
        var total = 0
        for r in rows { total += r.content.utf8.count }
        guard total > budget else { return (rows, 0) }
        var result = rows
        var running = total
        var blanked = 0
        var i = 0
        while running > budget && i < result.count {
            let bytes = result[i].content.utf8.count
            if bytes > 0 {
                result[i].content = ""
                running -= bytes
                blanked += 1
            }
            i += 1
        }
        return (result, blanked)
    }

    /// F5: cap each message body AND enforce the memory budget in a SINGLE pass over
    /// the rows (the common, under-budget case does no second pass), instead of mapping
    /// a cap over all rows and then summing them again. Output is identical to
    /// `applyBodyBudget(raw.map { cappedText($0.content) })`.
    nonisolated static func cappedRowsWithinBudget(_ raw: [AgentMessage], budget: Int = fullLoadBodyBudgetBytes) -> (rows: [AgentMessage], blanked: Int) {
        var rows: [AgentMessage] = []
        rows.reserveCapacity(raw.count)
        var total = 0
        for message in raw {
            var capped = message
            capped.content = AssistantTimelineState.cappedText(message.content)
            total += capped.content.utf8.count
            rows.append(capped)
        }
        guard total > budget else { return (rows, 0) }
        var running = total
        var blanked = 0
        var i = 0
        while running > budget && i < rows.count {
            let bytes = rows[i].content.utf8.count
            if bytes > 0 {
                rows[i].content = ""
                running -= bytes
                blanked += 1
            }
            i += 1
        }
        return (rows, blanked)
    }

    private func suppressPersistedFinalDuplicatedByTimeline() {
        // Persisted assistant rows are the durable completed answer. The view
        // suppresses matching live timeline text instead so partial replay
        // cannot hide the final response.
    }

    /// B7: count of threads with an in-flight run, for the rail header.
    public var activeThreadCount: Int {
        threads.filter { isThreadStartingOrRunning($0.id) }.count
    }

    /// Chrome spinner for this Agent App tab only.
    ///
    /// Spins when the selected thread has tracked in-flight work, or when this
    /// surface still owns a live run in `runThreads` (user switched threads
    /// mid-run). Does **not** roll up every workspace thread — multiple Agent
    /// App tabs share the same thread list, and a workspace-wide check made
    /// every tab spin whenever any one of them was running.
    public var hasRunningWorkForChrome: Bool {
        if hasWaitingBotPeerActivity,
           Self.waitingPeerActivityKeepsChromeBusy(threadStatus: status) {
            return true
        }
        if selectedThreadRunIsStartingOrRunning { return true }
        return runThreads.values.contains { threadId in
            coordinator.activeRunId(threadId: threadId) != nil
        }
    }

    /// A persisted `.waiting` peer row spins the chrome only while the thread
    /// can still deliver the reply. Cancelled/failed/interrupted threads must
    /// never latch the tab and workspace spinners on a stale waiting row.
    /// Completed stays busy on purpose: reply_only tails land after the host
    /// finishes, and reconciliation settles the row shortly after.
    nonisolated static func waitingPeerActivityKeepsChromeBusy(
        threadStatus: AgentRunStatus
    ) -> Bool {
        switch threadStatus {
        case .pending, .running, .completed:
            return true
        case .cancelled, .failed, .interrupted:
            return false
        }
    }

    /// UX-MAC_AGENT-BG-AWAIT: the most recent final answer for the selected
    /// thread, used to detect a background-await stall for the status badge /
    /// Continue affordance. Prefers the live timeline's last turn, falling back to
    /// the last persisted assistant message after a reload.
    public var latestFinalAssistantMessage: String? {
        if let final = timeline.turns.last?.finalAssistantMessage, !final.isEmpty { return final }
        return messages.last(where: { $0.role == .assistant })?.content
    }

    /// UX-MAC_AGENT-BG-AWAIT / incomplete-turn: true when the selected thread
    /// finished while still incomplete — either waiting on a background job or
    /// stopped mid multi-phase workflow (e.g. "Next: Phase 3 — Review"). Surfaced
    /// as an "awaiting" badge plus a Continue button instead of a misleading green
    /// "completed".
    public var isAwaitingBackgroundWork: Bool {
        status == .completed
            && IncompleteTurnContinuation.isIncompleteTurn(latestFinalAssistantMessage)
    }

    /// CLAUDE-BG-LIFECYCLE: background shells/subagents to advertise right now.
    ///
    /// Gated on a live run on purpose. The adapter clears its pending set inside
    /// `emitTerminal` WITHOUT emitting a further snapshot, so the last count the
    /// UI ever receives for a run can be non-zero; without this gate a finished
    /// thread would keep claiming shells are running. While a run is live the
    /// snapshots are authoritative (an empty `tasks` list replaces the set).
    /// Complements `isAwaitingBackgroundWork`, which covers the *after* case —
    /// this covers *during*.
    public var backgroundShellCount: Int {
        Self.visibleBackgroundShellCount(
            reported: liveBackgroundShellCount,
            runIsLive: selectedThreadRunIsStartingOrRunning
        )
    }

    public var visibleBackgroundTasks: [AgentBackgroundTask] {
        Self.visibleBackgroundTasks(
            reported: liveBackgroundTasks,
            runIsLive: selectedThreadRunIsStartingOrRunning
        )
    }

    /// Named work holding Stop, or nil when the run is idle / has no CLI tasks.
    public var backgroundHoldSummary: AgentBackgroundHoldSummary? {
        let tasks = Self.enrichingBackgroundTasks(
            visibleBackgroundTasks,
            timeline: timeline
        )
        guard !tasks.isEmpty else { return nil }
        return AgentBackgroundHoldSummary(tasks: tasks)
    }

    /// CLI `task_started` rows already land in the timeline as
    /// "Background shell" / "Background agent" with the human `description`.
    /// Their `task_id` is the timeline item's id, so details are joined only to
    /// the exact snapshot id that owns them.
    nonisolated static func enrichingBackgroundTasks(
        _ tasks: [AgentBackgroundTask],
        timeline: AssistantTimelineState
    ) -> [AgentBackgroundTask] {
        var latestItemsByID: [String: AssistantItem] = [:]
        for turn in timeline.turns.reversed() {
            for item in turn.items.reversed() where latestItemsByID[item.id] == nil {
                latestItemsByID[item.id] = item
            }
        }
        return tasks.map { task in
            guard task.description == nil, let item = latestItemsByID[task.id] else { return task }
            let summary = item.summary ?? ""
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: AgentBackgroundTaskKind
            if summary == "Background shell" { kind = .shell }
            else if summary == "Background agent" { kind = .agent }
            else { return task }
            let enriched = AgentBackgroundTask(id: task.id, kind: kind, description: body)
            return enriched.description == nil ? AgentBackgroundTask(id: task.id, kind: kind) : enriched
        }
    }

    /// Pure seam for the staleness gate above.
    nonisolated static func visibleBackgroundShellCount(reported: Int, runIsLive: Bool) -> Int {
        runIsLive ? reported : 0
    }

    nonisolated static func visibleBackgroundTasks(
        reported: [AgentBackgroundTask],
        runIsLive: Bool
    ) -> [AgentBackgroundTask] {
        runIsLive ? reported : []
    }

    /// Reason for the incomplete-turn chrome, if any (drives Continue prompt).
    public var incompleteTurnReason: IncompleteTurnContinuationReason? {
        guard status == .completed else { return nil }
        return IncompleteTurnContinuation.classify(latestFinalAssistantMessage)
    }

    /// UX-MAC_AGENT-BG-AWAIT: composer placeholder. When the selected thread ended
    /// while still incomplete (awaiting a background job, or paused mid multi-phase
    /// workflow), the placeholder reflects that state instead of the neutral
    /// "Ask <Provider> for changes…" — otherwise the composer reads as a finished,
    /// idle turn even though the run is not done (the reported defect). Typing and
    /// sending stay enabled: a send redirects the thread; the co-visible
    /// `backgroundAwaitBanner` directly above carries the Continue (resume) action.
    /// Copy is deliberately short and positionless — the editor draws the
    /// placeholder without wrapping, so long/position-coupled copy would clip. The
    /// `!selectedThreadRunIsStartingOrRunning` guard keeps the neutral copy during
    /// the brief window a resume run is starting.
    public var composerPlaceholder: String {
        if activeReplyTarget != nil { return "Reply…" }
        if let placeholder = embedding?.composerPlaceholder { return placeholder }
        let defaultPlaceholder = "Ask \(provider.rawValue.capitalized) for changes…"
        guard !selectedThreadRunIsStartingOrRunning,
              let reason = incompleteTurnReason else { return defaultPlaceholder }
        switch reason {
        case .backgroundAwait:
            return "Waiting on a background task — send to redirect…"
        case .workflowHandoff:
            return "Paused mid-workflow — send to redirect…"
        case .uncalledToolInvocation:
            return "Tool call was not executed — send to redirect…"
        }
    }

    /// P2: threads visible in the rail after applying the search query.
    /// Empty query returns all non-subagent threads (nested workers stay off-rail).
    // R7: memoize filteredThreads — rail re-evaluates body on every 16Hz drag tick
    // and on every streaming delta (threads unchanged). Cache hit avoids filter+search.
    // Invalidate when threads identity changes (count+first/last id) or query changes.
    private var filteredThreadsCache: (query: String, count: Int, firstId: AgentThreadID?, lastId: AgentThreadID?, result: [AgentThread])?
    public var filteredThreads: [AgentThread] {
        let firstId = threads.first?.id
        let lastId = threads.last?.id
        if let cache = filteredThreadsCache,
           cache.query == threadSearchQuery,
           cache.count == threads.count,
           cache.firstId == firstId,
           cache.lastId == lastId {
            return cache.result
        }
        let result = AgentAppViewModel.filterThreads(threads, query: threadSearchQuery)
        filteredThreadsCache = (query: threadSearchQuery, count: threads.count, firstId: firstId, lastId: lastId, result: result)
        return result
    }

    /// Test seam to clear cache when threads array is mutated externally (tests).
    func invalidateFilteredThreadsCache() { filteredThreadsCache = nil }

    /// Pure helper: drops orchestrated nested-worker rows, then applies search.
    /// Empty query keeps every non-subagent thread.
    /// WHY: "Subagent · …" rows are AgentAppMiddleware nested workers; product
    /// rule is Subagents-under-parent chrome, not first-class rail entries.
    nonisolated public static func filterThreads(_ threads: [AgentThread], query: String) -> [AgentThread] {
        let rail = threads.filter { !AgentThreadTitle.isSubagentThreadTitle($0.title) }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return rail }
        return rail.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.model.localizedCaseInsensitiveContains(q)
        }
    }

    /// C7: the most recent plan the agent proposed in this thread's
    /// timeline (t3code PlanSidebar — proposed-plan tracking).
    public var latestPlanText: String? {
        if let plan = timeline.proposedPlans.last?.markdown.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty {
            return plan
        }
        for turn in timeline.turns.reversed() {
            if let plan = turn.items.last(where: { $0.type == .plan }) {
                let t = plan.body.isEmpty ? (plan.summary ?? "") : plan.body
                return t.isEmpty ? nil : t
            }
        }
        return nil
    }
    public var latestProposedPlan: AssistantProposedPlan? {
        timeline.proposedPlans.last { !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Full access is an autonomous mode: tools and plan implementation run without
    /// a human review gate. Proposed-plan Approve/Reject must not appear.
    public var suppressesProposedPlanReview: Bool {
        permissionMode == .fullAccess
    }

    /// Proposed plan cards that still need a human decision (supervised / auto-edits).
    public var reviewableProposedPlan: AssistantProposedPlan? {
        guard !suppressesProposedPlanReview else { return nil }
        return latestProposedPlan
    }

    /// Plan IDs already scheduled for full-access auto-implement (dedupe flush + finish).
    private var fullAccessAutoImplementPlanIds: Set<String> = []

    /// Under full access, auto-implement the latest unimplemented proposed plan
    /// (queue if a turn is still open — never ask the user to Approve).
    public func scheduleFullAccessPlanAutoImplementIfNeeded() {
        guard suppressesProposedPlanReview else { return }
        guard let plan = latestProposedPlan, plan.showsImplementationActions else { return }
        // Dedupe concurrent flush+finish schedules only after a successful start/queue
        // (failed enqueue must remain retryable).
        guard !fullAccessAutoImplementPlanIds.contains(plan.id) else { return }
        fullAccessAutoImplementPlanIds.insert(plan.id)
        Task {
            await self.implementLatestPlan(newThread: false)
            // implementLatestPlan marks implemented only on success; release the
            // latch so a later finish/reopen can retry a failed admission.
            if self.latestProposedPlan?.id == plan.id,
               self.latestProposedPlan?.showsImplementationActions == true {
                self.fullAccessAutoImplementPlanIds.remove(plan.id)
            }
        }
    }

    @discardableResult
    public func saveLatestProposedPlan(to url: URL) throws -> URL {
        guard let plan = latestProposedPlan else {
            throw NSError(domain: "RemoteCode.AgentApp", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "No proposed plan is available to save."
            ])
        }
        try plan.markdown.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    public var activePlan: AssistantActivePlan? {
        timeline.activePlan
    }

    public var openPendingRequests: [AssistantPendingRequest] {
        timeline.pendingRequests.filter { $0.state == .pending }
    }

    public var openPendingUserInputs: [AssistantUserInputRequest] {
        timeline.pendingUserInputs.filter { $0.state == .pending }
    }

    public var visiblePendingRequests: [AssistantPendingRequest] {
        timeline.pendingRequests.filter { $0.state == .pending || $0.state == .stale }
    }

    public var visiblePendingUserInputs: [AssistantUserInputRequest] {
        timeline.pendingUserInputs.filter { $0.state == .pending || $0.state == .stale }
    }

    /// Builds the decline payload for a supervised-mode approval decision.
    /// A non-empty reason is included so the agent can steer future requests;
    /// blank/nil reason produces a plain decline with no annotation.
    nonisolated public static func declinePayload(reason: String?) -> AgentProviderRequestResponse {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .decline(trimmed.flatMap { $0.isEmpty ? nil : $0 })
    }

    public func respondToPendingRequest(_ request: AssistantPendingRequest, response: AgentProviderRequestResponse) {
        guard let threadId = selectedThreadId else { return }
        respondToPendingRequest(request, response: response, originThreadId: threadId)
    }

    public func respondToPendingRequest(
        _ request: AssistantPendingRequest,
        response: AgentProviderRequestResponse,
        originThreadId threadId: AgentThreadID
    ) {
        guard request.state == .pending else { return }
        guard threads.contains(where: { $0.id == threadId }) else { return }
        let state: AssistantRequestState
        switch response {
        case .approve, .approveForSession: state = .approved
        case .decline: state = .declined
        case .cancel: state = .cancelled
        }
        // coordinator.respondToRequest is now async (its codex app-server
        // permission-promotion no longer blocks the caller on a semaphore).
        // respondToPendingRequest stays a synchronous SwiftUI action; drive the
        // resolution off the main run loop, preserving the same success/failure
        // side-effects, ordering, and the trailing timeline tick.
        //
        // The async hop means a later, synchronous callback action (e.g.
        // answerPendingUserInput) can run BEFORE this Task resolves. To preserve
        // the pre-async "most-recent callback action's error is the visible one"
        // ordering, stamp this action and refuse to clobber timeline.error if a
        // newer callback action has been issued in the meantime.
        callbackActionSeq &+= 1
        let issuedSeq = callbackActionSeq
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.coordinator.respondToRequest(threadId: threadId, requestId: request.id, response: response)
                // QA-MAC_AGENT-010: record approval outcomes for diagnostics.
                agentSurfaceLog.info("approval.resolved thread=\(threadId.value.uuidString, privacy: .public) request=\(request.id, privacy: .public) state=\(state.rawValue, privacy: .public)")
                // Dynamic permission callbacks already carry the provider's
                // exact requested profile and session scope. Never translate
                // that narrow grant into the thread-wide Full Access mode.
                if response == .approveForSession, request.kind != .dynamic {
                    let thread = self.threads.first { $0.id == threadId }
                    let snapshot = thread.flatMap { thread in
                        self.providerSnapshots.first { $0.id == thread.providerInstanceId }
                            ?? self.providerSnapshots.first { $0.provider == thread.provider }
                    }
                    let supported = snapshot?.effectivePermissionModes
                        ?? AgentPermissionMode.allCases
                    if supported.contains(.fullAccess) {
                        self.setPermissionMode(.fullAccess, for: threadId)
                    }
                }
                // The async response belongs to the card's origin thread. A user
                // can switch threads while it is in flight; never resolve a same-id
                // callback in the newly selected thread's timeline.
                if self.selectedThreadId == threadId {
                    self.timeline.apply(.requestResolved(requestId: request.id, state: state))
                }
            } catch {
                // Always retain the stale diagnostic + clear the dead button, but
                // only surface this error message if it is still the most recent
                // callback action (no newer action stomped it via a sync write).
                if self.selectedThreadId == threadId {
                    if issuedSeq == self.callbackActionSeq {
                        self.timeline.apply(.error(message: "Provider request response failed: \(error)", recoverable: true))
                        self.lastErrorRecoverable = false
                    }
                    self.timeline.apply(.requestResolved(requestId: request.id, state: .stale))
                }
            }
            self.scheduleTimelineUpdateTick()
        }
    }

    public func answerPendingUserInput(_ request: AssistantUserInputRequest, answer: String) {
        guard request.state == .pending else { return }
        guard let threadId = selectedThreadId else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Newest callback action -- see respondToPendingRequest: bumping this seq
        // stops an in-flight async approval failure from overwriting this (more
        // recent) user-input error, preserving most-recent-action-wins ordering.
        clearVisibleErrorForNewUserMessage()
        callbackActionSeq &+= 1
        let stateKey = userInputStateKey(request, threadId: threadId)
        userInputSelections[stateKey] = nil
        userInputDrafts[stateKey] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.coordinator.respondToUserInput(threadId: threadId, requestId: request.id, text: trimmed)
                if self.selectedThreadId == threadId {
                    self.timeline.apply(.userInputResolved(requestId: request.id, answer: trimmed))
                }
            } catch {
                if self.selectedThreadId == threadId {
                    self.timeline.apply(.error(message: "Provider user-input response failed: \(error)", recoverable: true))
                    if let idx = self.timeline.pendingUserInputs.firstIndex(where: { $0.id == request.id }) {
                        self.timeline.pendingUserInputs[idx].state = .stale
                        self.timeline.pendingUserInputs[idx].resolvedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    }
                    // Response-failure, not a prompt failure — no prompt Retry offered.
                    self.lastErrorRecoverable = false
                }
            }
            self.scheduleTimelineUpdateTick()
        }
    }

    public func cancelPendingUserInput(_ request: AssistantUserInputRequest) {
        guard request.state == .pending else { return }
        if let snapshot = selectedProviderSnapshot,
           !snapshot.effectiveCapabilities.supportsUserInput {
            statusMessage = "\(providerDisplayName(provider)) does not support interactive questions for this session."
            return
        }
        guard let threadId = selectedThreadId else { return }
        clearVisibleErrorForNewUserMessage()
        callbackActionSeq &+= 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.coordinator.cancelUserInput(threadId: threadId, requestId: request.id)
                if self.selectedThreadId == threadId {
                    self.timeline.apply(.userInputResolved(requestId: request.id, answer: nil))
                }
            } catch {
                if self.selectedThreadId == threadId {
                    self.timeline.apply(.error(message: "Provider user-input cancellation failed: \(error)", recoverable: true))
                    if let index = self.timeline.pendingUserInputs.firstIndex(where: { $0.id == request.id }) {
                        self.timeline.pendingUserInputs[index].state = .stale
                        self.timeline.pendingUserInputs[index].resolvedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    }
                    self.lastErrorRecoverable = false
                }
            }
            self.scheduleTimelineUpdateTick()
        }
    }

    public func toggleUserInputOption(_ option: String, for request: AssistantUserInputRequest) {
        let key = userInputStateKey(request)
        var selection = userInputSelections[key] ?? []
        if selection.contains(option) { selection.remove(option) }
        else { selection.insert(option) }
        userInputSelections[key] = selection
    }

    public func selectedUserInputAnswer(for request: AssistantUserInputRequest) -> String {
        (userInputSelections[userInputStateKey(request)] ?? [])
            .filter { request.options.contains($0) }
            .sorted()
            .joined(separator: "\n")
    }

    /// AG-043: provider request ids are only unique inside one thread. All local
    /// draft and selection state therefore uses the callback's owning thread plus
    /// request id, preventing same-id cards in A/B from sharing user input.
    public func userInputStateKey(
        _ request: AssistantUserInputRequest,
        threadId: AgentThreadID? = nil
    ) -> String {
        let owner = threadId ?? selectedThreadId
        let ownerDescription = owner?.value.uuidString ?? "unbound"
        return "\(ownerDescription)\u{1}\(request.id)"
    }

    // MARK: Structured AskUserQuestion cards
    //
    // A structured request carries one or more questions, each with its own
    // options and single/multi-select mode. Selections and the per-question "Other"
    // freeform draft are keyed by (request, question) so multiple questions on one
    // card stay independent. Submitting builds one `{question text: answer}` map and
    // resolves the provider callback once — the Claude SDK expects answers keyed by
    // the question text, with multi-select answers comma-joined.
    public func askUserQuestionKey(_ request: AssistantUserInputRequest, _ question: AssistantUserInputQuestion) -> String {
        "\(userInputStateKey(request))\u{1}\(question.id)"
    }

    public func askUserQuestionOptionIsSelected(_ option: String, question: AssistantUserInputQuestion, request: AssistantUserInputRequest) -> Bool {
        userInputSelections[askUserQuestionKey(request, question)]?.contains(option) == true
    }

    public func selectAskUserQuestionOption(_ option: String, question: AssistantUserInputQuestion, request: AssistantUserInputRequest) {
        let key = askUserQuestionKey(request, question)
        var selection = userInputSelections[key] ?? []
        if question.allowsMultipleSelection {
            if selection.contains(option) { selection.remove(option) } else { selection.insert(option) }
        } else {
            selection = selection.contains(option) ? [] : [option]
        }
        userInputSelections[key] = selection
        // Options and the freeform "Other" field are mutually exclusive: interacting
        // with options always drops any "Other" text so a stale draft can't survive a
        // toggle-off and make the question look answered with old text.
        userInputDrafts[key] = nil
    }

    /// Sets the per-question freeform "Other" text. Editing the Other field claims the
    /// (exclusive) selection, so it clears any option selection — mirroring
    /// `selectAskUserQuestionOption`, which clears the draft unconditionally. Clearing
    /// is unconditional (not gated on non-empty text) so the option radio and the Other
    /// radio can never both read as selected, even for whitespace-only text that later
    /// trims empty.
    public func setAskUserQuestionOther(_ text: String, question: AssistantUserInputQuestion, request: AssistantUserInputRequest) {
        let key = askUserQuestionKey(request, question)
        userInputDrafts[key] = text
        userInputSelections[key] = nil
    }

    /// Whether "Other" is the active choice for the question — true once its radio
    /// has been picked or any text typed, even before the text is non-empty, so the
    /// Other radio can render filled and the option radios empty. A present draft
    /// (including an empty one) is the marker; `selectAskUserQuestionOption` clears it.
    public func askUserQuestionOtherIsSelected(question: AssistantUserInputQuestion, request: AssistantUserInputRequest) -> Bool {
        userInputDrafts[askUserQuestionKey(request, question)] != nil
    }

    /// Toggles the per-question "Other" radio. Selecting Other makes it the single
    /// choice (clearing any option selection); clicking it again clears Other, mirroring
    /// how the listed options toggle off. An empty Other selection stays unsubmittable
    /// until the user types text (see `askUserQuestionAnswer`).
    public func selectAskUserQuestionOther(question: AssistantUserInputQuestion, request: AssistantUserInputRequest) {
        let key = askUserQuestionKey(request, question)
        if userInputDrafts[key] != nil {
            userInputDrafts[key] = nil
        } else {
            userInputDrafts[key] = ""
            userInputSelections[key] = nil
        }
    }

    /// The answer for one question: a non-empty freeform "Other" draft wins,
    /// otherwise the selected option label(s) (comma-joined for multi-select).
    /// `nil` when the question is unanswered.
    public func askUserQuestionAnswer(for question: AssistantUserInputQuestion, in request: AssistantUserInputRequest) -> String? {
        let key = askUserQuestionKey(request, question)
        let draft = (userInputDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty { return draft }
        let labels = Set(question.options.map(\.label))
        let selected = (userInputSelections[key] ?? [])
            .filter { labels.contains($0) }
            .sorted()
        guard !selected.isEmpty else { return nil }
        return selected.joined(separator: ", ")
    }

    public func askUserQuestionIsComplete(_ request: AssistantUserInputRequest) -> Bool {
        !request.questions.isEmpty && request.questions.allSatisfy { askUserQuestionAnswer(for: $0, in: request) != nil }
    }

    public func submitAskUserQuestion(_ request: AssistantUserInputRequest) {
        guard askUserQuestionIsComplete(request) else { return }
        var answers: [String: String] = [:]
        for question in request.questions {
            if let answer = askUserQuestionAnswer(for: question, in: request) {
                answers[question.prompt] = answer
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        for question in request.questions {
            let key = askUserQuestionKey(request, question)
            userInputSelections[key] = nil
            userInputDrafts[key] = nil
        }
        answerPendingUserInput(request, answer: json)
    }

    public func loadModels() async {
        modelListLoading = true
        // F35: progress is signalled by `modelListLoading` alone. Reusing the
        // error-styled status message rendered a red duplicate "Loading
        // models..." plus a Retry row while the fetch was still in flight.
        modelListStatusMessage = nil
        defer { modelListLoading = false }
        do {
            let m: [AgentModelDescriptor]
            let isFallback: Bool
            if let modelListLoader {
                m = try await modelListLoader(provider)
                isFallback = false
            } else if provider == .claude {
                let launchConfig = providerLaunchConfig?(provider, providerInstanceId)
                let result = await ClaudeRunner(binaryNameOverride: launchConfig?.binary)
                    .listModelsResult(
                        environment: launchConfig?.environment ?? [:],
                        cwd: cwd,
                        runAsUser: runAsUser
                    )
                m = result.models
                isFallback = result.isFallback
            } else if provider == .grok {
                let launchConfig = providerLaunchConfig?(provider, providerInstanceId)
                let result = await GrokACPAdapter(
                    binaryNameOverride: launchConfig?.binary,
                    discoveryCwd: cwd,
                    discoveryEnvironment: launchConfig?.environment ?? [:],
                    discoveryRunAsUser: runAsUser
                ).listModelsResult()
                m = result.models
                isFallback = result.isFallback
            } else if provider == .distill {
                // Distill owns its catalog: falling through to Codex discovery
                // replaced the Distill fetch with Codex ids and let an installed
                // Codex CLI decide the Distill built-in-defaults signal.
                let launchConfig = providerLaunchConfig?(provider, providerInstanceId)
                let result = await DistillACPAdapter(
                    binaryNameOverride: launchConfig?.binary,
                    discoveryCwd: cwd,
                    discoveryEnvironment: launchConfig?.environment ?? [:],
                    discoveryRunAsUser: runAsUser
                ).listModelsResult()
                m = result.models
                isFallback = result.isFallback
            } else {
                let launchConfig = providerLaunchConfig?(provider, providerInstanceId)
                let result = await CodexAppServerModelDiscovery.listModelsResult(
                    binary: launchConfig?.binary ?? "codex",
                    cwd: cwd,
                    environment: launchConfig?.environment ?? [:],
                    runAsUser: runAsUser
                )
                m = result.models
                isFallback = result.isFallback
            }
            await MainActor.run {
                self.availableModels = m
                self.availableModelsAreFallback = isFallback
                self.modelListStatusMessage = m.isEmpty
                    ? (self.provider == .distill
                        ? "No models yet. Connect an account on the start screen, then retry."
                        : "No models returned for \(self.providerDisplayName(self.provider)). Retry from the model menu.")
                    : nil
                // B8: a provider switch must leave a model valid for that
                // provider — never a stale id from the other provider.
                // F8: validate against the union of this fetch and the list
                // the picker actually displays (snapshot rows win), and never
                // rewrite a pinned model against a fallback list — built-in
                // defaults are no evidence the model is gone. Empty or
                // provably other-provider selections still reset (B8).
                if !self.modelSelectionIsValid(self.model, in: m + self.modelOptionsForSelectedProvider) {
                    if !isFallback || self.model.isEmpty || self.modelIsFromAnotherProvider(self.model) {
                        self.model = m.first?.id ?? self.model
                    }
                }
                self.normalizeSelectedModelOptions()
            }
        } catch {
            await MainActor.run {
                self.modelListStatusMessage = "Model list failed. Retry from the model menu."
                self.availableModelsAreFallback = false
            }
        }
    }

    public func loadProviderSnapshots(forceCatalogRefresh: Bool = false) async {
        providerSnapshotLoadCount += 1
        providerSnapshotsLoading = true
        defer {
            providerSnapshotLoadCount = max(0, providerSnapshotLoadCount - 1)
            providerSnapshotsLoading = providerSnapshotLoadCount > 0
        }
        // Capture MainActor-only inputs, then verify provenance off the main
        // actor so Process/URLSession catalog probes cannot beachball send().
        let launchConfig = providerLaunchConfig
        let cwdSnapshot = cwd
        do {
            let loadedSnapshots: [AgentProviderSnapshot]
            if let providerSnapshotLoader {
                loadedSnapshots = try await providerSnapshotLoader()
            } else {
                loadedSnapshots = await Self.localFallbackProviderSnapshots()
            }
            let snapshots = await Self.snapshotsWithVerifiedCatalogProvenance(
                loadedSnapshots,
                cwd: cwdSnapshot,
                launchConfig: launchConfig,
                forceRefresh: forceCatalogRefresh,
                runAsUser: runAsUser
            )
            self.providerSnapshotStatusMessage = nil
            self.applyProviderSnapshots(snapshots)
            self.providerSnapshotsLoadedAt = Date()
        } catch {
            // Fail open for composer usability: keep a resolved binary fallback so
            // send is not stuck on missingSnapshot after a transient probe failure.
            let fallback = await Self.localFallbackProviderSnapshots()
            self.providerSnapshotStatusMessage = "Provider snapshot failed. Retry from the model menu."
            if self.providerSnapshots.isEmpty {
                self.applyProviderSnapshots(fallback)
            }
        }
    }

    /// True when a successful snapshot load finished inside the catalog TTL.
    /// Send and Auto-admit use this so a fresh cache is not re-probed per message.
    private var providerSnapshotsAreFresh: Bool {
        !ModelListTTLDecision.shouldRefetch(
            lastFetchedAt: providerSnapshotsLoadedAt,
            ttl: ModelListTTLDecision.defaultCatalogTTL,
            now: Date()
        )
    }

    private func applyProviderSnapshots(_ snapshots: [AgentProviderSnapshot]) {
        providerSnapshots = snapshots
        let previousProvider = provider
        let previousInstanceId = providerInstanceId
        // No provider is mandatory. Default is Codex for historical reasons,
        // but a missing Codex CLI must not trap the empty Agent App: rebind to
        // the first runnable Claude/Grok (or other) snapshot when unlocked.
        // After the first real message the source stays fixed (providerLocked).
        // Explicit Source picks (sourceSelectionUserPinned) stay sticky so the
        // user can inspect recovery on an unrunnable row without thrash.
        if !providerLocked {
            if sourceSelectionUserPinned {
                if snapshots.first(where: { $0.id == providerInstanceId }) == nil {
                    providerInstanceId = snapshots.first(where: { $0.provider == provider && $0.enabled })?.id
                        ?? snapshots.first(where: { $0.provider == provider })?.id
                        ?? providerInstanceId
                }
            } else if let preferred = AgentProviderRunnableSelection.resolve(
                snapshots: snapshots,
                preferredProvider: provider,
                preferredInstanceId: providerInstanceId
            ) {
                providerInstanceId = preferred.id
                provider = preferred.provider
            } else if snapshots.first(where: { $0.id == providerInstanceId }) == nil {
                providerInstanceId = snapshots.first(where: { $0.provider == provider && $0.enabled })?.id
                    ?? snapshots.first(where: { $0.provider == provider })?.id
                    ?? snapshots.first(where: \.enabled)?.id
                    ?? snapshots.first?.id
                    ?? provider.rawValue
            }
        } else if snapshots.first(where: { $0.id == providerInstanceId }) == nil {
            // Locked thread: still map stale ids ("codex" → "codex-cli").
            providerInstanceId = snapshots.first(where: { $0.provider == provider && $0.enabled })?.id
                ?? snapshots.first(where: { $0.provider == provider })?.id
                ?? snapshots.first(where: \.enabled)?.id
                ?? snapshots.first?.id
                ?? provider.rawValue
        }
        if let current = selectedProviderSnapshot {
            providerInstanceId = current.id
            provider = current.provider
            // F10/F33: keep the fallback flag coherent when snapshot rows
            // replace the VM's own fetch — a snapshot bringing a different
            // list is live discovery, so the warning must clear; an identical
            // list means the fallback was substituted again.
            if current.modelDiscoverySource != nil {
                availableModelsAreFallback = current.modelListIsFallback
            } else if availableModelsAreFallback {
                availableModelsAreFallback = current.models.map(\.id) == availableModels.map(\.id)
            }
            availableModels = current.models
            // A thread stored under the raw provider id ("distill", written by
            // AppCommandRouter.normalizedProviderInstanceId when no configured
            // instance matches) is the provider's default instance, not another
            // source. Mapping it to the snapshot id ("distill-acp") must keep
            // the thread's pinned model; a real instance switch still resets.
            let isDefaultInstanceAlias = selectedThreadId != nil
                && current.provider == previousProvider
                && previousInstanceId == previousProvider.rawValue
            let sourceChanged = current.provider != previousProvider
                || (current.id != previousInstanceId && !isDefaultInstanceAlias)
            if isDefaultInstanceAlias,
               let threadId = selectedThreadId,
               composerDraftsByThread[threadId]?[previousInstanceId] == nil,
               prompt.isEmpty,
               attachments.isEmpty {
                restoreComposerDraft(
                    threadId: threadId,
                    providerInstanceId: current.id,
                    fallbackInteractionMode: interactionMode
                )
            }
            if sourceChanged {
                // SC-ux-1: auto-rebind must reset model like setProvider — do not
                // keep a Codex id (e.g. gpt-5.6-sol) after switching to Claude.
                applyPreferredModelForCurrentProvider(availableModels: current.models)
            } else if !modelSelectionIsValid(model, in: current.models) {
                // F9: never silently swap a pinned model for the snapshot's
                // first alias — a fallback snapshot may simply omit a
                // live-discovered model. Fill only an empty selection (post
                // provider switch) or evict an id from another provider; a
                // kept-but-missing pin is explained by
                // selectedModelUnavailableNotice in the picker.
                if model.isEmpty || modelIsFromAnotherProvider(model) {
                    applyPreferredModelForCurrentProvider(availableModels: current.models)
                }
            }
            normalizeSelectedModelOptions()
            normalizeInteractionModeForSelectedProvider()
        }
    }

    private func normalizeInteractionModeForSelectedProvider() {
        if interactionMode == .plan, !supportsPlanInteractionForSelectedProvider {
            interactionMode = .default
        }
        if !supportedPermissionModesForSelectedProvider.contains(permissionMode) {
            permissionMode = supportedPermissionModesForSelectedProvider.first ?? .supervised
        }
    }

    /// F11: the picker's rows come from provider snapshots, so an explicit
    /// "Refresh model list" must reload the snapshots too (`loadModels` alone
    /// only rewrites `availableModels`, which the picker ignores while
    /// snapshot rows exist) and must bypass the 1h discovery TTL — otherwise
    /// a refresh within the TTL just serves the cached list back.
    public func refreshModelList() async {
        if provider == .claude {
            let launchConfig = providerLaunchConfig?(provider, providerInstanceId)
            _ = await AnthropicModelDiscovery.refresh(environment: launchConfig?.environment ?? [:])
        }
        await loadProviderSnapshots(forceCatalogRefresh: true)
        await loadModels()
    }

    public func refreshProviderSnapshotsInBackground() {
        seedProviderSnapshotsForStartup()
        // F10: the snapshot pipeline discards the live/fallback signal, so the
        // "built-in defaults" warning never appeared on the startup path; run
        // the VM's own model fetch alongside to populate the fallback flag.
        Task {
            await loadProviderSnapshots()
            await loadModels()
        }
    }

    private func seedProviderSnapshotsForStartup() {
        guard providerSnapshots.isEmpty else { return }
        Task {
            let fallback = await Self.localFallbackProviderSnapshots()
            await MainActor.run {
                guard self.providerSnapshots.isEmpty else { return }
                self.applyProviderSnapshots(fallback)
            }
        }
    }

    /// Local, process-locator-backed rows used for startup and load-failure
    /// recovery. Prefer real binary paths so Grok/Codex are not marked
    /// unavailable solely because seed used an empty path.
    nonisolated public static func localFallbackProviderSnapshots() async -> [AgentProviderSnapshot] {
        var rows: [AgentProviderSnapshot] = []
        for provider in AgentProvider.selectable {
            let models: [AgentModelDescriptor]
            switch provider {
            case .codex:
                models = await CodexRunner().listModels()
            case .claude:
                models = ClaudeRunner.listModels(installedVersion: nil)
            case .grok:
                models = GrokRunner.listModels(installedVersion: nil)
            case .distill:
                models = await DistillACPAdapter().listModels()
            }
            rows.append(AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: models,
                binaryPath: (provider == .distill
                    ? ProcessLocator.resolveDistillAgent(provider.rawValue)
                    : ProcessLocator.resolve(provider.rawValue)) ?? "",
                modelDiscoverySource: .builtInFallback
            ))
        }
        return rows
    }

    /// Live catalog verification for untagged claude/codex rows. `nonisolated`
    /// so Process/URLSession probes never run under `AgentAppViewModel`'s
    /// MainActor isolation (send-path beachball). Results are TTL-cached via
    /// `ModelListTTLDecision` so a second send within the window reuses the
    /// last live list instead of re-spawning CLI / network discovery.
    nonisolated static func snapshotsWithVerifiedCatalogProvenance(
        _ snapshots: [AgentProviderSnapshot],
        cwd: String,
        launchConfig: ((AgentProvider, String?) -> (binary: String?, environment: [String: String]))?,
        forceRefresh: Bool,
        runAsUser: AgentRunAsUser? = nil,
        now: Date = Date()
    ) async -> [AgentProviderSnapshot] {
        var resolved: [AgentProviderSnapshot] = []
        resolved.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            guard snapshot.modelDiscoverySource == nil,
                  snapshot.provider == .claude || snapshot.provider == .codex else {
                resolved.append(snapshot)
                continue
            }
            let launch = launchConfig?(snapshot.provider, snapshot.id)
            let binary = launch?.binary ?? snapshot.binaryPath ?? snapshot.provider.rawValue
            let environment = launch?.environment ?? [:]
            let cacheKey = CatalogVerificationCache.key(
                provider: snapshot.provider,
                binary: binary,
                cwd: cwd,
                environment: environment,
                instanceId: snapshot.id
            )
            let liveModels: [AgentModelDescriptor]
            if !forceRefresh,
               let cached = CatalogVerificationCache.shared.models(
                for: cacheKey,
                ttl: ModelListTTLDecision.defaultCatalogTTL,
                now: now
               ) {
                liveModels = cached
            } else {
                Self.catalogVerificationProbeCountForTesting &+= 1
                if let probe = Self.catalogVerificationLiveProbeForTesting {
                    liveModels = await probe(snapshot.provider, binary, environment, cwd)
                } else {
                    switch snapshot.provider {
                    case .claude:
                        let result = await ClaudeRunner(binaryNameOverride: binary)
                            .listModelsResult(
                                environment: environment,
                                cwd: cwd,
                                runAsUser: runAsUser
                            )
                        liveModels = result.isFallback ? [] : result.models
                    case .codex:
                        let result = await CodexAppServerModelDiscovery.listModelsResult(
                            binary: binary,
                            cwd: cwd,
                            environment: environment,
                            runAsUser: runAsUser
                        )
                        liveModels = result.isFallback ? [] : result.models
                    case .grok, .distill:
                        liveModels = []
                    }
                }
                // Cache live hits and empty failures alike so a flapping CLI
                // does not re-block the next send within the TTL.
                CatalogVerificationCache.shared.store(liveModels, for: cacheKey, at: now)
            }
            let capabilityVerified = snapshot.installed
                && snapshot.status == .available
                && snapshot.capabilities?.supportsStreaming == true
                && snapshot.binaryPath?.isEmpty == false
            let source = AgentProviderCatalogProvenance.resolvedSource(
                reportedSource: snapshot.modelDiscoverySource,
                liveCatalogVerified: !liveModels.isEmpty,
                streamingCapabilityVerified: capabilityVerified
            )
            resolved.append(Self.snapshot(
                snapshot,
                models: liveModels.isEmpty ? snapshot.models : liveModels,
                discoverySource: source
            ))
        }
        return resolved
    }

    /// Testing seam: increments once per live catalog verification probe
    /// (cache misses only). Used to prove send reuses a fresh TTL cache.
    nonisolated(unsafe) static var catalogVerificationProbeCountForTesting = 0
    /// Testing seam: optional live-probe override so hermetic tests never
    /// touch a real CLI or network during catalog verification.
    nonisolated(unsafe) static var catalogVerificationLiveProbeForTesting:
        (@Sendable (AgentProvider, String, [String: String], String) async -> [AgentModelDescriptor])?

    /// Process-wide TTL cache for untagged-snapshot catalog verification.
    private final class CatalogVerificationCache: @unchecked Sendable {
        static let shared = CatalogVerificationCache()
        private let lock = NSLock()
        private var entries: [String: (models: [AgentModelDescriptor], fetchedAt: Date)] = [:]

        static func key(
            provider: AgentProvider,
            binary: String,
            cwd: String,
            environment: [String: String],
            instanceId: String
        ) -> String {
            let environmentKeys = environment.keys.sorted().joined(separator: ",")
            let accountSelectors = ["HOME", "CODEX_HOME", "GROK_HOME", "DISTILL_HOME", "REMOTE_CODE_INSTANCE"]
                .map { "\($0)=\(environment[$0] ?? "")" }
                .joined(separator: "\u{1f}")
            return "\(provider.rawValue)|\(instanceId)|\(binary)|\(cwd)|\(environmentKeys)|\(accountSelectors)"
        }

        func models(for key: String, ttl: TimeInterval, now: Date) -> [AgentModelDescriptor]? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[key],
                  !ModelListTTLDecision.shouldRefetch(
                    lastFetchedAt: entry.fetchedAt,
                    ttl: ttl,
                    now: now
                  ) else {
                return nil
            }
            return entry.models
        }

        func store(_ models: [AgentModelDescriptor], for key: String, at date: Date) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = (models, date)
        }

        func resetForTesting() {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll()
        }
    }

    /// Test-only: clear the process-wide catalog verification cache.
    nonisolated static func resetCatalogVerificationCacheForTesting() {
        CatalogVerificationCache.shared.resetForTesting()
        catalogVerificationProbeCountForTesting = 0
        catalogVerificationLiveProbeForTesting = nil
    }

    nonisolated private static func snapshot(
        _ snapshot: AgentProviderSnapshot,
        models: [AgentModelDescriptor],
        discoverySource: AgentModelDiscoverySource
    ) -> AgentProviderSnapshot {
        AgentProviderSnapshot(
            id: snapshot.id,
            provider: snapshot.provider,
            driverKind: snapshot.driverKind,
            displayName: snapshot.displayName,
            accentColor: snapshot.accentColor,
            continuationGroup: snapshot.continuationGroup,
            interactionModes: snapshot.interactionModes,
            permissionModes: snapshot.permissionModes,
            enabled: snapshot.enabled,
            installed: snapshot.installed,
            version: snapshot.version,
            status: snapshot.status,
            statusDetail: snapshot.statusDetail,
            authenticated: snapshot.authenticated,
            accountLabel: snapshot.accountLabel,
            accountAuthMethod: snapshot.accountAuthMethod,
            binaryPath: snapshot.binaryPath,
            homePath: snapshot.homePath,
            environmentKeys: snapshot.environmentKeys,
            models: models,
            slashCommands: snapshot.slashCommands,
            skills: snapshot.skills,
            advisory: snapshot.advisory,
            updateState: snapshot.updateState,
            capabilities: snapshot.capabilities,
            modelDiscoverySource: discoverySource,
            modelDiscoveryCacheKey: snapshot.modelDiscoveryCacheKey
        )
    }

    public var selectedProviderSnapshot: AgentProviderSnapshot? {
        AgentProviderSnapshotSelection.resolve(
            snapshots: providerSnapshots,
            provider: provider,
            instanceId: providerInstanceId
        )
    }

    public var providerExecutionUnavailableReason: String? {
        Self.providerExecutionUnavailableReason(for: selectedProviderSnapshot)
    }

    public var selectedProviderCanRun: Bool {
        providerExecutionUnavailableReason == nil
    }

    nonisolated public static func providerExecutionUnavailableReason(
        for snapshot: AgentProviderSnapshot?
    ) -> String? {
        // Match iOS fail-closed: nil snapshot must not look runnable. The old
        // `return nil` here let send reach preflight and surface
        // "Provider capabilities are not loaded yet." only after the user tried.
        guard let snapshot else {
            return AgentProviderRunPreflightError.missingSnapshot.description
        }
        if !snapshot.enabled || snapshot.status == .disabled {
            return snapshot.statusDetail ?? "\(snapshot.displayName) is disabled."
        }
        if !snapshot.installed || snapshot.status == .unavailable {
            return snapshot.statusDetail ?? "\(snapshot.displayName) is unavailable."
        }
        if snapshot.authenticated == false {
            return "\(snapshot.displayName) is not authenticated. Sign in to continue."
        }
        return nil
    }

    public var selectedModelDescriptor: AgentModelDescriptor? {
        if let exact = modelOptionsForSelectedProvider.first(where: { $0.id == model }) {
            return exact
        }
        return model.isEmpty ? nil : modelOptionsForSelectedProvider.first { $0.supportsCustomModel }
    }

    public var modelOptionsForSelectedProvider: [AgentModelDescriptor] {
        let snapshot = selectedProviderSnapshot
        let optionProvider = snapshot?.provider ?? provider
        let snapshotModels = snapshot?.models.filter { $0.provider == optionProvider } ?? []
        if !snapshotModels.isEmpty { return snapshotModels }
        return availableModels.filter { $0.provider == optionProvider }
    }

    /// F9: a pinned model missing from the displayed list is kept, never
    /// silently rewritten to the first fallback alias. This notice tells the
    /// user why no picker row is highlighted (the pill's modelLabel already
    /// falls back to the raw id).
    public var selectedModelUnavailableNotice: String? {
        guard !model.isEmpty else { return nil }
        let options = modelOptionsForSelectedProvider
        guard !options.isEmpty else { return nil }
        guard !options.contains(where: { $0.id == model }) else { return nil }
        guard !(customModelsByProvider[provider] ?? []).contains(model) else { return nil }
        return "\(model) is not in the current model list"
    }

    /// F10/F33: `availableModelsAreFallback` describes the VM's own fetch, but
    /// the picker prefers snapshot rows. Only claim "built-in defaults" when
    /// the rows on screen match the flagged fetch, so a live snapshot list
    /// never carries a false fallback warning.
    public var displayedModelListIsFallback: Bool {
        guard availableModelsAreFallback else { return false }
        let options = modelOptionsForSelectedProvider
        var count = 0
        for model in availableModels where model.provider == provider {
            guard count < options.count, options[count].id == model.id else { return false }
            count += 1
        }
        return count == options.count
    }

    public var supportedReasoningEffortsForSelectedModel: [AgentReasoningEffort] {
        selectedModelDescriptor?.supportedReasoningEfforts ?? AgentReasoningEffort.supportedCases
    }

    public var supportsReasoningForSelectedModel: Bool {
        !supportedReasoningEffortsForSelectedModel.isEmpty
    }

    public var supportsServiceTierForSelectedModel: Bool {
        selectedModelDescriptor?.supportsServiceTier == true
    }

    public var supportsCustomModelForSelectedProvider: Bool {
        modelOptionsForSelectedProvider.contains { $0.supportsCustomModel }
    }

    public var customModelsForSelectedProvider: [String] {
        customModelsByProvider[provider] ?? []
    }

    public var selectedModelContextWindowLabel: String? {
        selectedModelDescriptor?.contextWindowLabel
    }

    private func modelSelectionIsValid(_ model: String, in models: [AgentModelDescriptor]) -> Bool {
        guard !models.isEmpty else { return true }
        if models.contains(where: { $0.id == model && $0.provider == provider }) { return true }
        return !model.isEmpty
            && (customModelsByProvider[provider] ?? []).contains(model)
            && models.contains { $0.provider == provider && $0.supportsCustomModel }
    }

    /// B8 backstop shared by the F8/F9 keep-the-pin paths: an id that provably
    /// belongs to a different provider must never survive a provider switch,
    /// even when the current provider's list is only a fallback.
    private func modelIsFromAnotherProvider(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return providerSnapshots.contains { snapshot in
            snapshot.provider != provider && snapshot.models.contains { $0.id == id }
        }
    }

    public var currentModelSelection: AgentModelSelection {
        let exactDescriptor = modelOptionsForSelectedProvider.first { $0.id == model }
        let descriptor = selectedModelDescriptor
        let isCustom = exactDescriptor == nil && descriptor?.supportsCustomModel == true && !model.isEmpty
        return AgentModelSelection(
            provider: provider,
            modelId: isCustom ? (descriptor?.id ?? "") : model,
            customModelId: isCustom ? model : nil,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            distillMainEffortSelection: provider == .distill ? distillMainEffortSelection : nil,
            distillReasoningEffortSelection: provider == .distill ? distillReasoningEffortSelection : nil,
            distillExecutionMode: provider == .distill ? distillExecutionMode : .normal
        )
    }

    public var distillReasoningEfforts: [AgentReasoningEffort] {
        guard provider == .distill, let reasoningModel else { return [] }
        return modelOptionsForSelectedProvider.first(where: { $0.id == reasoningModel })?.supportedReasoningEfforts
            ?? DistillReasoningPolicy.supportedEfforts(for: reasoningModel)
    }

    public var selectedDistillEffortValidationMessage: String? {
        guard provider == .distill else { return nil }
        if let effort = distillMainEffortSelection.effort,
           !supportedReasoningEffortsForSelectedModel.isEmpty,
           !supportedReasoningEffortsForSelectedModel.contains(effort) {
            return "Main effort \(effort.displayName) is unavailable for the selected Distill model. Choose Auto or a supported effort."
        }
        if let reasoningModel, let effort = distillReasoningEffortSelection.effort {
            if !distillReasoningEfforts.isEmpty, !distillReasoningEfforts.contains(effort) {
                return "Worker effort \(effort.displayName) is unavailable for \(reasoningModel). Choose Auto or a supported effort."
            }
            if !selectedProviderCapabilities.supportsDistillReasoningModelEffort {
                return "Update the Distill ACP harness to apply a separate Worker-model effort."
            }
        }
        return nil
    }

    public func normalizeSelectedModelOptions() {
        let efforts = supportedReasoningEffortsForSelectedModel
        if efforts.isEmpty {
            reasoningEffort = .medium
        } else if !efforts.contains(reasoningEffort) {
            reasoningEffort = efforts.contains(.high) ? .high : (efforts.first ?? .medium)
        }
        if provider == .distill {
            let advertisedEfforts = modelOptionsForSelectedProvider.first { $0.id == model }?.supportedReasoningEfforts ?? []
            distillMainEffortSelection = distillMainEffortSelection.normalized(
                for: advertisedEfforts,
                supportsAutomatic: selectedProviderCapabilities.supportsDistillMainEffortAuto
            )
        }
        if provider == .distill, reasoningModel == nil {
            distillReasoningEffortSelection = .automatic
        }
        if !supportsServiceTierForSelectedModel {
            serviceTier = .auto
        }
    }

    /// Cache of on-disk Claude skill/command names keyed by cwd, so the composer
    /// does not re-scan the filesystem on every keystroke. Refreshed lazily when
    /// the cwd changes.
    private var cachedClaudeSlashEntries: (cwd: String, entries: [String])?

    /// Project + user Claude skills/commands for the composer `/` menu. Empty for
    /// non-Claude providers (the discovery is `.claude`-directory specific).
    private func claudeProjectSlashEntries() -> [String] {
        guard selectedProviderSnapshot?.provider == .claude else { return [] }
        let cwd = self.cwd
        if let cached = cachedClaudeSlashEntries, cached.cwd == cwd { return cached.entries }
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let entries = ClaudeSlashCommandDiscovery.discover(cwd: cwd, home: home)
        cachedClaudeSlashEntries = (cwd, entries)
        return entries
    }

    public var mentionableBotsProvider: () -> [BotDefinition] = { [] }
    /// Opens the New Bot flow for this workspace; nil hides "New bot…" in the run-as sheet.
    public var createBotInWorkspace: ((WorkspaceID) -> Void)?
    public var mentionableBotsRevisionProvider: () -> UInt64 = { 0 }

    #if DEBUG
    /// Test-only: bots-provider invocations from `composerSuggestions`.
    nonisolated(unsafe) static var composerMentionableBotsProviderCallCountForTesting: UInt64 = 0
    /// Test-only: Claude slash-catalog loads from `composerSuggestions`.
    nonisolated(unsafe) static var composerClaudeSlashEntriesCallCountForTesting: UInt64 = 0
    #endif

    public var composerSuggestions: [AgentComposerSuggestion] {
        // F1: ordinary typing has no @ / $ token. Gathering bots + Claude slash
        // catalogs before `suggestions` can short-circuit wasted work on every
        // composer body (and every keystroke that republishes suggestions).
        let token = AgentComposerSuggestions.activeToken(
            in: prompt,
            cursorOffset: composerCursorOffset
        )
        guard let trigger = token.first, trigger == "@" || trigger == "/" || trigger == "$" else {
            return []
        }
        let isClaude = selectedProviderSnapshot?.provider == .claude
        let mentionableBots: [BotDefinition]
        if trigger == "@" {
            #if DEBUG
            Self.composerMentionableBotsProviderCallCountForTesting &+= 1
            #endif
            mentionableBots = mentionableBotsProvider()
        } else {
            mentionableBots = []
        }
        let extraSkillNames: [String]
        if isClaude && (trigger == "/" || trigger == "$") {
            #if DEBUG
            Self.composerClaudeSlashEntriesCallCountForTesting &+= 1
            #endif
            extraSkillNames = claudeProjectSlashEntries()
        } else {
            extraSkillNames = []
        }
        return AgentComposerSuggestions.suggestions(
            for: prompt,
            cursorOffset: composerCursorOffset,
            snapshot: selectedProviderSnapshot,
            localSlashCommands: Self.localSlashCommands,
            extraCommands: isClaude
                ? ClaudeSlashCommandDiscovery.builtInClaudeCommands
                : distillAdvertisedCommandNames,
            extraSkillNames: extraSkillNames,
            mentionableBots: mentionableBots,
            commandSubtitles: distillCommandSubtitles
        )
    }

    public func applyComposerSuggestion(_ suggestion: AgentComposerSuggestion) {
        prompt = AgentComposerSuggestions.replacingActiveToken(
            in: prompt,
            cursorOffset: composerCursorOffset,
            with: suggestion.insertText
        )
        promptHistoryCursor = nil
    }

    public func providerDisplayName(_ provider: AgentProvider) -> String {
        providerSnapshots.first { $0.provider == provider }?.displayName ?? provider.rawValue.capitalized
    }

    public func providerInstanceDisplayName(_ id: String) -> String {
        providerSnapshots.first { $0.id == id }?.displayName ?? id
    }

    public var providerStatusMessage: String? {
        guard let snapshot = selectedProviderSnapshot, snapshot.status != .available else { return nil }
        let message = snapshot.statusDetail ?? "\(snapshot.displayName) is \(snapshot.status.rawValue)."
        let signature = "\(snapshot.id)|\(snapshot.status.rawValue)|\(message)"
        return signature == dismissedProviderStatusSignature ? nil : message
    }

    public var providerAccountStatusMessage: String? {
        guard let snapshot = selectedProviderSnapshot,
              let summary = snapshot.accountSummary else { return nil }
        return "\(snapshot.displayName): \(summary)"
    }

    public var providerRecoveryActionTitle: String? {
        guard let snapshot = selectedProviderSnapshot else { return nil }
        if pendingSignInProvider == snapshot.provider,
           pendingSignInSnapshotID == snapshot.id,
           snapshot.authenticated == false {
            return AgentErrorRecoveryAction.retry.title
        }
        return Self.providerRecoveryActionTitle(for: snapshot)
    }

    public static func providerRecoveryActionTitle(for snapshot: AgentProviderSnapshot) -> String? {
        if snapshot.authenticated == false {
            return AgentErrorRecoveryAction.signIn.title
        }
        return snapshot.recoveryActionTitle
    }

    public func performProviderRecoveryAction() async {
        guard let snapshot = selectedProviderSnapshot,
              let title = providerRecoveryActionTitle else { return }
        if title == AgentErrorRecoveryAction.retry.title,
           pendingSignInProvider == snapshot.provider,
           pendingSignInSnapshotID == snapshot.id {
            _ = await refreshPendingProviderAuthentication(retryLastPromptWhenAuthenticated: false)
            return
        }
        if title.hasPrefix("Update") {
            guard let providerRecoveryAction else {
                providerRecoveryStatusMessage = "Update unavailable: app router is not ready."
                return
            }
            providerRecoveryActionRunning = true
            defer { providerRecoveryActionRunning = false }
            do {
                let stdout = try await providerRecoveryAction(snapshot.provider, snapshot.id)
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                providerRecoveryStatusMessage = stdout.isEmpty ? "Update completed." : stdout
                await loadProviderSnapshots()
            } catch {
                providerRecoveryStatusMessage = "Update failed: \(error)"
            }
            return
        }
        if snapshot.authenticated == false {
            providerRecoveryActionRunning = true
            defer { providerRecoveryActionRunning = false }
            beginProviderSignIn(provider: snapshot.provider, snapshotID: snapshot.id)
            return
        }
        let command: String
        switch snapshot.provider {
        case .codex:
            command = "npm install -g @openai/codex"
        case .claude:
            command = "npm install -g @anthropic-ai/claude-code"
        case .grok:
            command = "curl -fsSL https://x.ai/cli/install.sh | bash"
        case .distill:
            providerRecoveryStatusMessage = "Install Distill separately, then set its executable path in Settings."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        providerRecoveryStatusMessage = "Copied: \(command)"
    }

    private func beginProviderSignIn(provider: AgentProvider, snapshotID: String?) {
        guard let providerSignInAction else {
            providerRecoveryStatusMessage = "Sign-in unavailable: app router is not ready."
            return
        }
        do {
            try providerSignInAction(provider)
            pendingSignInProvider = provider
            pendingSignInSnapshotID = snapshotID
            providerRecoveryStatusMessage = "Opened \(providerDisplayName(provider)) sign-in in Terminal. Complete sign-in there, then choose Retry."
        } catch {
            providerRecoveryStatusMessage = "Could not open sign-in Terminal: \(error)"
        }
    }

    @discardableResult
    private func refreshPendingProviderAuthentication(
        retryLastPromptWhenAuthenticated: Bool
    ) async -> Bool {
        guard let pendingSignInProvider else { return false }
        let snapshots: [AgentProviderSnapshot]
        if let providerAuthenticationRefresher {
            snapshots = await providerAuthenticationRefresher(pendingSignInProvider)
        } else if let providerSnapshotLoader {
            do {
                snapshots = try await providerSnapshotLoader()
            } catch {
                providerRecoveryStatusMessage = "Could not refresh authentication status: \(error)"
                return false
            }
        } else {
            await loadProviderSnapshots()
            snapshots = providerSnapshots
        }
        guard !snapshots.isEmpty else {
            providerRecoveryStatusMessage = "Could not refresh authentication status. Choose Retry to try again."
            return false
        }
        applyProviderSnapshots(snapshots)
        let refreshed = snapshots.first {
            if let pendingSignInSnapshotID {
                return $0.id == pendingSignInSnapshotID
            }
            return $0.provider == pendingSignInProvider
        }
        guard refreshed?.authenticated == true else {
            providerRecoveryStatusMessage = "Sign-in is not confirmed yet. Complete it in Terminal, then choose Retry."
            return false
        }
        self.pendingSignInProvider = nil
        pendingSignInSnapshotID = nil
        providerRecoveryStatusMessage = retryLastPromptWhenAuthenticated
            ? "Authentication confirmed. Retrying the request."
            : "Authentication confirmed. Retry your request when ready."
        if retryLastPromptWhenAuthenticated {
            await retryLastPrompt()
        }
        return true
    }

    public var contextHealthMessage: String? {
        AgentContextStatusPresentation.message(
            usage: timeline.tokenUsage,
            compactionSummary: timeline.contextCompactionSummary
        )
    }

    /// A1: the provider (source) is fixed once the thread has a real
    /// conversation — only model/effort stay changeable after that.
    /// P3: system notes (from /status, /clear, etc.) must not count as
    /// "a conversation started", otherwise the source locks after the very
    /// first /status call before any user turn.
    public var providerLocked: Bool {
        selectedThreadId != nil && messages.contains { $0.role != .system }
    }

    /// Provider of the selected thread when RemoteCode no longer runs it (Distill only).
    /// Such threads stay viewable but can never start a provider run.
    public var legacyProviderThreadProvider: AgentProvider? {
        guard let id = selectedThreadId else { return nil }
        let threadProvider = threads.first(where: { $0.id == id })?.provider ?? provider
        return threadProvider.isSelectable ? nil : threadProvider
    }

    public var isLegacyProviderThread: Bool { legacyProviderThreadProvider != nil }

    public var legacyProviderBannerText: String {
        let name = legacyProviderThreadProvider.map(providerDisplayName) ?? ""
        return "This conversation used \(name). MacCode now runs Distill only, so it is read-only."
    }

    /// A thread locked to a bot that was deleted is read-only; the user continues without the bot.
    public var selectedThreadBotUnavailable: Bool {
        guard let id = selectedThreadId,
              let thread = threads.first(where: { $0.id == id }),
              thread.actorLockedAt != nil,
              case .bot(let botID) = thread.actor else { return false }
        return !botIsAvailable(botID)
    }

    private func refuseUnavailableBotThreadRun() -> Bool {
        guard selectedThreadBotUnavailable,
              let id = selectedThreadId,
              case .bot(let botID) = threads.first(where: { $0.id == id })?.actor else { return false }
        let label = botNameProvider(botID).map { "Bot \($0)" } ?? "Bot"
        statusMessage = "\(label) has been deleted. Use \"Continue without bot\"."
        return true
    }

    public var pendingMacExecutionReason: String? {
        selectedThreadId.flatMap { pendingMacExecutionByThread[$0] }
    }

    public func resolveMacExecution(approve: Bool) {
        guard let id = selectedThreadId, pendingMacExecutionByThread[id] != nil else { return }
        pendingMacExecutionByThread[id] = nil
        guard let resolver = botMacExecutionResolver else { return }
        Task { await resolver(id, approve) }
    }

    /// Updates the painted row only; the caller already persisted the target.
    public func mirrorExecutionTarget(_ target: ExecutionTarget, thread id: AgentThreadID) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].executionTarget = target
    }

    /// Blocks the send (true) when a bot thread's workspace is gone or its VM is down. Never falls back to the Mac.
    /// A thread with no workspace (a Bots Desk thread runs in BotHome) has nothing to mount: the gate only
    /// needs the VM up, since BotHome is never a registered workspace and mounting it would always fail.
    private func botVMGateBlocksRun(botID: BotID, thread: AgentThread?) async -> Bool {
        let workspace: String? = embedding != nil && thread?.workspaceId == nil
            ? nil
            : thread?.worktreePath ?? cwd
        if let workspace, !FileManager.default.fileExists(atPath: workspace) {
            statusMessage = "Workspace removed"
            return true
        }
        guard (thread?.executionTarget ?? executionTarget(for: botID)) == .vm else { return false }
        guard let preflight = botVMPreflight else { return false }
        if let failure = await preflight(botID, workspace, thread?.id) {
            statusMessage = "VM unavailable: \(failure)"
            vmUnavailableBotID = botID
            return true
        }
        vmUnavailableBotID = nil
        return false
    }

    /// Links the thread to the bot and locks the thread's actor and execution target.
    private func lockBotActor(botID: BotID, threadId tid: AgentThreadID) throws {
        guard let linker = botThreadLinker else { throw BotRunUnavailableError() }
        let target = botExecutionTargetProvider(botID)
        // The composer's provider belongs to the selected thread only.
        let lockedAt: Date
        do {
            lockedAt = try Self.lockThreadToBot(
                botID: botID,
                threadID: tid,
                target: target,
                composerProvider: selectedThreadId == tid ? provider : nil,
                composerRunAsUser: selectedThreadId == tid ? runAsUser : nil,
                threadRepo: threadRepo,
                linker: linker
            )
        } catch let error as ThreadActorAlreadyLockedError {
            // Another device locked it first: show its lock, never overwrite it.
            if let stored = try? threadRepo.get(id: tid) {
                mirrorActorLock(stored.actor, lockedAt: stored.actorLockedAt, target: stored.executionTarget, thread: tid)
            }
            throw error
        }
        if let index = threads.firstIndex(where: { $0.id == tid }) {
            threads[index].actor = .bot(botID)
            threads[index].actorLockedAt = lockedAt
            threads[index].executionTarget = target
            // iOS parity: paired devices show the lock without a refetch.
            onThreadConfigPersisted?(threads[index])
        }
    }

    /// Links the thread to the bot, writes the guest runtime marker and locks
    /// the thread's actor and execution target. Shared by the composer's first
    /// bot send and `agent.thread.actor.set` from a paired device. Returns the
    /// lock date. `composerProvider` and `composerRunAsUser` are what the
    /// composer will run the thread with; nil reads the thread's own. Throws
    /// `ThreadActorAlreadyLockedError` when the thread is already locked.
    @MainActor
    public static func lockThreadToBot(
        botID: BotID,
        threadID tid: AgentThreadID,
        target: ExecutionTarget,
        composerProvider: AgentProvider?,
        composerRunAsUser: AgentRunAsUser? = nil,
        threadRepo: AgentThreadRepository,
        linker: @MainActor (BotID, AgentThreadID) throws -> Void
    ) throws -> Date {
        let thread = try threadRepo.get(id: tid)
        // Checked before any write: a lock set elsewhere is never overwritten.
        guard thread?.actorLockedAt == nil else { throw ThreadActorAlreadyLockedError() }
        try linker(botID, tid)
        let lockedAt = storedLockDate()
        // Written before the lock: on its own (no `.vm` target yet) the marker routes nothing.
        let previousMarker = try threadRepo.guestPlacement(of: tid)?.guestRuntime
        let marker = guestRuntimeMarker(
            target: target,
            provider: composerProvider ?? thread?.provider,
            runAsUser: composerProvider != nil ? composerRunAsUser : thread?.runAsUser,
            hasMacDistillSession: thread?.provider == .distill && thread?.providerThreadId?.isEmpty == false
        )
        try threadRepo.setGuestRuntime(id: tid, marker)
        guard try threadRepo.lockActorIfUnlocked(
            id: tid, actor: .bot(botID), lockedAt: lockedAt, executionTarget: target
        ) else {
            try? threadRepo.setGuestRuntime(id: tid, previousMarker)
            if try threadRepo.get(id: tid) != nil { throw ThreadActorAlreadyLockedError() }
            throw NSError(
                domain: "RemoteCode.AgentAppViewModel",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "A conversa sumiu antes de iniciar."]
            )
        }
        return lockedAt
    }

    /// Now, at the precision `agent_threads.actor_locked_at` keeps (whole
    /// seconds), so the painted row and its event match what a reload reads.
    public nonisolated static func storedLockDate() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    /// Plan A placement rule, one for every bot lock and for later provider or
    /// run-as-user changes: a Distill thread of a bot on the VM runs inside the
    /// bot's Linux guest, unless it already has a Mac Distill session (D5) or
    /// runs as another macOS user (M9: the guest only gets the app user's own
    /// accounts and the guest resolver refuses such a run).
    public nonisolated static func guestRuntimeMarker(
        target: ExecutionTarget?,
        provider: AgentProvider?,
        runAsUser: AgentRunAsUser?,
        hasMacDistillSession: Bool
    ) -> String? {
        guard target == .vm, provider == .distill, !hasMacDistillSession,
              (runAsUser?.uid ?? getuid()) == getuid() else { return nil }
        return BotGuestRuntime.distillV1
    }

    /// A provider or run-as-user change on a bot-locked thread that has not
    /// started re-derives its guest marker with the lock's rule: a paired
    /// device locks the actor first and picks the provider at its first send.
    /// A started thread keeps its marker (its session lives where it ran).
    /// Returns true when the marker changed.
    @MainActor
    @discardableResult
    public static func resyncGuestRuntimeMarker(
        threadID tid: AgentThreadID,
        threadRepo: AgentThreadRepository,
        messageRepo: AgentMessageRepository
    ) throws -> Bool {
        guard let thread = try threadRepo.get(id: tid), thread.actorLockedAt != nil,
              case .bot = thread.actor, !(try messageRepo.hasAny(threadId: tid)) else { return false }
        let marker = guestRuntimeMarker(
            target: thread.executionTarget,
            provider: thread.provider,
            runAsUser: thread.runAsUser,
            hasMacDistillSession: thread.provider == .distill && thread.providerThreadId?.isEmpty == false
        )
        guard try threadRepo.guestPlacement(of: tid)?.guestRuntime != marker else { return false }
        try threadRepo.setGuestRuntime(id: tid, marker)
        return true
    }

    /// Updates the painted row and, on the selected thread, the actor chip.
    /// The caller already persisted the lock (a paired device set the actor).
    public func mirrorActorLock(_ actor: RunActor, lockedAt: Date?, target: ExecutionTarget?, thread id: AgentThreadID) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].actor = actor
        threads[index].actorLockedAt = lockedAt
        threads[index].executionTarget = target
        if selectedThreadId == id { selectedRunActor = actor }
    }

    /// "Start VM": provisions through the host, then clears the banner.
    public func startUnavailableBotVM() {
        guard let botID = vmUnavailableBotID, let provision = botVMProvision else { return }
        Task {
            if let failure = await provision(botID) {
                statusMessage = "VM unavailable: \(failure)"
            } else {
                vmUnavailableBotID = nil
                statusMessage = ""
            }
        }
    }

    /// "Run this thread on the Mac": explicit user choice, locks the thread to the Mac target.
    public func runSelectedThreadOnMac() {
        guard let botID = vmUnavailableBotID, let tid = selectedThreadId,
              let thread = threads.first(where: { $0.id == tid }) else { return }
        do {
            let lockedAt = thread.actorLockedAt ?? Self.storedLockDate()
            if thread.actorLockedAt == nil {
                guard let linker = botThreadLinker else { throw BotRunUnavailableError() }
                try linker(botID, tid)
            }
            let actor = thread.actorLockedAt == nil ? RunActor.bot(botID) : thread.actor
            guard try threadRepo.setActor(id: tid, actor: actor, lockedAt: lockedAt, executionTarget: .mac) else { return }
            if let index = threads.firstIndex(where: { $0.id == tid }) {
                threads[index].actor = actor
                threads[index].actorLockedAt = lockedAt
                threads[index].executionTarget = .mac
                // iOS parity: paired devices see the move to the Mac at once.
                onThreadConfigPersisted?(threads[index])
            }
            vmUnavailableBotID = nil
            statusMessage = ""
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Deterministic continuation draft: header plus the last user/assistant messages, truncated.
    public static func handoffSummary(title: String, threadId: AgentThreadID, messages: [AgentMessage]) -> String {
        AgentThreadHandoff.summary(title: title, threadId: threadId, messages: messages)
    }

    /// Opens a new thread in this workspace for `actor`, with a draft summarising `oldThreadId`.
    /// The old thread (actor, lock) is untouched.
    @discardableResult
    public func startHandoffThread(from oldThreadId: AgentThreadID, actor: RunActor) -> AgentThreadID? {
        if embedding != nil {
            handoffHost?(oldThreadId, actor)
            return nil
        }
        let old = threads.first(where: { $0.id == oldThreadId })
        let recent = (try? messageRepo.listRecent(threadId: oldThreadId, limit: 50)) ?? []
        let summary = Self.handoffSummary(
            title: old?.title ?? "", threadId: oldThreadId, messages: recent
        )
        createThread(title: "New thread")
        guard let newId = selectedThreadId, newId != oldThreadId else { return nil }
        selectedRunActor = actor
        prompt = summary
        persistComposerDraft(for: newId)
        return newId
    }

    /// Shown when Retry, Continue or a re-run is asked of a surface whose
    /// sends are intercepted (a bot group room or a member's private thread).
    public static let interceptedRunRefusal = "Bots in a group answer from the group. Write in the group."

    /// True when sends are intercepted: nothing may start a provider run here.
    private func refuseInterceptedRun() -> Bool {
        guard embedding?.sendInterceptor != nil else { return false }
        statusMessage = Self.interceptedRunRefusal
        return true
    }

    private func refuseLegacyProviderThreadRun() -> Bool {
        guard isLegacyProviderThread else { return false }
        statusMessage = "This conversation is read-only. Start a new Distill conversation."
        return true
    }
    public var selectedThreadRunIsStartingOrRunning: Bool {
        selectedThreadId.map(isThreadStartingOrRunning) ?? false
    }

    /// True only while the selected thread is still assembling its turn and no
    /// run is tracked yet. Deliberately yields to the running state so the two
    /// status lines can never both render. Does NOT use isThreadStartingOrRunning
    /// because that includes preparation for Stop/Escape chrome.
    public var selectedThreadIsPreparingRun: Bool {
        guard let tid = selectedThreadId, preparingRunThreads.contains(tid) else { return false }
        // Yield only when a tracked/scheduled run has taken over the status line.
        if trackedRunId(for: tid) != nil { return false }
        if isScheduledThreadRunning?(tid) == true { return false }
        return true
    }

    private func beginSurfacePreparation(threadId: AgentThreadID, generation: UInt64, runId: AgentRunID) {
        preparingRunThreads.insert(threadId)
        preparingRunGeneration[threadId] = generation
        preparingRunId[threadId] = runId
        if selectedThreadId == threadId {
            preparingRunThreadId = threadId
        }
    }

    private func endSurfacePreparationIfOwned(threadId: AgentThreadID, generation: UInt64) {
        guard preparingRunGeneration[threadId] == generation else { return }
        preparingRunThreads.remove(threadId)
        preparingRunGeneration.removeValue(forKey: threadId)
        preparingRunId.removeValue(forKey: threadId)
        if preparingRunThreadId == threadId {
            preparingRunThreadId = selectedThreadId.flatMap {
                preparingRunThreads.contains($0) ? $0 : nil
            }
        }
    }

    private func cancelSurfacePreparation(threadId: AgentThreadID) {
        let current = surfacePreparationStates[threadId] ?? ProviderPreparationState()
        surfacePreparationStates[threadId] = ProviderPreparationStateMachine.apply(
            state: current,
            event: .stopRequested
        ).state
        let abandonedRunId = preparingRunId[threadId]
        preparingRunThreads.remove(threadId)
        preparingRunGeneration.removeValue(forKey: threadId)
        preparingRunId.removeValue(forKey: threadId)
        if preparingRunThreadId == threadId {
            preparingRunThreadId = selectedThreadId.flatMap {
                preparingRunThreads.contains($0) ? $0 : nil
            }
        }
        coordinator.cancelPreparation(threadId: threadId)
        // Local Stop does not reach startRun — drop cancel tokens so they cannot leak.
        if let abandonedRunId {
            coordinator.discardProviderStartReservation(threadId: threadId, runId: abandonedRunId)
        }
    }

    /// Busy for Stop/Escape: tracked runs, scheduled runs, or in-flight preparation.
    public var selectedThreadIsStoppableBusy: Bool {
        selectedThreadId.map(isThreadStoppableBusy) ?? false
    }

    /// A fresh thread also uses `.pending` as its persisted idle state. A Stop
    /// affordance therefore needs a run identity, not status alone; otherwise a
    /// never-started thread is rendered as busy and its first prompt is queued.
    public func isThreadStartingOrRunning(_ threadId: AgentThreadID) -> Bool {
        if trackedRunId(for: threadId) != nil { return true }
        // LaunchAgent-owned scheduled runs have no local coordinator session.
        return isScheduledThreadRunning?(threadId) == true
    }

    /// `isThreadStartingOrRunning` for a whole rail pass: one coordinator lock
    /// instead of one per thread on every AgentAppView body (perf).
    public func startingOrRunningThreadIds(among threads: [AgentThread]) -> Set<AgentThreadID> {
        var ids = Set(runThreads.values).union(coordinator.activeThreadIdsSnapshot())
        if let isScheduledThreadRunning {
            for thread in threads where !ids.contains(thread.id) && isScheduledThreadRunning(thread.id) {
                ids.insert(thread.id)
            }
        }
        return ids
    }

    /// S5: Stop/Escape/Send concurrency — includes pre-run preparation.
    public func isThreadStoppableBusy(_ threadId: AgentThreadID) -> Bool {
        if preparingRunThreads.contains(threadId) { return true }
        if coordinator.isPreparingProviderStart(threadId: threadId) { return true }
        return isThreadStartingOrRunning(threadId)
    }

    private func trackedRunId(for threadId: AgentThreadID) -> AgentRunID? {
        runThreads.first(where: { $0.value == threadId })?.key
            ?? coordinator.activeRunId(threadId: threadId)
    }

    // MARK: - Path B (LaunchAgent-owned scheduled run) UI binding

    /// Poll while the selected thread is owned by the LaunchAgent so stream
    /// events written to shared SQLite keep painting without a local coordinator.
    private var scheduledLivePollTask: Task<Void, Never>?
    private var scheduledLiveStreamCount: Int = 0
    private var scheduledLiveStreamCursor: AgentRunRepository.StreamEventCursor?
    private(set) var scheduledLiveApplyCountForTesting = 0

    /// Pure replay plan for LaunchAgent live poll. Idle equal counts skip;
    /// prune, first apply, or overflow of the hot-replay cap full-replay;
    /// in-cap growth applies only the suffix.
    enum ScheduledLiveReplayPlan: Equatable, Sendable {
        case skip
        case suffix(offset: Int)
        case fullReplay
    }

    nonisolated static func scheduledLiveReplayPlan(
        previousCount: Int,
        currentCount: Int,
        cap: Int
    ) -> ScheduledLiveReplayPlan {
        if previousCount == currentCount { return .skip }
        if previousCount == 0 || currentCount < previousCount || currentCount > cap {
            return .fullReplay
        }
        return .suffix(offset: previousCount)
    }

    /// Idle 2s ticks already have run chrome from bindScheduledOwnedRun.
    /// Re-read durable chrome only when the stream moved or the run id is unset.
    nonisolated static func shouldRefreshScheduledLiveChrome(
        countChanged: Bool,
        hasBoundRunId: Bool
    ) -> Bool {
        countChanged || !hasBoundRunId
    }

    /// Seed Working-for clock + run id from durable agent_runs and start live poll.
    private func bindScheduledOwnedRun(threadId: AgentThreadID) {
        let durable = try? coordinator.durableActiveRunChrome(threadId: threadId)
        runStartedAt = AgentAppViewModel.resolvedRunStartedAt(
            current: runStartedAt,
            persisted: durable?.startedAt ?? (try? coordinator.runStartedAt(threadId: threadId))
        )
        if let durable {
            currentRunId = durable.id
            runThreads[durable.id] = threadId
            if status != .running { status = .running }
        }
        ensureScheduledLivePoll(for: threadId)
    }

    /// Pure change-detection for LaunchAgent live poll. Rebuild only when the
    /// durable stream event count moves (growth or prune). Unit-testable without
    /// decoding payloads.
    nonisolated static func shouldRebuildScheduledLiveTimeline(
        previousCount: Int,
        currentCount: Int
    ) -> Bool {
        previousCount != currentCount
    }

    private func ensureScheduledLivePoll(for threadId: AgentThreadID) {
        guard scheduledLivePollTask == nil else { return }
        // COUNT(*) + cursor only — do not decode hot-replay payloads just to seed.
        scheduledLiveStreamCount = coordinator.countStreamEvents(threadId: threadId)
        scheduledLiveStreamCursor = coordinator.streamEventCursor(threadId: threadId)
        scheduledLivePollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // 2s is enough for LaunchAgent-owned progress; 1s doubled MainActor work.
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, !self.isDisposed else { return }
                self.tickScheduledLivePoll()
            }
        }
    }

    private func stopScheduledLivePoll() {
        scheduledLivePollTask?.cancel()
        scheduledLivePollTask = nil
        scheduledLiveStreamCount = 0
        scheduledLiveStreamCursor = nil
        scheduledLiveApplyCountForTesting = 0
    }

    func tickScheduledLivePollForTesting() {
        tickScheduledLivePoll()
    }

    private func tickScheduledLivePoll() {
        guard let id = selectedThreadId else {
            stopScheduledLivePoll()
            return
        }
        guard isScheduledThreadRunning?(id) == true else {
            // Run finished in the LaunchAgent; one full rebind picks up terminal state.
            stopScheduledLivePoll()
            selectThread(id, markRead: false)
            return
        }
        // Idle polls: cheap COUNT(*) first. Cursor disagreement (window slide at
        // equal COUNT) fail-closes to a full replay. In-cap growth uses the
        // attested suffix and never zeros the already-applied prefix.
        let count = coordinator.countStreamEvents(threadId: id)
        let cursor = coordinator.streamEventCursor(threadId: id)
        let previousCount = scheduledLiveStreamCount
        let previousCursor = scheduledLiveStreamCursor
        var plan = Self.scheduledLiveReplayPlan(
            previousCount: previousCount,
            currentCount: count,
            cap: AgentRunCoordinator.hotReplayEventCount
        )
        if case .skip = plan, previousCursor != cursor {
            plan = .fullReplay
        }
        if Self.shouldRefreshScheduledLiveChrome(
            countChanged: plan != .skip,
            hasBoundRunId: currentRunId != nil
        ), let durable = try? coordinator.durableActiveRunChrome(threadId: id) {
            runStartedAt = AgentAppViewModel.resolvedRunStartedAt(
                current: runStartedAt,
                persisted: durable.startedAt
            )
            currentRunId = durable.id
            runThreads[durable.id] = id
            if status != .running { status = .running }
        }
        if plan != .skip, hiddenTimelineArchive != nil {
            // The suffix must extend the archived tree. The cursor is not
            // advanced, so the next tick applies the same events once the
            // off-main restore has landed.
            restoreColdTimelineOffMain()
            return
        }
        scheduledLiveApplyCountForTesting = 0
        switch plan {
        case .skip:
            break
        case .suffix:
            let suffixEvents = attestedScheduledLiveSuffix(
                threadId: id,
                previous: previousCursor,
                current: cursor
            )
            if let suffixEvents {
                applyScheduledLiveEvents(suffixEvents, resetTimeline: false)
                scheduledLiveStreamCount = count
                scheduledLiveStreamCursor = cursor
                rehydrateDurableActiveState(threadId: id)
                scheduleTimelineUpdateTick()
            } else {
                applyScheduledLiveFullReplay(threadId: id, count: count, cursor: cursor)
            }
        case .fullReplay:
            applyScheduledLiveFullReplay(threadId: id, count: count, cursor: cursor)
        }
    }

    private func attestedScheduledLiveSuffix(
        threadId: AgentThreadID,
        previous: AgentRunRepository.StreamEventCursor?,
        current: AgentRunRepository.StreamEventCursor
    ) -> [AssistantEvent]? {
        guard let previous,
              let runId = current.runId,
              previous.runId == runId,
              current.sequence > previous.sequence,
              let previousMutationId = previous.mutationId,
              let mutationId = current.mutationId
        else { return nil }
        let advance = current.sequence - previous.sequence
        guard let suffix = coordinator.attestedStreamEventSuffix(
            threadId: threadId,
            afterMutationId: previousMutationId,
            throughMutationId: mutationId,
            runId: runId,
            startingSequence: previous.sequence + 1,
            count: advance
        ), suffix.events.count == advance else { return nil }
        return suffix.events
    }

    private func applyScheduledLiveFullReplay(
        threadId: AgentThreadID,
        count: Int,
        cursor: AgentRunRepository.StreamEventCursor
    ) {
        applyScheduledLiveEvents(
            coordinator.latestStreamEvents(threadId: threadId),
            resetTimeline: true
        )
        scheduledLiveStreamCount = count
        scheduledLiveStreamCursor = cursor
        rehydrateDurableActiveState(threadId: threadId)
        scheduleTimelineUpdateTick()
    }

    private func applyScheduledLiveEvents(_ events: [AssistantEvent], resetTimeline: Bool) {
        scheduledLiveApplyCountForTesting += events.count
        if surfaceVisibility == .hidden {
            var hidden = resetTimeline
                ? AssistantTimelineState()
                : (latestHiddenTimeline ?? AssistantTimelineState())
            for event in events {
                hidden.apply(event)
            }
            hidden.enforceAggregateHotTextBudget()
            latestHiddenTimeline = hidden
            return
        }
        let protectedIDs = protectedTranscriptTurnIDs
        var next = resetTimeline ? AssistantTimelineState() : timeline
        for event in events {
            next.apply(event)
        }
        if resetTimeline {
            next.retainMissingTurns(from: timeline, protectedTurnIDs: protectedIDs)
        }
        next.enforceAggregateHotTextBudget(protectedTurnIDs: protectedIDs)
        timeline = next
    }

    public var executionLocked: Bool { providerLocked || selectedThreadRunIsStartingOrRunning }
    public var activeRunConfigurationLocked: Bool {
        selectedThreadRunIsStartingOrRunning
            || selectedThreadId.map { coordinator.activeThreadIdsSnapshot().contains($0) } == true
            || selectedThreadId.map { coordinator.hasProviderSession(threadId: $0) } == true
    }

    public func setProviderInstance(_ id: String) {
        guard !executionLocked else { return }
        guard let snapshot = providerSnapshots.first(where: { $0.id == id }) else { return }
        sourceSelectionUserPinned = true
        providerInstanceId = snapshot.id
        provider = snapshot.provider
        if provider == .distill {
            routingMode = .manual
        }
        // F10/F33: same flag coherence as applyProviderSnapshots — snapshot
        // rows replace the VM's own fetch, so a stale fallback flag must not
        // put a false "built-in defaults" warning on the new instance's list.
        if availableModelsAreFallback {
            availableModelsAreFallback = snapshot.models.map(\.id) == availableModels.map(\.id)
        }
        availableModels = snapshot.models
        applyPreferredModelForCurrentProvider(availableModels: snapshot.models)
        normalizeSelectedModelOptions()
        normalizeInteractionModeForSelectedProvider()
        persistThreadConfig()
    }

    public func setProvider(_ newProvider: AgentProvider) {
        guard !executionLocked else { return }
        applyProvider(newProvider)
    }

    /// `persistToSelectedThread: false` switches only the composer, for a new thread
    /// started while a read-only legacy thread is selected.
    private func applyProvider(_ newProvider: AgentProvider, persistToSelectedThread: Bool = true) {
        if let selectedThreadId { persistComposerDraft(for: selectedThreadId) }
        let previousProvider = provider
        sourceSelectionUserPinned = true
        provider = newProvider
        if newProvider == .distill {
            routingMode = .manual
        }
        // Prefer a real snapshot id when snapshots are loaded so Source stays
        // checkmarked after a Source switch (ids are "codex-cli", not "codex").
        if let snap = providerSnapshots.first(where: { $0.provider == newProvider && $0.enabled })
            ?? providerSnapshots.first(where: { $0.provider == newProvider }) {
            providerInstanceId = snap.id
            if snap.modelDiscoverySource != nil {
                availableModelsAreFallback = snap.modelListIsFallback
            } else if availableModelsAreFallback {
                availableModelsAreFallback = snap.models.map(\.id) == availableModels.map(\.id)
            }
            availableModels = snap.models
            applyPreferredModelForCurrentProvider(availableModels: snap.models)
        } else {
            providerInstanceId = newProvider.rawValue
            availableModels = []
            applyPreferredModelForCurrentProvider(availableModels: [])
        }
        if let selectedThreadId {
            restoreComposerDraft(
                threadId: selectedThreadId,
                providerInstanceId: providerInstanceId,
                fallbackInteractionMode: .default
            )
        }
        normalizeSelectedModelOptions()
        if newProvider == .distill, previousProvider != .distill {
            let efforts = supportedReasoningEffortsForSelectedModel
            distillMainEffortSelection = efforts.isEmpty
                ? .automatic
                : .fixed(efforts.contains(.medium) ? .medium : (efforts.contains(.high) ? .high : efforts[0]))
            distillReasoningEffortSelection = .automatic
        }
        normalizeInteractionModeForSelectedProvider()
        if persistToSelectedThread { persistThreadConfig() }
    }

    /// Persist the chosen run configuration onto the selected thread so a
    /// resumed run uses the right source, model, permission, and effort.
    @discardableResult
    public func persistThreadConfig() -> Bool {
        normalizeSelectedModelOptions()
        rememberNewThreadDefaults()
        guard let id = selectedThreadId else { return false }
        // Painted rail already holds the config persist would write. A leftover
        // 26-column + routing `get` then `upsert` hitchs every composer send
        // and bumps routing revision even when picker/permission/run-as-user
        // did not change.
        if let painted = threads.first(where: { $0.id == id }),
           (provider != .distill || painted.effectiveRoutingConfiguration.mode == .manual),
           Self.paintedThreadMatchesPersistedConfig(
                painted,
                provider: provider,
                providerInstanceId: providerInstanceId,
                runAsUser: runAsUser,
                model: model,
                permissionMode: permissionMode,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier,
                modelSelection: currentModelSelection,
                interactionMode: interactionMode,
                reasoningModel: reasoningModel
           ) {
            persistComposerDraft(for: id)
            return true
        }
        do {
            let now = Date()
            let painted = threads.first(where: { $0.id == id })
            let routingBase: AgentRoutingConfiguration
            if let painted {
                routingBase = painted.effectiveRoutingConfiguration
            } else if let stored = try threadRepo.routingConfiguration(of: id) {
                routingBase = stored
            } else {
                routingBase = .legacyManual(
                    selection: currentModelSelection,
                    providerInstanceId: providerInstanceId,
                    updatedAt: now
                )
            }
            let nextRouting = try routingBase.replacing(
                expectedRevision: routingBase.revision,
                mode: provider == .distill ? .manual : routingBase.mode,
                manualSelection: currentModelSelection,
                manualProviderInstanceId: providerInstanceId,
                eligibleProviders: routingBase.eligibleProviders,
                policyDigest: routingBase.policyDigest,
                updatedAt: now
            )
            // Picker chrome + routing CAS only. A leftover 26-column `get`
            // then full-row `upsert` hitchs model/permission changes and
            // rewrites title/status/unread/color/pin/execution.
            guard try threadRepo.setPickerConfig(
                of: id,
                provider: provider,
                providerInstanceId: providerInstanceId,
                runAsUser: runAsUser,
                model: model,
                permissionMode: permissionMode,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier,
                modelSelection: currentModelSelection,
                interactionMode: interactionMode,
                reasoningModel: reasoningModel,
                at: now
            ) else {
                statusMessage = "Could not save thread configuration: thread not found."
                return false
            }
            try threadRepo.setRoutingConfiguration(
                nextRouting,
                threadId: id,
                expectedRevision: routingBase.revision
            )
            // A thread a paired device locked to a bot gets its provider here.
            if let painted, painted.actorLockedAt != nil,
               painted.provider != provider || painted.runAsUser != runAsUser {
                try Self.resyncGuestRuntimeMarker(threadID: id, threadRepo: threadRepo, messageRepo: messageRepo)
            }
            if let i = threads.firstIndex(where: { $0.id == id }) {
                threads[i].provider = provider
                threads[i].providerInstanceId = providerInstanceId
                threads[i].runAsUser = runAsUser
                threads[i].model = model
                threads[i].permissionMode = permissionMode
                threads[i].reasoningEffort = reasoningEffort
                threads[i].reasoningModel = reasoningModel
                threads[i].serviceTier = serviceTier
                threads[i].modelSelection = currentModelSelection
                threads[i].interactionMode = interactionMode
                threads[i].updatedAt = now
                threads[i].routingConfiguration = nextRouting
                persistComposerDraft(for: id)
                onThreadConfigPersisted?(threads[i])
            } else {
                persistComposerDraft(for: id)
            }
            return true
        } catch {
            if let stored = try? threadRepo.get(id: id) { restoreThreadConfiguration(from: stored) }
            statusMessage = "Could not save thread configuration: \(error)"
            return false
        }
    }

    /// Config persist would only copy picker/permission/run-as-user onto the
    /// painted row. Matching means SQLite already has that chrome.
    nonisolated static func paintedThreadMatchesPersistedConfig(
        _ painted: AgentThread,
        provider: AgentProvider,
        providerInstanceId: String,
        runAsUser: AgentRunAsUser?,
        model: String,
        permissionMode: AgentPermissionMode,
        reasoningEffort: AgentReasoningEffort,
        serviceTier: AgentServiceTier,
        modelSelection: AgentModelSelection,
        interactionMode: AgentInteractionMode,
        reasoningModel: String? = nil
    ) -> Bool {
        let routing = painted.effectiveRoutingConfiguration
        return painted.provider == provider
            && (painted.providerInstanceId ?? painted.provider.rawValue) == providerInstanceId
            && painted.runAsUser == runAsUser
            && painted.model == model
            && painted.permissionMode == permissionMode
            && painted.reasoningEffort == reasoningEffort
            && painted.reasoningModel == reasoningModel
            && painted.serviceTier == serviceTier
            && painted.modelSelection == modelSelection
            && painted.effectiveInteractionMode == interactionMode
            && routing.manualSelection == modelSelection
            && (routing.manualProviderInstanceId ?? painted.provider.rawValue) == providerInstanceId
    }

    /// Changes the thread-owned routing mode with optimistic revision protection.
    /// Auto never overwrites the manual picker values; disabling it restores the
    /// exact provider/model/effort/tier captured when Auto was enabled.
    @discardableResult
    public func setAutoModelRoutingEnabled(_ enabled: Bool) -> Bool {
        guard provider != .distill || !enabled else { return false }
        guard let id = selectedThreadId else {
            routingMode = enabled ? .auto : .manual
            rememberNewThreadDefaults()
            statusMessage = ""
            return true
        }
        do {
            // Routing chrome only. A leftover 26-column `get` before Auto
            // toggle and another `get` after CAS hitchs the composer switch.
            let storedRouting = try threadRepo.routingConfiguration(of: id)
            let current: AgentRoutingConfiguration
            if let storedRouting {
                current = storedRouting
            } else if let picker = try threadRepo.threadWithoutRouting(of: id) {
                current = picker.effectiveRoutingConfiguration
            } else {
                statusMessage = "Could not save Auto model routing: thread not found."
                return false
            }
            let requestedMode: AgentRoutingMode = enabled ? .auto : .manual
            guard current.mode != requestedMode else { return true }

            let updatedConfiguration: AgentRoutingConfiguration
            if enabled {
                updatedConfiguration = try orchestrationRuntime.autoConfiguration(
                    replacing: current,
                    expectedRevision: current.revision,
                    manualSelection: currentModelSelection,
                    manualProviderInstanceId: providerInstanceId,
                    providerSnapshots: providerSnapshots
                )
            } else {
                updatedConfiguration = try orchestrationRuntime.manualConfiguration(
                    replacing: current,
                    expectedRevision: current.revision
                )
            }
            try threadRepo.setRoutingConfiguration(
                updatedConfiguration,
                threadId: id,
                expectedRevision: current.revision
            )
            var persisted: AgentThread
            if let index = threads.firstIndex(where: { $0.id == id }) {
                threads[index].routingConfiguration = updatedConfiguration
                threads[index].updatedAt = updatedConfiguration.updatedAt
                persisted = threads[index]
            } else if var picker = try threadRepo.threadWithoutRouting(of: id) {
                picker.routingConfiguration = updatedConfiguration
                picker.updatedAt = updatedConfiguration.updatedAt
                persisted = picker
            } else {
                statusMessage = "Could not restore the persisted routing configuration."
                return false
            }
            routingMode = updatedConfiguration.mode
            rememberNewThreadDefaults()
            if !enabled {
                restoreThreadConfiguration(from: persisted)
            }
            statusMessage = ""
            onThreadConfigPersisted?(persisted)
            return true
        } catch {
            let latestRouting = try? threadRepo.routingConfiguration(of: id) ?? nil
            if let index = threads.firstIndex(where: { $0.id == id }) {
                if let latestRouting {
                    threads[index].routingConfiguration = latestRouting
                }
                restoreThreadConfiguration(from: threads[index])
            } else if var picker = try? threadRepo.threadWithoutRouting(of: id) {
                picker.routingConfiguration = latestRouting
                restoreThreadConfiguration(from: picker)
            }
            statusMessage = "Could not save Auto model routing: \(error)"
            return false
        }
    }

    private func restoreThreadConfiguration(from thread: AgentThread) {
        let routing = thread.effectiveRoutingConfiguration
        let forceManualForDistill = routing.mode == .auto && routing.manualSelection.provider == .distill
        routingMode = forceManualForDistill ? .manual : routing.mode
        provider = routing.manualSelection.provider
        providerInstanceId = routing.manualProviderInstanceId ?? routing.manualSelection.provider.rawValue
        runAsUser = thread.runAsUser ?? AgentRunAsUser.current()
        selectedRunActor = thread.actor
        model = routing.manualSelection.effectiveModel
        permissionMode = thread.permissionMode
        reasoningEffort = routing.manualSelection.reasoningEffort
        reasoningModel = thread.reasoningModel
        serviceTier = routing.manualSelection.serviceTier
        interactionMode = thread.effectiveInteractionMode
        normalizeInteractionModeForSelectedProvider()
        if let i = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[i] = thread
        }
    }

    /// Actor chip lock: first real message or a persisted actor lock.
    public var runActorLocked: Bool {
        let lockedAt = selectedThreadId.flatMap { id in threads.first(where: { $0.id == id })?.actorLockedAt }
        return AgentRunAsUserPresentation.identityLocked(providerLocked: providerLocked, actorLockedAt: lockedAt)
    }

    /// Locked threads show the stored target; otherwise the bot's default.
    public func executionTarget(for botID: BotID) -> ExecutionTarget {
        let thread = selectedThreadId.flatMap { id in threads.first(where: { $0.id == id }) }
        if thread?.actorLockedAt != nil, let stored = thread?.executionTarget { return stored }
        return botExecutionTargetProvider(botID)
    }

    /// Picks who runs the next send. Refused once the thread is locked or running.
    public func setRunActor(_ actor: RunActor) {
        guard !runActorLocked else { return }
        guard !selectedThreadRunIsStartingOrRunning else { return }
        selectedRunActor = actor
    }

    /// Select the macOS account that will execute provider processes through the shared helper.
    /// Locked after the first real conversation message, same as provider source.
    public func setRunAsUser(_ user: AgentRunAsUser) {
        guard !providerLocked else { return }
        guard !selectedThreadRunIsStartingOrRunning else { return }
        // Re-resolve against the live directory so deleted/recreated accounts fail closed.
        if let live = MacOSLocalUserCatalog.resolve(shortName: user.shortName) {
            runAsUser = live
        } else {
            runAsUser = user
        }
        persistThreadConfig()
        // Binary/auth probes are runAsUser-aware — refresh so Auto admits the
        // account that will actually exec (not the previous user's snapshot).
        Task { await loadProviderSnapshots() }
    }

    public func refreshAvailableRunAsUsers() {
        availableRunAsUsers = MacOSLocalUserCatalog.listEligibleUsers()
        if let selected = runAsUser,
           let live = MacOSLocalUserCatalog.resolve(shortName: selected.shortName) {
            runAsUser = live
        } else if runAsUser == nil {
            runAsUser = AgentRunAsUser.current()
        }
    }

    /// Bot reply style (```choices blocks shown as a card) applies to Bot
    /// threads only: the Bot desk, or a thread a Bot runs. A plain Agent App
    /// reply that quotes a ```choices fence keeps it as written.
    public var showsBotChoices: Bool {
        embedding != nil || selectedRunActor.botID != nil
    }

    var linkedBotVMRequiresFullAccess: Bool {
        guard selectedRunActor.botID != nil,
              let selectedThreadId,
              let thread = threads.first(where: { $0.id == selectedThreadId }) else { return false }
        return thread.executionTarget == .vm
    }

    public func setPermissionMode(_ mode: AgentPermissionMode) {
        guard !linkedBotVMRequiresFullAccess || mode == .fullAccess else { return }
        guard !activeRunConfigurationLocked else { return }
        guard supportedPermissionModesForSelectedProvider.contains(mode) else {
            statusMessage = permissionModeUnavailableReason(mode) ?? "Permission mode is unavailable for this session."
            return
        }
        permissionMode = mode
        persistThreadConfig()
        if mode == .fullAccess {
            scheduleFullAccessPlanAutoImplementIfNeeded()
        }
    }

    /// Persist an async callback's permission escalation against the thread that
    /// owned the card, not whichever thread is selected when the await returns.
    private func setPermissionMode(_ mode: AgentPermissionMode, for threadId: AgentThreadID) {
        do {
            let now = Date()
            // Permission chrome only. A leftover 26-column + routing `get` then
            // full-row `upsert` hitchs session-grant persist and rewrites routing.
            guard try threadRepo.setPermissionMode(of: threadId, permissionMode: mode, at: now) else { return }
            if let index = threads.firstIndex(where: { $0.id == threadId }) {
                threads[index].permissionMode = mode
                threads[index].updatedAt = now
                onThreadConfigPersisted?(threads[index])
            }
            if selectedThreadId == threadId {
                permissionMode = mode
            }
        } catch {
            statusMessage = "Could not save permission mode: \(error)"
        }
    }

    public func setReasoningEffort(_ effort: AgentReasoningEffort) {
        let efforts = supportedReasoningEffortsForSelectedModel
        reasoningEffort = efforts.isEmpty ? .medium : (efforts.contains(effort) ? effort : (efforts.first ?? .medium))
        if provider == .distill {
            distillMainEffortSelection = .fixed(reasoningEffort)
        }
        persistThreadConfig()
    }

    public func setDistillMainEffortSelection(_ selection: AgentEffortSelection) {
        guard provider == .distill else { return }
        if selection.isAutomatic,
           !selectedProviderCapabilities.supportsDistillMainEffortAuto {
            statusMessage = "Update the Distill ACP session to enable Auto Main effort."
            return
        }
        if let effort = selection.effort {
            let supported = supportedReasoningEffortsForSelectedModel
            guard supported.isEmpty || supported.contains(effort) else { return }
            reasoningEffort = effort
        }
        distillMainEffortSelection = selection
        persistThreadConfig()
    }

    public func setDistillExecutionMode(_ mode: DistillExecutionMode) {
        guard provider == .distill else { return }
        distillExecutionMode = mode
        persistThreadConfig()
    }

    public func setDistillReasoningEffortSelection(_ selection: AgentEffortSelection) {
        guard provider == .distill,
              selectedProviderCapabilities.supportsDistillReasoningModelEffort,
              reasoningModel != nil else { return }
        if let effort = selection.effort,
           !distillReasoningEfforts.isEmpty,
           !distillReasoningEfforts.contains(effort) { return }
        distillReasoningEffortSelection = selection
        persistThreadConfig()
    }

    public func setServiceTier(_ tier: AgentServiceTier) {
        serviceTier = supportsServiceTierForSelectedModel ? tier : .auto
        persistThreadConfig()
    }

    /// IMP-MAC_AGENT-006: cycle reasoning effort across the model's supported
    /// efforts (for the Cmd+Shift+. power-user shortcut). No-op when the model
    /// has no reasoning efforts. Returns the new effort for transient feedback.
    @discardableResult
    public func cycleReasoningEffort() -> AgentReasoningEffort? {
        let efforts = supportedReasoningEffortsForSelectedModel
        guard !efforts.isEmpty else { return nil }
        let index = efforts.firstIndex(of: reasoningEffort) ?? -1
        let next = efforts[(index + 1) % efforts.count]
        setReasoningEffort(next)
        return next
    }

    public func setExecutionMode(_ mode: AgentExecutionMode) {
        guard !executionLocked else { return }
        executionMode = mode
        if mode == .worktree, baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            baseBranch = gitBranch ?? "main"
        }
        persistThreadExecutionConfig()
    }

    public func setBaseBranch(_ branch: String) {
        guard !executionLocked else { return }
        baseBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if executionMode == .worktree {
            persistThreadExecutionConfig()
        }
    }

    @discardableResult
    public func persistThreadExecutionConfig() -> Bool {
        guard let id = selectedThreadId else { return false }
        let branch = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextBranch = executionMode == .worktree ? (branch.isEmpty ? (gitBranch ?? "main") : branch) : nil
        // Execution chrome only. A leftover 26-column + routing `get` then
        // full-row `upsert` hitchs local↔worktree switches and rewrites routing.
        do {
            let now = Date()
            guard try threadRepo.setExecutionConfig(
                of: id,
                executionMode: executionMode,
                baseBranch: nextBranch,
                at: now
            ) else { return false }
            if let i = threads.firstIndex(where: { $0.id == id }) {
                threads[i].executionMode = executionMode
                threads[i].baseBranch = nextBranch
                if executionMode == .local { threads[i].worktreePath = nil }
                threads[i].updatedAt = now
            }
            return true
        } catch {
            if let stored = try? threadRepo.get(id: id) {
                executionMode = stored.executionMode
                baseBranch = stored.baseBranch ?? gitBranch ?? "main"
                worktreePath = stored.worktreePath
                if let i = threads.firstIndex(where: { $0.id == id }) { threads[i] = stored }
            }
            statusMessage = "Could not save thread execution settings: \(error)"
            return false
        }
    }

    public func setModel(_ model: String) {
        self.model = model
        rememberCurrentModel()
        normalizeSelectedModelOptions()
        persistThreadConfig()
    }

    public func setReasoningModel(_ model: String?) {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextModel = trimmed.isEmpty ? nil : trimmed
        if nextModel == nil {
            distillReasoningEffortSelection = .automatic
        }
        reasoningModel = nextModel
        persistThreadConfig()
    }

    public func setCustomModel(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsCustomModelForSelectedProvider else { return }
        if !trimmed.isEmpty {
            customModelStore?.add(trimmed, provider: provider)
            var values = customModelsByProvider[provider] ?? []
            if !values.contains(trimmed) {
                values.append(trimmed)
                customModelsByProvider[provider] = values
            }
        }
        model = trimmed.isEmpty
            ? preferredModelForCurrentProvider(availableModels: modelOptionsForSelectedProvider)
            : trimmed
        rememberCurrentModel()
        normalizeSelectedModelOptions()
        persistThreadConfig()
    }

    public func createThread(title: String) {
        // A legacy (read-only) thread leaves its provider on the VM; new threads are Distill.
        if !provider.isSelectable {
            applyProvider(.distill, persistToSelectedThread: false)
            guard provider.isSelectable else { return }
        }
        // New threads always reopen on the last model the user used for this
        // provider (not whatever model an older selected thread left on the VM).
        applyPreferredModelForCurrentProvider()
        normalizeSelectedModelOptions()
        // New threads start in Full Access; the user can lower it per thread.
        if supportedPermissionModesForSelectedProvider.contains(.fullAccess) {
            permissionMode = .fullAccess
        }
        // Auto admission requires revision > 0 and a current policy digest.
        // Leaving revision at the default 0 makes every first Auto send fail with
        // AgentOrchestrationAdmissionError.invalidPolicy (NSError code 4).
        let routingConfiguration = AgentRoutingConfiguration(
            mode: routingMode,
            manualSelection: currentModelSelection,
            manualProviderInstanceId: providerInstanceId,
            eligibleProviders: AgentProvider.selectable,
            policyDigest: routingMode == .auto ? orchestrationRuntime.policyDigest : "",
            revision: routingMode == .auto ? 1 : 0
        )
        let t = AgentThread(workspaceId: workspaceID, title: title, provider: provider,
                            providerInstanceId: providerInstanceId,
                            model: model,
                            permissionMode: permissionMode, reasoningEffort: reasoningEffort,
                            reasoningModel: reasoningModel,
                            serviceTier: serviceTier, modelSelection: currentModelSelection,
                            runAsUser: runAsUser, routingConfiguration: routingConfiguration)
        // The chip choice made before the thread existed survives selection; it is written at first send.
        let pendingRunActor = selectedRunActor
        let prunedThreadIDs: [AgentThreadID]
        do {
            prunedThreadIDs = try threadRepo.upsertEnforcingWorkspaceThreadLimit(t)
        } catch {
            statusMessage = "Could not create thread: \(error)"
            return
        }
        if !prunedThreadIDs.isEmpty {
            retireCommittedThreadPrunes(prunedThreadIDs)
            applyAuthoritativeThreadDeletions(Set(prunedThreadIDs))
            onThreadLifecycle?(.deleted(prunedThreadIDs))
        }
        if selectedThreadId == nil {
            // A fresh composer can hold user input, including a draft preserved
            // from an automatically pruned selection. Bind that input to the
            // new row before selectThread restores its thread-scoped draft.
            persistComposerDraft(for: t.id)
        }
        reloadThreads()
        onThreadLifecycle?(.created(threads.first(where: { $0.id == t.id }) ?? t))
        selectThread(t.id)
        selectedRunActor = pendingRunActor
    }

    /// Delete every thread in this workspace (stops active providers first).
    @Published private var dismissedThreadActivity: [String: Double] = UserDefaults.standard.dictionary(forKey: "agent.dismissedThreadActivity") as? [String: Double] ?? [:]

    public func threadNotificationDismissed(_ thread: AgentThread) -> Bool {
        dismissedThreadActivity[thread.id.value.uuidString] == thread.updatedAt.timeIntervalSince1970
    }

    public func clearAllThreads() async -> Bool {
        for thread in threads {
            if thread.hasUnread {
                guard let markThreadRead else { return false }
                do { try markThreadRead(thread.id) }
                catch { reloadThreads(); return false }
            }
            dismissedThreadActivity[thread.id.value.uuidString] = thread.updatedAt.timeIntervalSince1970
            if let index = threads.firstIndex(where: { $0.id == thread.id }) { threads[index].hasUnread = false }
        }
        UserDefaults.standard.set(dismissedThreadActivity, forKey: "agent.dismissedThreadActivity")
        return true
    }

    private func restoreNewThreadDefaults(_ saved: AgentNewThreadDefaults) {
        routingMode = saved.provider == .distill ? .manual : saved.routingMode
        runAsUser = saved.runAsUser ?? AgentRunAsUser.current()
        provider = saved.provider
        providerInstanceId = saved.providerInstanceId
        model = saved.model
        lastModelStore.remember(model: saved.model, for: saved.provider)
        reasoningEffort = saved.reasoningEffort
        distillMainEffortSelection = saved.distillMainEffortSelection
            ?? (saved.provider == .distill ? .fixed(saved.reasoningEffort) : .automatic)
        distillReasoningEffortSelection = saved.distillReasoningEffortSelection ?? .automatic
        if saved.provider == .distill, saved.routingMode == .auto {
            rememberNewThreadDefaults()
        }
    }

    private func rememberNewThreadDefaults() {
        newThreadDefaultsStore?.save(AgentNewThreadDefaults(
            routingMode: routingMode,
            runAsUser: runAsUser,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            reasoningEffort: reasoningEffort,
            distillMainEffortSelection: provider == .distill ? distillMainEffortSelection : nil,
            distillReasoningEffortSelection: provider == .distill ? distillReasoningEffortSelection : nil
        ))
    }

    /// Resolve last-used → built-in default → first listed model for the
    /// active provider. Used for new threads and provider switches.
    public func preferredModelForCurrentProvider(
        availableModels: [AgentModelDescriptor]? = nil
    ) -> String {
        let options = availableModels ?? modelOptionsForSelectedProvider
        return AgentDefaultModelSelection.resolve(
            provider: provider,
            lastUsed: lastModelStore.model(for: provider),
            availableModelIds: options.map(\.id),
            supportsCustomModel: options.contains(where: \.supportsCustomModel)
                || supportsCustomModelForSelectedProvider
        )
    }

    public func applyPreferredModelForCurrentProvider(
        availableModels: [AgentModelDescriptor]? = nil
    ) {
        model = preferredModelForCurrentProvider(availableModels: availableModels)
    }

    public func rememberCurrentModel() {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Never poison last-model with a foreign provider id after rebind.
        if modelIsFromAnotherProvider(trimmed) { return }
        let options = modelOptionsForSelectedProvider
        let known = options.contains(where: { $0.id == trimmed })
            || (customModelsByProvider[provider] ?? []).contains(trimmed)
        let allowCustom = options.contains(where: \.supportsCustomModel)
            || supportsCustomModelForSelectedProvider
        guard known || allowCustom else { return }
        lastModelStore.remember(model: trimmed, for: provider)
    }

    public func preparePullRequestThread() async {
        let url = pullRequestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        guard let pullRequestThreadPreparer else {
            pullRequestStatusMessage = "PR preparation unavailable: app router is not ready."
            return
        }
        normalizeSelectedModelOptions()
        pullRequestPreparing = true
        defer { pullRequestPreparing = false }
        do {
            let thread = try await pullRequestThreadPreparer(
                url,
                provider,
                model,
                permissionMode,
                reasoningEffort,
                serviceTier,
                currentModelSelection,
                providerInstanceId
            )
            pullRequestURL = ""
            reloadThreads()
            onThreadLifecycle?(.created(threads.first(where: { $0.id == thread.id }) ?? thread))
            selectThread(thread.id)
            pullRequestStatusMessage = "Opened \(thread.title)"
        } catch {
            pullRequestStatusMessage = "PR preparation failed: \(error)"
        }
    }

    public func renameThread(_ id: AgentThreadID, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            // Title only. A leftover 26-column + routing `get` then `upsert`
            // hitchs macOS rename and clobbers concurrent persistThreadConfig /
            // run-start writes (PERSISTENCE-DATA-002). RPC already uses this UPDATE.
            try threadRepo.updateTitlePreservingActivity(id, title: title)
        } catch {
            statusMessage = "Could not rename thread: \(error)"
            return
        }
        reloadThreads()
        if let updated = threads.first(where: { $0.id == id }) {
            onThreadLifecycle?(.updated(updated))
        }
    }

    /// A2: set/clear a thread's swatch color (empty string clears).
    public func setThreadColor(_ id: AgentThreadID, _ color: String) {
        do {
            // Color only. A leftover 26-column + routing `get` after the
            // targeted UPDATE hitchs the swatch click. Pin already reloads
            // the rail instead of compiling the row for the lifecycle event.
            try threadRepo.setColor(id: id, color: color.isEmpty ? nil : color)
        } catch {
            statusMessage = "Could not change thread color: \(error)"
            return
        }
        reloadThreads()
        if let updated = threads.first(where: { $0.id == id }) {
            onThreadLifecycle?(.updated(updated))
        }
    }

    public func setThreadPinned(_ id: AgentThreadID, _ pinned: Bool) {
        do {
            try threadRepo.setPinned(id: id, pinned: pinned)
        } catch {
            statusMessage = "Could not change pinned state: \(error)"
            return
        }
        reloadThreads()
        if let updated = threads.first(where: { $0.id == id }) {
            onThreadLifecycle?(.updated(updated))
        }
    }

    public func reorderThread(_ id: AgentThreadID, before target: AgentThreadID) {
        guard id != target,
              let targetIndex = threads.firstIndex(where: { $0.id == target }) else { return }
        do {
            try threadRepo.reorder(id: id, position: targetIndex)
        } catch {
            statusMessage = "Could not reorder threads: \(error)"
            return
        }
        reloadThreads()
        onThreadLifecycle?(.reordered(workspaceID, threads.map(\.id)))
    }

    // UX-XPLAT-DELETE-UNDO: thread deletion stays IMMEDIATE and final (the
    // delete*Thread contract is unchanged). On top of it we keep a transient
    // in-memory snapshot of the just-deleted thread(s) + their messages for a
    // short window so the user can undo an accidental delete. After the window
    // the snapshot is dropped and the delete is permanent. This is purely
    // additive: nothing defers the actual DELETE.
    public struct ThreadDeletionUndo {
        /// One deleted thread captured before it was removed from the store.
        public struct ThreadSnapshot: Sendable, Equatable {
            public let thread: AgentThread
            public let messages: [AgentMessage]
        }

        /// All threads removed by a single delete action, the instant captured,
        /// and which (if any) thread was selected at delete time so undo can
        /// restore selection too. `count` drives the toast copy.
        public var snapshots: [ThreadSnapshot]
        public var relationalSnapshot: AgentThreadRelationalSnapshot? = nil
        public var attachmentGCPinID: String? = nil
        public var capturedAt: Date
        public var previouslySelectedThreadId: AgentThreadID?

        public var count: Int { snapshots.count }

        /// Pure: is an undo still allowed `window` seconds after capture?
        /// WHY: an accidental delete must be recoverable, but only briefly —
        /// after the window the snapshot is dropped and the delete is final.
        public static func isWithinUndoWindow(
            capturedAt: Date,
            now: Date,
            window: TimeInterval
        ) -> Bool {
            now.timeIntervalSince(capturedAt) < window
        }

        /// Pure: FK-safe restore order for one snapshot. agent_messages has a
        /// `thread_id REFERENCES agent_threads(id) ON DELETE CASCADE` foreign
        /// key with `foreign_keys=ON`, so the parent thread row MUST be
        /// re-inserted before any message, and messages re-append oldest→newest
        /// to preserve their original order.
        public static func restorePlan(
            for snapshot: ThreadSnapshot
        ) -> (thread: AgentThread, messagesInAppendOrder: [AgentMessage]) {
            (snapshot.thread, snapshot.messages.sorted { $0.createdAt < $1.createdAt })
        }
    }

    /// Seconds the undo toast stays actionable after a thread delete.
    public static let threadDeletionUndoWindow: TimeInterval = 10

    /// UX-XPLAT-DELETE-UNDO: transient snapshot of the most recent thread
    /// delete. Non-nil only inside the undo window; cleared on undo, on a new
    /// delete, or when the window lapses. Drives the undo toast.
    @Published public private(set) var pendingThreadDeletionUndo: ThreadDeletionUndo?

    @discardableResult
    public func deleteThread(_ id: AgentThreadID) async -> Bool {
        await deleteThreads([id])
    }

    @discardableResult
    public func deleteThreads(_ ids: Set<AgentThreadID>) async -> Bool {
        guard !ids.isEmpty else { return true }
        let orderedIDs = ids.sorted { $0.value.uuidString < $1.value.uuidString }
        let handoffDeletion = beginBotPeerHandoffDeletion?(ids)
        var didFinishHandoffDeletion = false
        defer {
            if let handoffDeletion, !didFinishHandoffDeletion {
                finishBotPeerHandoffDeletion?(handoffDeletion, false)
            }
        }
        let suppressionLeases: [(AgentThreadID, UUID)]
        if let acquireQueueDrainSuppressions {
            suppressionLeases = await acquireQueueDrainSuppressions(orderedIDs)
        } else if let acquireQueueDrainSuppression {
            var acquired: [(AgentThreadID, UUID)] = []
            for id in ids {
                acquired.append((id, await acquireQueueDrainSuppression(id)))
            }
            suppressionLeases = acquired
        } else {
            suppressionLeases = []
        }
        defer {
            for (id, lease) in suppressionLeases {
                releaseQueueDrainSuppression?(id, lease)
            }
        }
        // AG-002: a thread row owns the provider lifecycle. Do not cascade-delete
        // its data or evict UI caches until every selected provider has confirmed
        // terminal state and its process tree is dead.
        do {
            try await coordinator.stopAndAwaitTermination(threadIds: orderedIDs)
        } catch {
            timeline.apply(.error(
                message: "Could not delete thread because its provider is still running: \(error.localizedDescription)",
                recoverable: true
            ))
            lastErrorRecoverable = true
            scheduleTimelineUpdateTick()
            return false
        }

        let previouslySelectedThreadId = selectedThreadId
        let wasSelected = selectedThreadId.map(ids.contains) ?? false
        let capturedAt = currentTime()
        let attachmentGCPinID = UUID().uuidString.lowercased()
        let relationalSnapshot: AgentThreadRelationalSnapshot
        do {
            relationalSnapshot = try threadRepo.deleteWithRelationalSnapshot(
                ids: Array(ids),
                undoGCPin: AgentThreadUndoGCPin(
                    id: attachmentGCPinID,
                    expiresAt: capturedAt.addingTimeInterval(Self.threadDeletionUndoWindow)
                )
            )
        } catch {
            statusMessage = "Could not delete thread data: \(error)"
            return false
        }
        if let handoffDeletion {
            finishBotPeerHandoffDeletion?(handoffDeletion, true)
            didFinishHandoffDeletion = true
        }
        let undo = ThreadDeletionUndo(
            snapshots: relationalSnapshot.threads.map { .init(thread: $0, messages: []) },
            relationalSnapshot: relationalSnapshot,
            attachmentGCPinID: attachmentGCPinID,
            capturedAt: capturedAt,
            previouslySelectedThreadId: previouslySelectedThreadId
        )
        evictThreadCaches(ids)
        if wasSelected {
            self.selectedThreadId = nil
        messages = []
        messageHistoryIsPartial = false
        messagePageLoadState = .idle
        timeline = AssistantTimelineState()
        resetTimelineUpdateTick()
        }
        reloadThreads()
        onThreadLifecycle?(.deleted(orderedIDs))
        // Reselect a remaining thread when the open one was deleted (delete UX);
        // never auto-bind a surface that was on the fresh-composer state.
        if wasSelected, selectedThreadId == nil, let next = threads.first {
            selectThread(next.id)
        }
        armThreadDeletionUndo(undo)
        return true
    }

    /// F9: drop deleted threads' per-thread caches so they don't leak for the life
    /// of the surface (composer drafts, the streaming dedup caches, workspace
    /// membership, the repaired-title marker), plus the coordinator's per-thread
    /// auto-continuation bookkeeping. The thread's persistent state is captured for
    /// undo separately; these transient caches rebuild on demand if a delete is
    /// undone.
    private func cachedThreadIDs() -> Set<AgentThreadID> {
        var ids = repairedThreadIds
        ids.formUnion(threadWorkspaceCache.keys)
        ids.formUnion(composerDraftsByThread.keys)
        ids.formUnion(lastPersistedAssistantContentByThread.keys)
        ids.formUnion(lastPersistedFinalIdByThread.keys)
        ids.formUnion(queueStatusByThread.keys)
        ids.formUnion(providerThreadSnapshotConfirmedAtByThread.keys)
        ids.formUnion(planNotesByThread.keys)
        ids.formUnion(runThreads.values)
        return ids
    }

    /// Clears visible state owned by a selected thread that disappeared outside the
    /// explicit-delete flow. The selection is already nil when this runs, so the
    /// existing reload helpers reset queue/checkpoint projections to fresh-composer
    /// state without persisting a change for the deleted thread. The unsent composer
    /// itself is deliberately preserved as the new unbound draft; pruning history
    /// must not destroy user input.
    private func resetDeletedSelectionToFreshComposer() {
        composerCursorOffset = nil
        attachmentInputError = nil
        lastSentAttachmentCount = 0
        pendingAttachmentRetryConfirmation = nil
        messages = []
        messageHistoryIsPartial = false
        // No thread is open: a page load in flight for the removed one will
        // never resolve this, and the fresh composer really is empty.
        messagePageLoadState = .idle
        cancelOlderMessageLoad()
        timeline = AssistantTimelineState()
        resetTimelineUpdateTick()
        _ = streamEventBatch.drain()
        streamUIBackpressured = false
        streamAggregateBudgetOps = 0
        historyReplayNotice = nil
        providerThreadSnapshotStatusMessage = nil
        providerThreadSnapshotLastConfirmedAt = nil
        selectedThreadHasRecoverableContext = false
        liveBackgroundShellCount = 0
        liveBackgroundTasks = []
        currentRunId = nil
        runStartedAt = nil
        stopScheduledLivePoll()
        userInputSelections = [:]
        userInputDrafts = [:]
        transcriptHistoryRevealCount = 0
        transcriptReadingStartID = nil
        planNotes = ""
        subagentActivity = .empty
        reloadQueuedMessages()
        reloadCheckpoints()
    }

    private func recoverDeletedSelectionIfNeeded(_ removedThreadIDs: Set<AgentThreadID>) {
        guard let selectedThreadId, removedThreadIDs.contains(selectedThreadId) else { return }
        // Ephemeral side threads are hidden from the rail, so a rail snapshot
        // never contains them. Keep the selection while the durable row exists;
        // only recover once the side thread was actually closed/deleted.
        if selectedThreadIsEphemeral, (try? threadRepo.get(id: selectedThreadId)) != nil { return }
        let preservedUnsentDraft = !prompt.isEmpty || !attachments.isEmpty
        self.selectedThreadId = nil
        selectedThreadIsEphemeral = false
        selectedThreadParentId = nil
        publishInterestedThreadId(nil)
        resetDeletedSelectionToFreshComposer()
        if preservedUnsentDraft {
            statusMessage = Self.deletedThreadDraftRecoveryMessage
        }
        onSelectedThreadChanged?(nil)
    }

    private func applyAuthoritativeThreadDeletions(_ deletedIDs: Set<AgentThreadID>) {
        guard !deletedIDs.isEmpty else { return }
        evictThreadCaches(deletedIDs)
        threads.removeAll { deletedIDs.contains($0.id) }
        recoverDeletedSelectionIfNeeded(deletedIDs)
    }

    /// Retires a rail row the durable store no longer backs — deleted, or owned by
    /// another workspace — with the same three steps as a committed delete: per-thread
    /// caches, the row itself, then the selection. The existence probe binds the rail
    /// row before it runs, so stopping at the selection left a phantom row that stayed
    /// clickable (and kept its draft/queue/plan caches) until a later rail reload
    /// happened to succeed.
    private func retireUnbackedRailRow(_ id: AgentThreadID) {
        evictThreadCaches([id])
        threads.removeAll { $0.id == id }
        recoverDeletedSelectionIfNeeded([id])
    }

    /// The repository transaction is authoritative for the victim list. Retire
    /// global runtime state before local cache eviction or lifecycle fan-out so a
    /// failed rail reload cannot leave a deleted provider session behind.
    private func retireCommittedThreadPrunes(
        _ ids: [AgentThreadID],
        coordinatorAlreadyRetired: Bool = false
    ) {
        guard !ids.isEmpty else { return }
        if let retireDeletedThreadRuntime {
            retireDeletedThreadRuntime(ids, coordinatorAlreadyRetired)
        } else if !coordinatorAlreadyRetired {
            // Direct/test surfaces have no AppContext retry owner. Delegate to
            // the coordinator's single fallback driver so retryRequired is kept.
            coordinator.retireDeletedThreads(ids, scheduleRetries: true)
        }
    }

    private func evictThreadCaches(_ ids: some Sequence<AgentThreadID>) {
        let ids = Set(ids)
        guard !ids.isEmpty else { return }
        let removedRunIDs = Set(runThreads.compactMap { runId, threadId in
            ids.contains(threadId) ? runId : nil
        })
        for runId in removedRunIDs {
            runThreads.removeValue(forKey: runId)
        }
        if let currentRunId, removedRunIDs.contains(currentRunId) {
            self.currentRunId = nil
            runStartedAt = nil
            isStopping = false
        }
        for id in ids {
            paintedTimelineByThread.removeValue(forKey: id)
            paintedTimelineOrder.removeAll { $0 == id }
            repairedThreadIds.remove(id)
            threadWorkspaceCache.removeValue(forKey: id)
            composerDraftsByThread.removeValue(forKey: id)
            lastPersistedAssistantContentByThread.removeValue(forKey: id)
            lastPersistedFinalIdByThread.removeValue(forKey: id)
            queueStatusByThread.removeValue(forKey: id)
            providerThreadSnapshotConfirmedAtByThread.removeValue(forKey: id)
            planNotesByThread.removeValue(forKey: id)
            surfacePreparationStates.removeValue(forKey: id)
            preparingRunThreads.remove(id)
            preparingRunGeneration.removeValue(forKey: id)
            preparingRunId.removeValue(forKey: id)
            coordinator.forgetThread(id)
        }
    }

    #if DEBUG
    func setReloadThreadListForTesting(_ loader: (() throws -> [AgentThread])?) {
        reloadThreadListForTesting = loader
    }

    func seedSelectedThreadChromeForTesting(_ threadId: AgentThreadID) {
        let now = Date(timeIntervalSince1970: 0)
        subagentActivity = SubagentActivitySnapshot(active: [
            SubagentActivityItem(
                id: UUID(),
                runId: nil,
                threadId: threadId,
                nodeId: "test-node",
                displayName: "test worker",
                provider: .codex,
                model: nil,
                phase: .working,
                lifecycleStatus: .accepted,
                finalRunStatus: nil,
                admittedAt: now,
                finalizedAt: nil,
                lifecycleUpdatedAt: now,
                isActive: true
            )
        ], done: [])
    }

    /// Test-only: the set of thread ids still present in ANY per-thread VM cache,
    /// so a test can prove `evictThreadCaches` leaves no residue after a delete.
    var threadCacheResidueForTesting: Set<AgentThreadID> {
        cachedThreadIDs()
    }

    /// Seeds the two per-thread caches that are otherwise populated only by
    /// queue/provider work, so cache-eviction regressions can observe them.
    func seedAdditionalThreadCachesForTesting(_ threadId: AgentThreadID) {
        let confirmedAt = Date(timeIntervalSince1970: 0)
        queueStatusByThread[threadId] = "test queue status"
        providerThreadSnapshotConfirmedAtByThread[threadId] = confirmedAt
        if selectedThreadId == threadId {
            queueStatusMessage = "test queue status"
            providerThreadSnapshotLastConfirmedAt = confirmedAt
        }
    }

    /// Seeds only the in-memory composer cache. Cap-performance fixtures must
    /// not manufacture durable user drafts, because those are now protected from
    /// automatic retention and are not memory the cap is allowed to reclaim.
    func seedComposerDraftCacheForTesting(
        _ threadId: AgentThreadID,
        providerInstanceId: String,
        text: String
    ) {
        composerDraftsByThread[threadId, default: [:]][providerInstanceId] = AgentThreadDraft(
            threadId: threadId,
            providerInstanceId: providerInstanceId,
            text: text
        )
    }

    @discardableResult
    func seedRunThreadProjectionForTesting(_ threadId: AgentThreadID) -> AgentRunID {
        let runId = AgentRunID()
        runThreads[runId] = threadId
        return runId
    }

    /// Test-only logical payload measure for pruning regressions. This counts the
    /// UTF-8 text held by the in-memory composer draft cache, rather than allocator
    /// footprint, so it remains deterministic when malloc retains freed pages.
    var cachedComposerDraftUTF8BytesForTesting: Int {
        composerDraftsByThread.values.reduce(into: 0) { total, drafts in
            total += drafts.values.reduce(0) { $0 + $1.text.utf8.count }
        }
    }
    #endif

    /// Publish the snapshot as the active undo affordance and schedule its
    /// expiry. The delete itself already happened; this only controls how long
    /// the user can take it back.
    private func armThreadDeletionUndo(_ undo: ThreadDeletionUndo?) {
        threadDeletionUndoExpiryTask?.cancel()
        if pendingThreadDeletionUndo?.attachmentGCPinID != undo?.attachmentGCPinID {
            releaseThreadDeletionUndoGCPin(pendingThreadDeletionUndo)
        }
        guard let undo else {
            pendingThreadDeletionUndo = nil
            return
        }
        pendingThreadDeletionUndo = undo
        let window = Self.threadDeletionUndoWindow
        threadDeletionUndoExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Only clear the snapshot we armed; a newer delete owns its own.
            if let current = self.pendingThreadDeletionUndo,
               current.attachmentGCPinID == undo.attachmentGCPinID,
               !ThreadDeletionUndo.isWithinUndoWindow(
                   capturedAt: current.capturedAt,
                   now: self.currentTime(),
                   window: window
               ) {
                self.releaseThreadDeletionUndoGCPin(current)
                self.pendingThreadDeletionUndo = nil
            }
        }
    }

    private func releaseThreadDeletionUndoGCPin(_ undo: ThreadDeletionUndo?) {
        guard let id = undo?.attachmentGCPinID else { return }
        try? threadRepo.removeUndoGCPin(id: id)
    }

    /// UX-XPLAT-DELETE-UNDO: restore the most recently deleted thread(s) from
    /// the transient snapshot, provided the undo window has not lapsed. Returns
    /// true if a restore happened. FK-safe: re-inserts the thread row first,
    /// then re-appends its messages.
    @discardableResult
    public func undoLastThreadDeletion() -> Bool {
        guard let undo = pendingThreadDeletionUndo,
              ThreadDeletionUndo.isWithinUndoWindow(
                  capturedAt: undo.capturedAt,
                  now: currentTime(),
                  window: Self.threadDeletionUndoWindow
              ) else {
            // Window lapsed (or nothing to undo): drop the stale snapshot.
            releaseThreadDeletionUndoGCPin(pendingThreadDeletionUndo)
            pendingThreadDeletionUndo = nil
            threadDeletionUndoExpiryTask?.cancel()
            return false
        }
        let prunedThreadIDs: [AgentThreadID]
        do {
            if let relationalSnapshot = undo.relationalSnapshot {
                prunedThreadIDs = try threadRepo.restoreEnforcingWorkspaceThreadLimit(relationalSnapshot)
            } else {
                prunedThreadIDs = []
                for snapshot in undo.snapshots {
                    let plan = ThreadDeletionUndo.restorePlan(for: snapshot)
                    try threadRepo.upsert(plan.thread)
                    for message in plan.messagesInAppendOrder {
                        try messageRepo.append(message)
                    }
                }
            }
        } catch {
            statusMessage = "Could not restore deleted thread data: \(error)"
            return false
        }
        if !prunedThreadIDs.isEmpty {
            retireCommittedThreadPrunes(prunedThreadIDs)
            applyAuthoritativeThreadDeletions(Set(prunedThreadIDs))
            onThreadLifecycle?(.deleted(prunedThreadIDs))
        }
        // restoreEnforcingWorkspaceThreadLimit returned only after the complete
        // relational graph committed. Materialize those exact committed rows now;
        // this is not a snapshot fallback after a failed repository operation.
        let committedRestoredThreads = undo.snapshots.map(\.thread)
        let restoredIDs = Set(committedRestoredThreads.map(\.id))
        threads.removeAll { restoredIDs.contains($0.id) }
        threads.append(contentsOf: committedRestoredThreads)
        threads.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.value.uuidString > $1.id.value.uuidString
        }
        for thread in committedRestoredThreads {
            if let workspaceID = thread.workspaceId {
                threadWorkspaceCache[thread.id] = workspaceID
            }
        }
        releaseThreadDeletionUndoGCPin(undo)
        pendingThreadDeletionUndo = nil
        threadDeletionUndoExpiryTask?.cancel()
        // Remote mirrors already saw the delete event; re-announce the restored
        // committed threads before any fallible rail reload.
        for thread in committedRestoredThreads {
            onThreadLifecycle?(.created(thread))
        }
        if let restore = undo.previouslySelectedThreadId,
           restoredIDs.contains(restore) {
            selectThread(restore)
        }
        reloadThreads()
        return true
    }

    /// UX-XPLAT-REVERT-UNDO: transient handle to the most recent checkpoint
    /// revert. `capturedAt` mirrors the toast arming instant (a hair after the
    /// coordinator's own undo capture); `checkpointTurnCount` drives the copy.
    public struct CheckpointRevertUndoToast: Equatable {
        public let threadId: AgentThreadID
        public let cwd: String
        public let checkpointTurnCount: Int
        public let capturedAt: Date
    }

    /// Seconds the undo toast stays actionable after a checkpoint revert.
    public static let checkpointRevertUndoWindow: TimeInterval = 10

    /// UX-XPLAT-REVERT-UNDO: transient handle to the most recent checkpoint
    /// revert. Non-nil only inside the undo window; cleared on undo, on a new
    /// revert, or when the window lapses. Drives the revert undo toast.
    @Published public private(set) var pendingCheckpointRevertUndo: CheckpointRevertUndoToast?

    /// Publish the toast as the active undo affordance and schedule its expiry.
    /// The revert itself already happened; this only controls how long the user
    /// can take it back. Mirrors armThreadDeletionUndo.
    private func armCheckpointRevertUndo(_ toast: CheckpointRevertUndoToast) {
        checkpointRevertUndoExpiryTask?.cancel()
        pendingCheckpointRevertUndo = toast
        let window = Self.checkpointRevertUndoWindow
        checkpointRevertUndoExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Only clear the toast we armed; a newer revert owns its own.
            if let current = self.pendingCheckpointRevertUndo,
               current.capturedAt == toast.capturedAt,
               !CheckpointRevertUndo.isWithinUndoWindow(
                   capturedAt: current.capturedAt,
                   now: self.currentTime(),
                   window: window
               ) {
                self.pendingCheckpointRevertUndo = nil
            }
        }
    }

    /// UX-XPLAT-REVERT-UNDO: ask the coordinator to reverse the most recent
    /// checkpoint revert (files + DB), then refresh the view. The coordinator
    /// owns its own undo window and THROWS if it has lapsed; the catch surfaces
    /// that. The toast is dismissed immediately on tap, like thread-delete undo.
    public func undoLastCheckpointRevert() {
        guard let toast = pendingCheckpointRevertUndo else { return }
        checkpointRevertUndoExpiryTask?.cancel()
        Task { @MainActor in
            do {
                try coordinator.undoLastCheckpointRevert(threadId: toast.threadId, cwd: toast.cwd)
                loadAllMessages(toast.threadId)
                reloadCheckpoints()
                reloadThreads()
                checkpointStatusMessage = "Restored."
            } catch {
                checkpointStatusMessage = "Undo failed: \(error.localizedDescription)"
            }
        }
        pendingCheckpointRevertUndo = nil
    }

    /// Derive the persisted thread title from the first user message.
    /// Display truncation is handled separately by AgentThreadTitle.display.
    public static func deriveTitle(from text: String) -> String {
        AgentThreadTitle.titleFromFirstMessage(text)
    }

    public func statusSummary() -> String {
        let t = threads.first(where: { $0.id == selectedThreadId })?.title ?? "—"
        return "provider=\(provider.rawValue) model=\(model) permission=\(permissionMode.rawValue) reasoning=\(reasoningEffort.rawValue) status=\(status.rawValue) thread=\(t)"
    }

    /// IMP-MAC_AGENT-013: serialize a full thread (read from the durable store,
    /// not the paged in-memory window) to shareable markdown.
    ///
    /// SQLite `listRecent` and body concat hop off MainActor (same pattern as
    /// `loadMessagePagePayloadOffMain`). Bodies stay complete; durable
    /// `maxMessagesPerThread` is unchanged.
    public func exportThreadMarkdown(
        _ id: AgentThreadID,
        includeTimeline: Bool = false
    ) async -> (fileName: String, contents: String)? {
        guard let thread = threads.first(where: { $0.id == id }) ?? (try? threadRepo.get(id: id)) else { return nil }
        let repository = messageRepo
        var contents = await Self.exportThreadMessageMarkdownOffMain(
            repository: repository,
            threadId: id,
            title: thread.title
        )
        if includeTimeline {
            let tlLines = ThreadMarkdownFormatter.timelineMarkdownLines(
                turns: timeline.turns,
                approvals: timeline.pendingRequests
            )
            if !tlLines.isEmpty {
                contents += "## Timeline\n\n"
                contents += tlLines.joined(separator: "\n")
                contents += "\n"
            }
        }
        // PERF: exportThreadMarkdown rebuilt the path-unsafe CharacterSet on
        // every export. Share one set for title → filename sanitization.
        let safeName = thread.title
            .components(separatedBy: Self.exportThreadFilenameSeparators)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (safeName.isEmpty ? "agent-thread" : safeName) + ".md"
        return (fileName, contents)
    }

    /// Newest retained window, complete bodies. Runs off MainActor so export
    /// does not concatenate SQLite rows on the UI actor.
    nonisolated static func exportThreadMessageMarkdownOffMain(
        repository: AgentMessageRepository,
        threadId: AgentThreadID,
        title: String
    ) async -> String {
        await Task.detached(priority: .userInitiated) {
            let rows = (try? repository.listRecent(
                threadId: threadId,
                limit: AgentMessageRepository.maxMessagesPerThread
            )) ?? []
            var lines: [String] = ["# \(title)", ""]
            lines.reserveCapacity(rows.count * 4 + 2)
            for message in rows {
                let heading: String
                switch message.role {
                case .user: heading = "## User"
                case .assistant: heading = "## Assistant"
                case .system: heading = "## System"
                }
                lines.append(heading)
                lines.append("")
                lines.append(message.content)
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }.value
    }

    private static let exportThreadFilenameSeparators = CharacterSet(charactersIn: "/\\:?%*|\"<>")

    private func systemNote(_ text: String) {
        guard let tid = selectedThreadId else { return }
        let m = AgentMessage(threadId: tid, role: .system, content: text)
        do {
            try messageRepo.append(m)
            messages.append(m)
        } catch {
            statusMessage = "Could not save system note: \(error)"
        }
    }

    /// `/fork` — create a provider-native branch, copy the visible local
    /// transcript into it, then select the isolated child thread.
    public func forkCurrentThread() async {
        guard let tid = selectedThreadId,
              let src = threads.first(where: { $0.id == tid }) else { return }
        // Legacy-provider threads are read-only: a fork would start their old provider.
        guard src.provider.isSelectable else {
            systemNote("This conversation is read-only. Start a new Distill conversation instead.")
            return
        }
        guard selectedProviderCapabilities.supportsFork else {
            systemNote(threadForkUnavailableReason ?? "Provider-side fork is unavailable for this session.")
            return
        }
        let child = AgentThread(
            projectId: src.projectId,
            workspaceId: src.workspaceId ?? workspaceID,
            title: "\(src.title) (fork)",
            provider: src.provider,
            providerInstanceId: src.providerInstanceId,
            model: src.model,
            permissionMode: src.permissionMode,
            reasoningEffort: src.reasoningEffort,
            executionMode: src.executionMode,
            baseBranch: src.baseBranch,
            worktreePath: src.worktreePath,
            serviceTier: src.serviceTier,
            modelSelection: src.modelSelection,
            interactionMode: src.effectiveInteractionMode
        )
        do {
            let result = try await coordinator.forkThreadReturningPrunedThreadIDs(
                sourceThreadId: tid,
                childThread: child
            )
            if !result.prunedThreadIDs.isEmpty {
                retireCommittedThreadPrunes(
                    result.prunedThreadIDs,
                    coordinatorAlreadyRetired: true
                )
                applyAuthoritativeThreadDeletions(Set(result.prunedThreadIDs))
                onThreadLifecycle?(.deleted(result.prunedThreadIDs))
            }
            reloadThreads()
            selectThread(result.thread.id)
        } catch {
            statusMessage = "Could not fork thread: \(error)"
        }
    }

    /// `/side` — ask the host to fork an ephemeral side chat and open it in a
    /// right split pane. Refused inside a side chat and when the provider cannot
    /// fork. The host creates the thread via `AppCommandRouter.sideAgentThread`.
    public func requestSideChat(text: String) {
        guard let tid = selectedThreadId else { return }
        // A side thread is hidden from the rail, so check its flag first.
        guard !selectedThreadIsEphemeral else {
            systemNote("/side — already in a side chat.")
            return
        }
        guard let src = threads.first(where: { $0.id == tid }) ?? (try? threadRepo.get(id: tid)) else { return }
        guard src.provider.isSelectable else {
            systemNote("This conversation is read-only. Start a new Distill conversation instead.")
            return
        }
        guard selectedProviderCapabilities.supportsFork else {
            systemNote(threadForkUnavailableReason ?? "Provider-side fork is unavailable for this session.")
            return
        }
        // An embedded chat (Bot desk) has no host for a side pane: say so
        // instead of swallowing the typed command.
        guard let onRequestSideChat else {
            systemNote("/side is not available in this chat.")
            return
        }
        onRequestSideChat(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Sends the `/side` inline text as the side chat's first message once the
    /// side surface is mounted and bound to the ephemeral thread.
    public func seedSideChatMessage(_ text: String) {
        guard selectedThreadId != nil else { return }
        prompt = text
        Task { @MainActor [weak self] in
            await self?.send()
        }
    }

    /// `/btw` — ask the host for a side answer against the thread's live session.
    /// The host replies through `appendBtwNote`, which shows it inline.
    public func requestBtw(question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            systemNote("/btw — usage: /btw <question>")
            return
        }
        guard let onRequestBtw else {
            systemNote("/btw is not available in this chat.")
            return
        }
        onRequestBtw(q)
    }

    /// `/btw` answer as a non-persisted inline transcript note.
    public func appendBtwNote(question: String, answer: String) {
        appendInlineNoteToTranscript("BTW · \(question)\n\(answer)")
    }

    /// Non-persisted inline transcript note: appended to the in-memory message
    /// list only. A reload from disk drops it (intended for `/btw` answers).
    private func appendInlineNoteToTranscript(_ text: String) {
        guard let tid = selectedThreadId else { return }
        messages.append(AgentMessage(threadId: tid, role: .system, content: text))
    }

    /// Intercept only RemoteCode-owned slash commands before they reach the
    /// provider. Provider commands such as `/goal` must pass through.
    public static let localSlashCommands = ["/btw", "/clear", "/default", "/fork", "/model", "/plan", "/side", "/status"]

    private var distillAdvertisedCommandNames: [String] {
        provider == .distill ? distillSlashCommands.map { "/\($0.name)" } : []
    }

    private var distillCommandSubtitles: [String: String] {
        guard provider == .distill else { return [:] }
        // Static `/loop` subtitle until Distill advertises its own.
        return Dictionary(
            distillSlashCommands.compactMap { cmd in cmd.subtitle.map { (cmd.name.lowercased(), $0) } }
                + [("loop", "Run a prompt on a recurring interval · [interval] <prompt>")],
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Parse a local RemoteCode slash/dollar command. Public so scheduled Path B
    /// can reject UI-only commands the same way Agent App intercepts them.
    public static func localSlashCommandParts(_ raw: String) -> (command: String, argument: String)? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept `/` and `$` so autocomplete insert of `$clear` / `$plan` still
        // hits the local RemoteCode command path (parity with slash trigger).
        guard let first = line.first, first == "/" || first == "$" else { return nil }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        return (
            parts.first?.lowercased() ?? "",
            parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        )
    }

    @discardableResult
    public func handleSlashCommand(_ raw: String) -> Bool {
        guard let parts = Self.localSlashCommandParts(raw) else { return false }
        let cmd = parts.command
        let arg = parts.argument
        // Distill owns `/status` (alias of session-info); let it reach the agent.
        if cmd == "status", provider == .distill { return false }
        switch cmd {
        case "clear":
            createThread(title: "New thread")
            // P2: /clear creates a new thread (CLI semantics); tell the user so
            // the silent switch doesn't look like a bug.
            systemNote("/clear — started a new thread. Previous thread is still in the rail.")
        case "fork":
            if let onForkInNewChat {
                onForkInNewChat(nil)
            } else {
                Task { @MainActor in
                    await forkCurrentThread()
                }
            }
        case "side":
            requestSideChat(text: arg)
        case "btw":
            requestBtw(question: arg)
        case "model":
            if !arg.isEmpty, let m = availableModels.first(where: {
                $0.id.localizedCaseInsensitiveContains(arg) || $0.label.localizedCaseInsensitiveContains(arg)
            }) {
                setModel(m.id)
                systemNote("Model → \(m.label)")
            } else {
                let names = availableModels.map { $0.label }.joined(separator: ", ")
                systemNote(names.isEmpty ? "No models loaded yet." : "Models: \(names)")
            }
        case "plan":
            guard supportsPlanInteractionForSelectedProvider else {
                systemNote(planInteractionUnavailableReason ?? "Plan mode is unavailable for this session.")
                return true
            }
            interactionMode = .plan
            permissionMode = .supervised
            persistThreadConfig()
            systemNote("Plan mode on · permission: supervised")
        case "default":
            interactionMode = .default
            persistThreadConfig()
            systemNote("Default mode on")
        case "status":
            systemNote(statusSummary())
        default:
            return false
        }
        return true
    }

    public func addAttachments(_ paths: [String]) {
        do {
            try AgentProviderRunPreflight.validate(
                snapshot: selectedProviderSnapshot,
                interactionMode: interactionMode,
                permissionMode: permissionMode,
                attachments: []
            )
            guard paths.isEmpty || selectedProviderSnapshot?.effectiveCapabilities.supportsAttachments == true else {
                throw AgentProviderRunPreflightError.attachmentsUnsupported(
                    selectedProviderSnapshot?.displayName ?? provider.rawValue.capitalized
                )
            }
            let staged = try attachmentStore?.stage(paths: paths) ?? AgentAttachmentResolver.resolve(paths: paths)
            try AgentProviderRunPreflight.validate(
                snapshot: selectedProviderSnapshot,
                interactionMode: interactionMode,
                permissionMode: permissionMode,
                attachments: attachments + staged
            )
            let deduplicationKey: (AgentAttachment) -> String = { attachment in
                if let digest = attachment.sha256, !digest.isEmpty { return "sha256:\(digest)" }
                return attachment.id ?? attachment.path
            }
            var known = Set(attachments.map(deduplicationKey))
            for attachment in staged where known.insert(deduplicationKey(attachment)).inserted {
                attachments.append(attachment)
            }
            attachmentInputError = nil
            statusMessage = ""
            if let selectedThreadId { persistComposerDraft(for: selectedThreadId) }
        } catch {
            attachmentInputError = String(describing: error)
            statusMessage = attachmentInputError ?? "Attachment failed."
        }
    }
    public func insertDroppedFilePaths(_ paths: [String]) {
        let insertion = DroppedFilePaths.composerInputText(for: paths)
        prompt = DroppedFilePaths.appending(insertion, to: prompt)
        promptWasEdited()
        focusTick &+= 1
    }
    public func promptWasEdited() {
        promptHistoryCursor = nil
        if let selectedThreadId { scheduleComposerDraftPersistence(for: selectedThreadId) }
    }
    public func removeAttachment(_ attachment: AgentAttachment) {
        attachments.removeAll { $0 == attachment }
        if let selectedThreadId { persistComposerDraft(for: selectedThreadId) }
    }

    private func clearVisibleErrorForNewUserMessage() {
        dismissDisplayedError()
        dismissStatusMessage()
    }

    public func dismissDisplayedError() {
        timeline.clearError()
        lastErrorRecoverable = false
        pendingAttachmentRetryConfirmation = nil
    }

    public func dismissStatusMessage() {
        statusMessage = ""
        attachmentInputError = nil
    }

    public func dismissHistoryReplayNotice() {
        historyReplayNotice = nil
    }

    public func dismissQueueStatusMessage() {
        if let selectedThreadId {
            queueStatusByThread.removeValue(forKey: selectedThreadId)
        }
        queueStatusMessage = nil
    }

    public func handleQueueLifecycleEvent(kind: String, threadId: String?, message: String?) {
        switch kind {
        case "agent.message.queue.failed", AgentQueueEventKinds.drained, AgentQueueEventKinds.cancelled:
            break
        default:
            return
        }
        guard let threadId,
              let uuid = UUID(uuidString: threadId) else { return }
        let eventThreadId = AgentThreadID(uuid)
        let eventWorkspaceID = resolvedWorkspaceID(for: eventThreadId, retainingForeignProbe: false)
        guard eventWorkspaceID == workspaceID else { return }
        switch kind {
        case "agent.message.queue.failed":
            let status = message ?? "The queued message could not start yet."
            setQueueStatus(status, threadId: eventThreadId)
        case AgentQueueEventKinds.drained:
            setQueueStatus(nil, threadId: eventThreadId)
        case AgentQueueEventKinds.cancelled:
            if let queuedMessageRepo,
               (try? queuedMessageRepo.list(threadId: eventThreadId).isEmpty) == true {
                setQueueStatus(nil, threadId: eventThreadId)
            }
        default:
            return
        }
    }

    /// Apply authoritative deletion IDs before the fallible rail reload. Cap
    /// producers publish these IDs because another surface cannot rediscover
    /// them if its first post-delete list read fails.
    public func handleThreadLifecycleEvent(kind: String, threadId: String?, threadIds: [String]?) {
        let rawIDs: [String]
        switch kind {
        case "agent.thread.deleted":
            rawIDs = threadId.map { [$0] } ?? []
        case "agent.thread.deleted_many":
            rawIDs = threadIds ?? []
        default:
            return
        }
        let deletedIDs = Set(rawIDs.compactMap { raw -> AgentThreadID? in
            UUID(uuidString: raw).map(AgentThreadID.init)
        })
        applyAuthoritativeThreadDeletions(deletedIDs)
    }

    public func dismissProviderThreadSnapshotStatusMessage() {
        providerThreadSnapshotStatusMessage = nil
    }

    public func dismissModelListStatusMessage() {
        modelListStatusMessage = nil
    }

    public func dismissProviderSnapshotStatusMessage() {
        providerSnapshotStatusMessage = nil
    }

    public func dismissProviderRecoveryStatusMessage() {
        providerRecoveryStatusMessage = nil
    }

    public func dismissPullRequestStatusMessage() {
        pullRequestStatusMessage = nil
    }

    public func dismissCheckpointStatusMessage() {
        checkpointStatusMessage = nil
    }

    public func dismissProviderStatusMessage() {
        guard let snapshot = selectedProviderSnapshot, snapshot.status != .available else { return }
        let message = snapshot.statusDetail ?? "\(snapshot.displayName) is \(snapshot.status.rawValue)."
        dismissedProviderStatusSignature = "\(snapshot.id)|\(snapshot.status.rawValue)|\(message)"
    }

    /// WHY: while Auto is on and provider/model lists are still loading, a send
    /// would start with incomplete routing and race the orchestrator. The send
    /// button and Enter path must both refuse until prerequisites are ready.
    nonisolated public static func isComposerSendBlockedByAutoRoutingLoad(
        routingMode: AgentRoutingMode,
        hasSelectedThread: Bool,
        providerSnapshotsEmpty: Bool,
        providerSnapshotsLoading: Bool,
        modelListLoading: Bool
    ) -> Bool {
        routingMode == .auto
            && hasSelectedThread
            && (providerSnapshotsEmpty || providerSnapshotsLoading || modelListLoading)
    }

    /// Starts a reply to `message` in the selected thread and focuses the composer.
    public func beginReply(to message: String) {
        guard supportsReplies, let threadId = selectedThreadId else { return }
        let excerpt = AgentReplyQuote.excerpt(of: message)
        guard !excerpt.isEmpty else { return }
        composerState.replyTarget = AgentReplyTarget(threadId: threadId, excerpt: excerpt)
        focusTick += 1
    }

    public func beginReply(to message: AgentMessage) {
        if let peer = BotPeerTranscript.parse(message.content), let threadID = selectedThreadId {
            let excerpt = AgentReplyQuote.excerpt(of: peer.body)
            guard !excerpt.isEmpty else { return }
            composerState.replyTarget = AgentReplyTarget(
                threadId: threadID, excerpt: excerpt, peerHandle: peer.handle, peerBotID: peer.botID
            )
            focusTick += 1
            return
        }
        let parsed = BotChoicesBlock.parse(message.content)
        if supportsReplies, embedding?.hostReplyHandler != nil,
           let choices = parsed.choices, choices.notice != nil, choices.canReply,
           let threadID = selectedThreadId {
            composerState.replyTarget = AgentReplyTarget(
                threadId: threadID,
                excerpt: choices.question ?? parsed.text,
                noticeMessageID: message.id.value.uuidString.lowercased()
            )
            focusTick += 1
            return
        }
        beginReply(to: parsed.text)
    }

    /// Answers a Titio notice card from its own field. The reply goes through
    /// the composer send, so the draft and attachment guards apply. Returns
    /// false on failure; the caller keeps its text.
    public func sendNoticeReply(to message: AgentMessage, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              attachments.isEmpty, let threadID = selectedThreadId else { return false }
        let parsed = BotChoicesBlock.parse(TitioNoticeBlock.parse(message.content).text)
        if supportsReplies, embedding?.hostReplyHandler != nil,
           let choices = parsed.choices, choices.notice != nil, choices.canReply {
            composerState.replyTarget = AgentReplyTarget(
                threadId: threadID,
                excerpt: choices.question ?? TitioNoticeBlock.visibleText(message.content),
                noticeMessageID: message.id.value.uuidString.lowercased()
            )
        } else {
            let firstLine = MarkdownPlainText.firstLine(TitioNoticeBlock.visibleText(message.content))
            let source = TitioNoticeBlock.parse(message.content).block?.source ?? [:]
            let label = [source["workspace"], source["bot"]].compactMap { $0 }.joined(separator: " › ")
            let excerpt = label.isEmpty ? firstLine : "\(label): \(firstLine)"
            composerState.replyTarget = AgentReplyTarget(threadId: threadID, excerpt: excerpt)
        }
        let target = composerState.replyTarget
        prompt = trimmed
        lastSendOutcome = .none
        await send()
        switch lastSendOutcome {
        case .accepted, .queued:
            return true
        case .none, .failed:
            // send() quoted the text into the composer and kept it there with
            // the error: the composer owns it now, so the card must not keep a copy.
            if prompt != trimmed, prompt.contains(trimmed) { return true }
            // Only undo what we set: a draft or target typed during the send stays.
            if prompt == trimmed { prompt = "" }
            if composerState.replyTarget == target { composerState.replyTarget = nil }
            return false
        }
    }

    private var protectedTranscriptTurnIDs: Set<String> {
        guard !isHiddenFromSurface else { return [] }
        let entries = AgentAppView.mergeTranscriptEntries(messages: messages, turns: timeline.turns)
        let paint = AgentAppView.transcriptColumnPaint(
            mergedEntries: entries, status: status, runStartedAt: runStartedAt,
            revealCount: transcriptHistoryRevealCount,
            readingStartID: transcriptReadingStartID
        ).paint
        return Set(paint.compactMap {
            if case .turn(let turn) = $0 { return turn.turnId }
            return nil
        })
    }

    public func setTranscriptReadingHistory(_ reading: Bool) {
        guard reading else {
            transcriptReadingStartID = nil
            return
        }
        guard transcriptReadingStartID == nil else { return }
        transcriptReadingStartID = AgentAppView.transcriptColumnPaint(
            mergedEntries: AgentAppView.mergeTranscriptEntries(messages: messages, turns: timeline.turns),
            status: status, runStartedAt: runStartedAt,
            revealCount: transcriptHistoryRevealCount
        ).paint.first?.id
    }

    public func cancelReply() {
        composerState.replyTarget = nil
    }

    /// The reply in effect for the selected thread (a pick made in another
    /// thread never quotes into this one).
    public var activeReplyTarget: AgentReplyTarget? {
        guard let target = composerState.replyTarget, target.threadId == selectedThreadId else { return nil }
        return target
    }

    public func send() async {
        if embedding?.sendInterceptor == nil,
           let hostReply = embedding?.hostReplyHandler,
           attachments.isEmpty, let threadId = selectedThreadId,
           !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                if try hostReply(prompt.trimmingCharacters(in: .whitespacesAndNewlines), threadId) {
                    prompt = ""
                    composerState.replyTarget = nil
                    statusMessage = ""
                    lastSendOutcome = .accepted
                    return
                }
            } catch {
                statusMessage = error.localizedDescription
                lastSendOutcome = .failed
                return
            }
        }
        // A reply sends the quote line first; text-less sends (attachments
        // only) keep no quote.
        if let reply = activeReplyTarget,
           !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = reply.compose(text: prompt, bots: mentionableBotsProvider())
            composerState.replyTarget = nil
        }
        let originalPrompt = prompt
        let sendThreadId = selectedThreadId
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if let interceptor = embedding?.sendInterceptor {
            sendThroughInterceptor(interceptor, text: trimmed)
            return
        }
        if refuseLegacyProviderThreadRun() { return }
        if refuseUnavailableBotThreadRun() { return }
        if let message = selectedDistillEffortValidationMessage {
            statusMessage = message
            return
        }
        // S5: refuse concurrent preparation only (active runs may still queue).
        // The preparation latch outlives the "Loading…" chrome: it is held until
        // the provider start returns, while a tracked run already renders
        // "Working…". Raw preparation membership therefore refused every
        // follow-up sent during the start window with "Stop it first, or wait."
        // and the queue never received it. A thread that already owns a run is
        // not a competing start — only preparation with no run at all is a race.
        let followUpCanQueue = sendThreadId.map {
            isThreadStartingOrRunning($0) && queuedMessageRepo != nil
        } ?? false
        if let sendThreadId,
           !followUpCanQueue,
           preparingRunThreads.contains(sendThreadId)
            || coordinator.isPreparingProviderStart(threadId: sendThreadId) {
            statusMessage = "A run is already preparing. Stop it first, or wait."
            return
        }
        // Auto is still resolving providers/models — refuse send (button is also
        // disabled) so a half-ready routing snapshot cannot start a provider.
        if Self.isComposerSendBlockedByAutoRoutingLoad(
            routingMode: routingMode,
            hasSelectedThread: selectedThreadId != nil,
            providerSnapshotsEmpty: providerSnapshots.isEmpty,
            providerSnapshotsLoading: providerSnapshotsLoading,
            modelListLoading: modelListLoading
        ) {
            statusMessage = "Automatic model routing is still loading. Try again in a moment."
            return
        }
        // Clear the composer immediately on send so the textarea empties before
        // snapshot load / provider start / queue admission. Capture attachments
        // first; restore the draft only if the turn never starts.
        let attachedForSend = attachments
        prompt = ""
        // At most one snapshot load per send. Catalog probes (CLI Process /
        // network discovery) are expensive and must not run 2–3× on the
        // MainActor-isolated send path. A fresh TTL cache covers the rest.
        var didLoadProviderSnapshotsThisSend = false
        // Snapshots can still be empty on first send (seed/load race). Load once
        // before the fail-closed gate so a ready Grok/Codex install is not blocked.
        // Also needed before `$goal` → `/goal` rewrite so provider slash catalogs
        // (Codex `/goal`) are available for normalization.
        if selectedProviderSnapshot == nil {
            await loadProviderSnapshots()
            didLoadProviderSnapshotsThisSend = true
        }
        // Canonical first-token triggers for every provider:
        // commands (`$goal`/`/goal`) → `/…`; skills (`/sam-work`/`$sam-work`) → `$…`.
        let text = AgentComposerSuggestions.normalizingComposerTriggerPrefix(
            trimmed,
            localSlashCommands: Self.localSlashCommands,
            providerSlashCommands: Array(Set(
                (selectedProviderSnapshot?.slashCommands ?? [])
                    + AgentComposerSuggestions.passThroughSlashCommands
                    + distillAdvertisedCommandNames
            )),
            skills: selectedProviderSnapshot?.skills ?? []
        )
        // Auto no longer silently routes to another provider — the Source host
        // must be runnable (install/auth/models). The old Auto bypass left users
        // with a late generic preferredSourceUnavailable after a failed admit.
        if !selectedProviderCanRun {
            // One refresh covers stale seed rows and run-as-user probe lag —
            // but only when this send has not already loaded and the catalog
            // TTL says the cache is stale.
            if !didLoadProviderSnapshotsThisSend,
               !providerSnapshotsAreFresh {
                await loadProviderSnapshots()
                didLoadProviderSnapshotsThisSend = true
            }
            if !selectedProviderCanRun {
                statusMessage = providerExecutionUnavailableReason ?? "The selected provider is unavailable."
                restoreComposerPromptAfterFailedSend(originalPrompt, expectedThreadId: sendThreadId)
                return
            }
        }
        // A real turn "uses" the active model — new threads reopen on it.
        rememberCurrentModel()
        lastSentAttachmentCount = attachedForSend.count
        recordPromptHistory(text)
        clearVisibleErrorForNewUserMessage()
        if let slash = Self.localSlashCommandParts(text),
           (slash.command == "plan" || slash.command == "default"),
           !slash.argument.isEmpty {
            if slash.command == "plan", !supportsPlanInteractionForSelectedProvider {
                _ = handleSlashCommand("/plan")
                prompt = slash.argument
                if let selectedThreadId { persistComposerDraft(for: selectedThreadId) }
                return
            }
            _ = handleSlashCommand("/\(slash.command)")
            // A failed/unavailable enqueue must fall through to a real run —
            // returning anyway silently dropped the user's prompt.
            if selectedThreadCanQueuePrompt,
               await enqueuePromptWhileRunning(text: slash.argument, attached: attachedForSend) {
                return
            }
            if await startProviderRun(
                text: slash.argument,
                attached: attachedForSend,
                recordHistory: false,
                interactionMode: interactionMode,
                recoveryDisplayText: originalPrompt
            ) == nil {
                lastSendOutcome = .failed
                restoreComposerPromptAfterFailedSend(originalPrompt, expectedThreadId: sendThreadId)
            } else {
                lastSendOutcome = .accepted
            }
            return
        }
        if (text.hasPrefix("/") || text.hasPrefix("$")), handleSlashCommand(text) {
            return
        }
        // A rebuild or stop holding the bot VM: the send queues behind it. A fresh thread
        // is created and its bot actor locked first so the drained message runs as the bot.
        let sendThread = sendThreadId.flatMap { id in threads.first(where: { $0.id == id }) }
        let sendActor: RunActor = sendThread?.actorLockedAt != nil ? (sendThread?.actor ?? .none) : selectedRunActor
        if case .bot(let botID) = sendActor,
           (sendThread?.actorLockedAt != nil ? sendThread?.executionTarget : nil) ?? botExecutionTargetProvider(botID) == .vm,
           let busy = botBusyMessage?(botID, sendThreadId ?? AgentThreadID()) {
            await queueBehindBusyBotVM(
                botID: botID, busy: busy, text: text, attached: attachedForSend,
                originalPrompt: originalPrompt, sendThreadId: sendThreadId, threadId: sendThreadId
            )
            return
        }
        if selectedThreadCanQueuePrompt,
           await enqueuePromptWhileRunning(text: text, attached: attachedForSend) {
            lastSendOutcome = .queued
            return
        }
        if await startProviderRun(
            text: text,
            attached: attachedForSend,
            recordHistory: false,
            interactionMode: interactionMode,
            recoveryDisplayText: originalPrompt
        ) == nil {
            // Another thread took the bot's VM after the check above: queue too.
            if let refusal = botVMClaimRefusal {
                botVMClaimRefusal = nil
                await queueBehindBusyBotVM(
                    botID: refusal.botID, busy: refusal.notice, text: text, attached: attachedForSend,
                    originalPrompt: originalPrompt, sendThreadId: sendThreadId, threadId: refusal.threadId
                )
                return
            }
            lastSendOutcome = .failed
            restoreComposerPromptAfterFailedSend(originalPrompt, expectedThreadId: sendThreadId)
        } else {
            lastSendOutcome = .accepted
        }
    }

    /// A rebuild or stop holds the bot VM: the send waits in the queue of the thread it was
    /// sent for (`threadId`; nil = a fresh thread) behind it, even when
    /// the user switched threads meanwhile. A fresh thread is created and its
    /// bot actor locked first so the drained message runs as the bot.
    private func queueBehindBusyBotVM(
        botID: BotID,
        busy: String,
        text: String,
        attached: [AgentAttachment],
        originalPrompt: String,
        sendThreadId: AgentThreadID?,
        threadId: AgentThreadID?
    ) async {
        // A fresh-thread send whose composer moved to another thread meanwhile
        // has no thread of its own to queue on.
        var target = threadId
        if target == nil, selectedThreadId == nil {
            createThread(title: "New thread")
            target = selectedThreadId
        }
        if let tid = target {
            if threads.first(where: { $0.id == tid })?.actorLockedAt == nil {
                do { try lockBotActor(botID: botID, threadId: tid) } catch {
                    if selectedThreadId == tid {
                        statusMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    }
                    lastSendOutcome = .failed
                    restoreComposerPromptAfterFailedSend(originalPrompt, expectedThreadId: sendThreadId)
                    return
                }
            }
            if await enqueuePromptWhileRunning(text: text, attached: attached, threadId: tid) {
                botWaitForVM?(botID, tid)
                if selectedThreadId == tid { statusMessage = busy }
                lastSendOutcome = .queued
                return
            }
        }
        if selectedThreadId == sendThreadId { statusMessage = busy }
        lastSendOutcome = .failed
        restoreComposerPromptAfterFailedSend(originalPrompt, expectedThreadId: sendThreadId)
    }

    /// The interceptor writes the send; its rows paint on this turn and the
    /// composer clears only once it accepted the message.
    private func sendThroughInterceptor(_ interceptor: AgentAppSendInterceptor, text: String) {
        guard let threadId = selectedThreadId ?? embedding?.pinnedThreadId else { return }
        do {
            let rows = try interceptor(text, attachments, threadId)
            prompt = ""
            attachments = []
            statusMessage = ""
            try? clearComposerDraft(threadId: threadId, providerInstanceId: providerInstanceId)
            guard selectedThreadId == threadId else { return }
            // Rows already projected while the send ran (waiting rows) are
            // re-placed in the send's order: the user line first.
            let sent = rows.filter { $0.threadId == threadId }
            let ids = Set(sent.map(\.id))
            var next = messages
            let insertAt = next.firstIndex { ids.contains($0.id) } ?? next.endIndex
            next.removeAll { ids.contains($0.id) }
            next.insert(contentsOf: sent, at: min(insertAt, next.endIndex))
            messages = next
            ensureBotPeerReconciliation()
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    @discardableResult
    public func presentBotPeerActivity(
        peer: BotDefinition,
        phase: BotPeerActivityPhase,
        threadId: AgentThreadID,
        replacing replacementID: AgentMessageID? = nil
    ) -> AgentMessageID? {
        presentBotPeerContent(
            BotPeerTranscript.encodeActivity(peer: peer, phase: phase),
            threadId: threadId,
            replacing: replacementID
        )
    }

    @discardableResult
    public func presentBotPeerMessage(
        peer: BotDefinition,
        text: String,
        threadId: AgentThreadID,
        replacing replacementID: AgentMessageID? = nil
    ) -> AgentMessageID? {
        presentBotPeerContent(
            BotPeerTranscript.encode(peer: peer, text: text),
            threadId: threadId,
            replacing: replacementID
        )
    }

    /// Applies one already-verified durable peer row without changing the
    /// selected thread, composer draft, or focus state.
    /// Workspace membership uses the cache-first probe — never a 26-column get.
    public func applyPersistedBotPeerMessage(
        messageID: AgentMessageID,
        threadId: AgentThreadID,
        terminalStatus: AgentRunStatus? = nil
    ) {
        guard resolvedWorkspaceID(for: threadId) == workspaceID,
              let message = try? messageRepo.get(id: messageID),
              message.threadId == threadId,
              message.role == .assistant else { return }
        if selectedThreadId == threadId {
            if let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
            if let terminalStatus {
                status = terminalStatus
            }
            ensureBotPeerReconciliation()
        }
        scheduleReloadThreads(delayMilliseconds: 0)
    }

    /// A row the host already persisted in `threadId` (Titio's inbox notices,
    /// the user rows and result lines of a card act, and resolution
    /// rewrites): upserted by id from the row itself, any role, with no
    /// SQLite read on the MainActor.
    /// Messages the host removed from the thread (a cleared Titio notice).
    public func applyHostRemovedMessages(_ ids: [AgentMessageID], threadId: AgentThreadID) {
        guard selectedThreadId == threadId else { return }
        let removed = Set(ids)
        guard messages.contains(where: { removed.contains($0.id) }) else { return }
        messages.removeAll { removed.contains($0.id) }
    }

    /// The clear button: the row leaves at once; if the host could not
    /// remove it, it comes back where it was and the reason is shown.
    public func clearHostMessage(_ id: AgentMessageID) {
        guard let handler = embedding?.noticeClearHandler,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let removed = messages.remove(at: index)
        Task { @MainActor [weak self] in
            guard await handler(id) == false, let self else { return }
            statusMessage = "Could not clear the notification."
            guard selectedThreadId == removed.threadId, !messages.contains(where: { $0.id == id }) else { return }
            let position = messages.firstIndex { $0.createdAt > removed.createdAt } ?? messages.endIndex
            messages.insert(removed, at: position)
        }
    }

    public func applyHostWrittenMessage(_ message: AgentMessage) {
        guard selectedThreadId == message.threadId else { return }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        scheduleReloadThreads(delayMilliseconds: 0)
    }

    /// Replaces waiting peer chrome from its durable row when the immediate
    /// projection event was missed.
    func reconcilePersistedBotPeerActivities() async {
        guard !isDisposed, let threadID = selectedThreadId else { return }
        let waitingIDs = Set(messages.compactMap { message -> AgentMessageID? in
            guard message.threadId == threadID,
                  message.role == .assistant,
                  BotPeerTranscript.parseActivity(message.content)?.phase == .waiting else {
                return nil
            }
            return message.id
        })
        let awaitsTerminalThreadStatus = (status == .pending || status == .running)
            && messages.contains {
                $0.threadId == threadID
                    && $0.role == .assistant
                    && BotPeerTranscript.parse($0.content) != nil
            }
        guard !waitingIDs.isEmpty || awaitsTerminalThreadStatus else { return }

        let repository = messageRepo
        let persisted = await Task.detached(priority: .utility) {
            var rows: [AgentMessageID: AgentMessage] = [:]
            for messageID in waitingIDs {
                if let message = try? repository.get(id: messageID) {
                    rows[messageID] = message
                }
            }
            return rows
        }.value

        guard !isDisposed, selectedThreadId == threadID else { return }
        var replacedWaitingRow = false
        for index in messages.indices {
            let current = messages[index]
            guard waitingIDs.contains(current.id),
                  BotPeerTranscript.parseActivity(current.content)?.phase == .waiting,
                  let stored = persisted[current.id],
                  stored.threadId == threadID,
                  stored.role == .assistant,
                  stored.content != current.content,
                  BotPeerTranscript.parse(stored.content) != nil
                    || BotPeerTranscript.parseActivity(stored.content) != nil else { continue }
            messages[index] = stored
            replacedWaitingRow = true
        }
        if replacedWaitingRow || awaitsTerminalThreadStatus,
           let durableStatus = try? threadRepo.status(of: threadID) {
            let statusChanged = status != durableStatus
            status = durableStatus
            if replacedWaitingRow || statusChanged {
                scheduleReloadThreads(delayMilliseconds: 0)
            }
        }
    }

    private func ensureBotPeerReconciliation() {
        guard botPeerReconciliationTask == nil,
              needsBotPeerReconciliation else { return }
        let interval = botPeerReconciliationIntervalNanoseconds
        botPeerReconciliationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self, !Task.isCancelled, !self.isDisposed else { return }
                await self.reconcilePersistedBotPeerActivities()
                guard self.needsBotPeerReconciliation else {
                    self.botPeerReconciliationTask = nil
                    return
                }
            }
        }
    }

    private var hasWaitingBotPeerActivity: Bool {
        transcriptState.waitingBotPeerActivity
    }

    private var needsBotPeerReconciliation: Bool {
        if hasWaitingBotPeerActivity { return true }
        guard status == .pending || status == .running,
              let threadID = selectedThreadId else { return false }
        return messages.contains {
            $0.threadId == threadID
                && $0.role == .assistant
                && BotPeerTranscript.parse($0.content) != nil
        }
    }

    private func presentBotPeerContent(
        _ content: String,
        threadId: AgentThreadID,
        replacing replacementID: AgentMessageID?
    ) -> AgentMessageID? {
        let messageID = replacementID ?? AgentMessageID()
        let existing = messages.first(where: { $0.id == messageID })
            ?? (try? messageRepo.get(id: messageID))
        let message = AgentMessage(
            id: messageID,
            threadId: threadId,
            role: .assistant,
            content: content,
            createdAt: existing?.createdAt ?? Date()
        )
        do {
            try messageRepo.append(message)
            guard let stored = try messageRepo.get(id: messageID),
                  stored.threadId == threadId,
                  stored.role == .assistant,
                  stored.content == content else {
                statusMessage = "The bot reply could not be verified."
                return nil
            }
        } catch {
            statusMessage = String(describing: error)
            return nil
        }
        guard selectedThreadId == threadId else {
            do {
                let unreadAt = Date()
                guard let wrote = try threadRepo.markUnreadUpdatingActivity(of: threadId, at: unreadAt) else {
                    statusMessage = "The bot reply thread is no longer available."
                    return nil
                }
                if wrote {
                    onThreadChromeWritten?(AgentThreadChromeWrite(
                        threadID: threadId, hasUnread: true, updatedAt: unreadAt
                    ))
                    scheduleReloadThreads(delayMilliseconds: 0)
                }
            } catch {
                statusMessage = String(describing: error)
                return nil
            }
            return messageID
        }
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        ensureBotPeerReconciliation()
        return messageID
    }

    /// Puts the draft back only when send never started a turn and the composer
    /// is still empty on the same thread (user did not type or switch away).
    private func restoreComposerPromptAfterFailedSend(
        _ original: String,
        expectedThreadId: AgentThreadID?
    ) {
        guard prompt.isEmpty else { return }
        if let expectedThreadId, selectedThreadId != expectedThreadId { return }
        prompt = original
    }

    /// UX-MAC_AGENT-BG-AWAIT / incomplete-turn: manually resume a thread that
    /// stalled mid-task (supervised counterpart of the autonomous auto-nudge).
    /// Uses the reason-specific prompt (workflow handoff vs background await).
    public func continueAfterBackgroundWait() async {
        guard let reason = incompleteTurnReason else { return }
        prompt = IncompleteTurnContinuation.prompt(for: reason)
        await send()
    }

    private var selectedThreadCanQueuePrompt: Bool {
        guard let selectedThreadId else { return false }
        if selectedThreadRunIsStartingOrRunning { return true }
        if coordinator.activeThreadIdsSnapshot().contains(selectedThreadId) { return true }
        if coordinator.hasProviderSession(threadId: selectedThreadId) { return true }
        guard let currentRunId,
              let runStatus = try? coordinator.runStatus(currentRunId) else { return false }
        return runStatus == .running || runStatus == .pending
    }

    /// Send/queue only need routing. The painted rail already JOINs it —
    /// do not full-get a 26-column row that is already in `threads`.
    private func routingConfigurationForSend(threadId: AgentThreadID) -> AgentRoutingConfiguration {
        if let painted = threads.first(where: { $0.id == threadId }) {
            return painted.effectiveRoutingConfiguration
        }
        // Routing row only. A leftover 26-column `get` hitchs send/queue when
        // the painted rail does not already hold the thread.
        return (try? threadRepo.routingConfiguration(of: threadId))
            ?? .legacyManual(selection: currentModelSelection, providerInstanceId: providerInstanceId)
    }

    func routingConfigurationForSendForTesting(threadId: AgentThreadID) -> AgentRoutingConfiguration {
        routingConfigurationForSend(threadId: threadId)
    }

    /// `threadId` (default: the selected thread) is the thread whose queue takes
    /// the message; the composer, timeline and queue chrome are touched only
    /// while that thread is still the selected one.
    private func enqueuePromptWhileRunning(
        text: String,
        attached: [AgentAttachment],
        interactionMode: AgentInteractionMode? = nil,
        threadId: AgentThreadID? = nil
    ) async -> Bool {
        guard !refuseLegacyProviderThreadRun() else { return false }
        guard let targetThreadId = threadId ?? selectedThreadId, let queuedMessageRepo else { return false }
        let isSelected = targetThreadId == selectedThreadId
        let draftProviderInstanceId = isSelected
            ? providerInstanceId
            : (threads.first(where: { $0.id == targetThreadId })?.providerInstanceId ?? providerInstanceId)
        let mode = interactionMode ?? self.interactionMode
        do {
            let routing = routingConfigurationForSend(threadId: targetThreadId)
            if routing.mode == .auto {
                _ = try orchestrationRuntime.route(
                    configuration: routing,
                    providerSnapshots: providerSnapshots
                )
            } else {
                try AgentProviderRunPreflight.validate(
                    snapshot: selectedProviderSnapshot,
                    interactionMode: mode,
                    permissionMode: permissionMode,
                    attachments: attached
                )
            }
            let queued = try queuedMessageRepo.enqueueConsumingDraft(
                threadId: targetThreadId,
                providerInstanceId: draftProviderInstanceId,
                text: text,
                attachments: attached,
                interactionMode: mode,
                queuedRoutingSnapshot: AgentQueuedMessageRoutingSnapshot(configuration: routing)
            )
            // Queued follow-ups live only in the queue UI until drain starts the
            // provider turn. Do not mirror a transcript bubble yet — that would
            // look like the agent already received the message. Identity is still
            // queued id = future run id on drain (AgentRunID(queued.id)), so the
            // bubble appears once via startProviderRun when the turn actually starts.
            // Still clear the prior Active plan: the user has superseded it.
            if isSelected {
                timeline.clearActivePlan()
                suppressStaleActivePlanUpdates = true
                resetTimelineUpdateTick()
                prompt = ""
                attachments = []
            }
            clearComposerDraftMemory(threadId: targetThreadId, providerInstanceId: draftProviderInstanceId)
            // UX-MAC_AGENT-019: a run is in flight, so this message was queued,
            // not sent now — confirm that explicitly near the composer.
            if isSelected { reloadQueuedMessages() }
            setQueueStatus(
                "Queued — will run after the current turn.",
                threadId: targetThreadId
            )
            // QA-MAC_AGENT-010: track queue depth for diagnostics.
            agentSurfaceLog.info("queue.enqueued thread=\(targetThreadId.value.uuidString, privacy: .public) depth=\(self.queuedMessages.count, privacy: .public)")
            onQueuedMessageEvent?(AgentQueueEventKinds.queued, queued)
            return true
        } catch {
            setQueueStatus(
                "Queue send failed: \(error)",
                threadId: targetThreadId
            )
            return false
        }
    }

    /// Ensures Auto routing can pass orchestration admission (`revision > 0` +
    /// current policy digest). Heals threads created before that contract was
    /// enforced, without changing manual routing.
    private func admitReadyAutoRoutingConfiguration(
        from configuration: AgentRoutingConfiguration,
        threadId: AgentThreadID?
    ) throws -> AgentRoutingConfiguration {
        guard configuration.mode == .auto else { return configuration }
        let needsHeal = configuration.revision <= 0
            || configuration.policyDigest != orchestrationRuntime.policyDigest
            || configuration.eligibleProviders.isEmpty
        guard needsHeal else { return configuration }

        let seed = AgentRoutingConfiguration(
            schemaVersion: configuration.schemaVersion,
            mode: .manual,
            manualSelection: configuration.manualSelection,
            manualProviderInstanceId: configuration.manualProviderInstanceId,
            eligibleProviders: configuration.eligibleProviders.isEmpty
                ? AgentProvider.selectable
                : configuration.eligibleProviders,
            policyDigest: "",
            revision: max(0, configuration.revision),
            updatedAt: configuration.updatedAt
        )
        let healed = try orchestrationRuntime.autoConfiguration(
            replacing: seed,
            expectedRevision: seed.revision,
            manualSelection: configuration.manualSelection,
            manualProviderInstanceId: configuration.manualProviderInstanceId ?? providerInstanceId,
            providerSnapshots: providerSnapshots
        )
        if let threadId {
            try threadRepo.setRoutingConfiguration(
                healed,
                threadId: threadId,
                expectedRevision: configuration.revision
            )
            // Routing chrome only. A leftover 26-column `get` after CAS hitchs
            // Auto send heal; the CAS result is already in `healed`.
            if let index = threads.firstIndex(where: { $0.id == threadId }) {
                threads[index].routingConfiguration = healed
                threads[index].updatedAt = healed.updatedAt
            }
            routingMode = .auto
        }
        return healed
    }

    @discardableResult
    private func startProviderRun(
        text: String,
        attached: [AgentAttachment],
        recordHistory: Bool,
        interactionMode: AgentInteractionMode,
        resumeInterrupted: Bool = false,
        requestedRunId: AgentRunID? = nil,
        routingConfiguration: AgentRoutingConfiguration? = nil,
        queuedRoutingSnapshot: AgentQueuedMessageRoutingSnapshot? = nil,
        /// Exact pre-normalization composer text for post-start draft-cleanup recovery.
        /// Provider still receives `text`; omit for non-send callers.
        recoveryDisplayText: String? = nil
    ) async -> AgentRunID? {
        botVMClaimRefusal = nil
        // A surface whose sends are intercepted (a bot group room) never runs a provider.
        guard !refuseInterceptedRun() else { return nil }
        guard !refuseLegacyProviderThreadRun() else { return nil }
        guard !refuseUnavailableBotThreadRun() else { return nil }
        let baseRouting = queuedRoutingSnapshot?.configuration
            ?? routingConfiguration
            ?? selectedThreadId.map { routingConfigurationForSend(threadId: $0) }
            ?? .legacyManual(selection: currentModelSelection, providerInstanceId: providerInstanceId)
        let runProvider = provider
        let runProviderInstanceId = providerInstanceId
        let runModel = model
        let runModelSelection = currentModelSelection
        let runReasoningEffort = provider == .distill
            ? runModelSelection.distillMainEffortSelection?.effort
            : reasoningEffort
        let runReasoningModel = reasoningModel
        let runServiceTier = serviceTier
        let runSnapshot = selectedProviderSnapshot
        let routingSnapshot: AgentOrchestrationRoutingSnapshot?
        let effectiveRouting: AgentRoutingConfiguration
        do {
            // Queued messages keep the snapshot captured at enqueue time.
            if queuedRoutingSnapshot != nil {
                effectiveRouting = baseRouting
            } else {
                effectiveRouting = try admitReadyAutoRoutingConfiguration(
                    from: baseRouting,
                    threadId: selectedThreadId
                )
            }
            if effectiveRouting.mode == .auto {
                guard selectedThreadId != nil else {
                    throw AgentOrchestrationAdmissionError.invalidRoutingMode
                }
                // Prefer a fresh probe when the Source is not yet Auto-admittable
                // (stale seed / run-as-user home not reflected in the last load).
                // Skip when the catalog is still inside the shared TTL — send()
                // may have just loaded, and a third MainActor-bound probe is what
                // beachballed the composer.
                var admitSnapshots = providerSnapshots
                if AgentOrchestrationRuntime.autoAdmitSnapshot(
                    provider: effectiveRouting.manualSelection.provider,
                    preferredInstanceId: effectiveRouting.manualProviderInstanceId ?? runProviderInstanceId,
                    providerSnapshots: admitSnapshots,
                    requireLiveCatalog: false
                ) == nil,
                   !providerSnapshotsAreFresh {
                    await loadProviderSnapshots()
                    admitSnapshots = providerSnapshots
                }
                if AgentOrchestrationRuntime.autoAdmitSnapshot(
                    provider: effectiveRouting.manualSelection.provider,
                    preferredInstanceId: effectiveRouting.manualProviderInstanceId ?? runProviderInstanceId,
                    providerSnapshots: admitSnapshots,
                    requireLiveCatalog: false
                ) == nil {
                    let threadRunAs = selectedThreadId.flatMap { id in
                        threads.first(where: { $0.id == id })?.runAsUser
                    } ?? runAsUser
                    throw AgentOrchestrationAdmissionError.preferredSourceUnavailable(
                        effectiveRouting.manualSelection.provider,
                        detail: AgentOrchestrationRuntime.preferredSourceUnavailabilityDetail(
                            provider: effectiveRouting.manualSelection.provider,
                            preferredInstanceId: effectiveRouting.manualProviderInstanceId ?? runProviderInstanceId,
                            providerSnapshots: admitSnapshots,
                            runAsUser: threadRunAs
                        )
                    )
                }
                let launchConfigurations = Dictionary(uniqueKeysWithValues: admitSnapshots.map { snapshot in
                    let launch = providerLaunchConfig?(snapshot.provider, snapshot.id)
                    return (snapshot.id, AgentOrchestrationLaunchConfiguration(
                        binary: launch?.binary,
                        environment: launch?.environment ?? [:]
                    ))
                })
                routingSnapshot = AgentOrchestrationRoutingSnapshot(
                    configuration: effectiveRouting,
                    providerSnapshots: admitSnapshots,
                    launchConfigurations: launchConfigurations,
                    admissionSnapshot: queuedRoutingSnapshot
                )
            } else {
                routingSnapshot = nil
                try AgentProviderRunPreflight.validate(
                    snapshot: runSnapshot,
                    interactionMode: interactionMode,
                    permissionMode: permissionMode,
                    attachments: attached
                )
            }
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return nil
        }
        if runProvider == .distill, runModel == "auto",
           runAsUser.map({ $0.uid == getuid() }) ?? true {
            let launch = providerLaunchConfig?(runProvider, runProviderInstanceId)
            let environment = ProcessInfo.processInfo.environment.merging(launch?.environment ?? [:]) { _, run in run }
            let home = DistillProvisioner.homeURL(
                environment: environment,
                userHome: runAsUser?.homePath ?? FileManager.default.homeDirectoryForCurrentUser.path
            )
            do {
                _ = try DistillAccounts.autoRoutingAccounts(home: home)
            } catch {
                statusMessage = error.localizedDescription
                showingAutoRoutingSetup = error is DistillAutoRoutingError && AgentAutoGuide.makeGuide != nil
                return nil
            }
        }
        if recordHistory { recordPromptHistory(text) }
        if selectedThreadId == nil {
            createThread(title: "New thread")
        }
        guard let tid = selectedThreadId else { return nil }
        let runId = requestedRunId ?? AgentRunID()
        // A locked thread keeps its stored actor; the chip only decides the first send.
        let cachedActorThread = threads.first(where: { $0.id == tid })
        let actorThread: AgentThread?
        do {
            actorThread = try cachedActorThread.map { try threadRepo.reconcileBotExecutionTarget($0, forUserSend: true) }
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
        if let actorThread, actorThread.executionTarget != cachedActorThread?.executionTarget {
            mirrorExecutionTarget(.mac, thread: tid)
            onThreadConfigPersisted?(actorThread)
        }
        let runActor: RunActor = actorThread?.actorLockedAt != nil ? (actorThread?.actor ?? .none) : selectedRunActor
        var botPrompt: String?
        // Agent App tabs gate every bot send; the embedded desk gates the threads
        // locked to the bot's VM (its legacy unlocked threads keep running on the Mac).
        if case .bot(let botID) = runActor,
           embedding == nil || (actorThread?.actorLockedAt != nil && actorThread?.executionTarget == .vm),
           await botVMGateBlocksRun(botID: botID, thread: actorThread) {
            return nil
        }
        // A paired device can lock the thread while the VM preflight above
        // awaits, or before this composer mirrored it: the stored lock wins and
        // this send stops with its prompt kept. Two columns; no full row read.
        if actorThread?.actorLockedAt == nil,
           (try? threadRepo.lockedBotActor(of: tid)) != nil,
           let stored = try? threadRepo.get(id: tid) {
            mirrorActorLock(stored.actor, lockedAt: stored.actorLockedAt, target: stored.executionTarget, thread: tid)
            statusMessage = ThreadActorAlreadyLockedError().errorDescription ?? ""
            return nil
        }
        // D12: claim the bot's VM before any visible start effect. When a
        // rebuild or stop holds it, refuse so `send()` queues behind it.
        var vmClaimRunId: AgentRunID?
        var vmRunStarted = false
        defer {
            if let vmClaimRunId, !vmRunStarted { botReleaseVM?(vmClaimRunId) }
        }
        if case .bot(let botID) = runActor, let claimVM = botClaimVM {
            let vmTarget = actorThread?.actorLockedAt != nil
                ? actorThread?.executionTarget
                : (embedding == nil ? botExecutionTargetProvider(botID) : nil)
            if vmTarget == .vm {
                // The title the thread gets from this message (B5 below).
                let title = actorThread.map {
                    AgentThreadTitle.isPlaceholder($0.title) && !((try? messageRepo.hasAny(threadId: tid)) ?? false)
                        ? Self.deriveTitle(from: text)
                        : $0.title
                } ?? Self.deriveTitle(from: text)
                let entry = BotVMRunRegistry.Entry(
                    threadID: tid,
                    runID: runId,
                    title: title,
                    workspace: actorThread?.worktreePath ?? embedding?.executionCwd ?? cwd
                )
                if let holder = claimVM(botID, entry) {
                    let notice = "The VM is busy in \(holder.title)"
                    botVMClaimRefusal = (botID, notice, tid)
                    if selectedThreadId == tid { statusMessage = notice }
                    return nil
                }
                vmClaimRunId = runId
            }
        }
        if embedding == nil, case .bot(let botID) = runActor {
            do {
                if actorThread?.actorLockedAt == nil { try lockBotActor(botID: botID, threadId: tid) }
                guard let transform = botPromptTransform else { throw BotRunUnavailableError() }
                botPrompt = try await transform(botID, text, tid, runId)
            } catch {
                statusMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                return nil
            }
        }
        // Everything from here to the tracked run below is preparation the user
        // cannot see (preflight, provider spawn). Show
        // "Loading…" for it; the defer covers the failure exits so a thread can
        // never be left permanently loading.
        // Run identity is fixed at acceptance so Stop can cancel this generation.
        // A prior run's last snapshot is not evidence for this run. Clear the
        // holder projection at acceptance, before the new run becomes live, so
        // an idle → new-run transition cannot resurrect old Stop-strip details.
        if selectedThreadId == tid {
            liveBackgroundShellCount = 0
            liveBackgroundTasks = []
        }
        // S5: accept surface-owned preparation generation before any preparation work.
        // Capture the generation for this startProviderRun invocation — never
        // re-read state.generation after await (Stop + resend can advance it).
        let surfaceAccept = ProviderPreparationStateMachine.apply(
            state: surfacePreparationStates[tid] ?? ProviderPreparationState(),
            event: .accept(
                draftMessageId: runId.value.uuidString,
                atMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )
        surfacePreparationStates[tid] = surfaceAccept.state
        let acceptedGeneration = surfaceAccept.state.generation
        beginSurfacePreparation(threadId: tid, generation: acceptedGeneration, runId: runId)
        // Coordinator-owned reservation before preparation so RPC/iOS Stop
        // during it can cancel this run (not only local UI Stop).
        coordinator.reserveProviderStart(threadId: tid, runId: runId)
        defer {
            endSurfacePreparationIfOwned(threadId: tid, generation: acceptedGeneration)
        }
        // B5: title a still-default thread from its first message.
        if let t = threads.first(where: { $0.id == tid }),
           AgentThreadTitle.isPlaceholder(t.title),
           !((try? messageRepo.hasAny(threadId: tid)) ?? false) {
            renameThread(tid, to: Self.deriveTitle(from: text))
        }
        loadAllMessages(tid)
        suppressPersistedFinalDuplicatedByTimeline()
        lastErrorRecoverable = false  // UX-MAC_AGENT-009: clear stale Retry on new run
        selectedThreadHasRecoverableContext = false  // UX-MAC_AGENT-CONTINUE: run started; hide Continue
        let display = AgentChatTranscriptChrome.displayUserLine(text: text, attachments: attached)
        // The coordinator is the single writer of run messages — mirror
        // the user message in-memory only (no double-persist). Queue drain
        // passes the same UUID as runId, so the optimistic bubble is stable.
        let durableUserMessageExists = (try? messageRepo.exists(id: AgentMessageID(runId.value))) == true
        if !resumeInterrupted && !durableUserMessageExists {
            presentOutgoingUserMessage(
                threadId: tid,
                messageId: AgentMessageID(runId.value),
                display: display,
                attachments: attached
            )
        } else {
            // Resume / already-persisted path still drops a stale Active plan so
            // the transcript bottom is the new turn, not the prior checklist.
            timeline.clearActivePlan()
            suppressStaleActivePlanUpdates = true
            resetTimelineUpdateTick()
            focusTick &+= 1
        }
        // UX-MAC_AGENT-PLAN-FRESH: keep suppressStaleActivePlanUpdates = true until a
        // *fresh* activePlanUpdated for this follow-up arrives (see flushStreamEvents).
        // Clearing suppress here immediately re-painted the prior turn's completed
        // checklist under the new user bubble (late events + durable rehydrate).
        persistThreadConfig()
        let launchConfig = providerLaunchConfig?(runProvider, runProviderInstanceId)
        let threadRunAsUser = threads.first(where: { $0.id == tid })?.runAsUser ?? runAsUser
        let persistedThread = threads.first(where: { $0.id == tid })
        let providerThreadId = persistedThread?.provider == runProvider
            ? persistedThread?.providerThreadId
            : nil
        // Leftover Graphify keys in a launch config never reach a provider.
        let launchEnvironment = (launchConfig?.environment ?? [:])
            .filter { !$0.key.hasPrefix("RC_GRAPHIFY_") }
        // S5: claim spawn immediately after preparation, *before* durable pending /
        // currentRunId/runThreads. A late cancelled generation must not leave
        // surface ownership that poisons trackedRunId for a newer send.
        let surfacePrep = surfacePreparationStates[tid] ?? ProviderPreparationState()
        guard let claimedState = ProviderPreparationStateMachine.finishAndClaimCapturedGeneration(
            state: surfacePrep,
            acceptedGeneration: acceptedGeneration
        ) else {
            // Always drop this runId's projection; never leave stale runThreads[A].
            runThreads[runId] = nil
            if currentRunId == runId {
                currentRunId = nil
                runStartedAt = nil
            }
            if preparingRunGeneration[tid] == acceptedGeneration {
                let cancelled = ProviderPreparationStateMachine.apply(
                    state: surfacePrep,
                    event: .providerFinished(
                        generation: acceptedGeneration,
                        reason: .cancelled
                    )
                )
                if !cancelled.suppressLateCallback {
                    surfacePreparationStates[tid] = cancelled.state
                }
                statusMessage = "Run cancelled during preparation"
                status = .cancelled
                endSurfacePreparationIfOwned(threadId: tid, generation: acceptedGeneration)
            }
            return nil
        }
        surfacePreparationStates[tid] = claimedState
        // Reservation already published before preparation; keep it until startRun
        // registers or failure paths release it.
        let mentionedBots = BotMentionParser.mentionedBots(
            in: text,
            bots: mentionableBotsProvider(),
            excluding: nil
        )
        let providerEnvironment = BotPeerDelegation.environment(
            addingTurnContextTo: launchEnvironment,
            mentionedBots: mentionedBots
        )
        var transformFailure: Error?
        var runPrompt = botPrompt ?? text
        if let transform = embedding?.promptTransform {
            do {
                runPrompt = try await transform(text, tid, runId)
            } catch {
                transformFailure = error
            }
        }
        let req = AgentRunRequest(
            runId: runId,
            threadId: tid,
            provider: runProvider,
            providerInstanceId: runProviderInstanceId,
            model: runModel,
            cwd: embedding?.executionCwd ?? cwd,
            prompt: runPrompt,
            userMessageContent: display,
            attachments: attached,
            providerThreadId: resumeInterrupted ? nil : providerThreadId,
            permissionMode: linkedBotVMRequiresFullAccess ? .fullAccess : permissionMode,
            reasoningEffort: runReasoningEffort,
            reasoningModel: runReasoningModel,
            distillMainEffortSelection: runProvider == .distill
                ? runModelSelection.distillMainEffortSelection : nil,
            distillReasoningEffortSelection: runProvider == .distill
                ? runModelSelection.distillReasoningEffortSelection : nil,
            distillExecutionMode: runProvider == .distill ? runModelSelection.distillExecutionMode : .normal,
            serviceTier: runServiceTier,
            interactionMode: interactionMode,
            providerBinary: launchConfig?.binary,
            environment: providerEnvironment,
            runAsUser: threadRunAsUser
        )
        do {
            // Status + unread + updated_at only. A leftover 26-column + routing
            // `get` then `upsert` hitchs every composer send and rewrites routing
            // JSON. Coordinator.startRun stamps the same pending chrome; this
            // hop only needs existence plus painted unread for the optimistic rail.
            guard try threadRepo.status(of: tid) != nil else {
                throw NSError(
                    domain: "RemoteCode.AgentAppViewModel",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Thread disappeared before provider start."]
                )
            }
            let pendingAt = Date()
            let paintedUnread = threads.first(where: { $0.id == tid })?.hasUnread ?? false
            try threadRepo.updateStatus(
                id: tid,
                status: .pending,
                hasUnread: paintedUnread,
                at: pendingAt
            )
            onThreadChromeWritten?(AgentThreadChromeWrite(
                threadID: tid, status: .pending, hasUnread: paintedUnread, updatedAt: pendingAt
            ))
            if let index = threads.firstIndex(where: { $0.id == tid }) {
                threads[index].status = .pending
                threads[index].updatedAt = pendingAt
            }
            // Per-run mapping is always safe; selection-facing fields only if still selected.
            runThreads[runId] = tid
            if selectedThreadId == tid {
                status = .pending
                currentRunId = runId
                runStartedAt = nil
                isStopping = false
            }
            onRunStateChange?()
        } catch {
            // S5: only mutate prep state for *this* accepted generation.
            let failed = ProviderPreparationStateMachine.apply(
                state: surfacePreparationStates[tid] ?? ProviderPreparationState(),
                event: .preparationFailed(
                    generation: acceptedGeneration,
                    reason: .durabilityFailure
                )
            )
            if !failed.suppressLateCallback {
                surfacePreparationStates[tid] = failed.state
                if let current = try? threadRepo.status(of: tid), current == .pending {
                    let failedAt = Date()
                    let paintedUnread = threads.first(where: { $0.id == tid })?.hasUnread ?? false
                    if (try? threadRepo.updateStatus(
                        id: tid,
                        status: .failed,
                        hasUnread: paintedUnread,
                        at: failedAt
                    )) != nil {
                        onThreadChromeWritten?(AgentThreadChromeWrite(
                            threadID: tid, status: .failed, hasUnread: paintedUnread, updatedAt: failedAt
                        ))
                    }
                    if let index = threads.firstIndex(where: { $0.id == tid }) {
                        threads[index].status = .failed
                        threads[index].updatedAt = failedAt
                    }
                }
                if selectedThreadId == tid {
                    statusMessage = "Failed to prepare run: \(error)"
                    status = .failed
                }
            }
            runThreads[runId] = nil
            if currentRunId == runId {
                currentRunId = nil
            }
            coordinator.releaseProviderStartReservation(threadId: tid, runId: runId)
            return nil
        }
        do {
            if let transformFailure {
                let failedAt = Date()
                if (try? threadRepo.updateStatus(id: tid, status: .failed, hasUnread: false, at: failedAt)) != nil {
                    onThreadChromeWritten?(AgentThreadChromeWrite(
                        threadID: tid, status: .failed, hasUnread: false, updatedAt: failedAt
                    ))
                }
                throw transformFailure
            }
            let runId = try await coordinator.startRun(
                req,
                routingSnapshot: routingSnapshot,
                recordUserMessage: !resumeInterrupted
            )
            vmRunStarted = true
            coordinator.releaseProviderStartReservation(threadId: tid, runId: runId)
            // Surface claim consumed the permit; coordinator owns the live run.
            // Terminalize *this* generation so a second send can accept again.
            let done = ProviderPreparationStateMachine.apply(
                state: surfacePreparationStates[tid] ?? ProviderPreparationState(),
                event: .providerFinished(
                    generation: acceptedGeneration,
                    reason: .completed
                )
            )
            if !done.suppressLateCallback {
                surfacePreparationStates[tid] = done.state
            }
            // Never wipe another tab's composer when this prep finishes off-selection.
            if selectedThreadId == tid {
                do {
                    try clearComposerDraft(threadId: tid, providerInstanceId: providerInstanceId)
                    attachments = []
                    prompt = ""
                } catch {
                    if prompt.isEmpty {
                        prompt = recoveryDisplayText ?? text
                    }
                    statusMessage = "Provider started, but draft cleanup failed: \(error)"
                }
            } else {
                try? clearComposerDraft(threadId: tid, providerInstanceId: providerInstanceId)
            }
            let runStatus = (try? coordinator.runStatus(runId)) ?? .running
            await MainActor.run {
                self.terminalRunIds.remove(runId)
                // Never reinsert a synchronously-finished run as "active".
                if runStatus == .running || runStatus == .pending {
                    self.runThreads[runId] = tid
                } else {
                    self.runThreads[runId] = nil
                    self.terminalRunIds = Self.boundedTerminalRunIds(
                        existing: self.terminalRunIds,
                        adding: runId
                    )
                }
                if self.selectedThreadId == tid {
                    if runStatus == .running || runStatus == .pending {
                        self.currentRunId = runId
                        self.status = .running
                        self.runStartedAt = AgentAppViewModel.resolvedRunStartedAt(
                            current: self.runStartedAt,
                            persisted: (try? self.coordinator.runStartedAt(threadId: tid))
                                ?? (try? self.coordinator.runStartedAt(runId: runId))
                        )
                        self.isStopping = false
                    } else {
                        self.currentRunId = nil
                        self.status = runStatus
                        self.runStartedAt = nil
                    }
                }
                self.reloadThreads()
                self.onRunStateChange?()
            }
            embedding?.onRunStarted?(runId, tid)
            if embedding == nil, case .bot(let botID) = runActor { botRunStarted?(botID, runId, tid) }
            return runId
        } catch {
            let wasCancelled: Bool = {
                if let acceptance = error as? AgentRunAcceptanceError,
                   case .cancelled = acceptance {
                    return true
                }
                return false
            }()
            let finished = ProviderPreparationStateMachine.apply(
                state: surfacePreparationStates[tid] ?? ProviderPreparationState(),
                event: .providerFinished(
                    generation: acceptedGeneration,
                    reason: wasCancelled ? .cancelled : .providerFailure
                )
            )
            if !finished.suppressLateCallback {
                surfacePreparationStates[tid] = finished.state
            }
            runThreads[runId] = nil
            if preparingRunGeneration[tid] == acceptedGeneration
                || preparingRunGeneration[tid] == nil {
                if !wasCancelled {
                    failSurfacePendingStampIfUnowned(threadId: tid, runId: runId)
                }
                await MainActor.run {
                    if self.selectedThreadId == tid {
                        if wasCancelled {
                            self.statusMessage = "Run cancelled during preparation"
                            self.status = .cancelled
                        } else {
                            let detail = (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription
                            self.statusMessage = "Failed to start: \(detail)"
                            self.status = .failed
                        }
                        if self.currentRunId == runId {
                            self.currentRunId = nil
                            self.runStartedAt = nil
                        }
                        self.clearActivePlanFollowUpSuppressionIfSafe()
                    }
                    self.reloadThreads()
                    self.onRunStateChange?()
                }
            }
            coordinator.releaseProviderStartReservation(threadId: tid, runId: runId)
            return nil
        }
    }

    /// `coordinator.startRun` can refuse before it writes its own run row
    /// (admission, fork recovery, a busy thread, a missing binary...). The
    /// surface's `pending` stamp then has no owner that will ever finish it,
    /// so stamp `failed` here, unless another start or live run owns the row.
    private func failSurfacePendingStampIfUnowned(threadId tid: AgentThreadID, runId: AgentRunID) {
        guard (try? threadRepo.status(of: tid)) == .pending,
              (try? coordinator.runStatus(runId)) == nil,
              coordinator.activeRunId(threadId: tid) == nil,
              !coordinator.hasPendingProviderStart(threadId: tid),
              !coordinator.hasProviderSession(threadId: tid) else { return }
        let failedAt = Date()
        let paintedUnread = threads.first(where: { $0.id == tid })?.hasUnread ?? false
        guard (try? threadRepo.updateStatus(
            id: tid,
            status: .failed,
            hasUnread: paintedUnread,
            at: failedAt
        )) != nil else { return }
        onThreadChromeWritten?(AgentThreadChromeWrite(
            threadID: tid, status: .failed, hasUnread: paintedUnread, updatedAt: failedAt
        ))
        if let index = threads.firstIndex(where: { $0.id == tid }) {
            threads[index].status = .failed
            threads[index].updatedAt = failedAt
        }
    }

    public func implementLatestPlan(newThread: Bool = false) async {
        guard let sourceThreadId = selectedThreadId,
              let plan = latestProposedPlan else { return }
        let targetThreadId: AgentThreadID
        if newThread {
            createThread(title: "Implement plan")
            guard let selectedThreadId else { return }
            targetThreadId = selectedThreadId
        } else {
            targetThreadId = sourceThreadId
        }
        let prompt = AgentPlanImplementationPrompt.make(markdown: plan.markdown)
        clearVisibleErrorForNewUserMessage()
        // Same-thread Approve must not open a concurrent provider turn. Grok/Codex/Claude
        // adapters reject second prompts while inFlight; queue like send() and drain after.
        if !newThread && selectedThreadCanQueuePrompt {
            guard await enqueuePromptWhileRunning(text: prompt, attached: [], interactionMode: .default) else { return }
            markLatestPlanImplemented(sourceThreadId: sourceThreadId, plan: plan, targetThreadId: targetThreadId)
            return
        }
        guard await startProviderRun(text: prompt, attached: [], recordHistory: false, interactionMode: .default) != nil else { return }
        markLatestPlanImplemented(sourceThreadId: sourceThreadId, plan: plan, targetThreadId: targetThreadId)
    }

    public func rejectLatestPlan() async {
        guard latestProposedPlan != nil else { return }
        let prompt = "Reject this proposed plan. Do not implement it. Stay in Plan mode and produce a revised plan before making any workspace changes."
        clearVisibleErrorForNewUserMessage()
        if selectedThreadCanQueuePrompt {
            _ = await enqueuePromptWhileRunning(text: prompt, attached: [], interactionMode: .plan)
            return
        }
        _ = await startProviderRun(text: prompt, attached: [], recordHistory: false, interactionMode: .plan)
    }

    private func markLatestPlanImplemented(
        sourceThreadId: AgentThreadID,
        plan: AssistantProposedPlan,
        targetThreadId: AgentThreadID
    ) {
        do {
            try proposedPlanRepo?.markImplemented(threadId: sourceThreadId, planId: plan.id, implementationThreadId: targetThreadId)
        } catch {
            statusMessage = "Plan started, but implementation state could not be saved: \(error)"
            return
        }
        var implemented = plan
        implemented.implementedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        timeline.apply(.proposedPlan(implemented))
    }

    private func recordPromptHistory(_ text: String) {
        guard !text.isEmpty else { return }
        promptHistory.append(text)
        // PERF: trim only when over budget instead of rebuilding the 200-entry
        // array via Array(suffix:) on every sent prompt.
        if promptHistory.count > PromptHistoryStore.limit {
            promptHistory.removeFirst(promptHistory.count - PromptHistoryStore.limit)
        }
        promptHistoryStore?.save(promptHistory, workspaceID: workspaceID)
        // NOTE: call promptHistoryStore?.search(workspaceID:query:limit:) from a
        // search field in the composer to surface filtered history to the user.
        promptHistoryCursor = nil
    }

    nonisolated static func promptHistoryWriteErrorMessage(_ error: Error) -> String {
        "Prompt history could not be saved: \(error.localizedDescription)."
    }

    /// UX-MAC_AGENT-009: re-send the last prompt after a recoverable error
    /// without forcing the user to retype it.
    public func retryLastPrompt() async {
        if refuseInterceptedRun() { return }
        if refuseLegacyProviderThreadRun() { return }
        let failedMessage = selectedThreadId.flatMap { threadId in
            try? messageRepo.listRecent(
                threadId: threadId,
                limit: AgentMessageRepository.maxMessagesPerThread
            ).last(where: { $0.role == .user })
        }
        let last = failedMessage.map(Self.retryPrompt) ?? promptHistory.last
        guard let last, !last.isEmpty else { return }
        let persistedAttachments = failedMessage?.attachments ?? []
        if !persistedAttachments.isEmpty {
            var retryable: [AgentAttachment] = []
            var unavailable: [String] = []
            for attachment in persistedAttachments {
                do {
                    guard let attachmentStore else { throw AgentAttachmentResolverError.notReadableFile(attachment.displayName) }
                    retryable.append(try attachmentStore.validatedForRetry(attachment))
                } catch {
                    unavailable.append(attachment.displayName)
                }
            }
            if !unavailable.isEmpty {
                pendingAttachmentRetryConfirmation = AttachmentRetryConfirmation(
                    prompt: last,
                    retryableAttachments: retryable,
                    unavailableAttachmentNames: unavailable
                )
                return
            }
            clearVisibleErrorForNewUserMessage()
            _ = await startProviderRun(text: last, attached: retryable, recordHistory: false, interactionMode: interactionMode)
            return
        } else if lastSentAttachmentCount > 0 {
            pendingAttachmentRetryConfirmation = AttachmentRetryConfirmation(
                prompt: last,
                retryableAttachments: [],
                unavailableAttachmentNames: ["previous attachments"]
            )
            return
        }
        clearVisibleErrorForNewUserMessage()
        _ = await startProviderRun(text: last, attached: [], recordHistory: false, interactionMode: interactionMode)
    }

    public var displayedErrorRecoveryAction: AgentErrorRecoveryAction? {
        guard let message = timeline.error else { return nil }
        let action = Self.errorRecoveryAction(
            provider: provider,
            message: message,
            recoverable: lastErrorRecoverable
        )
        if action == .signIn, pendingSignInProvider == provider {
            return .retry
        }
        return action
    }

    nonisolated public static func errorRecoveryAction(
        provider: AgentProvider,
        message: String,
        recoverable: Bool
    ) -> AgentErrorRecoveryAction? {
        _ = provider // classification deliberately shares one vocabulary across providers.
        return errorRecoveryAction(message: message, recoverable: recoverable)
    }

    nonisolated public static func errorRecoveryAction(
        message: String,
        recoverable: Bool
    ) -> AgentErrorRecoveryAction? {
        let normalized = message.lowercased()
        // `[fresh-session:…]`: the adapter already retired the session whose
        // history the model rejected, so Retry re-runs the prompt in a new
        // provider session on the SAME thread (a bot desk keeps its linked
        // conversation). Start fresh would orphan the desk link instead.
        if AgentErrorRecoveryAction.hasFreshSessionMarker(message) {
            return .retry
        }
        let resumeInvalidMarkers = [
            "session not found", "session/load", "invalid session", "invalid resume",
            "resume cursor", "could not be resumed", "failed to resume", "resume invalid"
        ]
        if resumeInvalidMarkers.contains(where: normalized.contains) {
            return .startFresh
        }
        // Distill words a used-up account route as "Authentication required";
        // signing in cannot fix it, so offer no Sign in.
        if normalized.contains("no available account route") || normalized.contains("saved account route is unavailable") {
            return nil
        }
        let authMarkers = [
            "[auth-required]", "401", "403", "unauthorized", "unauthenticated",
            "authentication", "login required", "sign in required", "token expired",
            "invalid_api_key", "invalid api key", "forbidden"
        ]
        if authMarkers.contains(where: normalized.contains) {
            return .signIn
        }
        let retryMarkers = [
            "rate limit", "rate_limit", "too many requests", "429", "network",
            "connection", "timed out", "timeout", "temporarily unavailable",
            "service unavailable", "502", "503", "504"
        ]
        if retryMarkers.contains(where: normalized.contains) || recoverable {
            return .retry
        }
        return nil
    }

    public func performDisplayedErrorRecoveryAction() async {
        guard let action = displayedErrorRecoveryAction else { return }
        switch action {
        case .retry:
            if pendingSignInProvider == provider {
                _ = await refreshPendingProviderAuthentication(retryLastPromptWhenAuthenticated: true)
                return
            }
            await retryLastPrompt()
        case .startFresh:
            let failedPrompt = selectedThreadId.flatMap { threadId in
                try? messageRepo.listRecent(
                    threadId: threadId,
                    limit: AgentMessageRepository.maxMessagesPerThread
                ).last(where: { $0.role == .user })
            }.map(Self.retryPrompt)
            createThread(title: "New thread")
            if let failedPrompt, !failedPrompt.isEmpty {
                prompt = failedPrompt
                focusTick &+= 1
            }
        case .signIn:
            beginProviderSignIn(provider: provider, snapshotID: selectedProviderSnapshot?.id)
        }
    }

    public func confirmRetryWithoutUnavailableAttachments() async {
        guard let pending = pendingAttachmentRetryConfirmation else { return }
        pendingAttachmentRetryConfirmation = nil
        systemNote("Retry continuing without unavailable attachment(s): \(pending.unavailableAttachmentNames.joined(separator: ", ")).")
        clearVisibleErrorForNewUserMessage()
        _ = await startProviderRun(
            text: pending.prompt,
            attached: pending.retryableAttachments,
            recordHistory: false,
            interactionMode: interactionMode
        )
    }

    public func cancelRetryWithoutUnavailableAttachments() {
        pendingAttachmentRetryConfirmation = nil
    }

    private static func retryPrompt(_ message: AgentMessage) -> String {
        AgentChatTranscriptChrome.promptByRemovingDisplayDecorations(
            from: message.content,
            attachments: message.attachments
        )
    }

    @discardableResult
    public func recallPreviousPrompt() -> Bool {
        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || promptHistoryCursor != nil else { return false }
        guard !promptHistory.isEmpty else { return false }
        let next = promptHistoryCursor.map { max($0 - 1, 0) } ?? (promptHistory.count - 1)
        promptHistoryCursor = next
        prompt = promptHistory[next]
        return true
    }

    @discardableResult
    public func recallNextPrompt() -> Bool {
        guard let cursor = promptHistoryCursor else { return false }
        let next = cursor + 1
        guard next < promptHistory.count else {
            promptHistoryCursor = nil
            prompt = ""
            return true
        }
        promptHistoryCursor = next
        prompt = promptHistory[next]
        return true
    }

    public func stop() {
        let tid = selectedThreadId
        // Only trust currentRunId when it maps to the selected thread (parallel prep).
        let localRunId: AgentRunID? = {
            if let c = currentRunId, let tid, runThreads[c] == tid { return c }
            return tid.flatMap { trackedRunId(for: $0) }
        }()
        // S5: cancel generation-owned surface preparation even when no run is
        // tracked yet (preflight window before coordinator.startRun).
        if let tid, preparingRunThreads.contains(tid) {
            cancelSurfacePreparation(threadId: tid)
            // Only fall through to stopRun when the coordinator already owns a
            // pending start or live run — otherwise stopRun arms pendingThreadStops
            // on a never-started thread and poisons the immediate resend.
            // cancelSurfacePreparation already called cancelPreparation; if a
            // start was reserved/pending, pendingThreadStops is armed — still
            // fall through to stopRun when a live/pending start exists.
            let coordinatorOwns = coordinator.hasPendingProviderStart(threadId: tid)
                || coordinator.isPreparingProviderStart(threadId: tid)
                || coordinator.activeRunId(threadId: tid) != nil
            if !coordinatorOwns {
                return
            }
        }
        // Second click while already Stopping: hard-await termination so a
        // stuck soft interrupt cannot leave the button disabled forever. This must
        // stay AHEAD of the stale-projection branch below: the first Stop can
        // already have released durable ownership (markStopRequested synthesizes a
        // cancelled terminal with providerTerminalAcknowledged=false) while the
        // provider's own teardown is still outstanding, and stopAndAwaitTermination
        // is the only path that then releases that live adapter session.
        if isStopping, let tid {
            Task { @MainActor in
                do {
                    try await self.coordinator.stopAndAwaitTermination(threadId: tid)
                } catch {
                    self.statusMessage = "Force stop: \(error.localizedDescription)"
                }
                // If the coordinator still owns the run after the hard deadline,
                // clear the UI latch so the user is not stuck on Stopping…
                if self.trackedRunId(for: tid) == nil {
                    self.isStopping = false
                    if self.selectedThreadId == tid {
                        self.currentRunId = nil
                        self.runStartedAt = nil
                    }
                } else if !self.hasStoppableRun(threadId: tid) {
                    // Ownership is only a stale surface projection (no live run, no
                    // durable pending/running row). That is not a stop timeout, so
                    // clear it silently instead of blaming the provider.
                    self.clearStaleRunProjection(threadId: tid)
                } else {
                    // Loud failure: hard timeout still left ownership — drop the
                    // latch so Stop is usable again and surface the error.
                    self.isStopping = false
                    if self.statusMessage.isEmpty {
                        self.statusMessage = "Stop is taking longer than expected. Try again or restart the agent."
                    }
                }
            }
            return
        }
        // Nothing to interrupt: the surface shows Working for a run that neither
        // this process nor SQLite still lists as active (a projection left behind
        // by a finished turn, or re-inflated by a recovered provider session).
        // Latching "Stopping…" here stranded the UI forever — only run lifecycle
        // events clear that latch and none can arrive for a dead run — so drop the
        // projection and go idle instead.
        if let tid, !hasStoppableRun(threadId: tid) {
            // Keep both best-effort stops the old fall-through performed: a handle
            // can still be registered under a runId whose thread mapping was
            // already released, and only stopRun(runId:) can cancel that orphan.
            if let localRunId { coordinator.stopRun(localRunId) }
            // The F19 guard's status probe is the repaint's status too: that path
            // returned before writing anything, so a second probe here is pure
            // overhead on every stale Stop.
            let guardStatus = coordinator.stopRun(threadId: tid)
            clearStaleRunProjection(threadId: tid, durableStatus: guardStatus)
            return
        }
        // Path B: scheduled runs are owned by the LaunchAgent. Prefer XPC stop
        // when SQLite says this thread has an active scheduled occurrence.
        if let tid, isScheduledThreadRunning?(tid) == true, let stopScheduledThread {
            isStopping = true
            Task { @MainActor in
                let accepted = await stopScheduledThread(tid, localRunId)
                if !accepted {
                    // Loud failure: do not leave the UI stuck on Stopping…
                    self.isStopping = false
                    self.statusMessage = "Could not stop scheduled run (scheduler unavailable or run not owned)."
                }
            }
            return
        }
        if let r = localRunId {
            coordinator.stopRun(r)
        }
        if let tid {
            coordinator.stopRun(threadId: tid)
        }
        // UX-MAC_AGENT-STOP: signal that the interrupt was sent so the UI can
        // show "Stopping..." until the run terminates. Keep the control enabled
        // so a second click can force-stop if soft cancel stalls.
        isStopping = true
    }

    /// True when Stop has a real target: a coordinator-owned run, a provider start
    /// still in flight, a durable pending/running row, or a LaunchAgent-owned
    /// scheduled occurrence. A live adapter session alone does NOT count — a
    /// recovered session for an already-finished turn is exactly the case that must
    /// resolve to "nothing to stop" instead of a permanent Stopping… latch.
    private func hasStoppableRun(threadId: AgentThreadID) -> Bool {
        if isScheduledThreadRunning?(threadId) == true { return true }
        // S5: surface preparation is stoppable before a run id is tracked.
        if preparingRunThreads.contains(threadId) { return true }
        if coordinator.isPreparingProviderStart(threadId: threadId) { return true }
        if coordinator.activeRunId(threadId: threadId) != nil { return true }
        if coordinator.hasPendingProviderStart(threadId: threadId) { return true }
        // A failed durable read must not be reported as "idle": attempting a real
        // stop is always safer than clearing a projection that may be backing a
        // live run, so a throwing read counts as stoppable.
        do {
            if try coordinator.hasDurableActiveRun(threadId: threadId) { return true }
        } catch {
            return true
        }
        return false
    }

    /// Drop every run projection this surface holds for `threadId` and repaint the
    /// thread from its durable status. Used when Stop finds no live run.
    ///
    /// `durableStatus` is the status a caller already read (the coordinator's F19
    /// guard hands its probe back); nil re-probes here, so a throwing read keeps
    /// today's behavior of leaving the painted status alone.
    private func clearStaleRunProjection(threadId: AgentThreadID, durableStatus: AgentRunStatus? = nil) {
        for (runId, mapped) in runThreads where mapped == threadId {
            runThreads[runId] = nil
            terminalRunIds = Self.boundedTerminalRunIds(existing: terminalRunIds, adding: runId)
        }
        if selectedThreadId == threadId {
            currentRunId = nil
            runStartedAt = nil
            isStopping = false
            if let durableStatus {
                status = durableStatus
            } else if let probedStatus = try? threadRepo.status(of: threadId) {
                status = probedStatus
            }
            clearActivePlanFollowUpSuppressionIfSafe()
        }
        stopScheduledLivePoll()
        scheduleReloadThreads()
        onRunStateChange?()
    }

    /// Stop a specific thread by id, regardless of which thread is currently selected.
    /// Allows the thread rail to stop any running thread without switching selection.
    public func stopThread(_ id: AgentThreadID) {
        if preparingRunThreads.contains(id) {
            cancelSurfacePreparation(threadId: id)
            let coordinatorOwns = coordinator.hasPendingProviderStart(threadId: id)
                || coordinator.isPreparingProviderStart(threadId: id)
                || coordinator.activeRunId(threadId: id) != nil
            if !coordinatorOwns {
                return
            }
        }
        if isScheduledThreadRunning?(id) == true, let stopScheduledThread {
            Task { @MainActor in
                _ = await stopScheduledThread(id, trackedRunId(for: id))
            }
            return
        }
        coordinator.stopRun(threadId: id)
    }

    // PERF-MAC_AGENT-006: last assistant text this VM persisted per thread, to
    // skip the O(history) reload when re-deduping the same completed answer.
    private var lastPersistedAssistantContentByThread: [AgentThreadID: String] = [:]

    // PERF-MAC_AGENT-012: ID of the last final message this surface appended per
    // thread. Non-nil = this session already wrote a final to DB; a subsequent
    // completion with new text can skip the O(history) messageRepo.list and just
    // append. Nil = first completion in this session → reload once to guard
    // against a prior session having written the same final already.
    private var lastPersistedFinalIdByThread: [AgentThreadID: AgentMessageID] = [:]

    // Pure decision seam: returns true when a full DB reload is needed before
    // deciding whether to append. False = session ID-memo proves last persist is
    // known; the incoming text differs (content memo already ruled out identity),
    // so a direct append is safe without consulting the full message list.
    //
    // nonisolated + static: callable from tests without a surface instance and
    // without main-actor hops.
    nonisolated static func shouldReloadForFinal(
        lastPersistedId: AgentMessageID?,
        lastPersistedKey: String?,
        incomingKey: String
    ) -> Bool {
        // Content equality is checked by the caller before reaching this point;
        // if we are here incomingKey != lastPersistedKey (new text).
        // If we have persisted before (id != nil) we already know DB state for
        // this thread from this session: the last final's id is recorded and its
        // content was different from incomingKey. A new final can be safely
        // appended. Reload only when id is nil (no session history — must check
        // DB for a pre-existing row written by a prior session/path).
        return lastPersistedId == nil
    }

    enum PersistFinalAssistantOffMainResult: Sendable {
        case alreadyPresent
        case appended(AgentMessageID)
    }

    /// `listRecent` + `append` for a finished turn. Same detached hop as
    /// `loadMessagePagePayloadOffMain`; caller applies session memos on MainActor.
    nonisolated static func persistFinalAssistantPayloadOffMain(
        repository: AgentMessageRepository,
        threadId: AgentThreadID,
        text: String,
        shouldReload: Bool
    ) async -> PersistFinalAssistantOffMainResult {
        await Task.detached(priority: .userInitiated) {
            if shouldReload {
                // Only scan the retained window for duplicate finals.
                let existing = (try? repository.listRecent(
                    threadId: threadId,
                    limit: AgentMessageRepository.maxMessagesPerThread
                )) ?? []
                if existing.contains(where: { $0.role == .assistant && $0.content == text }) {
                    return PersistFinalAssistantOffMainResult.alreadyPresent
                }
            }
            let msg = AgentMessage(threadId: threadId, role: .assistant, content: text)
            try? repository.append(msg)
            return .appended(msg.id)
        }.value
    }

    private func persistFinalAssistantIfMissing(_ text: String, threadId: AgentThreadID) async {
        let text = AssistantTimelineState.cappedText(text)
        // Fast path: same text already persisted this session — nothing to do.
        if lastPersistedAssistantContentByThread[threadId] == text { return }
        // PERF-MAC_AGENT-012: if we have a session ID for this thread the DB
        // state is known — skip O(history) list and append directly.
        // Reload only on first completion in a session (id == nil) to guard
        // against a prior session/path having already written this exact text.
        let shouldReload = Self.shouldReloadForFinal(
            lastPersistedId: lastPersistedFinalIdByThread[threadId],
            lastPersistedKey: lastPersistedAssistantContentByThread[threadId],
            incomingKey: text
        )
        // Claim before the SQLite hop so a concurrent same-text finish cannot
        // start a second list+append. Matches the original MainActor exclusion.
        lastPersistedAssistantContentByThread[threadId] = text
        let repository = messageRepo
        let outcome = await Self.persistFinalAssistantPayloadOffMain(
            repository: repository,
            threadId: threadId,
            text: text,
            shouldReload: shouldReload
        )
        if case .appended(let id) = outcome {
            lastPersistedFinalIdByThread[threadId] = id
        }
    }

    // MARK: AgentRunObserver

    /// Whether a stream event tagged with `run` may (re)latch the Working /
    /// running projection for `threadId`.
    ///
    /// WHY: `terminalRunIds` is in-memory only, so it is empty in a freshly
    /// launched process. A recovered provider session re-announces itself on
    /// reconnect (codex re-emits `mcpServer/startupStatus` plus the `itemStarted`
    /// it was interrupted on) and those events carry the PREVIOUS, already
    /// finished runId. That used to flip the surface back to "Working for Ns" for
    /// a run that ended hours earlier — a latch the user could never clear: Stop
    /// had no live run to interrupt, so the first click only latched "Stopping…"
    /// and the second reported a stop timeout while the spinner kept ticking.
    /// Require live coordinator ownership or a durable pending/running row before
    /// a stream event may claim the run is active. Timeline paint is unaffected;
    /// only the run-active latch is gated.
    private func streamEventMayMarkRunActive(_ run: AgentRunID, threadId: AgentThreadID) -> Bool {
        if terminalRunIds.contains(run) { return false }
        if coordinator.activeRunId(threadId: threadId) == run { return true }
        // Events can precede handle registration: startRun commits the run row as
        // `.pending` before the provider emits, so the durable row is the proof
        // that this run is the thread's current turn.
        if let durable = try? coordinator.durableActiveRunChrome(threadId: threadId), durable.id == run {
            return true
        }
        // Deliberately NOT memoized into `terminalRunIds`: a run row written by
        // another process (scheduled occurrence) can be invisible to this read for
        // a moment, and a permanent blacklist would then hide a genuinely live run
        // forever. The durable read only happens for runs this process does not
        // own, so a hot streaming run still short-circuits on the check above.
        return false
    }

    // PERF-MAC_AGENT-010: accumulate streaming events, reduce each quantum off
    // MainActor (pure timeline.apply), then commit with a single MainActor hop.
    // A fast token stream emits thousands of events/sec; the old code allocated
    // one Task per event and applied on MainActor. Order is preserved by a
    // serial in-flight latch + generation token.
    private func flushStreamEvents() {
        guard !isDisposed else {
            _ = streamEventBatch.drain()
            streamApplyInFlight = false
            streamFlushNeeded = false
            return
        }
        if streamApplyInFlight {
            streamFlushNeeded = true
            return
        }
        if hiddenTimelineArchive != nil {
            // Reducing onto the empty stand-in would replace the archived tree.
            // Events stay batched; the off-main restore flushes them.
            coldRestoreFlushPending = true
            restoreColdTimelineOffMain()
            return
        }
        let quantum = streamEventBatch.drainQuantum()
        let pending = quantum.entries
        if pending.isEmpty {
            streamFlushNeeded = false
            if streamUIBackpressured, let tid = selectedThreadId {
                rehydrateTimelineAfterStreamBackpressure(threadId: tid)
            }
            return
        }

        // Capture MainActor-only gates once; pure reduce never touches SQLite.
        let selected = selectedThreadId
        var allowedActiveRuns = Set<AgentRunID>()
        for (_, run, threadId) in pending where threadId == selected {
            if streamEventMayMarkRunActive(run, threadId: threadId) {
                allowedActiveRuns.insert(run)
            }
        }
        let input = StreamQuantumReduceInput(
            selectedThreadId: selected,
            timeline: latestHiddenTimeline ?? timeline,
            suppressStaleActivePlanUpdates: suppressStaleActivePlanUpdates,
            newestUserMessageAt: messages.last(where: { $0.role == .user })?.createdAt,
            runStartedAt: runStartedAt,
            hasQueuedFollowUp: hasQueuedFollowUpOnSelectedThread(),
            currentRunId: currentRunId,
            status: status,
            lastErrorRecoverable: lastErrorRecoverable,
            liveBackgroundShellCount: liveBackgroundShellCount,
            liveBackgroundTasks: liveBackgroundTasks,
            runsAllowedToMarkActive: allowedActiveRuns,
            entries: pending.map { StreamQuantumEntry(event: $0.0, run: $0.1, threadId: $0.2) }
        )
        let generation = streamApplyGeneration
        let hasMore = quantum.hasMore
        streamApplyInFlight = true

        // XCTest: same-stack reduce so a single Task.yield settles the batch
        // (matches rail reloadImmediate). Production: pure apply off MainActor.
        if Self.isRunningUnitTests {
            let reduced = Self.reduceStreamQuantum(input)
            finishStreamQuantumApply(
                reduced: reduced,
                generation: generation,
                hasMore: hasMore
            )
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let reduced = AgentAppViewModel.reduceStreamQuantum(input)
            await MainActor.run { [weak self] in
                self?.finishStreamQuantumApply(
                    reduced: reduced,
                    generation: generation,
                    hasMore: hasMore
                )
            }
        }
    }

    private func finishStreamQuantumApply(
        reduced: StreamQuantumReduceResult,
        generation: UInt64,
        hasMore: Bool
    ) {
        streamApplyInFlight = false
        guard !isDisposed, streamApplyGeneration == generation else {
            streamFlushNeeded = false
            // The quantum was reduced from a pre-open timeline and dropped by a
            // generation bump; its events are durable and the thread-open apply
            // re-reads them (perf AA-02).
            streamQuantumDrops &+= 1
            return
        }
        commitStreamQuantum(reduced)
        streamQuantumCommits &+= 1
        let needsAnother = hasMore
            || streamFlushNeeded
            || !streamEventBatch.isEmpty
        streamFlushNeeded = false
        if needsAnother {
            // Small gap so input/scroll can interleave between paint quanta.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(4))
                self?.flushStreamEvents()
            }
        } else if streamUIBackpressured, let tid = selectedThreadId {
            rehydrateTimelineAfterStreamBackpressure(threadId: tid)
        }
    }

    /// Force rule for the aggregate hot-text budget walk: a quantum of 64 KiB or
    /// more, or any structural (non delta/progress/state/tokenUsage) event.
    public nonisolated static func forcesAggregateBudget(events: [AssistantEvent], quantumBytes: Int? = nil) -> Bool {
        let bytes = quantumBytes ?? events.reduce(0) { $0 + max(1, $1.estimatedHotQueueBytes) }
        return bytes >= 64 * 1024
            || events.contains { event in
                switch event {
                case .itemDelta: return false
                case .itemProgress, .itemState, .tokenUsage: return false
                default: return true
                }
            }
    }

    /// Pure stream quantum reduce (off-MainActor). Durable run gates are pre-resolved
    /// into `runsAllowedToMarkActive` so this never touches SQLite or the coordinator.
    nonisolated static func reduceStreamQuantum(_ input: StreamQuantumReduceInput) -> StreamQuantumReduceResult {
        var nextTimeline = input.timeline
        var nextCurrentRunId = input.currentRunId
        var nextStatus = input.status
        var nextLastErrorRecoverable = input.lastErrorRecoverable
        var nextBackgroundShellCount = input.liveBackgroundShellCount
        var nextBackgroundTasks = input.liveBackgroundTasks
        var suppress = input.suppressStaleActivePlanUpdates
        var appliedEvent = false
        var seedRunStartedAt = false
        var runThreadBindings: [AgentRunID: AgentThreadID] = [:]
        var hasProposedPlan = false
        var appliedEvents: [AssistantEvent] = []
        var holderRunId = input.currentRunId
        appliedEvents.reserveCapacity(input.entries.count)

        for entry in input.entries {
            guard entry.threadId == input.selectedThreadId else { continue }
            if suppress, case .activePlanUpdated(let plan) = entry.event {
                if AgentAppView.shouldAcceptActivePlanForFollowUp(
                    plan: plan,
                    newestUserMessageAt: input.newestUserMessageAt,
                    runStartedAt: input.runStartedAt,
                    hasQueuedFollowUp: input.hasQueuedFollowUp
                ) {
                    suppress = false
                } else {
                    continue
                }
            }
            appliedEvent = true
            appliedEvents.append(entry.event)
            if case .turnStarted = entry.event, holderRunId != entry.run {
                // A new run owns a fresh pending-task set. Do this before any
                // snapshot from that run can repopulate the holder projection.
                nextBackgroundShellCount = 0
                nextBackgroundTasks = []
                holderRunId = entry.run
            }
            if entry.run == holderRunId,
               let tasks = backgroundTasks(fromRuntimeEvent: entry.event) {
                nextBackgroundTasks = tasks
                nextBackgroundShellCount = tasks.count
            }
            if input.runsAllowedToMarkActive.contains(entry.run) {
                nextCurrentRunId = entry.run
                runThreadBindings[entry.run] = entry.threadId
                if nextStatus != .running { nextStatus = .running }
                if input.runStartedAt == nil {
                    seedRunStartedAt = true
                }
            }
            nextTimeline.apply(entry.event)
            if case let .error(_, recoverable) = entry.event {
                nextLastErrorRecoverable = recoverable
            }
            if case .proposedPlan = entry.event {
                hasProposedPlan = true
            }
        }
        // Budget walk is O(items). Pure reduce only flags when this quantum is
        // large or structural; commitStreamQuantum coalesces cheap token quanta.
        let quantumBytes = input.entries.reduce(0) { $0 + max(1, $1.event.estimatedHotQueueBytes) }
        let forceBudget = forcesAggregateBudget(events: appliedEvents, quantumBytes: quantumBytes)
        if shouldAutoClearTransientTimelineError(
            errorAfterBatch: nextTimeline.error,
            appliedEvents: appliedEvents
        ) {
            nextTimeline.clearError()
            nextLastErrorRecoverable = false
        }
        return StreamQuantumReduceResult(
            appliedEvent: appliedEvent,
            timeline: nextTimeline,
            currentRunId: nextCurrentRunId,
            status: nextStatus,
            lastErrorRecoverable: nextLastErrorRecoverable,
            liveBackgroundShellCount: nextBackgroundShellCount,
            liveBackgroundTasks: nextBackgroundTasks,
            suppressStaleActivePlanUpdates: suppress,
            seedRunStartedAt: seedRunStartedAt,
            runThreadBindings: runThreadBindings,
            hasProposedPlan: hasProposedPlan,
            forceAggregateBudget: forceBudget,
            appliedEventCount: appliedEvents.count
        )
    }

    /// How many applied stream events may pass before a coalesced aggregate
    /// hot-text budget walk is forced anyway.
    ///
    /// Bounded overshoot — the binding constraint is the `quantumBytes >= 64 KiB`
    /// gate in `reduceStreamQuantum`, NOT the per-item caps. Any quantum at or
    /// over 64 KiB forces the walk in the same commit, and every quantum that
    /// skips still adds at least 1 to the counter, so at most `threshold - 1`
    /// quanta of `< 64 KiB` each can accumulate: under 1 MiB against the 96 MiB
    /// `AssistantTimelineState.aggregateHotTextByteLimit`. Changing either this
    /// threshold or that 64 KiB gate changes the bound; the per-item
    /// `liveTextLimit` / `liveOutputLimit` caps are a second, independent bound
    /// and must not be mistaken for this one.
    public static let streamAggregateBudgetThreshold = 16

    /// Coalescing decision for the O(items) aggregate hot-text budget walk.
    ///
    /// Extracted from `commitStreamQuantum` so the skip window is directly
    /// testable: the walk itself is cheap per item but ran on every token quantum.
    public static func aggregateBudgetDecision(
        force: Bool,
        opsSinceLastWalk: Int,
        appliedEventCount: Int,
        threshold: Int = streamAggregateBudgetThreshold
    ) -> (runsWalk: Bool, nextOps: Int) {
        let ops = opsSinceLastWalk + max(1, appliedEventCount)
        if force || ops >= max(1, threshold) { return (true, 0) }
        return (false, ops)
    }

    #if DEBUG
    /// Test-only override for the aggregate hot-text ceiling.
    ///
    /// Proving the aggregate budget walk needs a real eviction, and allocating
    /// 96 MiB in a unit test is not viable — so tests lower the ceiling
    /// instead. DEBUG-only so release builds keep the constant.
    var aggregateHotTextByteLimitForTesting: Int?
    #endif

    /// The ceiling `commitStreamQuantum` actually enforces.
    ///
    /// Resolved here rather than with a `#if DEBUG` fork at the call site, so the
    /// statement that ships is the same statement tests execute. A fork there
    /// would leave release relying on `enforceAggregateHotTextBudget`'s default
    /// argument while DEBUG passed one explicitly — and a future change to that
    /// default would silently diverge the two with no test failing.
    var activeAggregateHotTextByteLimit: Int {
        #if DEBUG
        return aggregateHotTextByteLimitForTesting ?? AssistantTimelineState.aggregateHotTextByteLimit
        #else
        return AssistantTimelineState.aggregateHotTextByteLimit
        #endif
    }

    /// Counter behind `streamAggregateBudgetThreshold`. Not `private` so a test
    /// can assert it actually resets when the walk runs — a regression that drops
    /// the reset would otherwise leave the pure-function tests green.
    var streamAggregateBudgetOpsForTesting: Int { streamAggregateBudgetOps }

    func commitStreamQuantum(_ reduced: StreamQuantumReduceResult) {
        guard reduced.appliedEvent else { return }
        suppressStaleActivePlanUpdates = reduced.suppressStaleActivePlanUpdates
        for (run, threadId) in reduced.runThreadBindings {
            runThreads[run] = threadId
        }
        if reduced.seedRunStartedAt, runStartedAt == nil {
            runStartedAt = Date()
        }
        if currentRunId != reduced.currentRunId { currentRunId = reduced.currentRunId }
        if status != reduced.status { status = reduced.status }
        if lastErrorRecoverable != reduced.lastErrorRecoverable {
            lastErrorRecoverable = reduced.lastErrorRecoverable
        }
        if liveBackgroundShellCount != reduced.liveBackgroundShellCount {
            liveBackgroundShellCount = reduced.liveBackgroundShellCount
        }
        if liveBackgroundTasks != reduced.liveBackgroundTasks {
            liveBackgroundTasks = reduced.liveBackgroundTasks
        }
        let budget = Self.aggregateBudgetDecision(
            force: reduced.forceAggregateBudget,
            opsSinceLastWalk: streamAggregateBudgetOps,
            appliedEventCount: reduced.appliedEventCount
        )
        streamAggregateBudgetOps = budget.nextOps
        if surfaceVisibility == .hidden {
            var hidden = reduced.timeline
            if budget.runsWalk {
                hidden.enforceAggregateHotTextBudget(byteLimit: activeAggregateHotTextByteLimit)
                aggregateHotTextBudgetGeneration &+= 1
            }
            latestHiddenTimeline = hidden
            let now = nowForTesting()
            let due = lastHiddenTimelinePublishAt.map {
                now.timeIntervalSince($0) >= hiddenTimelinePublishIntervalForTesting
            } ?? true
            if due {
                lastHiddenTimelinePublishAt = now
                hiddenTimelinePublishCountForTesting += 1
            }
            scheduleTimelineUpdateTick()
            if reduced.hasProposedPlan {
                scheduleFullAccessPlanAutoImplementIfNeeded()
            }
            return
        }
        timeline = reduced.timeline
        if budget.runsWalk {
            timeline.enforceAggregateHotTextBudget(byteLimit: activeAggregateHotTextByteLimit, protectedTurnIDs: protectedTranscriptTurnIDs)
            aggregateHotTextBudgetGeneration &+= 1
        }
        scheduleTimelineUpdateTick()
        if reduced.hasProposedPlan {
            scheduleFullAccessPlanAutoImplementIfNeeded()
        }
    }

    /// Count of CLI-owned background shells / async subagents carried by a
    /// `claude.session.snapshot` runtime event, or nil when `event` is not such a
    /// snapshot (or predates the field — e.g. the SDK-bridge route, which does not
    /// report background tasks). Returning nil rather than 0 is deliberate: an
    /// unrelated event must not clear a live count. Pure, for unit testing.
    nonisolated static func backgroundShellCount(fromRuntimeEvent event: AssistantEvent) -> Int? {
        backgroundTasks(fromRuntimeEvent: event)?.count
    }

    /// CLI background task ids from the adapter's `claude.session.snapshot`.
    /// Timeline task rows carry the human type/description and are joined by
    /// exact task id in `enrichingBackgroundTasks`. nil when the event is not
    /// a snapshot that carries the producer's id field.
    nonisolated static func backgroundTasks(fromRuntimeEvent event: AssistantEvent) -> [AgentBackgroundTask]? {
        guard case .providerRuntime(let runtime) = event,
              runtime.provider == .claude,
              runtime.method == "claude.session.snapshot",
              let data = runtime.payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let ids = payload["pendingBackgroundTaskIds"] as? [String] else { return nil }
        return AgentBackgroundTask.placeholders(fromIds: ids)
    }

    /// Apply one event that the hot queue refused, without growing the queue.
    /// Timeline caps keep the paint bounded; used for the first saturation of an
    /// episode so a single huge tool payload still appears live.
    private func applyRefusedStreamEventDirectly(
        _ event: AssistantEvent,
        run: AgentRunID,
        threadId: AgentThreadID
    ) {
        guard threadId == selectedThreadId else { return }
        if suppressStaleActivePlanUpdates, case .activePlanUpdated(let plan) = event {
            let newestUserAt = messages.last(where: { $0.role == .user })?.createdAt
            if AgentAppView.shouldAcceptActivePlanForFollowUp(
                plan: plan,
                newestUserMessageAt: newestUserAt,
                runStartedAt: runStartedAt,
                hasQueuedFollowUp: hasQueuedFollowUpOnSelectedThread()
            ) {
                suppressStaleActivePlanUpdates = false
            } else {
                return
            }
        }
        if streamEventMayMarkRunActive(run, threadId: threadId) {
            currentRunId = run
            runThreads[run] = threadId
            if status != .running { status = .running }
        }
        timeline.apply(event)
        timeline.enforceAggregateHotTextBudget(protectedTurnIDs: protectedTranscriptTurnIDs)
        if case let .error(_, recoverable) = event {
            lastErrorRecoverable = recoverable
        }
        scheduleTimelineUpdateTick()
        if case .proposedPlan = event {
            scheduleFullAccessPlanAutoImplementIfNeeded()
        }
    }

    /// True when the selected thread still has a follow-up that has not become a
    /// transcript bubble yet. Plan events during this window belong to the prior
    /// still-running turn and must not lift follow-up plan suppress.
    private func hasQueuedFollowUpOnSelectedThread() -> Bool {
        guard let selectedThreadId else { return false }
        return queuedMessages.contains { $0.threadId == selectedThreadId }
    }

    /// Lift follow-up plan suppress only when no queued successor is waiting.
    /// Clearing on predecessor terminal while a queue row exists would re-paint
    /// the prior checklist before drain starts the new turn.
    private func clearActivePlanFollowUpSuppressionIfSafe() {
        guard !hasQueuedFollowUpOnSelectedThread() else { return }
        suppressStaleActivePlanUpdates = false
    }

    /// Rebuild the live timeline from the durable hot-replay window after the UI
    /// queue refused events. Idempotent: clears the backpressure flag so a quiet
    /// stream does not keep replaying.
    private func rehydrateTimelineAfterStreamBackpressure(threadId: AgentThreadID) {
        guard streamUIBackpressured, selectedThreadId == threadId else { return }
        streamUIBackpressured = false
        let events = coordinator.latestStreamEvents(threadId: threadId)
        var rebuilt = AssistantTimelineState()
        let newestUserAt = messages.last(where: { $0.role == .user })?.createdAt
        for event in events {
            if suppressStaleActivePlanUpdates, case .activePlanUpdated(let plan) = event {
                if AgentAppView.shouldAcceptActivePlanForFollowUp(
                    plan: plan,
                    newestUserMessageAt: newestUserAt,
                    runStartedAt: runStartedAt,
                    hasQueuedFollowUp: hasQueuedFollowUpOnSelectedThread()
                ) {
                    suppressStaleActivePlanUpdates = false
                } else {
                    continue
                }
            }
            rebuilt.apply(event)
        }
        let protectedIDs = protectedTranscriptTurnIDs
        rebuilt.retainMissingTurns(from: timeline, protectedTurnIDs: protectedIDs)
        rebuilt.enforceAggregateHotTextBudget(protectedTurnIDs: protectedIDs)
        timeline = rebuilt
        rehydrateDurableActiveState(threadId: threadId)
        lastErrorRecoverable = Self.displayedErrorIsRecoverable(in: events)
        scheduleTimelineUpdateTick()
    }

    /// True for local durability noise that is not a provider-run failure.
    /// These banners should auto-dismiss when the thread keeps making progress.
    nonisolated static func isTransientPersistenceTimelineError(_ message: String) -> Bool {
        let n = message.lowercased()
        return n.contains("persistence failure")
            || n.contains("database is locked")
            || n.contains("sqlite step: database is locked")
    }

    /// After a stream batch: drop a transient persistence banner when any
    /// non-error event shows the run continued past the lock/outage.
    nonisolated static func shouldAutoClearTransientTimelineError(
        errorAfterBatch: String?,
        appliedEvents: [AssistantEvent]
    ) -> Bool {
        guard let errorAfterBatch, isTransientPersistenceTimelineError(errorAfterBatch) else {
            return false
        }
        return appliedEvents.contains { event in
            if case .error = event { return false }
            return true
        }
    }

    /// Pure multi-tab stream gate: only the surface whose selected thread matches
    /// the event should buffer/flush. `nil` interest means no selected thread
    /// (fresh composer) — drop all stream events.
    nonisolated static func acceptsStreamEvent(
        eventThreadId: AgentThreadID,
        interestedThreadId: AgentThreadID?
    ) -> Bool {
        eventThreadId == interestedThreadId
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {
        // Multi-tab freeze guard: every open Agent App observes the coordinator.
        // Drop stream events for other threads before buffering/scheduling so N
        // idle tabs do not pay MainActor work for one streaming tab.
        guard Self.acceptsStreamEvent(
            eventThreadId: threadId,
            interestedThreadId: currentInterestedThreadId()
        ) else { return }
        // PERF-MAC_AGENT-010: append to the batch buffer. If the buffer was
        // empty (first event of this tick), schedule a single flush Task.
        // Later events in the same tick just append — no extra Task allocation.
        if case .providerRuntime(let runtime) = event,
           runtime.provider == .distill,
           DistillLiveStatus.isCarrierMethod(runtime.method) {
            Task { @MainActor in
                self.applyDistillRuntime(runtime, run: run, threadId: threadId)
            }
        } else if case .providerRuntime(let runtime) = event,
                  runtime.provider == .distill,
                  runtime.method == "available_commands_update" {
            Task { @MainActor in
                self.applyDistillAdvertisedCommands(runtime)
            }
        }
        let outcome = streamEventBatch.appendBounded(event: event, run: run, threadId: threadId)
        switch outcome {
        case .scheduled, .scheduledAfterEviction:
            Task { @MainActor in
                self.flushStreamEvents()
            }
            if outcome == .scheduledAfterEviction {
                Task { @MainActor in
                    guard !self.isDisposed, self.selectedThreadId == threadId else { return }
                    // Oldest UI paints were dropped under budget; durable history
                    // still has them — rehydrate when the queue drains / run ends.
                    self.streamUIBackpressured = true
                }
            }
        case .bufferedAfterEviction:
            Task { @MainActor in
                guard !self.isDisposed, self.selectedThreadId == threadId else { return }
                self.streamUIBackpressured = true
            }
        case .buffered:
            break
        case .saturated:
            // Single frame larger than the entire hot queue. Provider keeps
            // running; apply directly (timeline caps) and rehydrate later.
            let refused = event
            Task { @MainActor in
                guard !self.isDisposed, self.selectedThreadId == threadId else { return }
                self.streamUIBackpressured = true
                self.applyRefusedStreamEventDirectly(refused, run: run, threadId: threadId)
            }
        case .saturationAlreadyReported:
            Task { @MainActor in
                guard !self.isDisposed, self.selectedThreadId == threadId else { return }
                self.streamUIBackpressured = true
            }
        }
    }

    private func applyDistillRuntime(_ runtime: ProviderRuntimeEvent, run: AgentRunID, threadId: AgentThreadID) {
        guard !isDisposed, selectedThreadId == threadId else { return }
        if runtime.method == "_remotecode/operation",
           let active = coordinator.activeRunId(threadId: threadId), active != run { return }
        var next: DistillLiveStatus
        if distillLive?.runId == run, let current = distillLive {
            next = current
        } else {
            // Goal and loops outlive a run; compaction/subagents do not.
            next = DistillLiveStatus(runId: run)
            next.goal = distillLive?.goal
            next.scheduledTasks = distillLive?.scheduledTasks ?? []
        }
        next.apply(method: runtime.method, payloadJSON: runtime.payloadJSON)
        if next != distillLive { distillLive = next }
    }

    private func applyDistillAdvertisedCommands(_ runtime: ProviderRuntimeEvent) {
        guard !isDisposed,
              let commands = DistillLiveStatus.advertisedCommands(
                method: runtime.method,
                payloadJSON: runtime.payloadJSON
              ),
              commands != distillSlashCommands else { return }
        distillSlashCommands = commands
    }

    private func resetTimelineUpdateTick() {
        timelineUpdateTickTask?.cancel()
        timelineUpdateTickTask = nil
        timelineUpdateTick = 0
    }

    /// ~30 Hz stream paint coalesce, shared with the Bots desk.
    public static let streamPaintCoalesceInterval: Duration = .milliseconds(33)

    private func scheduleTimelineUpdateTick() {
        guard surfaceVisibility != .hidden else { return }
        timelineTickScheduleCountForTesting += 1
        guard timelineUpdateTickTask == nil else { return }
        // ~30 Hz paint coalesce (was 16 ms / 60 Hz) — fewer full transcript
        // re-evaluations while tokens stream.
        timelineUpdateTickTask = Task { @MainActor in
            try? await Task.sleep(for: Self.streamPaintCoalesceInterval)
            guard !Task.isCancelled else { return }
            self.timelineUpdateTick &+= 1
            self.timelineUpdateTickTask = nil
        }
    }

    /// Whether this Agent App surface should treat a finished run as local work
    /// that may promote the sidebar workspace MRU / refresh busy chrome.
    /// WHY: every mounted Agent App observes the coordinator. Without a workspace
    /// gate, one completed run fans out `onRunCompleted` to every surface and each
    /// re-stamps a different workspace's `lastActivityAt`, so the workspace that
    /// just finished is no longer first in the MRU list.
    nonisolated public static func shouldHandleRunFinishForWorkspace(
        threadWorkspace: WorkspaceID?,
        surfaceWorkspace: WorkspaceID
    ) -> Bool {
        threadWorkspace == surfaceWorkspace
    }

    /// Sidebar promote / busy refresh belongs only to the workspace that owned
    /// the finished run — not to every open Agent App tab in other workspaces.
    nonisolated public static func shouldNotifyHostOfRunLifecycle(
        threadWorkspace: WorkspaceID?,
        surfaceWorkspace: WorkspaceID,
        status: AgentRunStatus,
        notifyOnCompletedOnly: Bool
    ) -> Bool {
        guard shouldHandleRunFinishForWorkspace(
            threadWorkspace: threadWorkspace,
            surfaceWorkspace: surfaceWorkspace
        ) else { return false }
        if notifyOnCompletedOnly { return status == .completed }
        return true
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
        streamEventBatch.resetSaturation(for: runId)
        Task { @MainActor in
            guard !self.isDisposed else { return }
            let finishedTid = threadId
            // Same workspace filter as didChangeStatus: multi-tab Agent Apps must
            // not pay MainActor work or promote unrelated workspaces on finish.
            let threadWorkspace = self.resolvedWorkspaceID(for: finishedTid)
            guard Self.shouldHandleRunFinishForWorkspace(
                threadWorkspace: threadWorkspace,
                surfaceWorkspace: self.workspaceID
            ) else { return }

            self.terminalRunIds = Self.boundedTerminalRunIds(existing: self.terminalRunIds, adding: runId)
            self.runThreads[runId] = nil
            if status == .completed, let msg = finalMessage, !msg.isEmpty {
                // The coordinator is normally the persistence owner, but
                // live provider completions can arrive after stream drain on
                // a background handler. Keep the restart contract here too.
                await self.persistFinalAssistantIfMissing(msg, threadId: finishedTid)
                if finishedTid == self.selectedThreadId {
                    self.loadAllMessages(finishedTid)
                    self.suppressPersistedFinalDuplicatedByTimeline()
                    self.timeline.clearActivePlan()
                    self.scheduleTimelineUpdateTick()
                }
            }
            if finishedTid == self.selectedThreadId {
                if self.streamUIBackpressured {
                    self.rehydrateTimelineAfterStreamBackpressure(threadId: finishedTid)
                }
                if status == .completed || status == .cancelled {
                    // A finished turn that progressed past a durability blip must
                    // not leave "database is locked" stuck under the composer.
                    if let err = self.timeline.error,
                       Self.isTransientPersistenceTimelineError(err) {
                        self.timeline.clearError()
                        self.lastErrorRecoverable = false
                        self.scheduleTimelineUpdateTick()
                    }
                }
                if status == .failed,
                   self.timeline.error == nil,
                   let finalMessage,
                   !finalMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let recoverable = Self.errorRecoveryAction(
                        provider: self.provider,
                        message: finalMessage,
                        recoverable: false
                    ) == .retry
                    self.timeline.apply(.error(message: finalMessage, recoverable: recoverable))
                    self.lastErrorRecoverable = recoverable
                    self.scheduleTimelineUpdateTick()
                }
                self.status = status
                self.currentRunId = nil
                self.runStartedAt = nil
                // UX-MAC_AGENT-PLAN-FRESH: end-of-run lifts follow-up plan suppress so a
                // later turn (or durable rehydrate) is not permanently latched off when
                // the provider never emitted a fresh plan this run. Paint gate still
                // hides stale/all-done checklists independently. Keep suppress if a
                // queued successor is waiting (prior plan must not reappear mid-queue).
                self.clearActivePlanFollowUpSuppressionIfSafe()
                self.isStopping = false  // UX-MAC_AGENT-STOP: run finished; clear stopping flag
                // A run that kept a hidden tab hot may compact once it is idle.
                if self.surfaceVisibility == .hidden { self.scheduleHiddenReclaim() }
            }
            // Coalesce N same-workspace Agent App tabs into one reload per surface.
            self.scheduleReloadThreads()
            self.loadGitBranchThrottled()   // the run may have changed the tree
            if Self.shouldNotifyHostOfRunLifecycle(
                threadWorkspace: threadWorkspace,
                surfaceWorkspace: self.workspaceID,
                status: status,
                notifyOnCompletedOnly: true
            ) {
                self.onRunCompleted?()
                // Plan may have landed only as the turn ended; full access must still auto-implement.
                if finishedTid == self.selectedThreadId {
                    self.scheduleFullAccessPlanAutoImplementIfNeeded()
                }
            }
            self.onRunStateChange?()
            if let embedding = self.embedding, finishedTid == embedding.pinnedThreadId {
                embedding.onRunFinished?(runId, finishedTid, status, finalMessage)
            }
        }
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {
        Task { @MainActor in
            guard !self.isDisposed else { return }
            // PERF-MAC_AGENT-009: use the cache for the workspace filter; fall back to
            // DB only on a cache miss (first event for a thread not yet loaded here).
            let threadWorkspace = self.resolvedWorkspaceID(for: threadId)
            guard threadWorkspace == self.workspaceID else { return }
            // X-02: status-only events must not re-list the rail (ISO parse × N).
            // Patch the in-memory row; create/delete/rename still call reloadThreads.
            self.applyInMemoryThreadStatus(threadId, status: status)
            if threadId == self.selectedThreadId {
                if status == .running {
                    self.status = status
                    self.terminalRunIds.remove(runId)
                    self.currentRunId = runId
                    self.runStartedAt = AgentAppViewModel.resolvedRunStartedAt(
                        current: self.runStartedAt,
                        persisted: (try? self.coordinator.runStartedAt(threadId: threadId)) ?? (try? self.coordinator.runStartedAt(runId: runId))
                    )
                    self.isStopping = false  // UX-MAC_AGENT-STOP: new run started; clear any stale stopping flag
                    // Host-started runs (queue drain, Force, mirror send) persist
                    // their user row before going live; show it now, not at run end.
                    if !self.messages.contains(where: { $0.id == AgentMessageID(runId.value) }) {
                        self.loadAllMessages(threadId)
                    }
                } else if Self.isTerminalRunStatus(status) {
                    // Always record the terminal runId so late stream events cannot
                    // re-inflate runThreads / Working after cancel/complete (ghost
                    // "Threads · N active"). Full selected-thread idle paint still
                    // waits until the coordinator releases active ownership.
                    self.terminalRunIds = Self.boundedTerminalRunIds(existing: self.terminalRunIds, adding: runId)
                    self.runThreads[runId] = nil
                    if !self.coordinator.activeThreadIdsSnapshot().contains(threadId) {
                        self.status = status
                        self.currentRunId = nil
                        self.runStartedAt = nil
                        self.clearActivePlanFollowUpSuppressionIfSafe()
                        self.isStopping = false  // UX-MAC_AGENT-STOP: terminal; clear stopping flag
                    } else {
                        // Ownership still held: nudge durable reconcile so a
                        // finishedAt row cannot leave activeThreads ghosted.
                        _ = self.coordinator.reconcileStaleActiveOwnershipWithDurableState()
                        if !self.coordinator.activeThreadIdsSnapshot().contains(threadId) {
                            self.status = status
                            self.currentRunId = nil
                            self.runStartedAt = nil
                            self.clearActivePlanFollowUpSuppressionIfSafe()
                            self.isStopping = false
                        }
                    }
                } else {
                    self.status = status
                }
            } else if Self.isTerminalRunStatus(status) {
                // Non-selected threads: still clear the rail projection so the
                // active count and spinner drop when this run ends.
                self.terminalRunIds = Self.boundedTerminalRunIds(existing: self.terminalRunIds, adding: runId)
                self.runThreads[runId] = nil
                _ = self.coordinator.reconcileStaleActiveOwnershipWithDurableState()
            }
            // Admission receipts finalize on terminal status. One shared,
            // off-main read updates every selected surface for this workspace.
            AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedSubagentActivityRefresh(
                workspaceID: self.workspaceID
            )
            self.onRunStateChange?()
        }
    }

    private static func isTerminalRunStatus(_ status: AgentRunStatus) -> Bool {
        switch status {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        case .pending, .running:
            return false
        }
    }

    // MARK: - Continue (relaunch-interrupted thread) seam

    /// Pure, testable function that decides whether to show the inline Continue
    /// action. True only when the selected thread has a recoverable provider
    /// session AND no run is currently active.
    /// WHY: a relaunch-interrupted thread should be one-click resumable, not a
    /// dead end requiring the user to re-type their last prompt.
    nonisolated public static func showsContinueAction(hasRecoverableContext: Bool, runActive: Bool) -> Bool {
        hasRecoverableContext && !runActive
    }

    /// Recoverability belongs to the currently displayed error. Timeline replay
    /// retains the last error banner, so relaunch/thread switching must restore
    /// the matching Retry affordance from the same persisted event stream.
    nonisolated public static func displayedErrorIsRecoverable(in events: [AssistantEvent]) -> Bool {
        for event in events.reversed() {
            if case .error(_, let recoverable) = event { return recoverable }
        }
        return false
    }

    /// Resume a relaunch-interrupted provider context without inventing an empty
    /// user message. The instruction is provider-only and the coordinator loads
    /// the durable cursor plus runtime configuration from the interrupted session.
    public func continueInterruptedThread() async {
        guard let continuingThreadId = selectedThreadId else { return }
        guard !coordinator.hasProviderSession(threadId: continuingThreadId) else {
            statusMessage = "The provider turn is still running."
            return
        }
        let hadRecoverableContext = selectedThreadHasRecoverableContext
        let runId = await startProviderRun(
            text: "Continue the interrupted turn from the last saved context. Do not repeat completed work.",
            attached: [],
            recordHistory: false,
            interactionMode: interactionMode,
            resumeInterrupted: true
        )
        if runId == nil,
           selectedThreadId == continuingThreadId,
           hadRecoverableContext {
            selectedThreadHasRecoverableContext = true
        }
    }

    // MARK: - Stop button state seam

    public enum StopButtonState: Equatable {
        /// Run is active, stop has not been requested yet.
        case stop
        /// Stop was requested; button is disabled while the interrupt round-trips.
        case stopping
        /// No active run; button should be hidden.
        case hidden
    }

    /// Pure, testable function that drives the Stop button label and enabled state.
    /// WHY: a Stop button with no feedback invites repeated clicks and user confusion.
    public static func stopButtonState(runActive: Bool, isStopping: Bool) -> StopButtonState {
        guard runActive else { return .hidden }
        return isStopping ? .stopping : .stop
    }

    /// Returns the authoritative run-start time.
    ///
    /// WHY: the Mac IS the host, so the persisted `AgentRun.startedAt` is the
    /// ground truth. The `current` argument (the value already held by the
    /// view model) is returned unchanged when it is already set AND no persisted
    /// value is available -- this handles the brief race between run creation
    /// and DB commit. When `persisted` is available it always wins so that
    /// "Working for Xs" counts from the true start, not from the moment the
    /// view noticed the run.
    nonisolated public static func resolvedRunStartedAt(current: Date?, persisted: Date?) -> Date {
        if let persisted { return persisted }
        return current ?? Date()
    }

    // PERF-L15: bound the terminal-run-id set so it cannot grow without limit.
    // Run IDs are fresh UUIDs; they are never re-used, so old finished IDs
    // accumulate forever. The gate at flushStreamEvents only needs recent IDs
    // (coordinator has already released any run older than cap). When the set
    // would exceed cap, drop an arbitrary existing entry (not the new one).
    // internal (not private) so the test target can call it directly.
    nonisolated internal static func boundedTerminalRunIds(
        existing: Set<AgentRunID>,
        adding newId: AgentRunID,
        cap: Int = 256
    ) -> Set<AgentRunID> {
        var updated = existing
        updated.insert(newId)
        if updated.count > cap, let oldest = updated.first(where: { $0 != newId }) {
            updated.remove(oldest)
        }
        return updated
    }
}

/// Lock-protected selected-thread mirror for multi-tab stream filtering.
/// Safe from coordinator background threads and the main actor.
final class InterestedThreadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentThreadID?

    func set(_ id: AgentThreadID?) {
        lock.lock()
        value = id
        lock.unlock()
    }

    func get() -> AgentThreadID? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// One stream event entry for pure off-MainActor quantum reduce.
struct StreamQuantumEntry: Sendable {
    let event: AssistantEvent
    let run: AgentRunID
    let threadId: AgentThreadID
}

/// MainActor-captured inputs for pure stream quantum reduce.
struct StreamQuantumReduceInput: Sendable {
    let selectedThreadId: AgentThreadID?
    let timeline: AssistantTimelineState
    let suppressStaleActivePlanUpdates: Bool
    let newestUserMessageAt: Date?
    let runStartedAt: Date?
    let hasQueuedFollowUp: Bool
    let currentRunId: AgentRunID?
    let status: AgentRunStatus
    let lastErrorRecoverable: Bool
    let liveBackgroundShellCount: Int
    let liveBackgroundTasks: [AgentBackgroundTask]
    let runsAllowedToMarkActive: Set<AgentRunID>
    let entries: [StreamQuantumEntry]
}

/// Pure reduce output committed on MainActor in one hop.
struct StreamQuantumReduceResult: Sendable {
    let appliedEvent: Bool
    let timeline: AssistantTimelineState
    let currentRunId: AgentRunID?
    let status: AgentRunStatus
    let lastErrorRecoverable: Bool
    let liveBackgroundShellCount: Int
    let liveBackgroundTasks: [AgentBackgroundTask]
    let suppressStaleActivePlanUpdates: Bool
    let seedRunStartedAt: Bool
    let runThreadBindings: [AgentRunID: AgentThreadID]
    let hasProposedPlan: Bool
    /// True when this quantum should force an aggregate hot-text budget walk.
    let forceAggregateBudget: Bool
    /// Number of events applied into the timeline this quantum.
    let appliedEventCount: Int
}

// PERF-MAC_AGENT-010: lock-protected buffer used by runCoordinator(_:didReceive:)
// to coalesce streaming events. Safe to access from both the coordinator's
// background thread (append) and the main actor (drain).
final class StreamEventBatch: @unchecked Sendable {
    struct Limits: Equatable {
        /// Hot UI queue only — durable stream history is bounded separately.
        /// Smaller quanta keep each MainActor hop short so scrolling/composer
        /// stay responsive during tool storms (rehydrate fills gaps after).
        /// Was 8_192; 4_096 still covers tool storms without multi-thread queue bloat.
        var maxBufferedCount: Int = 4_096
        /// Was 32 MiB; 2 MiB keeps each MainActor hop short under multi-thread streams.
        var maxBufferedBytes: Int = 2 * 1_024 * 1_024
        /// Token deltas are tiny and reduced off the MainActor; `drainBytes`
        /// bounds hop cost. 48 made a 2,000-delta burst paint ~42 hops (~217 ms)
        /// behind the provider and republish the transcript ~84 times.
        var drainCount: Int = 512
        var drainBytes: Int = 512 * 1_024
    }

    enum AppendOutcome: Equatable {
        case scheduled
        case buffered
        /// Newest event admitted after dropping oldest buffered UI events.
        case scheduledAfterEviction
        case bufferedAfterEviction
        /// Single frame larger than the entire hot queue — cannot retain; durable
        /// history still holds it and the surface rehydrates from there.
        case saturated
        case saturationAlreadyReported
    }

    struct DrainQuantum {
        let entries: [(event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID)]
        let encodedByteCount: Int
        let hasMore: Bool
    }

    private struct Entry {
        let event: AssistantEvent
        let run: AgentRunID
        let threadId: AgentThreadID
        let encodedByteCount: Int
    }

    /// Compact after this many consumed head slots (and when dead ≥ live).
    /// Matches WebSocketOutboundQueue: amortized O(1) drain/evict without
    /// O(n) `removeFirst` on every token during tool storms.
    private static let compactionThreshold = 1_024

    private let lock = NSLock()
    private let limits: Limits
    /// Ring-style storage: live range is `storage[headIndex...]` (non-nil).
    /// Consumed slots are nilled so large AssistantEvent payloads release early.
    private var storage: [Entry?] = []
    private var headIndex = 0
    private var bufferedBytes = 0
    private var flushScheduled = false
    private var saturationRunID: AgentRunID?

    init(limits: Limits = Limits()) {
        self.limits = Limits(
            maxBufferedCount: max(1, limits.maxBufferedCount),
            maxBufferedBytes: max(1, limits.maxBufferedBytes),
            drainCount: max(1, limits.drainCount),
            drainBytes: max(1, limits.drainBytes)
        )
    }

    private var queuedCount: Int { storage.count - headIndex }

    private func compactIfNeeded() {
        if headIndex == storage.count {
            storage.removeAll(keepingCapacity: true)
            headIndex = 0
        } else if headIndex >= Self.compactionThreshold,
                  headIndex >= storage.count - headIndex {
            storage.removeFirst(headIndex)
            headIndex = 0
        }
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return queuedCount == 0
    }

    /// Appends an event. Returns `true` iff the caller should schedule a flush Task
    /// (i.e. the buffer was empty before this append — first event of the tick).
    func append(event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) -> Bool {
        appendBounded(event: event, run: run, threadId: threadId) == .scheduled
    }

    func appendBounded(event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) -> AppendOutcome {
        // PERF: never JSON-encode on the per-token admission path — estimate only.
        let eventBytes = max(1, event.estimatedHotQueueBytes)
        let bytes = eventBytes + MemoryLayout<AgentRunID>.stride + MemoryLayout<AgentThreadID>.stride
        lock.lock()
        defer { lock.unlock() }
        if let saturationRunID, saturationRunID != run {
            self.saturationRunID = nil
        }
        // drainBytes is a *paint quantum* (how much work one MainActor hop applies),
        // not a hard admission ceiling. drainQuantum already admits a single event
        // larger than the quantum when the buffer head is oversized.
        //
        // Budget pressure: drop OLDEST buffered UI events until the newest fits.
        // Durable stream history still has the dropped paints; the surface rehydrates.
        // Only a single frame larger than the entire hot queue is refused.
        if bytes > limits.maxBufferedBytes {
            if saturationRunID == run { return .saturationAlreadyReported }
            saturationRunID = run
            return .saturated
        }
        var didEvict = false
        while queuedCount > 0
            && (queuedCount >= limits.maxBufferedCount
                || bufferedBytes + bytes > limits.maxBufferedBytes) {
            // Amortized O(1) eviction — advance head; do not shift the array.
            if let removed = storage[headIndex] {
                storage[headIndex] = nil
                bufferedBytes = max(0, bufferedBytes - removed.encodedByteCount)
                didEvict = true
            }
            headIndex += 1
            compactIfNeeded()
        }
        storage.append(Entry(event: event, run: run, threadId: threadId, encodedByteCount: bytes))
        bufferedBytes += bytes
        if didEvict {
            saturationRunID = run
            if flushScheduled { return .bufferedAfterEviction }
            flushScheduled = true
            return .scheduledAfterEviction
        }
        if flushScheduled { return .buffered }
        flushScheduled = true
        return .scheduled
    }

    func drainQuantum() -> DrainQuantum {
        lock.lock()
        defer { lock.unlock() }
        var count = 0
        var bytes = 0
        let live = queuedCount
        while count < live && count < limits.drainCount {
            guard let nextEntry = storage[headIndex + count] else { break }
            let next = nextEntry.encodedByteCount
            if count > 0 && bytes + next > limits.drainBytes { break }
            bytes += next
            count += 1
        }
        var drained: [Entry] = []
        drained.reserveCapacity(count)
        for offset in 0..<count {
            if let entry = storage[headIndex + offset] {
                drained.append(entry)
                storage[headIndex + offset] = nil
            }
        }
        headIndex += count
        bufferedBytes = max(0, bufferedBytes - bytes)
        compactIfNeeded()
        let hasMore = queuedCount > 0
        flushScheduled = hasMore
        if !hasMore { saturationRunID = nil }
        return DrainQuantum(
            entries: drained.map { ($0.event, $0.run, $0.threadId) },
            encodedByteCount: bytes,
            hasMore: hasMore
        )
    }

    /// Drains and returns all buffered entries, resetting the buffer and the
    /// scheduled flag so the next incoming event will schedule a new flush.
    func drain() -> [(event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID)] {
        lock.lock()
        defer { lock.unlock() }
        var out: [(event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID)] = []
        out.reserveCapacity(queuedCount)
        if headIndex < storage.count {
            for idx in headIndex..<storage.count {
                if let entry = storage[idx] {
                    out.append((entry.event, entry.run, entry.threadId))
                }
            }
        }
        storage.removeAll(keepingCapacity: true)
        headIndex = 0
        bufferedBytes = 0
        flushScheduled = false
        saturationRunID = nil
        return out
    }

    func resetSaturation(for runID: AgentRunID) {
        lock.lock()
        if saturationRunID == runID { saturationRunID = nil }
        lock.unlock()
    }
}

public struct AgentComposerSuggestion: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case slashCommand
        case skill
        case bot
    }

    public let id: String
    public let title: String
    public let subtitle: String
    public let insertText: String
    public let kind: Kind
    public let botName: String?
    public let botHandle: String?
    public let botAvatarSymbol: String?

    public init(
        title: String,
        subtitle: String,
        insertText: String,
        kind: Kind,
        botName: String? = nil,
        botHandle: String? = nil,
        botAvatarSymbol: String? = nil
    ) {
        self.id = "\(kind)-\(insertText)"
        self.title = title
        self.subtitle = subtitle
        self.insertText = insertText
        self.kind = kind
        self.botName = botName
        self.botHandle = botHandle
        self.botAvatarSymbol = botAvatarSymbol
    }
}

public enum AgentComposerSuggestions {
    /// Provider-pass-through commands available on every Agent provider (Codex,
    /// Claude, Grok). Not RemoteCode-local handlers — `send` forwards them as the
    /// first user token. Always merged into autocomplete + `$`→`/` normalization so
    /// a stale/empty snapshot cannot hide `/goal`.
    public static let passThroughSlashCommands = ["/goal", "/loop"]

    public static func suggestions(
        for text: String,
        cursorOffset: Int? = nil,
        snapshot: AgentProviderSnapshot?,
        localSlashCommands: [String],
        extraCommands: [String] = [],
        extraSkillNames: [String] = [],
        mentionableBots: [BotDefinition] = [],
        commandSubtitles: [String: String] = [:],
        limit: Int = 8
    ) -> [AgentComposerSuggestion] {
        let token = activeToken(in: text, cursorOffset: cursorOffset)
        if token.hasPrefix("@") {
            let query = String(token.dropFirst())
            return BotMentionParser.suggestions(query: query, bots: mentionableBots, excluding: nil)
                .prefix(limit)
                .map { bot in
                    AgentComposerSuggestion(
                        title: bot.name,
                        subtitle: bot.title.isEmpty ? "@\(bot.handle)" : "\(bot.title) · @\(bot.handle)",
                        insertText: "@\(bot.handle) ",
                        kind: .bot,
                        botName: bot.name,
                        botHandle: bot.handle,
                        botAvatarSymbol: bot.avatarSymbol
                    )
                }
        }
        // Both `/` and `$` open the same mixed catalog: modes/commands + skills.
        // Insert text keeps the typed trigger so `/sam-work` and `$goal` work.
        guard let trigger = token.first, trigger == "/" || trigger == "$" else { return [] }
        let prefix = String(trigger)
        let query = String(token.dropFirst()).lowercased()
        let display = snapshot?.displayName ?? "Provider"
        // extraCommands = provider built-ins the app doesn't own (e.g. `/mcp`).
        // extraSkillNames = project/user skills + commands discovered on disk so
        // the menu matches interactive claude's `/`, not just the cached probe.
        let providerCommands = Array(Set((snapshot?.slashCommands ?? []) + passThroughSlashCommands + extraCommands))
        let allCommands = Array(Set(localSlashCommands + providerCommands))
        let skills = Array(Set((snapshot?.skills ?? []) + extraSkillNames))

        struct Candidate: Equatable {
            let bare: String
            let kind: AgentComposerSuggestion.Kind
            let subtitle: String
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(allCommands.count + skills.count)
        for command in allCommands {
            let bare = command.hasPrefix("/") || command.hasPrefix("$")
                ? String(command.dropFirst())
                : command
            guard !bare.isEmpty else { continue }
            let source = localSlashCommands.contains(command) || localSlashCommands.contains("/\(bare)")
                ? "MacCode command"
                : "\(display) command"
            candidates.append(Candidate(
                bare: bare,
                kind: .slashCommand,
                subtitle: commandSubtitles[bare.lowercased()] ?? source
            ))
        }
        for skill in skills where !skill.isEmpty {
            candidates.append(Candidate(
                bare: skill,
                kind: .skill,
                subtitle: "\(display) skill"
            ))
        }

        // WHY: skill catalogs are large (50–80+). Ranking every bare name together
        // with limit=8 buries modes/commands (`/plan`, `/goal`) under ads-* skills
        // on bare `/`. Emit every matching command first (never truncated by limit),
        // then give skills their OWN budget of `limit` rows on top. The earlier
        // `max(limit, commandCount)` cap starved skills to ZERO whenever commands
        // already filled `limit` (e.g. Claude's built-ins + `/mcp`), hiding every
        // project/user skill on a bare `/`; skills must always get room.
        var commandNames: [String] = []
        var skillNames: [String] = []
        commandNames.reserveCapacity(candidates.count)
        skillNames.reserveCapacity(candidates.count)
        for candidate in candidates {
            switch candidate.kind {
            case .slashCommand: commandNames.append(candidate.bare)
            case .skill: skillNames.append(candidate.bare)
            default: break
            }
        }
        let commandBares = ranked(
            commandNames,
            query: query
        )
        let skillBares = ranked(
            skillNames,
            query: query
        )
        var seenBareKind = Set<String>()
        var results: [AgentComposerSuggestion] = []
        results.reserveCapacity(max(limit, commandBares.count))

        func append(bares: [String], kind: AgentComposerSuggestion.Kind, stopAt: Int?) {
            for bare in bares {
                if let stopAt, results.count >= stopAt { return }
                for candidate in candidates
                    where candidate.kind == kind
                        && candidate.bare.caseInsensitiveCompare(bare) == .orderedSame {
                    let key = "\(candidate.kind)-\(candidate.bare.lowercased())"
                    guard seenBareKind.insert(key).inserted else { continue }
                    let title = "\(prefix)\(candidate.bare)"
                    results.append(AgentComposerSuggestion(
                        title: title,
                        subtitle: candidate.subtitle,
                        insertText: "\(title) ",
                        kind: candidate.kind
                    ))
                    if let stopAt, results.count >= stopAt { return }
                }
            }
        }

        append(bares: commandBares, kind: .slashCommand, stopAt: nil)
        let skillCap = results.count + limit
        append(bares: skillBares, kind: .skill, stopAt: skillCap)
        return results
    }

    /// Canonical first-token triggers before provider dispatch (all providers):
    /// - Known slash commands → `/name` (from `$name` or `/name`)
    /// - Known skills that are not also commands → `$name` (from `/name` or `$name`)
    /// Commands win on name collision so `$plan`/`/plan` stay modes, not skills.
    public static func normalizingComposerTriggerPrefix(
        _ raw: String,
        localSlashCommands: [String],
        providerSlashCommands: [String],
        skills: [String]
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trigger = trimmed.first, trigger == "/" || trigger == "$" else { return raw }
        let body = trimmed.dropFirst()
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let barePart = parts.first else { return raw }
        let bareRaw = String(barePart)
        let bareKey = bareRaw.lowercased()
        guard !bareKey.isEmpty else { return raw }

        func bareCatalog(_ tokens: [String]) -> [String: String] {
            var map: [String: String] = [:]
            for token in tokens {
                let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedToken.isEmpty else { continue }
                let name = (trimmedToken.hasPrefix("/") || trimmedToken.hasPrefix("$"))
                    ? String(trimmedToken.dropFirst())
                    : trimmedToken
                let key = name.lowercased()
                guard !key.isEmpty, map[key] == nil else { continue }
                map[key] = name
            }
            return map
        }

        let commandCatalog = bareCatalog(localSlashCommands + providerSlashCommands)
        let skillCatalog = bareCatalog(skills)
        let argument = parts.count > 1 ? String(parts[1]) : nil

        func compose(prefix: Character, name: String) -> String {
            if let argument, !argument.isEmpty {
                return "\(prefix)\(name) \(argument)"
            }
            return "\(prefix)\(name)"
        }

        if let commandName = commandCatalog[bareKey] {
            return compose(prefix: "/", name: commandName.lowercased())
        }
        if let skillName = skillCatalog[bareKey] {
            return compose(prefix: "$", name: skillName)
        }
        return raw
    }

    /// Compatibility wrapper: command-only rewrite (`$goal` → `/goal`).
    public static func normalizingProviderSlashPrefix(
        _ raw: String,
        localSlashCommands: [String],
        providerSlashCommands: [String]
    ) -> String {
        normalizingComposerTriggerPrefix(
            raw,
            localSlashCommands: localSlashCommands,
            providerSlashCommands: providerSlashCommands,
            skills: []
        )
    }

    public static func replacingActiveToken(in text: String, cursorOffset: Int? = nil, with replacement: String) -> String {
        guard let range = activeTokenRange(in: text, cursorOffset: cursorOffset) else { return replacement }
        var updated = text
        updated.replaceSubrange(range, with: replacement)
        return updated
    }

    /// Shared with `AgentAppViewModel.composerSuggestions` and
    /// `BotsViewModel.composerSuggestions` so a VM can gate expensive
    /// bot/slash catalog loads before calling `suggestions`.
    nonisolated public static func activeToken(in text: String, cursorOffset: Int? = nil) -> String {
        guard let range = activeTokenRange(in: text, cursorOffset: cursorOffset) else { return "" }
        return String(text[range])
    }

    /// Returns the range of the token immediately before the cursor.
    ///
    /// WHY: suggestions must anchor at the cursor position, not `text.endIndex`,
    /// so that editing the middle of a multiline prompt (e.g. inserting a slash
    /// command on line 2 of 3) produces correct suggestions. When `cursorOffset`
    /// is nil the old behavior (anchor at endIndex) is preserved for call sites
    /// that have not yet been wired up.
    ///
    /// The token extends from the nearest preceding whitespace (exclusive) to
    /// the cursor position (exclusive of any text after the cursor).
    nonisolated public static func activeTokenRange(text: String, cursorOffset: Int) -> Range<String.Index>? {
        let utf16 = text.utf16
        // Negative offsets are invalid (buggy caller) -> nil. An offset past the
        // end (e.g. a transient paste race in NSTextView) clamps to endIndex so
        // suggestions still resolve the trailing token rather than vanishing.
        guard cursorOffset >= 0 else { return nil }
        let cursorOffset = min(cursorOffset, utf16.count)
        let cursorIdx: String.Index
        if cursorOffset == utf16.count {
            cursorIdx = text.endIndex
        } else if let idx = text.index(text.startIndex, offsetBy: cursorOffset, limitedBy: text.endIndex) {
            cursorIdx = idx
        } else {
            cursorIdx = text.endIndex
        }
        var start = cursorIdx
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace { break }
            start = previous
        }
        guard start < cursorIdx else { return nil }
        return start..<cursorIdx
    }

    private static func activeTokenRange(in text: String, cursorOffset: Int? = nil) -> Range<String.Index>? {
        if let offset = cursorOffset {
            return activeTokenRange(text: text, cursorOffset: offset)
        }
        // Legacy: anchor at text.endIndex (used when cursor position is unknown).
        let end = text.endIndex
        var start = end
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace { break }
            start = previous
        }
        guard start < end else { return nil }
        return start..<end
    }

    private static func ranked(_ values: [String], query: String) -> [String] {
        let unique = Array(Set(values)).sorted()
        guard !query.isEmpty else { return unique }
        let normalizedQuery = query.hasPrefix("$") || query.hasPrefix("/")
            ? String(query.dropFirst()).lowercased()
            : query
        guard !normalizedQuery.isEmpty else { return unique }
        // PERF: fold case once per row instead of per filter check plus twice
        // per sort comparison on every composer keystroke; order identical.
        struct RankedRow {
            let raw: String
            let folded: String
            let bare: String
            let prefixHit: Bool
        }
        var rows: [RankedRow] = []
        rows.reserveCapacity(unique.count)
        for value in unique {
            let folded = value.lowercased()
            let bare = folded.hasPrefix("/") || folded.hasPrefix("$")
                ? String(folded.dropFirst())
                : folded
            guard bare.contains(normalizedQuery) || folded.contains(normalizedQuery) else { continue }
            rows.append(RankedRow(
                raw: value,
                folded: folded,
                bare: bare,
                prefixHit: bare.hasPrefix(normalizedQuery) || folded.hasPrefix(normalizedQuery)
                    || folded.hasPrefix("/\(normalizedQuery)") || folded.hasPrefix("$\(normalizedQuery)")
            ))
        }
        rows.sort {
            if $0.prefixHit != $1.prefixHit { return $0.prefixHit }
            return $0.raw < $1.raw
        }
        return rows.map(\.raw)
    }
}

public enum AgentContextStatusPresentation {
    public static func message(usage: AssistantTokenUsage?, compactionSummary: String?) -> String? {
        let compacted = compactionSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let usage else {
            return compacted?.isEmpty == false ? "Context compacted: \(compacted!)" : nil
        }
        // Occupancy percentage must come from per-request `contextTokens` only.
        // `totalTokens` can be session-cumulative billing (Claude modelUsage cache
        // re-reads) and must never drive "Context N%" — that produced 999%.
        let tokenText: String
        if let occupancy = usage.contextTokens {
            if let window = usage.contextWindow, window > 0 {
                let pct = min(100, max(0, Int((Double(occupancy) / Double(window) * 100).rounded())))
                tokenText = "Context \(pct)% · \(occupancy) / \(window) tokens"
            } else {
                tokenText = "Context \(occupancy) tokens"
            }
        } else if let window = usage.contextWindow, window > 0 {
            tokenText = "Session \(usage.totalTokens) / \(window) tokens"
        } else {
            tokenText = "Session \(usage.totalTokens) tokens"
        }
        var parts = [tokenText]
        if usage.compactsAutomatically == true {
            parts.append("auto-compacts")
        }
        if let compacted, !compacted.isEmpty {
            parts.append("compacted")
        }
        return parts.joined(separator: " · ")
    }
}

public struct AgentTimelineItemPresentation: Equatable, Sendable {
    public let icon: String
    public let verb: String
    public let label: String
    public let detail: String?

    public static func make(for item: AssistantItem) -> AgentTimelineItemPresentation {
        let label = primaryText(for: item).replacingOccurrences(of: "\n", with: " ")
        return AgentTimelineItemPresentation(
            icon: icon(for: item),
            verb: verb(for: item),
            label: label,
            detail: detailText(for: item)
        )
    }

    private static func primaryText(for item: AssistantItem) -> String {
        if let progress = item.progress {
            let percent = Int((AssistantTimelineState.normalizedProgress(progress) * 100).rounded())
            return "\(percent)% \(basePrimaryText(for: item))"
        }
        return basePrimaryText(for: item)
    }

    private static func basePrimaryText(for item: AssistantItem) -> String {
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? item.type.rawValue : body
    }

    private static func detailText(for item: AssistantItem) -> String? {
        if item.type == .reasoning {
            // F21: the Codex app-server adapter streams reasoning text into `output`
            // with a constant "Reasoning" summary, so prefer the actual text over
            // the placeholder; summary remains the fallback for providers that only
            // send reasoning summaries.
            if item.output?.isEmpty == false { return item.output }
            let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary?.isEmpty == false ? summary : nil
        }
        return item.output?.isEmpty == false ? item.output : nil
    }

    /// The command / input that a tool actually ran, extracted from `item.body`.
    /// The parser stores a tool_use's input there as JSON (e.g. {"command":"…"} for Bash,
    /// {"file_path":"…"} for Read/Edit). The transcript previously showed only "Ran Bash"
    /// with no command — this surfaces the actual command so the run is legible.
    ///
    /// PERF: live tool rows used to `JSONSerialization` this body on every paint
    /// (~30 Hz × N tools). Route through `toolInputObject` so identical JSON
    /// parses once and subsequent paints are cache hits.
    static func toolCommandPreview(for item: AssistantItem) -> String? {
        switch item.type {
        case .tool, .mcpToolCall, .dynamicToolCall, .collabToolCall, .commandExecution:
            break
        default:
            return nil
        }
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        // S-02: every tool row asked for this 1-2× per body pass (label, L2
        // summary, expanded command) and each call re-parsed the input JSON.
        // `toolInputObject` already memoizes the parse per body string.
        if let obj = toolInputObject(for: item) {
            // Most-informative field per tool family, in priority order.
            for key in ["command", "cmd", "script", "query", "pattern", "skill", "file_path", "path", "url", "prompt", "name"] {
                if let value = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return AgentAppView.cappedVisibleText(value, limit: AgentAppView.commandPreviewCharacterLimit, truncatedLabel: "hidden from preview")
                }
            }
            // Prefer humanized meta for opaque task/timeout payloads over raw API keys.
            if let human = humanizedStructuredPreview(from: obj) {
                return human
            }
            // Unknown shape: a clean one-line key: value digest. Scalars show their value;
            // arrays/objects show a compact shape hint (not Swift's brace-y debug description).
            let digest = obj.keys.sorted().prefix(4).map { key -> String in
                "\(key): \(Self.shortValue(obj[key]))"
            }.joined(separator: "   ")
            return digest.isEmpty ? nil : digest
        }
        // Non-JSON body is already a human-readable input/description.
        return AgentAppView.cappedVisibleText(body, limit: AgentAppView.commandPreviewCharacterLimit, truncatedLabel: "hidden from preview")
    }

    // MARK: Tool card presentation (collapsed density)

    // PERF: tool L1/L2 paint recompiled these on every row (label, summary,
    // shell family). Compile once; same patterns as the prior String.range /
    // replacingOccurrences(options: .regularExpression) forms.
    private static let bgPrefixRegex = try! NSRegularExpression(pattern: #"^\[bg\]\s*"#)
    private static let backgroundPrefixRegex = try! NSRegularExpression(
        pattern: #"^background:\s*"#,
        options: [.caseInsensitive]
    )
    private static let trailingCallIdRegex = try! NSRegularExpression(
        pattern: #"(?::\s*|\s+)call-[0-9a-f-]{8,}\s*$"#,
        options: [.caseInsensitive]
    )
    private static let usersHomePathRegex = try! NSRegularExpression(pattern: #"/Users/[^/\s]+/"#)
    // PERF: tool L1 paint trims trailing colon/whitespace on every streaming row.
    // CharacterSet.union allocates; share one set for the display-label path.
    private static let toolLabelTrailingTrimSet = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ":"))

    private static func replacingMatches(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    /// L1 title for tool rows: short tool name without full shell pipelines or call UUIDs.
    /// Does not mutate stored summary/body — pure display transform.
    static func toolDisplayLabel(for item: AssistantItem) -> String {
        var label = basePrimaryText(for: item)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Provider titles sometimes embed `[bg]` + the whole command.
        label = replacingMatches(bgPrefixRegex, in: label, with: "")
        label = replacingMatches(backgroundPrefixRegex, in: label, with: "")
        // "Get task output: call-<uuid>" / trailing call ids
        label = replacingMatches(trailingCallIdRegex, in: label, with: "")
        label = label.trimmingCharacters(in: toolLabelTrailingTrimSet)
        if looksLikeShellCommand(label) {
            return shellToolFamilyName(for: item)
        }
        if label.contains("_"), !label.contains(" "), label.count <= 64 {
            return label
                .split(separator: "_")
                .map { part in
                    let s = String(part)
                    return s.prefix(1).uppercased() + s.dropFirst().lowercased()
                }
                .joined(separator: " ")
        }
        // Collapse very long titles that aren't pure shell (still too noisy for L1).
        if label.count > 48, toolCommandPreview(for: item) != nil {
            return shellToolFamilyName(for: item)
        }
        return label.isEmpty ? item.type.rawValue : label
    }

    /// Collapsed L2 summary: meaningful last command, no distill pipe, short paths.
    /// Full command remains available via `toolCommandPreview` when expanded.
    /// When stages are elided, appends `· +N more` so density never silently drops intent.
    static func toolCommandSummary(for item: AssistantItem) -> String? {
        guard let full = toolCommandPreview(for: item) else { return nil }
        // Structured human previews are already short — keep them.
        if full.contains(" · ") || full.hasPrefix("timeout ") || full.hasSuffix(" task") || full.hasSuffix(" tasks") {
            return full
        }
        return summarizeShellishCommand(full)
    }

    /// True when the tool ran (or is running) detached/backgrounded.
    static func isBackgroundTool(for item: AssistantItem) -> Bool {
        if let summary = item.summary?.lowercased(),
           summary.contains("[bg]")
            || summary.contains("background shell")
            || summary.contains("background agent")
            || summary.hasPrefix("background") {
            return true
        }
        guard let obj = toolInputObject(for: item) else { return false }
        if let flag = obj["background"] as? Bool { return flag }
        if let flag = obj["background"] as? NSNumber { return flag.boolValue }
        if let flag = obj["run_in_background"] as? Bool { return flag }
        if let flag = obj["run_in_background"] as? NSNumber { return flag.boolValue }
        return false
    }

    /// True when this tool is a wait/poll on background task output
    /// (Grok `Get task output`, Claude `BashOutput` / `bash_id`, task_ids + timeout, etc.).
    /// These rows are the ones that feel "stuck" without a live heartbeat.
    static func isTaskWaitTool(for item: AssistantItem) -> Bool {
        let summary = (item.summary ?? "").lowercased()
        if summary.contains("get task output")
            || summary.contains("task output")
            || summary.contains("await task")
            || summary.contains("wait for task")
            || summary.contains("bashoutput")
            || summary.contains("bash output")
            || summary.contains("bash_output") {
            return true
        }
        guard let obj = toolInputObject(for: item) else { return false }
        let hasWaitKey = obj["task_ids"] != nil
            || obj["task_id"] != nil
            || obj["bash_id"] != nil
        guard hasWaitKey else { return false }
        // Shell tools can also carry ids; only treat as wait when there is no command body.
        for key in ["command", "cmd", "script"] {
            if let value = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return false
            }
        }
        return true
    }

    /// Live per-row clocks are reserved for wait/background tools only.
    /// Ordinary foreground tools stay off the tick path (perf + "Working for" covers them).
    static func showsLiveToolElapsed(for item: AssistantItem) -> Bool {
        guard item.state == .streaming else { return false }
        return isBackgroundTool(for: item) || isTaskWaitTool(for: item)
    }

    /// True when a consecutive tool run must stay ungrouped so live wait UI is not buried
    /// under a collapsed "Running N commands…" header.
    static func mustKeepToolsUngrouped(_ items: [AssistantItem]) -> Bool {
        items.contains { showsLiveToolElapsed(for: $0) }
    }

    /// Leading/trailing streaming status — "Waiting" for task polls so color is not the only signal.
    static func toolStreamingStatusLabel(for item: AssistantItem) -> String {
        if isTaskWaitTool(for: item) { return "Waiting" }
        return "Running"
    }

    /// Collapsed liveness copy when a long wait has not produced tool output yet.
    /// WHY: without this, Background / Get task output rows look frozen for minutes.
    static func toolActivityHint(for item: AssistantItem, hasOutput: Bool) -> String? {
        guard item.state == .streaming, !hasOutput else { return nil }
        if isTaskWaitTool(for: item) {
            return "No output yet · background task still running"
        }
        if isBackgroundTool(for: item) {
            return "No output yet · command still running in background"
        }
        return nil
    }

    /// Expand affordance for *streaming* wait rows before stdout arrives (timeout / status).
    /// Completed/failed waits must not keep a dead chevron or "waiting" a11y claim.
    static func toolCanExpandWithoutOutput(for item: AssistantItem) -> Bool {
        guard item.state == .streaming else { return false }
        if isTaskWaitTool(for: item) { return true }
        return showsLiveToolElapsed(for: item)
    }

    /// Compact elapsed label (`12s`, `1m 53s`) from start→end timestamps.
    static func durationLabel(fromMs: Int64, toMs: Int64) -> String? {
        let elapsedMs = max(0, Int(toMs - fromMs))
        return formatDurationMs(elapsedMs)
    }

    /// Duration label for finished tools (≥1s), plus live elapsed for background/task-wait
    /// streaming tools when `nowMs` is supplied by an `ElapsedTickSchedule` TimelineView.
    static func toolDurationLabel(for item: AssistantItem, nowMs: Int64? = nil) -> String? {
        switch item.state {
        case .streaming:
            guard showsLiveToolElapsed(for: item), let nowMs else { return nil }
            let elapsedMs = max(0, Int(nowMs - item.startedAtMs))
            // Match finished-row floor: avoid "0s" / sub-second flicker on first paint.
            guard elapsedMs >= 1_000 else { return nil }
            return formatDurationMs(elapsedMs)
        case .completed, .failed, .cancelled:
            guard let finished = item.finishedAtMs else { return nil }
            let elapsedMs = max(0, Int(finished - item.startedAtMs))
            // Suppress 0s walls when providers stamp started==finished.
            guard elapsedMs >= 1_000 else { return nil }
            return formatDurationMs(elapsedMs)
        }
    }

    /// Accessibility label: status + tool name + optional summary + duration (not color-only).
    static func toolAccessibilityLabel(for item: AssistantItem, nowMs: Int64? = nil) -> String {
        var parts: [String] = []
        if item.state == .streaming {
            parts.append(toolStreamingStatusLabel(for: item))
        } else {
            parts.append(verb(for: item))
        }
        parts.append(toolDisplayLabel(for: item))
        if isBackgroundTool(for: item) { parts.append("background") }
        // Only claim active wait while streaming — completed polls must not say "waiting".
        if item.state == .streaming, isTaskWaitTool(for: item) {
            parts.append("waiting for task output")
        }
        if let summary = toolCommandSummary(for: item), !summary.isEmpty {
            parts.append(summary)
        }
        if let duration = toolDurationLabel(for: item, nowMs: nowMs) {
            parts.append(duration)
        }
        let detail = detailText(for: item)
        let hasOutput = (detail?.isEmpty == false)
        if let hint = toolActivityHint(for: item, hasOutput: hasOutput) {
            parts.append(hint)
        }
        return parts.joined(separator: ", ")
    }

    /// Humanize task/timeout shaped inputs for collapsed display.
    static func humanizedStructuredPreview(from obj: [String: Any]) -> String? {
        var parts: [String] = []
        if let ids = obj["task_ids"] as? [Any], !ids.isEmpty {
            parts.append(ids.count == 1 ? "1 task" : "\(ids.count) tasks")
        } else if let id = obj["task_id"] {
            let text = shortValue(id)
            if !text.isEmpty, text != "—" { parts.append("task \(text)") }
        }
        if let timeout = intMillis(from: obj["timeout_ms"]) ?? intMillis(from: obj["timeout"]) {
            if let label = formatDurationMs(timeout) {
                parts.append("timeout \(label)")
            }
        }
        if let bashId = obj["bash_id"] {
            let text = shortValue(bashId)
            if !text.isEmpty, text != "—" { parts.append("bash \(text)") }
        }
        // Only claim this path when we humanized the noisy keys providers dump by default.
        let noisyKeys: Set<String> = ["task_ids", "task_id", "bash_id", "timeout_ms", "timeout", "call_id", "id"]
        let otherKeys = obj.keys.filter { !noisyKeys.contains($0) }
        guard !parts.isEmpty, otherKeys.isEmpty || otherKeys.count <= 1 else { return nil }
        return parts.joined(separator: " · ")
    }

    static func summarizeShellishCommand(_ command: String) -> String {
        var s = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        var elided = 0
        // Drop only closed-allowlist leading segments (`cd`, `export`, `source`, `.`, `set -e…`).
        let segments = s
            .components(separatedBy: "&&")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if segments.count > 1 {
            var kept = segments
            while let first = kept.first, isDisposableLeadingShellSegment(first), kept.count > 1 {
                kept.removeFirst()
                elided += 1
            }
            s = kept.first ?? s
            if kept.count > 1 {
                // Additional trailing stages after the primary command stay collapsed.
                elided += kept.count - 1
            }
        }
        let home = NSHomeDirectory()
        if !home.isEmpty {
            s = s.replacingOccurrences(of: home, with: "~")
        }
        // Collapse `/Users/name/...` even when not exactly NSHomeDirectory (remote paths).
        s = replacingMatches(usersHomePathRegex, in: s, with: "~/")
        let limit = 96
        if s.count > limit {
            s = String(s.prefix(limit - 1)) + "…"
        }
        if elided > 0 {
            return "\(s) · +\(elided) more"
        }
        return s
    }

    /// Leading shell setup stages safe to hide behind `· +N more` (never hide `rm` etc.).
    static func isDisposableLeadingShellSegment(_ segment: String) -> Bool {
        let t = segment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("cd ") || t == "cd" { return true }
        if t.hasPrefix("export ") { return true }
        if t.hasPrefix("source ") || t.hasPrefix(". ") { return true }
        if t.hasPrefix("set -") || t == "set -e" || t == "set -eo pipefail" { return true }
        return false
    }

    /// Raw `command`/`cmd`/`script` string from tool input JSON (uncapped), if present.
    static func rawShellCommand(for item: AssistantItem) -> String? {
        guard let obj = toolInputObject(for: item) else { return nil }
        for key in ["command", "cmd", "script"] {
            if let value = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func looksLikeShellCommand(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8 else { return false }
        if t.contains("&&") || t.contains("|") { return true }
        if t.hasPrefix("cd ") || t.hasPrefix("git ") || t.hasPrefix("npm ") || t.hasPrefix("swift ") {
            return true
        }
        if t.contains("/Users/") || t.hasPrefix("~/") { return true }
        return false
    }

    static func shellToolFamilyName(for item: AssistantItem) -> String {
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            let withoutBg = replacingMatches(bgPrefixRegex, in: summary, with: "")
            if !looksLikeShellCommand(withoutBg),
               summary.count <= 32,
               !summary.contains(":") {
                return withoutBg
            }
        }
        switch item.type {
        case .commandExecution: return "Shell"
        default: return "Shell"
        }
    }

    /// Live tool rows re-enter `body` (and TimelineView ticks) on the same JSON.
    /// Parse once per body string; SwiftUI must not JSON-decode on every pass.
    private final class ToolInputJSONBox {
        let object: [String: Any]?
        init(_ object: [String: Any]?) { self.object = object }
    }

    private static let toolInputCache: NSCache<NSString, ToolInputJSONBox> = {
        let cache = NSCache<NSString, ToolInputJSONBox>()
        cache.countLimit = 256
        cache.totalCostLimit = 128 * 1_024
        return cache
    }()

    #if DEBUG
    nonisolated(unsafe) static var toolInputObjectComputeCountForTesting = 0
    #endif

    static func toolInputObject(for item: AssistantItem) -> [String: Any]? {
        toolInputObject(forBody: item.body)
    }

    /// Shared JSON object cache for live tool rows and Edit/diff extraction.
    /// Use the body as the key to avoid re-hashing large JSON strings on every
    /// live-row paint; NSCache bounds the retained entries and values.
    static func toolInputObject(forBody raw: String) -> [String: Any]? {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let key = body as NSString
        if let cached = toolInputCache.object(forKey: key) {
            return cached.object
        }
        #if DEBUG
        toolInputObjectComputeCountForTesting &+= 1
        #endif
        let parsed: [String: Any]?
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parsed = obj
        } else {
            parsed = nil
        }
        toolInputCache.setObject(ToolInputJSONBox(parsed), forKey: key, cost: max(1, body.utf8.count))
        return parsed
    }

    static func intMillis(from value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let i as Int64: return Int(i)
        case let n as NSNumber: return n.intValue
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        default: return nil
        }
    }

    static func formatDurationMs(_ ms: Int) -> String? {
        guard ms >= 0 else { return nil }
        if ms < 1000 { return "\(max(ms, 0))ms" }
        let totalSeconds = ms / 1000
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
    }

    /// UX-MAC_AGENT-OPEN-SPLIT: the openable target of a tool call — Read/Edit-style
    /// inputs carry a file path, fetch-style inputs a URL. Drives the transcript's
    /// "open in split panel" affordance on tool rows.
    enum ToolOpenTarget: Equatable {
        case file(String)
        case url(URL)
    }

    static func toolOpenTarget(for item: AssistantItem) -> ToolOpenTarget? {
        switch item.type {
        case .tool, .mcpToolCall, .dynamicToolCall, .collabToolCall, .commandExecution, .fileChange:
            break
        default:
            return nil
        }
        guard let obj = toolInputObject(for: item) else { return nil }
        for key in ["file_path", "path", "notebook_path"] {
            if let value = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return .file(value)
            }
        }
        if let raw = (obj["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return .url(url)
        }
        return nil
    }

    /// A compact, human-readable rendering of a tool-input value for the one-line digest.
    /// Scalars print their value; arrays/objects print a shape hint instead of raw braces.
    static func shortValue(_ value: Any?) -> String {
        switch value {
        case let s as String: return String(s.prefix(80))
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return "[\(a.count)]"
        case let d as [String: Any]: return "{\(d.keys.sorted().prefix(3).joined(separator: ","))}"
        case is NSNull, nil: return "—"
        default: return String(String(describing: value ?? "").prefix(40))
        }
    }

    /// Whether this timeline item is a Skill tool whose body/output must stay complete.
    /// Skill content is a protected verbatim category (never Distill / display truncation).
    static func isSkillToolItem(_ item: AssistantItem) -> Bool {
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           summary.compare("Skill", options: .caseInsensitive) == .orderedSame {
            return true
        }
        guard let obj = toolInputObject(for: item),
              let skill = (obj["skill"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !skill.isEmpty else {
            return false
        }
        return true
    }

    /// Sanitize + cap inline tool output: strip ANSI escape codes (Bash output is full
    /// of them and they render as literal garbage in a Text view) and cap length so one noisy
    /// command can't blow up the transcript. Full text remains selectable / in the stored event.
    /// Skill tool output is never truncated in presentation — skill content must stay complete.
    ///
    /// PERF: expanded tool rows re-evaluate this on streaming paint. A full
    /// `String.count` grapheme walk of multi-10k command dumps dominated body eval
    /// the same way pre-F11 `cappedText` did. Use O(1) `utf8.count` under-limit
    /// and O(limit) index arithmetic when over (same contract as
    /// `AgentAppView.cappedVisibleText`). The dropped residual is a UTF-8 byte
    /// count — an exact grapheme delta would need the O(n) walk this avoids — so
    /// the marker reports a size, not a character count.
    static func cappedDetail(_ text: String, limit: Int = 6_000, for item: AssistantItem? = nil) -> String {
        let ansiStripped = stripANSI(text)
        let clean = item?.distillApplied == true
            ? DistillAppliedReceipt.strip(ansiStripped)
            : ansiStripped
        if let item, isSkillToolItem(item) {
            return clean
        }
        let limit = max(0, limit)
        guard limit > 0 else { return "" }
        guard clean.utf8.count > limit else { return clean }
        guard let end = clean.index(clean.startIndex, offsetBy: limit, limitedBy: clean.endIndex),
              end < clean.endIndex else {
            return clean
        }
        let head = clean[..<end]
        let dropped = max(1, clean.utf8.count - head.utf8.count)
        return "\(head)\n… \(truncationSizeLabel(dropped)) more truncated in view …"
    }

    /// Human-readable size for a truncation marker.
    ///
    /// The residual these markers can report runs to six digits (`liveOutputLimit`
    /// is 400_000), and every other byte quantity this app shows the user goes
    /// through `ByteCountFormatter` (Settings, Sidebar, Files, SSH). Formatting
    /// here keeps the transcript consistent with that convention instead of
    /// printing a raw digit wall.
    ///
    /// Three properties this deliberately accepts, so they are not mistaken for
    /// bugs later:
    /// - **Lossy.** 4032 B and 4064 B both render "4 KB". The marker communicates
    ///   scale, not an exact count; the exact bytes are in the stored event.
    /// - **Locale-dependent.** 1_500_000 renders "1.5 MB" under en and "1,5 MB"
    ///   under pt-BR, while the surrounding sentence stays English. That matches
    ///   the rest of the app, which is not localized but does format numbers.
    /// - **~1.3 µs per call**, measured `-O`, against ~0.01 µs for the raw `Int`
    ///   it replaced. It runs only on the over-limit branch, and only once per
    ///   truncated string per paint, against ~6.5 µs for the cap work beside it
    ///   (which this MR brought down from ~180 µs). Caching the formatter does
    ///   not help — the cost is in formatting, not allocation.
    static func truncationSizeLabel(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, byteCount)), countStyle: .file)
    }

    /// Remove ANSI/VT control sequences (SGR colors, cursor moves, OSC) so command output is
    /// readable instead of showing literal escape codes. Cheap fast-path when none present.
    ///
    /// PERF: compile CSI/OSC/lone-escape patterns once. `cappedDetail` calls this on every
    /// expanded-tool / streaming paint for Bash dumps; `replacingOccurrences(options:
    /// .regularExpression)` recompiled all three patterns per call and dominated strip
    /// cost on multi-10k CSI-heavy command output.
    private static let ansiCSIRegex = try! NSRegularExpression(
        pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]"
    )
    private static let ansiOSCRegex = try! NSRegularExpression(
        pattern: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)"
    )
    private static let ansiLoneEscapeRegex = try! NSRegularExpression(
        pattern: "\u{001B}[@-Z\\\\-_]"
    )

    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{001B}") else { return text }
        var result = text
        for regex in [ansiCSIRegex, ansiOSCRegex, ansiLoneEscapeRegex] {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
        }
        return result
    }

    private static func verb(for item: AssistantItem) -> String {
        switch item.state {
        case .streaming:
            // Align L1 with trailing wait semantics — avoid "Running … Waiting".
            return toolStreamingStatusLabel(for: item)
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .completed:
            if isFreshSessionNotice(item) { return "New session" }
            switch item.type {
            case .fileChange: return "Changed"
            case .webSearch: return "Searched"
            case .imageView: return "Viewed"
            case .review: return "Reviewed"
            case .contextCompaction: return "Compacted"
            case .error: return "Issue"
            default: return "Ran"
            }
        }
    }

    private static func icon(for item: AssistantItem) -> String {
        if item.state == .streaming { return "circle.dotted" }
        if item.state == .failed { return "xmark.octagon" }
        if item.state == .cancelled { return "nosign" }
        if isFreshSessionNotice(item) { return "arrow.triangle.2.circlepath" }
        switch item.type {
        case .fileChange: return "doc.badge.gearshape"
        case .mcpToolCall, .dynamicToolCall, .collabToolCall: return "puzzlepiece.extension"
        case .webSearch: return "magnifyingglass"
        case .imageView: return "photo"
        case .review: return "checklist"
        case .contextCompaction: return "rectangle.compress.vertical"
        case .error: return "exclamationmark.triangle"
        default: return "terminal"
        }
    }

    /// Distill's replacement-session notice rides as `.contextCompaction` for
    /// decoder compatibility (`DistillACPAdapter.emitFreshSessionNotice`); it
    /// is a new provider session, not a compaction.
    static func isFreshSessionNotice(_ item: AssistantItem) -> Bool {
        item.type == .contextCompaction && item.id.hasPrefix("distill-fresh-session-")
    }

}

public struct AgentImageViewPresentation: Equatable, Sendable, Identifiable {
    public let displayName: String
    public let resourceURL: URL

    public var id: String { resourceURL.path }

    public static func make(for item: AssistantItem) -> AgentImageViewPresentation? {
        guard item.type == .imageView else { return nil }
        // Prefer the private resource path (never shown as label text). Absolute
        // paths in body/summary are a last resort when resourcePath is missing.
        let candidates: [String?] = [item.resourcePath, item.body, item.summary, item.output]
        for raw in candidates {
            guard let path = Self.absoluteFilePath(from: raw) else { continue }
            let url = URL(fileURLWithPath: path)
            return AgentImageViewPresentation(
                displayName: url.lastPathComponent,
                resourceURL: url
            )
        }
        return nil
    }

    /// Absolute filesystem path only — basenames alone must not resolve against CWD.
    public static func absoluteFilePath(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("~") {
            return (trimmed as NSString).expandingTildeInPath
        }
        guard trimmed.hasPrefix("/") else { return nil }
        return (trimmed as NSString).standardizingPath
    }

    /// Pure: which items in a tool-burst group can show a transcript thumbnail.
    public static func presentations(in items: [AssistantItem]) -> [AgentImageViewPresentation] {
        items.compactMap(make(for:))
    }
}

// MARK: - Transcript image thumbnails (UX-MAC_AGENT-IMAGE-THUMB)

/// Compact or featured image preview for agent-cited images in the transcript.
/// Loads off the main actor and reserves layout space so thumbs don't CLS the chat.
private struct AgentTranscriptImageThumb: View {
    enum Style {
        /// Grid cell in a multi-image strip.
        case strip
        /// Single image row: larger, letterboxed.
        case featured
    }

    let url: URL
    let displayName: String
    var style: Style = .strip
    var accessibilityID: String = "agent.image.thumb"

    @State private var image: NSImage?
    @State private var failed = false

    private var thumbWidth: CGFloat { style == .featured ? 320 : 112 }
    private var thumbHeight: CGFloat { style == .featured ? 200 : 84 }

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(DS.Palette.surface)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(width: thumbWidth, height: thumbHeight)
                            .clipped()
                    } else if failed {
                        VStack(spacing: DS.Space.xs) {
                            Image(systemName: "photo")
                                .font(.system(size: style == .featured ? 22 : 16, weight: .medium))
                                .foregroundColor(DS.Palette.textTertiary)
                            if style == .featured {
                                Text("Preview unavailable")
                                    .font(DS.Font.caption2)
                                    .foregroundColor(DS.Palette.textTertiary)
                            }
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: thumbWidth, height: thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                )

                Text(displayName)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: thumbWidth, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(displayName)")
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel("Image \(displayName)")
        .accessibilityHint("Opens the image")
        .dsPointingHandCursor()
        .task(id: "\(url.path)#\(style == .featured ? 640 : 280)") { await loadThumbnail() }
    }

    @MainActor
    private func loadThumbnail() async {
        failed = false
        image = nil
        let path = url.path
        // Reuse the process-wide hard-bounded loader so remounting transcript
        // rows does not decode the same multi-megapixel citation again.
        let loaded = await AgentAttachmentThumbnailLoader.shared.transcriptThumbnail(
            forPath: path,
            featured: style == .featured
        )
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded.image
        } else {
            failed = true
        }
    }
}

/// Horizontal strip of thumbnails for grouped image citations ("Running 2 images…").
private struct AgentTranscriptImageThumbStrip: View {
    let presentations: [AgentImageViewPresentation]
    var accessibilityPrefix: String = "agent.image.strip"

    var body: some View {
        // Do not nest a SwiftUI ScrollView inside the transcript ScrollView.
        // Inner ScrollView reads the parent's Observable
        // `ScrollEnvironmentStorage.isScrollViewTransformClippingEnabled`
        // and SIGSEGVs when the outer storage is mid-update (macOS 26).
        HStack(alignment: .top, spacing: DS.Space.sm) {
            ForEach(Array(presentations.enumerated()), id: \.element.id) { index, presentation in
                AgentTranscriptImageThumb(
                    url: presentation.resourceURL,
                    displayName: presentation.displayName,
                    style: .strip,
                    accessibilityID: "\(accessibilityPrefix).\(index)"
                )
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(presentations.count) image preview\(presentations.count == 1 ? "" : "s")")
    }
}

// MARK: - ThreadMarkdownFormatter

/// Pure, nonisolated formatter that converts live timeline data (tool-call items
/// and approval requests) into markdown lines suitable for inclusion in the
/// exported thread markdown when the caller opts in via `includeTimeline: true`.
///
/// Kept separate from `AgentAppViewModel` so it is fully testable without any
/// actor or SwiftUI state. All inputs are value types.
public enum ThreadMarkdownFormatter {

    /// Render timeline items (tool calls, commands, etc.) and approval requests
    /// as ordered markdown lines.  Items are sorted chronologically by
    /// `startedAtMs`; approvals are interleaved by `createdAtMs`.
    ///
    /// Returns an empty array when both collections are empty, so callers can
    /// skip the section header when there is nothing to show.
    public static func timelineMarkdownLines(
        turns: [AssistantTurnSnapshot],
        approvals: [AssistantPendingRequest]
    ) -> [String] {
        struct Entry {
            let sortKey: Int64
            let line: String
        }

        var entries: [Entry] = []

        // Tool-call items from all turns.
        for turn in turns {
            for item in turn.items {
                guard isTimelineItem(item) else { continue }
                let label = itemLabel(item)
                let statePart = item.state.rawValue
                let durPart = itemDurationString(item).map { " [\($0)]" } ?? ""
                let line = "- \(label) (\(statePart))\(durPart)"
                entries.append(Entry(sortKey: item.startedAtMs, line: line))
            }
        }

        // Approval requests.
        for req in approvals {
            let statePart = req.state.rawValue
            let durPart = approvalDurationString(req).map { " [\($0)]" } ?? ""
            let line = "- Approval: \(req.title) (\(statePart))\(durPart)"
            entries.append(Entry(sortKey: req.createdAtMs, line: line))
        }

        guard !entries.isEmpty else { return [] }

        entries.sort { $0.sortKey < $1.sortKey }
        return entries.map(\.line)
    }

    // MARK: - Private helpers

    /// Exclude assistant-message items and reasoning from the work log since
    /// those are already captured in the role-based export.
    private static func isTimelineItem(_ item: AssistantItem) -> Bool {
        switch item.type {
        case .assistantMessage, .reasoning: return false
        default: return true
        }
    }

    private static func itemLabel(_ item: AssistantItem) -> String {
        if let s = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? item.type.rawValue : String(body.prefix(120))
    }

    private static func itemDurationString(_ item: AssistantItem) -> String? {
        guard let finished = item.finishedAtMs, finished >= item.startedAtMs else { return nil }
        let seconds = Int((finished - item.startedAtMs) / 1000)
        guard seconds > 0 else { return nil }
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private static func approvalDurationString(_ req: AssistantPendingRequest) -> String? {
        guard let resolved = req.resolvedAtMs, resolved >= req.createdAtMs else { return nil }
        let seconds = Int((resolved - req.createdAtMs) / 1000)
        guard seconds > 0 else { return nil }
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

private struct PendingSessionApprovalConfirmation {
    let originThreadId: AgentThreadID
    let request: AssistantPendingRequest
}

public struct AgentAppViewLayout: Equatable {
    public var showsThreadRail: Bool
    public var showsHeader: Bool
    /// False for a host that shows the conversation but sends from elsewhere (Activity).
    public var showsComposer: Bool

    public init(showsThreadRail: Bool = true, showsHeader: Bool = true, showsComposer: Bool = true) {
        self.showsThreadRail = showsThreadRail
        self.showsHeader = showsHeader
        self.showsComposer = showsComposer
    }

    public static let standard = AgentAppViewLayout()
}

/// Where the undo toasts mount (pure, testable seam). One toast fits in the
/// transcript's top padding, so it floats over it. Two would cover the first
/// row, and each carries a live Undo, so the checkpoint toast takes a row
/// above the transcript while both are armed.
public enum AgentUndoToastPlacement {
    public static func checkpointRevertTakesARow(
        threadDeletionArmed: Bool,
        checkpointRevertArmed: Bool
    ) -> Bool {
        threadDeletionArmed && checkpointRevertArmed
    }
}

public struct AgentAppView: View {
    struct QueueStatusBannerPresentation: Equatable {
        let message: String
        let offersCopy: Bool
        let offersRetry: Bool
    }

    private static let threadRailWidthRange: ClosedRange<CGFloat> = 320...360
    private static let threadRailIdealWidth: CGFloat = 320
    private static let conversationMinimumWidth: CGFloat = 560
    static func visibleStatusMessage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func standaloneQueueStatusMessage(_ message: String?, queuedCount: Int) -> String? {
        guard queuedCount == 0, let message else { return nil }
        return visibleStatusMessage(message)
    }

    static func standaloneQueueStatusBanner(
        _ message: String?,
        queuedCount: Int
    ) -> QueueStatusBannerPresentation? {
        guard let message = standaloneQueueStatusMessage(message, queuedCount: queuedCount) else {
            return nil
        }
        return QueueStatusBannerPresentation(message: message, offersCopy: true, offersRetry: true)
    }
    @ObservedObject var vm: AgentAppViewModel
    /// Opens Settings at Accounts & Auto (nil when no Distill accounts host).
    private let openAccountsSettings: (() -> Void)?
    private let layout: AgentAppViewLayout
    /// Host action on the transcript's bottom-trailing corner (Bots Desk +).
    private let timelineAccessory: AnyView?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Message a reply-quote jump landed on; cleared 1.2s later by the latest jump only.
    @State private var quoteJumpHighlightID: AgentMessageID?
    @State private var quoteJumpHighlightTask: Task<Void, Never>?
    @State private var announcedUndoToasts: Set<Date> = []
    @State private var renamingThreadId: AgentThreadID?
    @State private var renameText: String = ""
    @State private var expandedTools: Set<String> = []
    @State private var expandedToolGroups: Set<String> = []
    /// Older grouped tool members revealed beyond the strict initial paint window.
    @State private var toolGroupRevealByID: [String: Int] = [:]
    // UX-MAC_AGENT-010: reasoning rows collapse to "Thought" by default once
    // completed; ids here are the ones the user explicitly expanded.
    @State private var expandedReasoning: Set<String> = []
    @State private var selectedThreadIds: Set<AgentThreadID> = []
    @State private var lastSelectedThreadId: AgentThreadID?
    @State private var draggingThreadId: AgentThreadID?
    @State private var timelineThreadRejoinEpoch = 0
    // IMP-MAC_AGENT-010: highlights the transcript while a file drag hovers it.
    @State private var timelineDropTargeted = false

    @AppStorage("agent.threadRail.intent.v1") private var threadRailIntentRaw = AdaptiveSidebarIntent.auto.rawValue
    @State private var showThreadRail = true
    @State private var lastAutomaticThreadRailChange: TimeInterval?
    @State private var proposedPlanExpanded = false
    @State private var showWorkLog = false
    @State private var dismissedChoices = AgentChatChoicesCard.DismissedStore.load()
    /// User-opened finished (or non-default) work disclosures.
    @State private var expandedCompletedWorkTurns: Set<String> = []
    /// Live turns the user manually collapsed (suppresses default-open latest live).
    @State private var userCollapsedLiveWorkTurns: Set<String> = []
    /// How many older Work so far steps the user revealed per turn (paint window).
    @State private var workDisclosureRevealByTurn: [String: Int] = [:]
    /// Turn ids already treated as finished for collapse-all-on-final (one-shot).
    @State private var knownFinishedWorkTurnIds: Set<String> = []
    /// Bumps when expanded work height changes so pinned readers re-assert bottom.
    @State private var workDisclosureLayoutEpoch: Int = 0
    @State private var queuedMessagePendingCancel: AgentQueuedMessage?
    @State private var pendingSessionApproval: PendingSessionApprovalConfirmation?
    @State private var expandedRequestPreviews: Set<String> = []
    @State private var declineReasonDrafts: [String: String] = [:]
    // P1: thread delete confirmation — ids staged here until user confirms.
    @State private var pendingDeleteThreadIds: Set<AgentThreadID> = []
    /// Clear All confirmation for the thread rail.
    @State private var pendingClearAllThreads = false
    // UX-XPLAT-007: checkpoint revert confirmation — staged turn count until user confirms.
    @State private var pendingRevertCheckpointTurnCount: Int?
    // P3: user-message "show more" — message ids the user has expanded past 28 lines.

    @State private var showModelOptions = false
    @State private var showAllModelOptions = false
    /// Source/account capsule popover (Codex / Claude / Grok). Always openable so
    /// locked/single-source states fail loud instead of a dead click.
    @State private var showSourceOptions = false
    /// Subagents activity popover (provider-neutral Active/Done list).
    @State private var showSubagentActivity = false
    // UX-MAC_AGENT-013: inline custom-model entry replaces the blocking NSAlert.
    @State private var showCustomModelField = false
    @State private var showExecutionSheet = false
    @State private var customModelDraft = ""
    /// Composer Simple (attach/model/send) vs Power (full toolbar).
    /// Always full chrome — no Simple/Power collapse toggle on macOS.
    /// A surface whose sends are intercepted (a bot group room) only relays:
    /// its provider, model and run chrome would change nothing.
    private var composerChromeMode: AgentComposerChromeMode {
        vm.embedding?.sendInterceptor != nil ? .relay : .power
    }

    public init(
        vm: AgentAppViewModel,
        openAccountsSettings: (() -> Void)? = nil,
        layout: AgentAppViewLayout = .standard,
        timelineAccessory: AnyView? = nil
    ) {
        self.vm = vm
        self.openAccountsSettings = openAccountsSettings
        self.layout = layout
        self.timelineAccessory = timelineAccessory
    }

    static let fullAccessScopeDescription =
        "The agent runs tools, edits, and proposed plans without asking for this thread until you change it."

    static let sessionApprovalHelp =
        "Auto-approve requests for this thread until you change it"

    static let threadDeletionConfirmationDescription =
        "Threads are deleted immediately. You can undo for 10 seconds; after that, their history is permanently deleted."

    static let emptyThreadSubtitle =
        "Send a prompt to start a Distill thread."

    static func attachmentRemovalAccessibilityLabel(path: String) -> String {
        "Remove attachment \((path as NSString).lastPathComponent)"
    }

    /// Pure seam: checkpoint revert always needs a destructive confirmation.
    /// WHY: reverting rolls back the working tree and cannot be undone; any
    /// checkpoint that is ready to apply is destructive. The predicate is
    /// extracted so tests can verify the guard without instantiating views.
    nonisolated static func needsRevertConfirmation(checkpointStatus: AgentTurnCheckpointStatus) -> Bool {
        checkpointStatus == .ready
    }

    static func shouldRenderFinalAssistantMessage(_ turn: AssistantTurnSnapshot, persistedAssistantTexts: [String] = []) -> Bool {
        guard let final = turn.finalAssistantMessage, !final.isEmpty else { return false }
        let bodies = renderableAssistantItemBodies(in: turn, persistedAssistantTexts: persistedAssistantTexts)
        // Already painted as an assistant-item row outside Work so far — skip field.
        if assistantText(bodies.joined(separator: "\n"), equals: final) { return false }
        if bodies.contains(where: { assistantText($0, matches: final) }) { return false }
        // WHY (open-thread order): when the turn has Work so far (tools/preambles)
        // and the durable answer is also a persisted AgentMessage, prefer the
        // turn-owned final (always after Work so far) and hide the message row.
        // Without work, keep the old message-only path (no empty Work so far).
        if turnHasWorkDisclosureContent(turn, finalText: final) {
            return true
        }
        if assistantText(final, matchesAny: persistedAssistantTexts) { return false }
        return true
    }

    /// True when the turn would show a Work so far / Worked disclosure (tools,
    /// reasoning, or non-final assistant preambles). Pure for tests.
    static func turnHasWorkDisclosureContent(
        _ turn: AssistantTurnSnapshot,
        finalText: String? = nil
    ) -> Bool {
        let final = (finalText ?? turn.finalAssistantMessage)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return turn.items.contains { item in
            switch item.type {
            case .assistantMessage:
                guard !final.isEmpty else { return !item.body.isEmpty }
                return !item.body.isEmpty
                    && !assistantText(item.body, matches: final)
                    && !assistantText(final, matches: item.body)
            default:
                return true
            }
        }
    }

    static func shouldRenderAssistantItemBody(_ body: String, priorAssistantTexts: [String] = [], persistedAssistantTexts: [String] = []) -> Bool {
        return !body.isEmpty &&
            !assistantText(body, equalsAny: priorAssistantTexts) &&
            !assistantText(body, equalsAny: persistedAssistantTexts)
    }

    static func shouldRenderPersistedAssistantMessage(_ text: String, timelineTurns: [AssistantTurnSnapshot]) -> Bool {
        guard !text.isEmpty else { return false }
        return !timelineTurns.contains { turn in
            let visibleAssistantText = renderableAssistantItemBodies(in: turn, persistedAssistantTexts: [text])
                .joined(separator: "\n")
            return assistantText(visibleAssistantText, equals: text)
        }
    }

    static func renderableItems(in turn: AssistantTurnSnapshot, persistedAssistantTexts: [String] = []) -> [AssistantItem] {
        var priorAssistantTexts: [String] = []
        return turn.items.filter { item in
            guard item.type == .assistantMessage else { return true }
            let shouldRender = shouldRenderAssistantItemBody(
                item.body,
                priorAssistantTexts: priorAssistantTexts,
                persistedAssistantTexts: persistedAssistantTexts
            )
            if shouldRender {
                priorAssistantTexts.append(item.body)
            }
            return shouldRender
        }
    }

    static func completedFinalAssistantItemIDs(in turn: AssistantTurnSnapshot,
                                               renderableItems: [AssistantItem],
                                               persistedAssistantTexts: [String] = []) -> Set<String> {
        guard turn.finished else { return [] }
        let assistantItems = renderableItems.filter { $0.type == .assistantMessage }
        guard !assistantItems.isEmpty else { return [] }
        if let final = turn.finalAssistantMessage,
           !shouldRenderFinalAssistantMessage(turn, persistedAssistantTexts: persistedAssistantTexts) {
            // The final answer is the LAST assistant item that the final text
            // covers — not every assistant item in the turn. A turn can emit many
            // preamble messages ("State:/Action:/…") before the real answer; those
            // must collapse into the Worked disclosure, leaving only the last
            // message as the visible answer. Legacy Grok turns persisted the joined
            // text phases as `final`; accepting the inverse containment keeps their
            // last answer visible without changing new turns. When the last item has
            // already been hidden because it duplicates the persisted answer, no item
            // matches and every preamble correctly demotes to the work log.
            return Set([assistantItems.last {
                assistantText($0.body, matches: final) || assistantText(final, matches: $0.body)
            }?.id].compactMap { $0 })
        }
        if turn.finalAssistantMessage == nil, let final = assistantItems.last {
            return [final.id]
        }
        return []
    }

    static func completedWorkItems(in turn: AssistantTurnSnapshot,
                                   renderableItems: [AssistantItem],
                                   persistedAssistantTexts: [String] = []) -> [AssistantItem] {
        guard turn.finished else { return renderableItems }
        let finalIDs = completedFinalAssistantItemIDs(
            in: turn,
            renderableItems: renderableItems,
            persistedAssistantTexts: persistedAssistantTexts
        )
        return renderableItems.filter { !finalIDs.contains($0.id) }
    }

    static func completedVisibleAssistantItems(in turn: AssistantTurnSnapshot,
                                               renderableItems: [AssistantItem],
                                               persistedAssistantTexts: [String] = []) -> [AssistantItem] {
        guard turn.finished else { return renderableItems }
        let finalIDs = completedFinalAssistantItemIDs(
            in: turn,
            renderableItems: renderableItems,
            persistedAssistantTexts: persistedAssistantTexts
        )
        return renderableItems.filter { finalIDs.contains($0.id) }
    }

    // MARK: Tool-burst grouping
    //
    // A run of >=2 consecutive tool-style items (e.g. a flurry of MCP status polls or
    // file reads) collapses into one "Ran N commands" row the user can expand — instead
    // of flooding the transcript with identical "Ran …" lines. A lone tool call renders
    // inline as before. Non-tool items (assistant text, reasoning, plan, errors) always
    // break a run, so the answer prose is never swallowed into a group.
    enum TurnRenderBlock: Identifiable, Equatable {
        case item(AssistantItem)
        case toolGroup(id: String, items: [AssistantItem])

        var id: String {
            switch self {
            case .item(let item): return "block-item-\(item.id)"
            case .toolGroup(let id, _): return "block-group-\(id)"
            }
        }
    }

    /// Tool-call kinds that are safe to fold into a count. `error`/`review`/`contextCompaction`
    /// are deliberately excluded — they're noteworthy and must stay visible standalone.
    static func isGroupableTool(_ type: AssistantItemType) -> Bool {
        switch type {
        case .tool, .commandExecution, .mcpToolCall, .dynamicToolCall, .collabToolCall, .webSearch, .imageView, .fileChange:
            return true
        case .reasoning, .plan, .assistantMessage, .review, .contextCompaction, .error:
            return false
        }
    }

    static func turnRenderBlocks(_ items: [AssistantItem], groupThreshold: Int = 2) -> [TurnRenderBlock] {
        var blocks: [TurnRenderBlock] = []
        var run: [AssistantItem] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            // Live background/task-wait rows must stay inline: collapsed groups hide
            // Waiting + elapsed + activity strip and reintroduce the "stuck" feel.
            if run.count >= groupThreshold,
               !AgentTimelineItemPresentation.mustKeepToolsUngrouped(run) {
                blocks.append(.toolGroup(id: run[0].id, items: run))
            } else {
                blocks.append(contentsOf: run.map { .item($0) })
            }
            run.removeAll(keepingCapacity: true)
        }
        for item in items {
            if isGroupableTool(item.type) {
                run.append(item)
            } else {
                flushRun()
                blocks.append(.item(item))
            }
        }
        flushRun()
        return blocks
    }

    /// Keep block structure/ids; replace embedded AssistantItem payloads from `items`.
    nonisolated static func rematerializeWorkBlocks(
        _ blocks: [TurnRenderBlock],
        items: [AssistantItem]
    ) -> [TurnRenderBlock] {
        var byId = [String: AssistantItem](minimumCapacity: items.count)
        for item in items { byId[item.id] = item }
        return blocks.map { block in
            switch block {
            case .item(let old):
                return .item(byId[old.id] ?? old)
            case .toolGroup(let id, let oldItems):
                return .toolGroup(id: id, items: oldItems.map { byId[$0.id] ?? $0 })
            }
        }
    }

    /// Prefer append / sealed-prefix reuse when expanded live work only grew a tail.
    /// WHY: full `turnRenderBlocks(settled)` on every stream tick rematerializes O(N) rows.
    static func appendFriendlyCompletedWorkBlocks(
        previousItems: [AssistantItem],
        previousBlocks: [TurnRenderBlock],
        nextItems: [AssistantItem],
        groupThreshold: Int = 2
    ) -> [TurnRenderBlock] {
        let previousIds = previousItems.map(\.id)
        let nextIds = nextItems.map(\.id)
        guard AgentCompletedWorkBlockGrowth.isPrefixStableAppend(
            previousIds: previousIds,
            nextIds: nextIds
        ) else {
            return turnRenderBlocks(nextItems, groupThreshold: groupThreshold)
        }
        if nextIds.count == previousIds.count {
            // Same id sequence: keep block shells, refresh item payloads.
            // Returning previousBlocks verbatim froze body/output for the whole
            // stream (token deltas never change id count).
            guard !previousBlocks.isEmpty, !nextItems.isEmpty else {
                return turnRenderBlocks(nextItems, groupThreshold: groupThreshold)
            }
            return rematerializeWorkBlocks(previousBlocks, items: nextItems)
        }
        // Fast path: pure tool runs collapse to one group/item list — append items only.
        if !nextItems.isEmpty,
           previousItems.allSatisfy({ isGroupableTool($0.type) }),
           nextItems.allSatisfy({ isGroupableTool($0.type) }) {
            if nextItems.count >= groupThreshold {
                return [.toolGroup(id: nextItems[0].id, items: nextItems)]
            }
            if previousBlocks.count == nextItems.count - (nextItems.count - previousItems.count),
               previousItems.count < groupThreshold {
                // Still below group threshold: reuse prior .item shells and append new.
                let newItems = Array(nextItems.dropFirst(previousItems.count))
                return previousBlocks + newItems.map { .item($0) }
            }
            return turnRenderBlocks(nextItems, groupThreshold: groupThreshold)
        }
        let previousGroupable = previousItems.map { isGroupableTool($0.type) }
        let from = AgentCompletedWorkBlockGrowth.rebuildFromItemIndex(
            previousIds: previousIds,
            previousGroupable: previousGroupable,
            nextIds: nextIds
        )
        if from <= 0 {
            return turnRenderBlocks(nextItems, groupThreshold: groupThreshold)
        }
        let sealedItems = Array(previousItems.prefix(from))
        let sealedBlockCount = turnRenderBlockCount(sealedItems, groupThreshold: groupThreshold)
        let sealedBlocks: [TurnRenderBlock]
        if sealedBlockCount == 0 {
            sealedBlocks = []
        } else if sealedBlockCount <= previousBlocks.count {
            // Refresh payloads on sealed shells too (state/output may settle).
            sealedBlocks = rematerializeWorkBlocks(
                Array(previousBlocks.prefix(sealedBlockCount)),
                items: nextItems
            )
        } else {
            return turnRenderBlocks(nextItems, groupThreshold: groupThreshold)
        }
        let tail = Array(nextItems.suffix(from: from))
        return sealedBlocks + turnRenderBlocks(tail, groupThreshold: groupThreshold)
    }

    /// F2: the per-turn data `turnView` needs, computed once instead of re-deriving
    /// `renderableItems` / `completedFinalAssistantItemIDs` (twice) / block grouping /
    /// plan filtering on every SwiftUI body pass. Pure value so it can be memoized for
    /// immutable (finished) turns and unit-tested against the prior inline logic.
    struct TurnRenderInputs: Equatable {
        var turnPlans: [AssistantProposedPlan]
        var visibleBlocks: [TurnRenderBlock]
        var completedWorkBlocks: [TurnRenderBlock]
        /// Block count for the collapsed "Work so far" label — available even when
        /// `completedWorkBlocks` is empty (lazy: full blocks only when expanded).
        var completedWorkBlockCount: Int
        var hiddenLiveItemCount: Int
        var shouldRenderFinal: Bool
        /// Settled/work source items when expanded (for append-friendly cache). Empty when collapsed.
        var expandedWorkSourceItems: [AssistantItem] = []
    }

    static func computeTurnRenderInputs(turn: AssistantTurnSnapshot,
                                        persistedAssistantTexts: [String],
                                        proposedPlans allPlans: [AssistantProposedPlan],
                                        running: Bool,
                                        expandCompletedWork: Bool = false,
                                        followUpWorkAnchorMs: Int64? = nil,
                                        previousExpandedWorkItems: [AssistantItem]? = nil,
                                        previousExpandedWorkBlocks: [TurnRenderBlock]? = nil) -> TurnRenderInputs {
        let turnPlans = allPlans.filter {
            $0.turnId == turn.turnId && !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Chat follow-up: only items that started at/after the newest user message
        // paint under that bubble. Long provider turns often keep prior tools in
        // the same turnId — without this filter "Work so far · N steps" re-shows
        // the previous task under the new prompt.
        let rawRenderable = renderableItems(in: turn, persistedAssistantTexts: persistedAssistantTexts)
            .filter { !($0.type == .plan && !turnPlans.isEmpty) }
        let renderable = itemsAfterFollowUpAnchor(rawRenderable, anchorMs: followUpWorkAnchorMs)
        // Chat composition (macOS ↔ iOS parity): user → Work so far (ALL non-final) → final only.
        // Live: no tool/group rows outside the disclosure (active tail no longer leaks).
        let finalIDs = turn.finished
            ? completedFinalAssistantItemIDs(in: turn, renderableItems: renderable, persistedAssistantTexts: persistedAssistantTexts)
            : []
        let split = AgentTurnChatComposition.splitItems(
            renderable,
            turnFinished: turn.finished,
            isFinalItem: { finalIDs.contains($0.id) }
        )
        // Live body caps keep expanded Work so far paint cheap without leaving rows outside.
        let workSourceItems: [AssistantItem] = {
            guard !turn.finished, running else { return split.work }
            return split.work.map(liveRenderableCopy)
        }()
        let workCount = turnRenderBlockCount(split.work)
        let shouldBuild = AgentCompletedWorkPresentation.shouldBuildBlocks(
            expandCompletedWork: expandCompletedWork,
            workItemCount: workCount
        )
        let workBlocks: [TurnRenderBlock]
        if shouldBuild {
            if !turn.finished,
               let prevItems = previousExpandedWorkItems,
               let prevBlocks = previousExpandedWorkBlocks {
                workBlocks = appendFriendlyCompletedWorkBlocks(
                    previousItems: prevItems,
                    previousBlocks: prevBlocks,
                    nextItems: workSourceItems
                )
            } else {
                workBlocks = turnRenderBlocks(workSourceItems)
            }
        } else {
            workBlocks = []
        }
        // Outside the disclosure: final assistant item(s) only (finished). Live: empty.
        let visibleBlocks = turn.finished ? turnRenderBlocks(split.outside) : []
        let shouldRenderFinal = turn.finished
            && turn.finalAssistantMessage != nil
            && shouldRenderFinalAssistantMessage(turn, persistedAssistantTexts: persistedAssistantTexts)
            && !(followUpWorkAnchorMs != nil && renderable.isEmpty && split.work.isEmpty)
        return TurnRenderInputs(
            turnPlans: turnPlans,
            visibleBlocks: visibleBlocks,
            completedWorkBlocks: workBlocks,
            completedWorkBlockCount: workCount,
            hiddenLiveItemCount: 0,
            shouldRenderFinal: shouldRenderFinal,
            expandedWorkSourceItems: shouldBuild ? workSourceItems : []
        )
    }

    /// Count twin of `turnRenderBlocks` — same grouping + live-wait ungroup rules.
    static func turnRenderBlockCount(_ items: [AssistantItem], groupThreshold: Int = 2) -> Int {
        var count = 0
        var run: [AssistantItem] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count >= groupThreshold,
               !AgentTimelineItemPresentation.mustKeepToolsUngrouped(run) {
                count += 1
            } else {
                count += run.count
            }
            run.removeAll(keepingCapacity: true)
        }
        for item in items {
            if isGroupableTool(item.type) {
                run.append(item)
            } else {
                flushRun()
                count += 1
            }
        }
        flushRun()
        return count
    }

    /// Split a live turn into settled work (already done — collapse) vs the active
    /// tail the user needs to see right now (streaming + short open context).
    /// Pure + testable. Finished turns never call this.
    nonisolated static func partitionLiveTurnItems(
        _ items: [AssistantItem],
        activeTailLimit: Int = liveTurnActiveTailLimit
    ) -> (settled: [AssistantItem], active: [AssistantItem]) {
        guard !items.isEmpty else { return ([], []) }
        let tailLimit = max(1, activeTailLimit)
        if let lastStreaming = items.lastIndex(where: { $0.state == .streaming }) {
            // Keep a short pre-stream context so the active command/thought has
            // continuity, but fold everything older into the work disclosure.
            let activeStart = max(0, lastStreaming - (tailLimit - 1))
            return (Array(items.prefix(activeStart)), Array(items.suffix(from: activeStart)))
        }
        // Between tools nothing is streaming: keep only the newest tail live so
        // a multi-minute turn does not re-paint every completed command.
        if items.count <= tailLimit {
            return ([], items)
        }
        return (Array(items.dropLast(tailLimit)), Array(items.suffix(tailLimit)))
    }

    /// Collapsed-group header text: count-aware verb + noun, e.g. "Ran 4 commands",
    /// "Changed 3 files", or "Running 2 commands…" while any member is still streaming.
    /// Task-wait members use "Waiting…" so color is not the only live signal.
    static func toolGroupSummary(_ items: [AssistantItem]) -> String {
        AgentChatLiveTurnChrome.toolGroupSummary(items)
    }

    /// Earliest live wait/background member for group-header elapsed (defense in depth).
    static func liveElapsedAnchor(in items: [AssistantItem]) -> AssistantItem? {
        items
            .filter { AgentTimelineItemPresentation.showsLiveToolElapsed(for: $0) }
            .min(by: { $0.startedAtMs < $1.startedAtMs })
    }

    static func toolGroupNoun(_ items: [AssistantItem]) -> String {
        let plural = items.count != 1
        switch Set(items.map(\.type)) {
        case [.fileChange]: return plural ? "files" : "file"
        case [.webSearch]: return plural ? "searches" : "search"
        case [.imageView]: return plural ? "images" : "image"
        default: return plural ? "commands" : "command"
        }
    }

    // AA-20: normalize the (possibly live, possibly > cache limit) LHS ONCE per
    // candidate list instead of once per candidate — the per-candidate variant
    // re-walked a growing streamed body for every persisted assistant message.
    private static func assistantText(_ text: String, matchesAny candidates: [String]) -> Bool {
        guard !candidates.isEmpty else { return false }
        let normalizedLHS = normalizedAssistantText(text)
        guard !normalizedLHS.isEmpty else { return false }
        var compactLHS: String?
        return candidates.contains { rhs in
            let normalizedRHS = normalizedAssistantText(rhs)
            guard !normalizedRHS.isEmpty else { return false }
            if normalizedLHS == normalizedRHS || normalizedLHS.contains(normalizedRHS) { return true }
            if compactLHS == nil { compactLHS = compactAssistantText(text) }
            let compactRHS = compactAssistantText(rhs)
            return compactLHS! == compactRHS || compactLHS!.contains(compactRHS)
        }
    }

    private static func assistantText(_ text: String, equalsAny candidates: [String]) -> Bool {
        guard !candidates.isEmpty else { return false }
        let normalizedLHS = normalizedAssistantText(text)
        guard !normalizedLHS.isEmpty else { return false }
        var compactLHS: String?
        return candidates.contains { rhs in
            let normalizedRHS = normalizedAssistantText(rhs)
            guard !normalizedRHS.isEmpty else { return false }
            if normalizedLHS == normalizedRHS { return true }
            if compactLHS == nil { compactLHS = compactAssistantText(text) }
            return compactLHS! == compactAssistantText(rhs)
        }
    }

    private static func renderableAssistantItemBodies(in turn: AssistantTurnSnapshot, persistedAssistantTexts: [String] = []) -> [String] {
        renderableItems(in: turn, persistedAssistantTexts: persistedAssistantTexts)
            .filter { $0.type == .assistantMessage }
            .map(\.body)
            .filter { !$0.isEmpty }
    }

    private static func assistantText(_ lhs: String, matches rhs: String) -> Bool {
        let normalizedLHS = normalizedAssistantText(lhs)
        let normalizedRHS = normalizedAssistantText(rhs)
        guard !normalizedLHS.isEmpty, !normalizedRHS.isEmpty else { return false }
        let compactLHS = compactAssistantText(lhs)
        let compactRHS = compactAssistantText(rhs)
        return normalizedLHS == normalizedRHS ||
            normalizedLHS.contains(normalizedRHS) ||
            compactLHS == compactRHS ||
            compactLHS.contains(compactRHS)
    }

    private static func assistantText(_ lhs: String, equals rhs: String) -> Bool {
        let normalizedLHS = normalizedAssistantText(lhs)
        let normalizedRHS = normalizedAssistantText(rhs)
        guard !normalizedLHS.isEmpty, !normalizedRHS.isEmpty else { return false }
        return normalizedLHS == normalizedRHS ||
            compactAssistantText(lhs) == compactAssistantText(rhs)
    }

    // PERF-MAC_AGENT-002: collapse whitespace manually over unicode scalars
    // instead of regex; these run for every assistant row on every render, and
    // regex over capped 80k-char bodies dominated the dedup cost. Results are
    // memoized so repeated comparisons of the same body don't re-scan.
    //
    // PERF 2026-08-06: cache eligibility used `text.count` (O(n) grapheme walk)
    // *before* the NSCache lookup. Stream paint re-runs hidden-persisted dedupe
    // on every timelineUpdateTick; warm cache hits still paid a full walk per
    // assistant body. UTF-8 length is O(1) and every grapheme is ≥1 byte, so
    // `utf8 ≤ limit` is a safe under-limit admission for the byte-budgeted cache
    // (slightly more eager to skip cache for multi-byte text — still correct).
    private static let dedupeCacheCharacterLimit = 16_384
    /// Peak entries retained per assistant-text NSCache (normalized + compact).
    /// Was 512; 128 matches other agent window caps (memory-loop tip).
    nonisolated static let assistantTextDedupeCacheCountLimit = 128
    /// Peak UTF-8 cost retained per assistant-text NSCache (normalized + compact).
    /// Was 8 MiB; 128 KiB bounds stream-paint dedupe occupancy (memory-loop tip).
    nonisolated static let assistantTextDedupeCacheCostLimit = 128 * 1024
    private static let normalizedTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = assistantTextDedupeCacheCountLimit
        cache.totalCostLimit = assistantTextDedupeCacheCostLimit
        return cache
    }()
    private static let compactTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = assistantTextDedupeCacheCountLimit
        cache.totalCostLimit = assistantTextDedupeCacheCostLimit
        return cache
    }()

    #if DEBUG
    nonisolated(unsafe) static var normalizedTextCacheComputeCountForTesting: UInt64 = 0
    nonisolated(unsafe) static var compactTextCacheComputeCountForTesting: UInt64 = 0
    static func normalizedAssistantTextForTesting(_ text: String) -> String {
        normalizedAssistantText(text)
    }
    static func compactAssistantTextForTesting(_ text: String) -> String {
        compactAssistantText(text)
    }
    #endif

    private static func normalizedAssistantText(_ text: String) -> String {
        guard text.utf8.count <= dedupeCacheCharacterLimit else {
            return makeNormalizedAssistantText(text)
        }
        let key = AgentMessageMarkdown.cacheKey(for: text)
        if let cached = normalizedTextCache.object(forKey: key) {
            return cached as String
        }
        #if DEBUG
        normalizedTextCacheComputeCountForTesting &+= 1
        #endif
        let out = makeNormalizedAssistantText(text)
        normalizedTextCache.setObject(out as NSString, forKey: key, cost: out.utf8.count)
        return out
    }

    private static func makeNormalizedAssistantText(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.unicodeScalars.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func compactAssistantText(_ text: String) -> String {
        guard text.utf8.count <= dedupeCacheCharacterLimit else {
            return makeCompactAssistantText(text)
        }
        let key = AgentMessageMarkdown.cacheKey(for: text)
        if let cached = compactTextCache.object(forKey: key) {
            return cached as String
        }
        #if DEBUG
        compactTextCacheComputeCountForTesting &+= 1
        #endif
        let out = makeCompactAssistantText(text)
        compactTextCache.setObject(out as NSString, forKey: key, cost: out.utf8.count)
        return out
    }

    private static func makeCompactAssistantText(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    private struct AssistantTextLookup {
        var normalizedIds: [String: Set<AgentMessageID>] = [:]
        var compactIds: [String: Set<AgentMessageID>] = [:]

        init(messages: [AgentMessage]) {
            for message in messages where message.role == .assistant && !message.content.isEmpty {
                normalizedIds[normalizedAssistantText(message.content), default: []].insert(message.id)
                compactIds[compactAssistantText(message.content), default: []].insert(message.id)
            }
        }

        func ids(equalTo text: String) -> Set<AgentMessageID> {
            guard !text.isEmpty else { return [] }
            var ids = normalizedIds[normalizedAssistantText(text)] ?? []
            ids.formUnion(compactIds[compactAssistantText(text)] ?? [])
            return ids
        }
    }

    /// Content key for the view-level hidden-persisted memo.
    ///
    /// Inputs that actually change `hiddenPersistedAssistantMessageIDs` outcomes:
    /// assistant message identity + content digest, and per-turn final /
    /// renderable assistant body content digests (and item ids). Deliberately
    /// omits `timelineUpdateTick` so pure paint ticks with unchanged content
    /// hit cache. Digests are cheap `Hasher` folds over text content — not
    /// UTF-8 length alone — so equal-length replacements (e.g. "alpha"→"bravo")
    /// invalidate the memo and force hide-set recompute.
    nonisolated static func hiddenPersistedAssistantContentKey(
        messages: [AgentMessage],
        timelineTurns: [AssistantTurnSnapshot]
    ) -> String {
        var key = hiddenPersistedMessagesKeyPart(messages: messages)
        key += "|t\(timelineTurns.count)"
        for turn in timelineTurns {
            key += hiddenPersistedTurnKeyPart(turn)
        }
        return key
    }

    nonisolated static func hiddenPersistedMessagesKeyPart(messages: [AgentMessage]) -> String {
        var key = "m\(messages.count)"
        for message in messages {
            if message.role != .assistant { continue }
            key += "|a\(message.id.value.uuidString):\(hiddenPersistedTextDigest(message.content))"
        }
        return key
    }

    nonisolated static func hiddenPersistedTurnKeyPart(_ turn: AssistantTurnSnapshot) -> String {
        var bodyHasher = Hasher()
        var itemIds = ""
        for item in turn.items where item.type == .assistantMessage {
            bodyHasher.combine(item.body)
            if !itemIds.isEmpty { itemIds += "," }
            itemIds += item.id
        }
        let finalDigest = hiddenPersistedTextDigest(turn.finalAssistantMessage ?? "")
        return "|\(turn.turnId):f\(finalDigest):b\(bodyHasher.finalize()):i\(itemIds):fin\(turn.finished ? 1 : 0)"
    }

    /// Within-process content fingerprint for memo keys. Combines full text so
    /// equal-length swaps do not collide (unlike utf8.count alone).
    nonisolated static func hiddenPersistedTextDigest(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }

    static func hiddenPersistedAssistantMessageIDs(messages: [AgentMessage],
                                                   timelineTurns: [AssistantTurnSnapshot]) -> Set<AgentMessageID> {
        let assistantMessages = messages.filter { $0.role == .assistant && !$0.content.isEmpty }
        guard !assistantMessages.isEmpty, !timelineTurns.isEmpty else { return [] }
        let lookup = AssistantTextLookup(messages: assistantMessages)
        var hidden: Set<AgentMessageID> = []
        for turn in timelineTurns {
            let visibleAssistantBodies = renderableAssistantItemBodies(in: turn)
            for body in visibleAssistantBodies {
                hidden.formUnion(lookup.ids(equalTo: body))
            }
            let visibleAssistantText = visibleAssistantBodies.joined(separator: "\n")
            hidden.formUnion(lookup.ids(equalTo: visibleAssistantText))
            if let final = turn.finalAssistantMessage, !final.isEmpty {
                hidden.formUnion(lookup.ids(equalTo: final))
                for message in assistantMessages where assistantText(message.content, matches: final)
                    || assistantText(final, matches: message.content) {
                    hidden.insert(message.id)
                }
            }
        }
        return hidden
    }

    /// Max width for user prompt bubbles. Short text hugs content; long text wraps here.
    /// Kept well under the old 600pt hard fill so chat bubbles stay compact.
    /// Shared with Bots Desk via `AgentChatTranscriptChrome`.
    static let userMessageBubbleMaxWidth: CGFloat = AgentChatTranscriptChrome.userMessageBubbleMaxWidth
    /// Leading spacer so user bubbles stay right-aligned with a readable gutter.
    static let userMessageBubbleLeadingGutter: CGFloat = AgentChatTranscriptChrome.userMessageBubbleLeadingGutter
    /// Floor so a very narrow agent column still shows a usable bubble.
    static let userMessageBubbleMinWidth: CGFloat = AgentChatTranscriptChrome.userMessageBubbleMinWidth

    /// Flexible bubble cap for the current transcript column.
    /// Long prompts wrap at this width; short prompts still hug via `fixedSize`.
    /// Never exceeds `userMessageBubbleMaxWidth`, and never exceeds the column
    /// minus the leading gutter — prevents the bubble + copy/timestamp meta from
    /// painting over the timeline edge and adjacent chrome.
    static func userMessageBubbleWidthCap(columnWidth: CGFloat) -> CGFloat {
        AgentChatTranscriptChrome.userMessageBubbleWidthCap(columnWidth: columnWidth)
    }
    nonisolated static let runningTranscriptContextSlack: TimeInterval = 2
    // PERF-MAC_AGENT-023: idle/completed threads render their transcript in an
    // eager (non-Lazy) VStack, so a very long thread re-builds and re-lays-out the
    // whole history on every routine invalidation (focus, hover, scroll, the
    // one-shot completion tick) — pathologically slow on huge threads. Bound the
    // idle render to a recent tail, mirroring the running-state window; the older
    // slice stays one tap away via the existing "earlier transcript items" reveal.
    nonisolated static let idleTranscriptWindowCount = 20
    /// Very small histories stay mounted. Lazy rematerialization of tall,
    /// self-sizing NSTextView rows can cycle in AttributeGraph during scroll.
    nonisolated static let eagerTranscriptHistoryEntryLimit =
        AgentChatTimelineHistoryLayout.eagerEntryLimit
    nonisolated static let hiddenTranscriptRevealPageCount = 50
    static let liveTurnRenderableItemLimit = 48
    /// How many trailing items stay expanded while a turn is still running.
    /// Everything older folds into the "Work so far" disclosure so Thought-
    /// interleaved tool storms read like a chat, not a full command log.
    static let liveTurnActiveTailLimit = 3
    static let liveTurnBodyCharacterLimit = 2_000
    static let liveTurnOutputCharacterLimit = 1_500
    static let liveTurnSummaryCharacterLimit = 240
    static let commandPreviewCharacterLimit = 1_200

    /// User bubbles show the full stored prompt. Layout wraps long lines and
    /// grows vertically with content — no character or line-count truncation.
    static func userMessageDisplayText(_ text: String) -> String {
        text
    }

    static func messagedPeer(in text: String, bots: [BotDefinition]) -> BotDefinition? {
        let peers = messagedPeers(in: text, bots: bots)
        return peers.count == 1 ? peers.first : nil
    }

    static func messagedPeers(in text: String, bots: [BotDefinition]) -> [BotDefinition] {
        guard !BotPeerTranscript.isHostHopUserText(text) else { return [] }
        return BotMentionParser.mentionedBots(in: text, bots: bots, excluding: nil)
    }

    nonisolated static func isInternalPeerHopUserMessage(_ message: AgentMessage) -> Bool {
        guard message.role == .user else { return false }
        return BotPeerTranscript.isHostHopUserText(message.content)
    }

    static func resolvedPeerAvatarSymbol(
        handle: String,
        encoded: String,
        bots: [BotDefinition]
    ) -> String? {
        if !encoded.isEmpty { return encoded }
        return bots.first {
            $0.handle.caseInsensitiveCompare(handle) == .orderedSame
        }?.avatarSymbol
    }

    static func mentionedCaption(in text: String, bots: [BotDefinition]) -> String? {
        guard let bot = messagedPeer(in: text, bots: bots) else { return nil }
        return BotPeerTranscript.mentionedCaption(for: bot)
    }

    /// Visible-text check without allocating a trimmed copy.
    /// `collapseAllCompletedWorkOnFinalIfNeeded` runs on every
    /// `timelineUpdateTick` (~30 Hz) and used to `trimmingCharacters`
    /// every finished answer, including already-collapsed turns.
    nonisolated static func finalAssistantHasVisibleText(_ text: String?) -> Bool {
        guard let text else { return false }
        for scalar in text.unicodeScalars {
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        }
        return false
    }

    /// Rebuilds the finished-turn set from the live timeline (so pruned
    /// turns drop out) without rescanning already-known finals.
    /// Stream flushes (~30 Hz) usually add tokens to a still-live turn:
    /// reuse `previouslyKnown` so we do not allocate a new Set of every
    /// finished turn id on each flush.
    nonisolated static func completedWorkTurnIds(
        turns: [AssistantTurnSnapshot],
        previouslyKnown: Set<String>
    ) -> (ids: Set<String>, hasNewlyFinished: Bool) {
        var hasNewlyFinished = false
        var knownStillPresent = 0
        for turn in turns {
            if previouslyKnown.contains(turn.turnId) {
                knownStillPresent += 1
                continue
            }
            if turn.finished || finalAssistantHasVisibleText(turn.finalAssistantMessage) {
                hasNewlyFinished = true
            }
        }
        if !hasNewlyFinished && knownStillPresent == previouslyKnown.count {
            return (previouslyKnown, false)
        }
        var ids = Set<String>()
        ids.reserveCapacity(turns.count)
        for turn in turns {
            if previouslyKnown.contains(turn.turnId)
                || turn.finished
                || finalAssistantHasVisibleText(turn.finalAssistantMessage) {
                ids.insert(turn.turnId)
            }
        }
        return (ids, hasNewlyFinished)
    }

    /// Cap live-render text to the first `limit` graphemes (head window).
    ///
    /// PERF: `text.count` is an O(n) grapheme walk paid on every live-render copy
    /// during streaming paint (~30 Hz via `timelineUpdateTick`). Long tool bodies
    /// and reasoning streams can hold up to `liveTextLimit` (200k) bytes in the
    /// timeline while the view only needs the first 2k characters. Use the same
    /// F11 insight as `AssistantTimelineState.cappedText`: `utf8.count` is O(1)
    /// and every grapheme is ≥1 UTF-8 byte, so `utf8 ≤ limit` ⇒ `count ≤ limit`.
    /// Over the byte budget, end-relative / start-relative index arithmetic is
    /// O(limit) instead of O(n). The "dropped" residual is a UTF-8 byte count —
    /// an exact grapheme delta would need the O(n) walk this avoids — so the
    /// marker reports a formatted size rather than overstating a character count
    /// for multi-byte transcripts.
    static func cappedVisibleText(_ text: String, limit: Int, truncatedLabel: String = "truncated in live view") -> String {
        let limit = max(0, limit)
        guard limit > 0 else { return "" }
        guard text.utf8.count > limit else { return text }
        guard let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex),
              end < text.endIndex else {
            // Grapheme count ≤ limit even though UTF-8 exceeded the budget
            // (multi-byte characters under the grapheme window).
            return text
        }
        let head = text[..<end]
        let dropped = max(1, text.utf8.count - head.utf8.count)
        return "\(head)\n... \(AgentTimelineItemPresentation.truncationSizeLabel(dropped)) more \(truncatedLabel) ..."
    }

    static func cappedOptionalVisibleText(_ text: String?, limit: Int, truncatedLabel: String = "truncated in live view") -> String? {
        guard let text else { return nil }
        return cappedVisibleText(text, limit: limit, truncatedLabel: truncatedLabel)
    }

    static func liveRenderableCopy(_ item: AssistantItem) -> AssistantItem {
        var copy = item
        copy.summary = cappedOptionalVisibleText(copy.summary, limit: liveTurnSummaryCharacterLimit)
        // Streaming: keep the *tail* (latest tokens). Head-capping freezes early
        // text while later tokens rewrite "on top" without the user seeing them
        // (reasoning, assistantMessage, tool body/output).
        if item.state == .streaming {
            copy.body = cappedVisibleTextTail(copy.body, limit: liveTurnBodyCharacterLimit)
            if let output = copy.output {
                copy.output = cappedVisibleTextTail(output, limit: liveTurnOutputCharacterLimit)
            }
        } else {
            copy.body = cappedVisibleText(copy.body, limit: liveTurnBodyCharacterLimit)
            copy.output = cappedOptionalVisibleText(copy.output, limit: liveTurnOutputCharacterLimit)
        }
        return copy
    }

    /// Keep the newest `limit` graphemes (plus a short head-omission marker).
    ///
    /// Same O(n)→O(limit) rationale as `cappedVisibleText` — streaming Thought /
    /// tool bodies grow far past the live window; every paint must not re-scan the
    /// full held body just to decide whether to show the tail.
    static func cappedVisibleTextTail(_ text: String, limit: Int, truncatedLabel: String = "of earlier output truncated in live view") -> String {
        let limit = max(0, limit)
        guard limit > 0 else { return "" }
        guard text.utf8.count > limit else { return text }
        guard let start = text.index(text.endIndex, offsetBy: -limit, limitedBy: text.startIndex),
              start > text.startIndex else {
            return text
        }
        let tail = text[start...]
        let dropped = max(1, text.utf8.count - tail.utf8.count)
        return "... \(AgentTimelineItemPresentation.truncationSizeLabel(dropped)) \(truncatedLabel) ...\n\(tail)"
    }

    static func toolCommandPreview(for item: AssistantItem) -> String? {
        AgentTimelineItemPresentation.toolCommandPreview(for: item)
    }

    static func visibleLiveTurnItems(_ items: [AssistantItem], running: Bool) -> [AssistantItem] {
        guard running else { return items }
        return items.suffix(liveTurnRenderableItemLimit).map(liveRenderableCopy)
    }

    enum TranscriptEntry: Identifiable {
        case message(AgentMessage)
        case turn(AssistantTurnSnapshot)

        var id: String {
            switch self {
            case .message(let message): return "message-\(message.id.value.uuidString)"
            case .turn(let turn): return "turn-\(turn.turnId)"
            }
        }

        var sortTime: TimeInterval {
            switch self {
            case .message(let message):
                return message.createdAt.timeIntervalSince1970
            case .turn(let turn):
                // Anti-disorder: only the **first** item's startedAt counts (append
                // order). Never min() and never "first non-nil later item" — both can
                // jump the key when a later tool arrives or an earlier item's stamp
                // fills in. Fall back to turn.startedAtMs so empty live turns do not
                // sort at epoch 0 (above the user bubble).
                if let started = turn.items.first?.startedAtMs {
                    return TimeInterval(started) / 1000
                }
                if let started = turn.startedAtMs {
                    return TimeInterval(started) / 1000
                }
                return TimeInterval.greatestFiniteMagnitude
            }
        }
    }

    /// Chat paint row: either an untouched transcript entry, or one segment of
    /// a turn that was split around interleaved bot peer messages so the chat
    /// keeps strict arrival order (work → reply → more work → waiting…).
    enum ChatFlowRow: Identifiable {
        case entry(TranscriptEntry)
        case segment(AgentChatTurnSegmentation.TurnSegment)

        var id: String {
            switch self {
            case .entry(let entry): return entry.id
            case .segment(let segment): return segment.rowId
            }
        }
    }

    /// Immutable context derived once for the current transcript paint. Peer
    /// group headers and duplicate-final decisions used to rescan row suffixes
    /// and visible entries independently for every mounted row.
    struct ChatRowPaintContext {
        let peerGroupHeadersByRowID: [String: AgentChatPeerGroupHeader]
        let hideAssistantOutputByTurnId: [String: Bool]

        func peerGroupHeader(for row: ChatFlowRow) -> AgentChatPeerGroupHeader? {
            peerGroupHeadersByRowID[row.id]
        }

        func hidesAssistantOutput(for row: ChatFlowRow) -> Bool {
            switch row {
            case .entry(.turn(let turn)):
                return hideAssistantOutputByTurnId[turn.turnId] ?? false
            case .segment(let segment):
                return hideAssistantOutputByTurnId[segment.snapshot.turnId] ?? false
            case .entry(.message): return false
            }
        }
    }

    /// Only bot-peer chrome interleaves a turn: waiting/needs-attention
    /// activity rows and attributed "From <bot>" replies. Every other message
    /// (user prompts, the turn's own durable final, system rows) ends boundary
    /// collection so the existing order for non-bot threads never changes.
    nonisolated static func messageCanInterleaveTurn(_ message: AgentMessage) -> Bool {
        guard message.role == .assistant else { return false }
        return BotPeerTranscript.parseActivity(message.content) != nil
            || BotPeerTranscript.parse(message.content) != nil
    }

    /// Pure paint mapping: each `.turn` entry is woven with the peer messages
    /// that follow it (until the next turn) at item granularity. Turns without
    /// interleaving boundaries pass through unchanged, so threads with no
    /// bot-to-bot hops paint exactly as before.
    nonisolated static func chatFlowRows(_ entries: [TranscriptEntry]) -> [ChatFlowRow] {
        var rows: [ChatFlowRow] = []
        rows.reserveCapacity(entries.count)
        var index = 0
        while index < entries.count {
            guard case .turn(let turn) = entries[index] else {
                rows.append(.entry(entries[index]))
                index += 1
                continue
            }
            var following: [AgentChatTurnSegmentation.FollowingRow<TranscriptEntry>] = []
            var next = index + 1
            var stopped = false
            while next < entries.count, case .message(let message) = entries[next] {
                let can = !stopped && messageCanInterleaveTurn(message)
                if !can { stopped = true }
                following.append(AgentChatTurnSegmentation.FollowingRow(
                    timeMs: Int64(message.createdAt.timeIntervalSince1970 * 1000),
                    canInterleave: can,
                    row: entries[next]
                ))
                next += 1
            }
            if let woven = AgentChatTurnSegmentation.interleaved(turn: turn, following: following) {
                for element in woven {
                    switch element {
                    case .segment(let segment): rows.append(.segment(segment))
                    case .row(let entry): rows.append(.entry(entry))
                    }
                }
            } else {
                rows.append(.entry(entries[index]))
                for item in following { rows.append(.entry(item.row)) }
            }
            index = next
        }
        return rows
    }

    /// Derive all row-local peer and prior-turn context once per paint input.
    /// Bounded metadata preserves the old contiguous-group and chronological
    /// prior-turn semantics without making every row scan the same input again.
    static func makeChatRowPaintContext(
        rows: [ChatFlowRow],
        visibleEntries: [TranscriptEntry],
        bots: [BotDefinition]
    ) -> ChatRowPaintContext {
        let identities = rows.map { peerHopIdentity(for: $0, bots: bots) }
        var groupHeaders: [String: AgentChatPeerGroupHeader] = [:]
        var index = 0
        while index < rows.count {
            guard let peer = identities[index] else {
                index += 1
                continue
            }
            if index > 0,
               let previous = identities[index - 1],
               previous.handle.caseInsensitiveCompare(peer.handle) == .orderedSame {
                index += 1
                continue
            }
            var end = index + 1
            while end < rows.count,
                  let next = identities[end],
                  next.handle.caseInsensitiveCompare(peer.handle) == .orderedSame {
                end += 1
            }
            if end - index >= 2 {
                groupHeaders[rows[index].id] = AgentChatPeerGroupHeader(
                    hostName: "",
                    hostHandle: "",
                    peerName: peer.name,
                    peerHandle: peer.handle,
                    peerSymbol: peer.symbol,
                    count: end - index,
                    accessibilityIdentifier: "agent.peer.group"
                )
            }
            index = end
        }

        var previousNormalizedFinals = Set<String>()
        previousNormalizedFinals.reserveCapacity(visibleEntries.count)
        var hideAssistantOutputByTurnId: [String: Bool] = [:]
        hideAssistantOutputByTurnId.reserveCapacity(visibleEntries.count)
        for entry in visibleEntries {
            guard case .turn(let turn) = entry else { continue }
            hideAssistantOutputByTurnId[turn.turnId] = AgentChatLiveTurnChrome.shouldHideAssistantOutput(
                turn,
                previousNormalizedFinals: previousNormalizedFinals
            )
            AgentChatLiveTurnChrome.insertNormalizedAssistantFinals(
                from: turn,
                into: &previousNormalizedFinals
            )
        }
        return ChatRowPaintContext(
            peerGroupHeadersByRowID: groupHeaders,
            hideAssistantOutputByTurnId: hideAssistantOutputByTurnId
        )
    }

    /// Returns the ordered slice of `allItems` not present in `visibleWindow`.
    /// These are the older entries hidden while a run is active, available for
    /// read-only audit when the user taps the "N earlier items hidden" row.
    nonisolated static func hiddenTranscriptSlice(
        allItems: [TranscriptEntry],
        visibleWindow: [TranscriptEntry]
    ) -> [TranscriptEntry] {
        let visibleIDs = Set(visibleWindow.map(\.id))
        return allItems.filter { !visibleIDs.contains($0.id) }
    }

    nonisolated static func hiddenTranscriptRevealWindow(
        allItems: [TranscriptEntry],
        visibleWindow: [TranscriptEntry],
        revealCount: Int
    ) -> [TranscriptEntry] {
        guard revealCount > 0 else { return [] }
        return Array(hiddenTranscriptSlice(
            allItems: allItems,
            visibleWindow: visibleWindow
        ).suffix(revealCount))
    }

    /// Count-only path for collapsed history. The reveal row needs only this
    /// number; building the hidden prefix on every composer keystroke scans a
    /// huge completed thread even though the rows are not visible.
    nonisolated static func hiddenTranscriptCount(
        totalCount: Int,
        visibleCount: Int
    ) -> Int {
        max(0, totalCount - visibleCount)
    }

    /// Canonical transcript ordering: ascending by `sortTime`, then by `id` for a
    /// total order (deterministic regardless of sort stability). Message and turn
    /// ids carry distinct prefixes, so two entries never tie on (sortTime, id).
    nonisolated static func transcriptEntryOrdersBefore(_ lhs: TranscriptEntry, _ rhs: TranscriptEntry) -> Bool {
        AgentTranscriptOrder.ordersBefore(
            lhsTime: lhs.sortTime,
            lhsId: lhs.id,
            rhsTime: rhs.sortTime,
            rhsId: rhs.id
        )
    }

    /// Fail-closed paint order: if anything inverted the list, re-sort once.
    nonisolated static func ensuringTranscriptOrder(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        AgentTranscriptOrder.ensuringOrdered(
            entries,
            time: \.sortTime,
            id: \.id
        )
    }

    /// After time-order, force durable finals below their turn's Work so far.
    /// WHY: opening a thread sometimes paints the persisted answer above the work disclosure.
    nonisolated static func ensuringFinalAnswersFollowTurns(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        AgentTranscriptOrder.placingMatchingFinalsAfterTurns(
            entries,
            turnFinalText: { entry in
                guard case .turn(let turn) = entry else { return nil }
                // Prefer explicit final; fall back to last assistant item so
                // hydration rows without finalAssistantMessage still reorder.
                if let final = turn.finalAssistantMessage?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !final.isEmpty {
                    return final
                }
                return turn.items.last(where: { $0.type == .assistantMessage })?.body
            },
            assistantMessageText: { entry in
                if case .message(let message) = entry, message.role == .assistant {
                    return message.content
                }
                return nil
            },
            normalizedText: AgentTranscriptOrder.normalizedFinalText
        )
    }

    /// Single paint-order gate: time order, then final-after-Work-so-far.
    nonisolated static func paintOrderedTranscriptEntries(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        #if DEBUG
        TranscriptPaintOrderedProbe.increment()
        #endif
        return ensuringFinalAnswersFollowTurns(ensuringTranscriptOrder(entries))
    }

    #if DEBUG
    enum TranscriptPaintOrderedProbe {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var count = 0

        static var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        static func reset() {
            lock.lock()
            count = 0
            lock.unlock()
        }

        static func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    enum VisibleTranscriptWindowProbe {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var count = 0

        static var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        static func reset() {
            lock.lock()
            count = 0
            lock.unlock()
        }

        static func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    enum TranscriptRematerializeProbe {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var dictionaryBuilds = 0
        nonisolated(unsafe) private static var liveTurnPatches = 0

        static var dictionaryBuildCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return dictionaryBuilds
        }

        static var liveTurnPatchCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return liveTurnPatches
        }

        static func reset() {
            lock.lock()
            dictionaryBuilds = 0
            liveTurnPatches = 0
            lock.unlock()
        }

        static func incrementDictionaryBuild() {
            lock.lock()
            dictionaryBuilds += 1
            lock.unlock()
        }

        static func incrementLiveTurnPatch() {
            lock.lock()
            liveTurnPatches += 1
            lock.unlock()
        }
    }
    #endif

    /// Conversation-column paint: order the full merged transcript once, then
    /// window and reveal from that ordered list. Do not re-run
    /// `placingMatchingFinalsAfterTurns` on already-ordered subsets.
    nonisolated static func transcriptColumnPaint(
        mergedEntries: [TranscriptEntry],
        status: AgentRunStatus,
        runStartedAt: Date?,
        revealCount: Int,
        alreadyPaintOrdered: Bool = false,
        readingStartID: String? = nil
    ) -> (
        all: [TranscriptEntry],
        visible: [TranscriptEntry],
        paint: [TranscriptEntry]
    ) {
        let allEntries = alreadyPaintOrdered ? mergedEntries : paintOrderedTranscriptEntries(mergedEntries)
        let visible = visibleTranscriptWindow(
            entries: allEntries,
            status: status,
            runStartedAt: runStartedAt,
            readingStartID: readingStartID
        )
        let hiddenCount = hiddenTranscriptCount(
            totalCount: allEntries.count,
            visibleCount: visible.count
        )
        let revealed = min(max(0, revealCount), hiddenCount)
        if revealed > 0 {
            let older = hiddenTranscriptRevealWindow(
                allItems: allEntries,
                visibleWindow: visible,
                revealCount: revealed
            )
            // Visible can be a filtered non-suffix (running / no-user / time-cutoff
            // after matching finals have moved). Concatenating older+visible can
            // put a durable final back above its Work-so-far turn. Select the
            // union by id while keeping allEntries relative order.
            var paintIDs = Set(visible.map(\.id))
            paintIDs.reserveCapacity(visible.count + older.count)
            for entry in older {
                paintIDs.insert(entry.id)
            }
            return (allEntries, visible, allEntries.filter { paintIDs.contains($0.id) })
        }
        return (allEntries, visible, visible)
    }

    /// Only honor `latestLiveTurnId` when it sits in the recent eager tail.
    /// A stale unfinished near the top of a long paint set must not force the
    /// entire Lazy history into the eager path.
    nonisolated static func eagerAnchorTurnId(
        _ entries: [TranscriptEntry],
        latestLiveTurnId: String?,
        maxEagerTail: Int = idleTranscriptWindowCount
    ) -> String? {
        guard let lid = latestLiveTurnId,
              let idx = entries.firstIndex(where: {
                  if case .turn(let turn) = $0 { return turn.turnId == lid && !turn.finished }
                  return false
              }),
              entries.count - idx <= max(1, maxEagerTail)
        else { return nil }
        return lid
    }

    /// Eager suffix for the **current** streaming turn only.
    ///
    /// - Prefer a *recent-tail* `latestLiveTurnId` when unfinished: everything
    ///   from that row to the end is eager (streaming row never inside Lazy).
    /// - Else peel only **trailing** unfinished turns.
    /// history + liveTail == original sequence.
    nonisolated static func splitTrailingLiveTurns(
        _ entries: [TranscriptEntry],
        latestLiveTurnId: String? = nil
    ) -> (history: [TranscriptEntry], liveTail: [TranscriptEntry]) {
        let anchor = eagerAnchorTurnId(entries, latestLiveTurnId: latestLiveTurnId)
        if let lid = anchor,
           let idx = entries.firstIndex(where: {
               if case .turn(let turn) = $0 { return turn.turnId == lid && !turn.finished }
               return false
           }) {
            return (
                Array(entries.prefix(idx)),
                Array(entries.suffix(from: idx))
            )
        }
        // R8: evita O(n²) insert(at:0) no tail de turns vivos (cada insert shifta).
        // Coleta em ordem reversa e reverte uma vez → O(n).
        var end = entries.count
        var revTail: [TranscriptEntry] = []
        revTail.reserveCapacity(4)
        while end > 0 {
            let idx = end - 1
            if case .turn(let turn) = entries[idx], !turn.finished {
                revTail.append(entries[idx])
                end = idx
            } else {
                break
            }
        }
        let liveTail = Array(revTail.reversed())
        return (Array(entries.prefix(end)), liveTail)
    }

    /// User-bubble relative time only needs 1 Hz identity. Passing a fresh
    /// `Date()` into Equatable rows at ~30 Hz remounted timestamps with no
    /// visible copy change inside the same second.
    nonisolated static func relativeTimestampNowBucket(_ now: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.rounded(.down))
    }

    /// Header working strip only cares about the trailing unfinished turn.
    /// Scanning every finished turn's items on ~30 Hz chrome ticks walked the
    /// whole timeline for a bit that cannot be true on completed history.
    nonisolated static func hasStreamingGroupableTools(
        in turns: [AssistantTurnSnapshot]
    ) -> Bool {
        var index = turns.count - 1
        while index >= 0 {
            let turn = turns[index]
            if turn.finished { break }
            if turn.items.contains(where: {
                $0.state == .streaming && isGroupableTool($0.type)
            }) {
                return true
            }
            index -= 1
        }
        return false
    }

    /// F7: build the merged transcript in O(N) by merging two already-ordered
    /// sequences instead of re-sorting the whole thread (O(N log N)) on every
    /// structural change (turn/item/message add) during a run. `messages` are
    /// append-only in createdAt order and `turns` in start order, so each side is
    /// already in canonical order. The message side is verified in O(N); if a
    /// thread ever violates the invariant (e.g. exact-timestamp ties out of id
    /// order) we fall back to a full sort, so the output is ALWAYS identical to the
    /// canonical ordering — only the path that produces it gets cheaper.
    nonisolated static func mergeTranscriptEntries(messages: [AgentMessage],
                                                  turns: [AssistantTurnSnapshot]) -> [TranscriptEntry] {
        let messageEntries = messages.compactMap { message -> TranscriptEntry? in
            guard !isInternalPeerHopUserMessage(message) else { return nil }
            return TranscriptEntry.message(message)
        }
        // Turns are few; sort defensively so the merge precondition always holds.
        let turnEntries = turns.map(TranscriptEntry.turn).sorted(by: transcriptEntryOrdersBefore)
        guard isOrderedByTranscriptOrder(messageEntries) else {
            return (messageEntries + turnEntries).sorted(by: transcriptEntryOrdersBefore)
        }
        return mergeOrderedTranscriptEntries(messageEntries, turnEntries)
    }

    /// True when `entries` is already in canonical transcript order (no adjacent
    /// inversion). O(N), no allocation.
    nonisolated static func isOrderedByTranscriptOrder(_ entries: [TranscriptEntry]) -> Bool {
        guard entries.count > 1 else { return true }
        for i in 1..<entries.count where transcriptEntryOrdersBefore(entries[i], entries[i - 1]) {
            return false
        }
        return true
    }

    /// Standard 2-way merge of two canonically-ordered sequences. Equivalent to
    /// `(a + b).sorted(by: transcriptEntryOrdersBefore)` because there are no
    /// cross-side (sortTime, id) ties (distinct id prefixes) and each input is sorted.
    nonisolated static func mergeOrderedTranscriptEntries(_ a: [TranscriptEntry], _ b: [TranscriptEntry]) -> [TranscriptEntry] {
        var result: [TranscriptEntry] = []
        result.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if transcriptEntryOrdersBefore(b[j], a[i]) {
                result.append(b[j]); j += 1
            } else {
                result.append(a[i]); i += 1
            }
        }
        if i < a.count { result.append(contentsOf: a[i...]) }
        if j < b.count { result.append(contentsOf: b[j...]) }
        return result
    }

    // PERF-MAC_AGENT-001: the merged+sorted transcript is read from `body`, so
    // it recomputed (O(n log n)) on every @Published change — every streaming
    // delta and every keystroke. Memoize it, re-sorting only when the message
    // or turn identities actually change (cheap signature compare).
    private final class TranscriptCache {
        var signature: String?
        var entries: [TranscriptEntry] = []
        var messagesGeneration: UInt64?
        var aggregateBudgetGeneration: UInt64?
        /// AA-21: paint-order permutation (indices into `entries`) keyed by
        /// structure + completion. `paintOrderedTranscriptEntries` runs the
        /// final-after-turn repair, which normalizes every assistant text in the
        /// thread with an O(n²) substring fallback — it must not run per frame.
        var paintKey: String?
        var paintOrder: [Int] = []
    }
    private let transcriptCache = TranscriptCache()

    private var transcriptEntries: [TranscriptEntry] {
        let signature = transcriptSignature
        if transcriptCache.signature == signature {
            // F1: a signature hit only proves the ORDER is unchanged — the signature
            // deliberately ignores item bodies/outputs/states and turn completion so
            // streaming deltas don't re-sort. The cached entries embed VALUE COPIES
            // of the snapshots, so serving them verbatim froze streamed text at
            // the last structural change. Re-materialize payloads from the live
            // collections (shallow O(entries) map, no re-sort). Most messages are
            // append-only, but bot activity deliberately replaces a waiting row
            // with the reply under the same id.
            //
            // CRITICAL: write rematerialized entries BACK into the cache so a turn
            // that completes mid-signature stays baseline-finished and
            // shouldRematerializeTurn stops returning true on every later tick.
            let messagesUnchanged = transcriptCache.messagesGeneration
                == vm.transcriptState.messagesGeneration
            let forceFullPath = transcriptCache.aggregateBudgetGeneration
                != vm.aggregateHotTextBudgetGeneration
            let lastLiveId = vm.timeline.turns.last(where: { !$0.finished })?.turnId
            let refreshed = Self.rematerializedTranscriptEntries(
                cached: transcriptCache.entries,
                messages: vm.messages,
                turns: vm.timeline.turns,
                liveTurnIds: lastLiveId.map { Set([$0]) },
                messagesGenerationUnchanged: messagesUnchanged,
                forceFullPath: forceFullPath
            )
            transcriptCache.entries = refreshed
            transcriptCache.messagesGeneration = vm.transcriptState.messagesGeneration
            transcriptCache.aggregateBudgetGeneration = vm.aggregateHotTextBudgetGeneration
            return refreshed
        }
        let merged = Self.ensuringTranscriptOrder(
            Self.mergeTranscriptEntries(messages: vm.messages, turns: vm.timeline.turns)
        )
        transcriptCache.signature = signature
        transcriptCache.entries = merged
        transcriptCache.messagesGeneration = vm.transcriptState.messagesGeneration
        transcriptCache.aggregateBudgetGeneration = vm.aggregateHotTextBudgetGeneration
        return merged
    }

    /// F1 + large-thread stream path: rewrite mutable cached payloads from the
    /// live collections while preserving cached ORDER.
    ///
    /// - **Unfinished / live turns** always take the live snapshot (streaming
    ///   bodies must not freeze — F1).
    /// - **Finished turns** keep the cached payload unless completion structure
    ///   changed (`finished`, item count, or final text). Token deltas on a live
    ///   turn must not rebuild every finished turn's item tree (O(paint-window)).
    nonisolated static func rematerializedTranscriptEntries(
        cached: [TranscriptEntry],
        messages: [AgentMessage],
        turns: [AssistantTurnSnapshot],
        liveTurnIds: Set<String>? = nil,
        messagesGenerationUnchanged: Bool = false,
        forceFullPath: Bool = false
    ) -> [TranscriptEntry] {
        guard !messages.isEmpty || !turns.isEmpty else { return cached }
        if !forceFullPath,
           messagesGenerationUnchanged,
           let patched = rematerializedLiveTurnOnly(
               cached: cached,
               turns: turns,
               liveTurnIds: liveTurnIds
           ) {
            #if DEBUG
            TranscriptRematerializeProbe.incrementLiveTurnPatch()
            #endif
            return patched
        }
        #if DEBUG
        TranscriptRematerializeProbe.incrementDictionaryBuild()
        #endif
        var messagesById = [AgentMessageID: AgentMessage](minimumCapacity: messages.count)
        for message in messages { messagesById[message.id] = message }
        var turnsById = [String: AssistantTurnSnapshot](minimumCapacity: turns.count)
        for turn in turns { turnsById[turn.turnId] = turn }
        let explicitLive = liveTurnIds
        return cached.map { entry in
            switch entry {
            case .message(let stale):
                return messagesById[stale.id].map(TranscriptEntry.message) ?? entry
            case .turn(let stale):
                guard let live = turnsById[stale.turnId] else { return entry }
                if Self.shouldRematerializeTurn(stale: stale, live: live, liveTurnIds: explicitLive) {
                    return .turn(live)
                }
                return entry
            }
        }
    }

    /// Signature-hit fast path: only the unfinished live turn (or the last
    /// unfinished) is patched. Finished item trees stay the cached copies.
    nonisolated static func rematerializedLiveTurnOnly(
        cached: [TranscriptEntry],
        turns: [AssistantTurnSnapshot],
        liveTurnIds: Set<String>?
    ) -> [TranscriptEntry]? {
        let liveId: String
        if let liveTurnIds {
            guard liveTurnIds.count == 1, let only = liveTurnIds.first else { return nil }
            liveId = only
        } else if let last = turns.last, !last.finished,
                  turns.dropLast().allSatisfy(\.finished) {
            liveId = last.turnId
        } else {
            return nil
        }
        guard let live = turns.first(where: { $0.turnId == liveId }), !live.finished else {
            return nil
        }
        var liveIndex: Int?
        var unfinishedCached = 0
        for (index, entry) in cached.enumerated() {
            guard case .turn(let stale) = entry else { continue }
            if !stale.finished { unfinishedCached += 1 }
            if stale.turnId == liveId { liveIndex = index }
        }
        guard unfinishedCached <= 1, let liveIndex else { return nil }
        var next = cached
        next[liveIndex] = .turn(live)
        return next
    }

    /// Pure gate for stream-tick rematerialization scope.
    nonisolated static func shouldRematerializeTurn(
        stale: AssistantTurnSnapshot,
        live: AssistantTurnSnapshot,
        liveTurnIds: Set<String>? = nil
    ) -> Bool {
        if let liveTurnIds, liveTurnIds.contains(live.turnId) {
            return true
        }
        // Always refresh unfinished turns (streaming body/output/state).
        if !live.finished { return true }
        // Completion transition or structural change on a finished turn.
        if stale.finished != live.finished { return true }
        if stale.items.count != live.items.count { return true }
        if stale.finalAssistantMessage != live.finalAssistantMessage { return true }
        // Stable finished turn: keep cached payload (skip full item-tree copy).
        return false
    }

    /// AA-21: `paintOrderedTranscriptEntries` memoized on (structure signature,
    /// finished-turn count, message count). Token deltas change none of those,
    /// so the order repair — the only O(messages × turns × text) pass left in
    /// the body — runs on structural change only. The permutation is applied
    /// to the freshly rematerialized entries, so bodies never go stale.
    private func paintOrderedTranscriptEntriesCached(_ merged: [TranscriptEntry]) -> [TranscriptEntry] {
        var finishedTurns = 0
        for turn in vm.timeline.turns where turn.finished { finishedTurns += 1 }
        let key = "\(transcriptCache.signature ?? "-")|\(finishedTurns)|\(vm.messages.count)|\(merged.count)"
        if transcriptCache.paintKey == key,
           transcriptCache.paintOrder.count == merged.count,
           transcriptCache.paintOrder.allSatisfy({ $0 < merged.count }) {
            return transcriptCache.paintOrder.map { merged[$0] }
        }
        let ordered = Self.paintOrderedTranscriptEntries(merged)
        var indexById = [String: Int](minimumCapacity: merged.count)
        for (index, entry) in merged.enumerated() { indexById[entry.id] = index }
        let order = ordered.compactMap { indexById[$0.id] }
        if order.count == merged.count, Set(order).count == merged.count {
            transcriptCache.paintKey = key
            transcriptCache.paintOrder = order
        } else {
            transcriptCache.paintKey = nil
            transcriptCache.paintOrder = []
        }
        return ordered
    }

    private func activeBotPeerReviewName(in visibleEntries: [TranscriptEntry]) -> String? {
        guard vm.selectedThreadRunIsStartingOrRunning,
              let runStartedAt = vm.runStartedAt else { return nil }
        var newestUserMessageAt: Date?
        var newestPeerReply: (createdAt: Date, name: String)?
        for entry in visibleEntries {
            guard case .message(let message) = entry else { continue }
            if message.role == .user {
                newestUserMessageAt = message.createdAt
            } else if message.role == .assistant,
                      let reply = BotPeerTranscript.parse(message.content) {
                newestPeerReply = (message.createdAt, reply.name)
            }
        }
        guard let newestUserMessageAt,
              let newestPeerReply,
              newestPeerReply.createdAt >= newestUserMessageAt,
              newestPeerReply.createdAt <= runStartedAt else { return nil }
        return newestPeerReply.name
    }

    /// Keep the same recent history during pending, running and completed states.
    /// A new answer must not hide the question or the preceding conversation.
    nonisolated static func visibleTranscriptWindow(
        entries: [TranscriptEntry],
        status: AgentRunStatus,
        runStartedAt: Date?,
        idleWindowCount: Int = idleTranscriptWindowCount,
        readingStartID: String? = nil
    ) -> [TranscriptEntry] {
        #if DEBUG
        VisibleTranscriptWindowProbe.increment()
        #endif
        let start = max(0, entries.count - max(1, idleWindowCount))
        let readingStart = readingStartID.flatMap { id in entries.firstIndex { $0.id == id } }
        return Array(entries.dropFirst(min(start, readingStart ?? start)))
    }

    nonisolated static func usesLazyTranscriptHistoryLayout(
        entryCount: Int,
        liveTurnActive: Bool = false
    ) -> Bool {
        AgentChatTimelineHistoryLayout.usesLazyLayout(
            entryCount: entryCount,
            liveTurnActive: liveTurnActive
        )
    }

    /// Whether an Active plan belongs to the current follow-up (not a prior turn).
    /// Pure seam used by stream gating and the view paint gate.
    nonisolated static func isActivePlanFreshForFollowUp(
        plan: AssistantActivePlan,
        newestUserMessageAt: Date?,
        runStartedAt: Date?,
        slack: TimeInterval = runningTranscriptContextSlack
    ) -> Bool {
        let planSeconds = TimeInterval(plan.updatedAtMs) / 1000
        var anchor: TimeInterval = 0
        if let runStartedAt {
            anchor = max(anchor, runStartedAt.timeIntervalSince1970)
        }
        if let newestUserMessageAt {
            anchor = max(anchor, newestUserMessageAt.timeIntervalSince1970)
        }
        guard anchor > 0 else { return true }
        return planSeconds >= anchor - slack
    }

    /// Chat contract: a fully completed checklist is history, not a live card.
    nonisolated static func activePlanIsFullyCompleted(_ plan: AssistantActivePlan) -> Bool {
        !plan.steps.isEmpty && plan.steps.allSatisfy { $0.status == .completed }
    }

    /// Whether stream/rehydrate may apply this plan while follow-up suppress is on.
    /// Rejects all-done checklists (re-emitted prior plans) and non-fresh timestamps.
    nonisolated static func shouldAcceptActivePlanForFollowUp(
        plan: AssistantActivePlan,
        newestUserMessageAt: Date?,
        runStartedAt: Date?,
        hasQueuedFollowUp: Bool,
        slack: TimeInterval = runningTranscriptContextSlack
    ) -> Bool {
        if hasQueuedFollowUp { return false }
        // A re-stamped all-Done plan is not "a new plan for this message".
        if activePlanIsFullyCompleted(plan) { return false }
        return isActivePlanFreshForFollowUp(
            plan: plan,
            newestUserMessageAt: newestUserMessageAt,
            runStartedAt: runStartedAt,
            slack: slack
        )
    }

    /// View-level paint gate for the inline / sidebar Active plan card.
    /// Chat contract: fully completed plans never paint (they read as the prior
    /// turn's checklist under the new bubble). Incomplete plans only paint when
    /// fresh relative to the follow-up anchor.
    nonisolated static func shouldRenderActivePlan(
        plan: AssistantActivePlan?,
        status: AgentRunStatus,
        runStartedAt: Date?,
        newestUserMessageAt: Date?,
        slack: TimeInterval = runningTranscriptContextSlack
    ) -> Bool {
        guard let plan, !plan.steps.isEmpty else { return false }
        if activePlanIsFullyCompleted(plan) { return false }
        return isActivePlanFreshForFollowUp(
            plan: plan,
            newestUserMessageAt: newestUserMessageAt,
            runStartedAt: runStartedAt,
            slack: slack
        )
    }

    /// Items that belong *after* the newest user message (chat follow-up scope).
    /// Drops prior-turn tools that still live in a long-lived provider turn blob
    /// so "Work so far · N steps" only counts work since the user spoke.
    nonisolated static func itemsAfterFollowUpAnchor(
        _ items: [AssistantItem],
        anchorMs: Int64?
    ) -> [AssistantItem] {
        guard let anchorMs else { return items }
        return items.filter { $0.startedAtMs >= anchorMs }
    }

    /// Milliseconds cutoff for post-user-message work. `nil` when not in a live
    /// follow-up (idle history keeps full turn content).
    nonisolated static func followUpWorkAnchorMs(
        status: AgentRunStatus,
        newestUserMessageAt: Date?,
        slack: TimeInterval = runningTranscriptContextSlack
    ) -> Int64? {
        guard status == .running || status == .pending else { return nil }
        guard let newestUserMessageAt else { return nil }
        let seconds = newestUserMessageAt.timeIntervalSince1970 - slack
        return Int64(seconds * 1000)
    }

    /// Cheap identity signature: changes only when a message/turn is added,
    /// removed, or reordered, not on streaming text deltas. O(turns), NOT O(messages):
    /// the full thread loads append-only (new sends land at the end), so the message
    /// side collapses to count + first/last id — capturing every add/remove/revert
    /// without walking all N messages on every body eval (critical now that N is the
    /// whole thread, not a 30-row window).
    ///
    /// Extracted as `nonisolated static` so it is testable without a view context and
    /// shared by every consumer in a single body pass through `SignatureCache`.
    nonisolated static func buildTranscriptSignature(messages: [AgentMessage],
                                                     turns: [AssistantTurnSnapshot]) -> String {
        var sig = "m\(messages.count)|\(messages.first?.id.value.uuidString ?? "-")|\(messages.last?.id.value.uuidString ?? "-")|t\(turns.count)|"
        for turn in turns {
            sig += turn.turnId
            // A turn's sortTime derives from its items' min startedAtMs; fold item count
            // in so the sort refreshes on item add (not on pure text deltas).
            sig += "#\(turn.items.count)"
        }
        return sig
    }

    /// F40: order-sensitive, non-cancelling fold of per-turn item counts. The previous
    /// XOR fold cancelled for equal-count turns (h ^ h == 0), so a flush in which two
    /// equal-count turns each gained an item ({c,c} -> {c+1,c+1}) left the hash — and
    /// therefore the cached signature and the stale transcript merge — unchanged.
    nonisolated static func turnItemCountsHash(_ turns: [AssistantTurnSnapshot]) -> Int {
        var hasher = Hasher()
        for turn in turns { hasher.combine(turn.items.count) }
        return hasher.finalize()
    }

    // PERF-MAC_AGENT-011: cache the signature string so a single SwiftUI body
    // pass computes it only once regardless of how many consumers read it.
    private final class SignatureCache {
        var lastMessages: Int = -1
        var lastFirstId: String = ""
        var lastLastId: String = ""
        var lastTurnsCount: Int = -1
        var lastTurnsItemCountsHash: Int = 0
        var cached: String = ""
    }
    private let signatureCache = SignatureCache()

    private var transcriptSignature: String {
        let msgCount = vm.messages.count
        let firstId = vm.messages.first?.id.value.uuidString ?? "-"
        let lastId = vm.messages.last?.id.value.uuidString ?? "-"
        let turnCount = vm.timeline.turns.count
        // Cheap hash of per-turn item counts — changes when an item is added to any turn.
        let itemCountsHash = Self.turnItemCountsHash(vm.timeline.turns)
        let c = signatureCache
        if c.lastMessages == msgCount && c.lastFirstId == firstId && c.lastLastId == lastId
            && c.lastTurnsCount == turnCount && c.lastTurnsItemCountsHash == itemCountsHash {
            return c.cached
        }
        let sig = Self.buildTranscriptSignature(messages: vm.messages, turns: vm.timeline.turns)
        c.lastMessages = msgCount; c.lastFirstId = firstId; c.lastLastId = lastId
        c.lastTurnsCount = turnCount; c.lastTurnsItemCountsHash = itemCountsHash
        c.cached = sig
        return sig
    }

    // Memoized on a message-only key so it recomputes only when a message is
    // appended/removed (human-paced) — NOT on every streaming tool call, and NOT
    // O(messages) per visible turn render.
    private final class AssistantTextsCache {
        var key: String?
        var texts: [String] = []
    }
    private let assistantTextsCache = AssistantTextsCache()

    /// F2: memoize `makeChatRowPaintContext` across chrome-only / paint-tick
    /// body passes when `contentGeneration` and row/visible counts match.
    /// Tool-body-only timeline publishes keep generation stable; skip the
    /// bot-identity signature string on that hit path.
    private final class ChatRowPaintContextCache {
        var generation: UInt64 = 0
        var botsRevision: UInt64 = 0
        var signature: String = ""
        var rowCount: Int = -1
        var visibleCount: Int = -1
        var context: ChatRowPaintContext?
    }
    private let chatRowPaintContextCache = ChatRowPaintContextCache()

    /// Snapshot `mentionableBotsProvider` once per transcript/catalog revision
    /// for header + transcript column. Composer `@` stays live on the provider.
    private final class MentionableBotsSnapshotCache {
        var generation: UInt64 = 0
        var botsRevision: UInt64 = 0
        var bots: [BotDefinition] = []
        var hasValue = false
    }
    private let mentionableBotsSnapshotCache = MentionableBotsSnapshotCache()

    /// Memoize finished-history `chatFlowRows` across chrome-only / paint-tick
    /// bodies. The live suffix is never cached: a content hash that would keep
    /// it honest walks the tool text and measured slower than rebuilding the
    /// rows, which share the existing strings. Split is skipped when the
    /// paint-sequence ends and live-turn id match the previous pass.
    private final class ChatFlowPaintCache {
        var generation: UInt64 = 0
        var aggregateBudgetGeneration: UInt64 = 0
        var count: Int = -1
        var firstId: String?
        var lastId: String?
        var paintCount: Int = -1
        var paintFirstId: String?
        var paintLastId: String?
        var latestLiveTurnId: String?
        var splitIndex: Int = -1
        var historyRows: [ChatFlowRow] = []
        var hasValue = false
    }
    private let chatFlowPaintCache = ChatFlowPaintCache()
    #if DEBUG
    /// Test-only: uncached `makeChatRowPaintContext` invocations.
    static nonisolated(unsafe) var chatRowPaintContextComputeCountForTesting: UInt64 = 0
    /// Test-only: `chatRowPaintContextSignature` allocations.
    static nonisolated(unsafe) var chatRowPaintContextSignatureBuilderCountForTesting: UInt64 = 0
    /// Test-only: provider calls from the generation-gated bots snapshot.
    static nonisolated(unsafe) var mentionableBotsSnapshotProviderCallCountForTesting: UInt64 = 0
    /// Test-only: uncached history `chatFlowRows` invocations.
    static nonisolated(unsafe) var chatFlowPaintComputeCountForTesting: UInt64 = 0
    /// Test-only: live-tail `chatFlowRows` invocations (always, so progress stays fresh).
    static nonisolated(unsafe) var chatFlowPaintLiveComputeCountForTesting: UInt64 = 0
    /// Test-only: `splitTrailingLiveTurns` invocations from cached paint.
    static nonisolated(unsafe) var chatFlowPaintSplitCountForTesting: UInt64 = 0
    #endif

    /// Signature for F2 paint-context reuse. Includes every bot identity field
    /// consumed by peer-header derivation (handle/name/symbol), not just ends.
    nonisolated static func chatRowPaintContextSignature(
        generation: UInt64,
        rows: [ChatFlowRow],
        visibleEntries: [TranscriptEntry],
        bots: [BotDefinition]
    ) -> String {
        var signature = "\(generation)|\(rows.count)|\(visibleEntries.count)|\(bots.count)"
        if let first = rows.first?.id { signature += "|r0:\(first)" }
        if let last = rows.last?.id { signature += "|rN:\(last)" }
        if let first = visibleEntries.first?.id { signature += "|v0:\(first)" }
        if let last = visibleEntries.last?.id { signature += "|vN:\(last)" }
        for bot in bots {
            signature += "|b:\(bot.handle)|\(bot.name)|\(bot.avatarSymbol)"
        }
        return signature
    }

    private func cachedChatRowPaintContext(
        rows: [ChatFlowRow],
        visibleEntries: [TranscriptEntry],
        bots: [BotDefinition]
    ) -> ChatRowPaintContext {
        let generation = vm.transcriptState.contentGeneration
        let botsRevision = vm.mentionableBotsRevisionProvider()
        // Rank 4: matching transcript/catalog revisions + row/visible counts
        // returns before `chatRowPaintContextSignature` (no bot-string alloc).
        if chatRowPaintContextCache.generation == generation,
           chatRowPaintContextCache.botsRevision == botsRevision,
           chatRowPaintContextCache.rowCount == rows.count,
           chatRowPaintContextCache.visibleCount == visibleEntries.count,
           let cached = chatRowPaintContextCache.context {
            return cached
        }
        #if DEBUG
        Self.chatRowPaintContextSignatureBuilderCountForTesting &+= 1
        #endif
        let signature = Self.chatRowPaintContextSignature(
            generation: generation,
            rows: rows,
            visibleEntries: visibleEntries,
            bots: bots
        )
        if chatRowPaintContextCache.generation == generation,
           chatRowPaintContextCache.botsRevision == botsRevision,
           chatRowPaintContextCache.signature == signature,
           let cached = chatRowPaintContextCache.context {
            chatRowPaintContextCache.rowCount = rows.count
            chatRowPaintContextCache.visibleCount = visibleEntries.count
            return cached
        }
        #if DEBUG
        Self.chatRowPaintContextComputeCountForTesting &+= 1
        #endif
        let context = Self.makeChatRowPaintContext(
            rows: rows,
            visibleEntries: visibleEntries,
            bots: bots
        )
        chatRowPaintContextCache.generation = generation
        chatRowPaintContextCache.botsRevision = botsRevision
        chatRowPaintContextCache.signature = signature
        chatRowPaintContextCache.rowCount = rows.count
        chatRowPaintContextCache.visibleCount = visibleEntries.count
        chatRowPaintContextCache.context = context
        return context
    }

    private func snapshotMentionableBots() -> [BotDefinition] {
        let generation = vm.transcriptState.contentGeneration
        let botsRevision = vm.mentionableBotsRevisionProvider()
        if mentionableBotsSnapshotCache.hasValue,
           mentionableBotsSnapshotCache.generation == generation,
           mentionableBotsSnapshotCache.botsRevision == botsRevision {
            return mentionableBotsSnapshotCache.bots
        }
        #if DEBUG
        Self.mentionableBotsSnapshotProviderCallCountForTesting &+= 1
        #endif
        let bots = vm.mentionableBotsProvider()
        mentionableBotsSnapshotCache.generation = generation
        mentionableBotsSnapshotCache.botsRevision = botsRevision
        mentionableBotsSnapshotCache.bots = bots
        mentionableBotsSnapshotCache.hasValue = true
        return bots
    }

    private func cachedChatFlowPaint(
        paintSequence: [TranscriptEntry],
        latestLiveTurnId: String?
    ) -> (historyRows: [ChatFlowRow], liveRows: [ChatFlowRow], allRows: [ChatFlowRow]) {
        let generation = vm.transcriptState.contentGeneration
        let aggregateBudgetGeneration = vm.aggregateHotTextBudgetGeneration
        let paintCount = paintSequence.count
        let paintFirstId = paintSequence.first?.id
        let paintLastId = paintSequence.last?.id
        let splitIndex: Int
        let historyEntries: [TranscriptEntry]
        let liveEntries: [TranscriptEntry]
        if chatFlowPaintCache.hasValue,
           chatFlowPaintCache.generation == generation,
           chatFlowPaintCache.aggregateBudgetGeneration == aggregateBudgetGeneration,
           chatFlowPaintCache.paintCount == paintCount,
           chatFlowPaintCache.paintFirstId == paintFirstId,
           chatFlowPaintCache.paintLastId == paintLastId,
           chatFlowPaintCache.latestLiveTurnId == latestLiveTurnId,
           chatFlowPaintCache.splitIndex >= 0,
           chatFlowPaintCache.splitIndex <= paintCount {
            splitIndex = chatFlowPaintCache.splitIndex
            historyEntries = []
            liveEntries = []
        } else {
            #if DEBUG
            Self.chatFlowPaintSplitCountForTesting &+= 1
            #endif
            let split = Self.splitTrailingLiveTurns(
                paintSequence,
                latestLiveTurnId: latestLiveTurnId
            )
            splitIndex = split.history.count
            historyEntries = split.history
            liveEntries = split.liveTail
            chatFlowPaintCache.paintCount = paintCount
            chatFlowPaintCache.paintFirstId = paintFirstId
            chatFlowPaintCache.paintLastId = paintLastId
            chatFlowPaintCache.latestLiveTurnId = latestLiveTurnId
            chatFlowPaintCache.splitIndex = splitIndex
        }
        let historySlice = paintSequence.prefix(splitIndex)
        let liveSlice = paintSequence.suffix(from: splitIndex)
        let count = splitIndex
        let firstId = historySlice.first?.id
        let lastId = historySlice.last?.id
        let historyRows: [ChatFlowRow]
        if chatFlowPaintCache.hasValue,
           chatFlowPaintCache.generation == generation,
           chatFlowPaintCache.aggregateBudgetGeneration == aggregateBudgetGeneration,
           chatFlowPaintCache.count == count,
           chatFlowPaintCache.firstId == firstId,
           chatFlowPaintCache.lastId == lastId {
            historyRows = chatFlowPaintCache.historyRows
        } else {
            #if DEBUG
            Self.chatFlowPaintComputeCountForTesting &+= 1
            #endif
            // Chat flow: weave each turn with the bot peer rows that arrived
            // mid-turn. The split boundary never cuts a turn from its following
            // messages, so mapping each side independently equals the whole.
            historyRows = Self.chatFlowRows(
                historyEntries.isEmpty ? Array(historySlice) : historyEntries
            )
            chatFlowPaintCache.generation = generation
            chatFlowPaintCache.aggregateBudgetGeneration = aggregateBudgetGeneration
            chatFlowPaintCache.count = count
            chatFlowPaintCache.firstId = firstId
            chatFlowPaintCache.lastId = lastId
            chatFlowPaintCache.historyRows = historyRows
            chatFlowPaintCache.hasValue = true
        }
        guard splitIndex < paintCount else {
            return (historyRows, [], historyRows)
        }
        #if DEBUG
        Self.chatFlowPaintLiveComputeCountForTesting &+= 1
        #endif
        // Do not memoize. Tool progress, summary, and same-length rewrites must
        // paint on the next tick, and hashing the bodies to detect that was
        // slower than this weave on a ~1 MB tail.
        let liveRows = Self.chatFlowRows(
            liveEntries.isEmpty ? Array(liveSlice) : liveEntries
        )
        return (historyRows, liveRows, historyRows + liveRows)
    }

    #if DEBUG
    /// Test seam for F2 cache hit/miss counters.
    func cachedChatRowPaintContextForTesting(
        rows: [ChatFlowRow],
        visibleEntries: [TranscriptEntry],
        bots: [BotDefinition]
    ) -> ChatRowPaintContext {
        cachedChatRowPaintContext(rows: rows, visibleEntries: visibleEntries, bots: bots)
    }

    func snapshotMentionableBotsForTesting() -> [BotDefinition] {
        snapshotMentionableBots()
    }

    func cachedChatFlowPaintForTesting(
        paintSequence: [TranscriptEntry],
        latestLiveTurnId: String?
    ) -> (historyRows: [ChatFlowRow], liveRows: [ChatFlowRow], allRows: [ChatFlowRow]) {
        cachedChatFlowPaint(paintSequence: paintSequence, latestLiveTurnId: latestLiveTurnId)
    }
    #endif

    // F2: per-turn render data, memoized for FINISHED turns (immutable content) so a
    // long completed thread no longer re-derives renderableItems / final-id splitting /
    // block grouping / plan filtering for every visible turn on every body pass. Keyed
    // per turnId; an entry is replaced when its signature changes. Running turns are
    // never cached (their content changes each delta) — they compute fresh.
    private final class TurnRenderCache {
        var entries: [String: (signature: String, value: TurnRenderInputs)] = [:]
    }
    private let turnRenderCache = TurnRenderCache()
    #if DEBUG
    // Test-only: counts how many times the uncached per-turn computation ran, so a
    // unit test can prove finished turns are served from cache across body passes.
    static nonisolated(unsafe) var turnRenderComputeCountForTesting = 0
    #endif

    /// Append cache for expanded live work so stream ticks append rather than full re-tree.
    /// Held in `@State` so the reference survives SwiftUI body re-evals.
    private final class ExpandedLiveWorkCache {
        var turnId: String?
        var items: [AssistantItem] = []
        var blocks: [TurnRenderBlock] = []
        func clear() {
            turnId = nil
            items = []
            blocks = []
        }
    }
    @State private var expandedLiveWorkCache = ExpandedLiveWorkCache()

    private var latestLiveWorkTurnId: String? {
        vm.timeline.turns.last(where: { !$0.finished })?.turnId
    }

    private func isCompletedWorkExpanded(for turn: AssistantTurnSnapshot) -> Bool {
        let latest = latestLiveWorkTurnId
        return AgentCompletedWorkExpandPolicy.isExpanded(
            isLive: !turn.finished,
            isLatestLiveTurn: latest == turn.turnId,
            userExplicitlyExpanded: expandedCompletedWorkTurns.contains(turn.turnId),
            userCollapsedWhileLive: userCollapsedLiveWorkTurns.contains(turn.turnId)
        )
    }

    private func toggleCompletedWork(for turn: AssistantTurnSnapshot) {
        let latest = latestLiveWorkTurnId
        let currently = isCompletedWorkExpanded(for: turn)
        let result = AgentCompletedWorkExpandPolicy.toggle(
            turnId: turn.turnId,
            currentlyExpanded: currently,
            isLive: !turn.finished,
            isLatestLiveTurn: latest == turn.turnId,
            userExpanded: expandedCompletedWorkTurns,
            userCollapsedLive: userCollapsedLiveWorkTurns
        )
        expandedCompletedWorkTurns = result.expanded
        userCollapsedLiveWorkTurns = result.collapsedLive
        if !result.expanded.contains(turn.turnId) && !(latest == turn.turnId && !turn.finished && !result.collapsedLive.contains(turn.turnId)) {
            if expandedLiveWorkCache.turnId == turn.turnId {
                expandedLiveWorkCache.clear()
            }
        }
    }

    /// F2: the memoized entry point used by `turnView`. Finished turns are immutable,
    /// so their inputs are cached against a signature that also folds in the external
    /// dependencies (persisted assistant texts + proposed plans). Running/unfinished
    /// turns are computed fresh every pass.
    nonisolated static func finishedTurnRenderSignature(turn: AssistantTurnSnapshot,
                                                        assistantTextsKey: String,
                                                        plansKey: String,
                                                        expandCompletedWork: Bool = false) -> String {
        "\(turn.turnId)|i\(turn.items.count)|\(assistantTextsKey)|pl\(plansKey)|w\(expandCompletedWork ? 1 : 0)"
    }

    /// The message-only key that backs `persistedAssistantTexts`'s memo; reused as the
    /// persisted-texts component of the finished-turn render signature.
    private var assistantTextsKey: String {
        "\(vm.messages.count)|\(vm.messages.last?.id.value.uuidString ?? "-")"
    }

    private final class HiddenPersistedAssistantMessageCache {
        var generation: UInt64?
        var key: String?
        var ids: Set<AgentMessageID> = []
    }
    private let hiddenPersistedAssistantMessageCache = HiddenPersistedAssistantMessageCache()

    /// AA-31: `hiddenPersistedAssistantContentKey` hashed EVERY persisted
    /// assistant message and every turn's assistant bodies on each content
    /// generation — i.e. on every assistant-text delta, O(total transcript
    /// text). Messages only change when `messagesGeneration` moves; finished
    /// turns are immutable in practice (items.count + final length re-key
    /// them). Only the live turn is re-hashed per delta.
    private final class HiddenPersistedContentKeyCache {
        var messagesGeneration: UInt64?
        var messagesPart = ""
        var turnParts: [String: (itemsCount: Int, finalCount: Int, part: String)] = [:]
        var turnPartComputeCount = 0
    }
    private let hiddenPersistedContentKeyCache = HiddenPersistedContentKeyCache()

    private func cachedHiddenPersistedAssistantContentKey() -> String {
        let cache = hiddenPersistedContentKeyCache
        let messagesGeneration = vm.transcriptState.messagesGeneration
        if cache.messagesGeneration != messagesGeneration {
            cache.messagesPart = Self.hiddenPersistedMessagesKeyPart(messages: vm.messages)
            cache.messagesGeneration = messagesGeneration
        }
        let turns = vm.timeline.turns
        var key = cache.messagesPart
        key += "|t\(turns.count)"
        for turn in turns {
            let finalCount = turn.finalAssistantMessage?.utf8.count ?? -1
            if turn.finished,
               let cached = cache.turnParts[turn.turnId],
               cached.itemsCount == turn.items.count,
               cached.finalCount == finalCount {
                key += cached.part
                continue
            }
            let part = Self.hiddenPersistedTurnKeyPart(turn)
            cache.turnPartComputeCount += 1
            if turn.finished {
                cache.turnParts[turn.turnId] = (turn.items.count, finalCount, part)
            }
            key += part
        }
        if cache.turnParts.count > turns.count + 64 {
            let live = Set(turns.map(\.turnId))
            cache.turnParts = cache.turnParts.filter { live.contains($0.key) }
        }
        return key
    }

    private var persistedAssistantTexts: [String] {
        let key = "\(vm.messages.count)|\(vm.messages.last?.id.value.uuidString ?? "-")"
        if assistantTextsCache.key == key { return assistantTextsCache.texts }
        let texts = vm.messages.compactMap { $0.role == .assistant ? $0.content : nil }
        assistantTextsCache.key = key
        assistantTextsCache.texts = texts
        return texts
    }

    private var hiddenPersistedAssistantMessageIDs: Set<AgentMessageID> {
        // R4-C: key on content fingerprint, not timelineUpdateTick. Paint
        // ticks republish transcriptState (~30 Hz) even when messages/timeline
        // are unchanged; contentGeneration skips the O(thread) hash+hide
        // recompute on those passes. Tool-body-only stream assigns also
        // leave generation still so hide-set is not rehashed at token rate.
        let generation = vm.transcriptState.contentGeneration
        if hiddenPersistedAssistantMessageCache.generation == generation {
            return hiddenPersistedAssistantMessageCache.ids
        }
        let key = cachedHiddenPersistedAssistantContentKey()
        if hiddenPersistedAssistantMessageCache.key == key {
            hiddenPersistedAssistantMessageCache.generation = generation
            return hiddenPersistedAssistantMessageCache.ids
        }
        let ids = Self.hiddenPersistedAssistantMessageIDs(
            messages: vm.messages,
            timelineTurns: vm.timeline.turns
        )
        hiddenPersistedAssistantMessageCache.generation = generation
        hiddenPersistedAssistantMessageCache.key = key
        hiddenPersistedAssistantMessageCache.ids = ids
        return ids
    }

    public var body: some View {
        GeometryReader { proxy in
            HSplitView {
                if showThreadRail && layout.showsThreadRail {
                    threadRail
                        .frame(
                            minWidth: Self.threadRailWidthRange.lowerBound,
                            idealWidth: Self.threadRailIdealWidth,
                            maxWidth: Self.threadRailWidthRange.upperBound
                        )
                }
                conversationColumn(availableHeight: proxy.size.height)
                    .frame(minWidth: 0, maxWidth: .infinity)
            }
            .onAppear { applyAdaptiveSidebars(width: proxy.size.width, event: .structural) }
            .onChange(of: proxy.size.width) { width in
                applyAdaptiveSidebars(width: width, event: .resize)
            }
        }
        .background(DS.Palette.bg)
        .background(newThreadShortcut)
        .sheet(isPresented: $vm.showingAutoRoutingSetup) {
            AgentChoiceSheet(
                icon: "sparkles", tint: DS.Palette.ultracode,
                title: AgentAutoGuide.title, subtitle: AgentAutoGuide.subtitle,
                width: 600, accessibilityIdentifier: "agent.autoSetup.sheet",
                onClose: { vm.showingAutoRoutingSetup = false }
            ) {
                if let makeGuide = AgentAutoGuide.makeGuide {
                    makeGuide { vm.showingAutoRoutingSetup = false }
                }
            }
        }
        // UX-MAC_AGENT-OPEN-SPLIT: any tapped link inside this surface's markdown
        // (file mentions, bare URLs, markdown links) routes through the VM so it
        // opens — or reuses — a split panel to the right instead of leaving the app.
        .environment(\.openURL, OpenURLAction { url in
            vm.handleTranscriptLink(url) ? .handled : .systemAction
        })
        .task {
            // Let the first transcript/composer frame paint before provider
            // catalog probes (claude/codex/grok model lists) compete for CPU.
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            if vm.providerSnapshots.isEmpty {
                await vm.loadProviderSnapshots()
                // F10: the snapshot path drops the live/fallback signal —
                // run the VM's own fetch so availableModelsAreFallback (and
                // with it the "built-in defaults" warning + Refresh row) is
                // populated on startup, not only after a manual retry.
                await vm.loadModels()
            }
            // Subagent badge polling is workspace-coalesced in
            // AgentWorkspaceRailReloadCoordinator (one shared timer for all workspaces).
            // Registration happens in AgentAppViewModel.init.
        }
        .onDeleteCommand { deleteSelectedThreads() }
        // P1: confirm before deleting threads — irreversible and instant otherwise.
        .confirmationDialog(
            pendingDeleteThreadIds.count == 1
                ? "Delete this thread?"
                : "Delete \(pendingDeleteThreadIds.count) threads?",
            isPresented: Binding(
                get: { !pendingDeleteThreadIds.isEmpty },
                set: { if !$0 { pendingDeleteThreadIds = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { commitPendingDelete() }
            Button("Cancel", role: .cancel) { pendingDeleteThreadIds = [] }
        } message: {
            Text(Self.threadDeletionConfirmationDescription)
        }
        .confirmationDialog(
            "Clear all notifications?",
            isPresented: $pendingClearAllThreads,
            titleVisibility: .visible
        ) {
            Button("Clear All") { commitClearAllThreads() }
            Button("Cancel", role: .cancel) { pendingClearAllThreads = false }
        } message: {
            Text("Clears notification indicators. Conversations, messages, and running agents are kept.")
        }
    }

    // UX-MAC_AGENT-002: ⌘N starts a thread even when the rail (and its "+"
    // button) is collapsed. A zero-size button carries the shortcut.
    private var newThreadShortcut: some View {
        Button { vm.createThread(title: "New thread") } label: { EmptyView() }
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityHidden(true)
    }

    // MARK: Thread rail

    private var threadRail: some View {
        AgentChatThreadRail(
            title: AgentChatThreadRailCopy.headerTitle(activeCount: vm.activeThreadCount),
            isEmpty: vm.threads.isEmpty,
            emptySubtitle: Self.emptyThreadSubtitle,
            searchQuery: $vm.threadSearchQuery,
            hasSearchMatches: !vm.filteredThreads.isEmpty,
            identifier: "agent.thread.rail",
            hideIdentifier: "agent.thread.hide",
            clearAllIdentifier: "agent.thread.clearAll",
            newIdentifier: "agent.thread.new",
            searchIdentifier: "agent.thread.search",
            newHelp: "New thread (⌘N)",
            showsTrailingHairline: true,
            onHide: {
                threadRailIntent = .forcedHidden
                showThreadRail = false
            },
            onClearAll: { pendingClearAllThreads = true },
            onNew: { vm.createThread(title: "New thread") }
        ) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                    let runningThreadIds = vm.startingOrRunningThreadIds(among: vm.filteredThreads)
                    let now = vm.currentTime()
                    ForEach(vm.filteredThreads, id: \.id) { t in
                        threadRow(t, running: runningThreadIds.contains(t.id), now: now)
                    }
                }.padding(DS.Space.sm)
            }
            .focusable()
            .onMoveCommand { direction in
                let delta: Int
                switch direction {
                case .up:   delta = -1
                case .down: delta = 1
                default: return
                }
                let threads = vm.filteredThreads
                let current = threads.firstIndex(where: { $0.id == vm.selectedThreadId })
                guard let next = AgentThreadRailKeyboardNav.moveThreadSelection(
                    current: current,
                    direction: delta,
                    count: threads.count
                ) else { return }
                vm.selectThread(threads[next].id)
            }
        }
    }

    @ViewBuilder
    private func threadRow(_ t: AgentThread, running: Bool, now: Date) -> some View {
        if renamingThreadId == t.id {
            renameRow(t)
        } else {
            let selected = vm.selectedThreadId == t.id
            let multiSelected = selectedThreadIds.contains(t.id)
            let markColor = TabColor.from(t.color).map { Color(hex: $0.hex) }
                ?? (t.status == .failed && !vm.threadNotificationDismissed(t) ? DS.Palette.danger : DS.Palette.textTertiary)
            let status: AgentChatThreadStatusMark = {
                if running { return .running }
                if t.pinned { return .symbol(name: "pin.fill", color: markColor, size: 9) }
                if t.status == .failed && !vm.threadNotificationDismissed(t) { return .symbol(name: "circle.fill", color: DS.Palette.danger, size: 7) }
                if !t.hasUnread { return .symbol(name: "circle.fill", color: markColor, size: 7) }
                return .hidden
            }()
            AgentChatThreadRow(
                title: AgentThreadTitle.display(t.title),
                subtitle: AgentThreadRailRowCopy.subtitle(
                    provider: t.provider,
                    model: t.model,
                    updatedAt: t.updatedAt,
                    now: now
                ),
                unread: t.hasUnread,
                selected: selected || multiSelected,
                status: status,
                identifier: "agent.thread.row.\(t.id.value.uuidString)",
                unreadIdentifier: "agent.thread.row.unread.\(t.id.value.uuidString)",
                runningIdentifier: "agent.thread.row.running.\(t.id.value.uuidString)",
                stopIdentifier: "agent.thread.row.stop.\(t.id.value.uuidString)",
                onSelect: { selectThreadRow(t) },
                onStop: running ? { vm.stopThread(t.id) } : nil,
                leading: {
                    if case .bot(let botID) = t.actor,
                       let bot = vm.mentionableBotsProvider().first(where: { $0.id == botID }) {
                        BotsAvatarView(name: bot.name, handle: bot.handle, symbol: bot.avatarSymbol, size: 20)
                    } else {
                        AgentThreadProviderMonogram(provider: t.provider)
                    }
                },
                trailing: {
                    if AgentThreadRowPresentation.showsSelectionCheck(
                        threadStatus: t.status,
                        selected: selected,
                        surfaceStatus: vm.status,
                        multiSelected: multiSelected
                    ) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Palette.accent)
                    }
                }
            )
            .help(t.title)
            .onDrag {
                draggingThreadId = t.id
                return NSItemProvider(object: t.id.value.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: AgentThreadDropDelegate(vm: vm, draggingThreadId: $draggingThreadId, target: t))
            .contextMenu {
                if running {
                    Button("Stop", role: .destructive) { vm.stopThread(t.id) }
                        .accessibilityIdentifier("agent.thread.contextmenu.stop.\(t.id.value.uuidString)")
                    Divider()
                }
                Button(t.pinned ? "Unpin" : "Pin") { vm.setThreadPinned(t.id, !t.pinned) }
                Divider()
                Button("Rename…") { renameText = t.title; renamingThreadId = t.id }
                Menu("Color") {
                    Button { vm.setThreadColor(t.id, "") } label: {
                        TabColorMenuLabel.none
                    }
                    ForEach(TabColor.allCases, id: \.self) { c in
                        Button { vm.setThreadColor(t.id, c.rawValue) } label: {
                            TabColorMenuLabel(c)
                        }
                    }
                }
                Divider()
                // IMP-MAC_AGENT-013: export the thread to a shareable markdown file.
                Button("Export…") { exportThread(t) }
                Divider()
                Button("Delete", role: .destructive) {
                    pendingDeleteThreadIds = selectedThreadIds.isEmpty ? [t.id] : selectedThreadIds
                }
            }
        }
    }

    private func renameRow(_ t: AgentThread) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "pencil")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Palette.accent)
            TextField("Thread name", text: $renameText)
                .textFieldStyle(.plain)
                .font(DS.Font.bodyDense)
                .onSubmit { commitRename(t) }
            Button { renamingThreadId = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Cancel rename")
            .help("Cancel rename")
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .strokeBorder(DS.Palette.accent.opacity(0.4), lineWidth: DS.Border.hairline))
    }

    private func commitRename(_ t: AgentThread) {
        vm.renameThread(t.id, to: renameText)
        renamingThreadId = nil
    }

    // MARK: Conversation column

    private func conversationColumn(availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if layout.showsHeader {
                header
            }
            if vm.permissionMode == .fullAccess {
                fullAccessBanner
            }
            if AgentUndoToastPlacement.checkpointRevertTakesARow(
                threadDeletionArmed: vm.pendingThreadDeletionUndo != nil,
                checkpointRevertArmed: vm.pendingCheckpointRevertUndo != nil
            ), let crToast = vm.pendingCheckpointRevertUndo {
                checkpointRevertUndoBanner(crToast)
            }
            // Stream paint: observe transcriptState only so token/tool ticks do
            // not rebuild chrome, rail, or composer through the parent VM.
            TranscriptReactiveScope(transcriptState: vm.transcriptState) {
                Group {
                    if !vm.hidesToolActivity, !vm.timeline.workActivities.isEmpty {
                        workLogRow
                            .padding(.horizontal, 22)
                            .padding(.vertical, DS.Space.md)
                            .background(DS.Palette.bg)
                    }
                    timeline
                        // An undo toast floats over the top of the transcript. As
                        // a row above it, it pushed every message down, then
                        // let it jump back when the undo window closed.
                        .overlay(alignment: .top) {
                            if let undo = vm.pendingThreadDeletionUndo {
                                threadDeletionUndoBanner(undo)
                            } else if let crToast = vm.pendingCheckpointRevertUndo {
                                checkpointRevertUndoBanner(crToast)
                            }
                        }
                }
            }
            backgroundAwaitBanner
            pendingCallbackRows
            // A failed page read stays on screen with Retry; the transcript
            // above shows no "No messages" for it. No dismiss: without the
            // strip the unread thread would be a blank column with no Retry.
            if let failure = vm.messagePageLoadFailureMessage {
                AgentChatErrorStrip(
                    message: failure,
                    identifier: "agent.messages.loadFailed",
                    onRetry: { vm.retryMessagePageLoad() }
                )
            }
            // Unified system strip: severity-ordered, capped (replaces stacked banners).
            systemStatusStrip
            if let stop = vm.stopDistillLoop, !vm.distillLoops.isEmpty {
                DistillLoopStrip(
                    loops: vm.distillLoops,
                    onStop: stop,
                    onDismissExpired: { vm.dismissDistillLoop?($0) },
                    onResume: vm.resumeDistillLoop
                )
            }
            queuedMessagesSection
            if vm.selectedThreadIsEphemeral {
                sideChatParentStatusStrip
                    .padding(.horizontal, 22)
                    .padding(.bottom, DS.Space.xs)
            }
            // F1: render the composer inside a scope that observes only the composer
            // text, so a keystroke re-renders the composer subtree and NOT this body
            // (which builds the whole transcript).
            // The legacy banner explains a locked composer and offers a new chat; it belongs with the composer.
            if vm.isLegacyProviderThread, layout.showsComposer {
                legacyProviderBanner
            }
            if vm.selectedThreadBotUnavailable {
                deletedBotBanner
            }
            if vm.pendingMacExecutionReason != nil {
                BotMacExecutionBanner(vm: vm)
            }
            if vm.vmUnavailableBotID != nil {
                BotVMUnavailableBanner(vm: vm)
            }
            if layout.showsComposer {
                if let nowStrip = vm.embedding?.nowStrip {
                    AgentNowStripHost(source: nowStrip, cached: vm.embedding?.nowStripCached)
                }
                ComposerReactiveScope(composerState: vm.composerState) {
                    composer
                        .disabled(vm.isLegacyProviderThread || vm.selectedThreadBotUnavailable)
                }
            }
        }
        .background(DS.Palette.bg)
        // C6: Esc interrupts an in-flight run (remotecode.io parity).
        .onExitCommand { if vm.selectedThreadIsStoppableBusy { vm.stop() } }
        // IMP-MAC_AGENT-006: power-user shortcut to cycle reasoning effort
        // without opening the model popover; the composer model pill reflects
        // the new effort immediately. Hidden control carries the shortcut.
        .background(
            Button("") { vm.cycleReasoningEffort() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    /// Empty closed Subagents chrome does not read elapsed time. A fresh
    /// `Date()` on every header body churned identity while Auto showed an
    /// idle badge.
    nonisolated static let subagentActivityBadgeStableNow = Date(timeIntervalSinceReferenceDate: 0)

    nonisolated static func subagentActivityBadgeNow(
        snapshotEmpty: Bool,
        popoverPresented: Bool,
        currentTime: () -> Date
    ) -> Date {
        if snapshotEmpty && !popoverPresented {
            return subagentActivityBadgeStableNow
        }
        return currentTime()
    }

    // Thin context header. Run-config (provider/model/permission) lives in
    // the composer footer now, Codex-style.
    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            if !showThreadRail {
                DSIconButton("sidebar.left", help: AgentChatThreadRailCopy.showHelp) {
                    threadRailIntent = .forcedVisible
                    showThreadRail = true
                }
                // UX-MAC_AGENT-002: keep a new-thread affordance reachable while
                // the rail's "+" button is collapsed away.
                DSIconButton("plus", help: "New thread (⌘N)") { vm.createThread(title: "New thread") }
                    .accessibilityIdentifier("agent.thread.new.collapsed")
            }
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
            Text(vm.gitBranch ?? "no branch")
                .font(DS.Font.caption2.monospaced())
                .foregroundColor(DS.Palette.textSecondary)
                .lineLimit(1).truncationMode(.middle)
                .help(vm.gitBranch ?? "no branch")
            if let context = vm.contextHealthMessage {
                Text("·").foregroundColor(DS.Palette.textTertiary)
                Text(context)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Text("·").foregroundColor(DS.Palette.textTertiary)
            Text(URL(fileURLWithPath: vm.cwd).lastPathComponent)
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textSecondary)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            botScreenControls
            // Unified working phase strip (replaces separate awaiting/shell/status pills).
            workingPhaseStrip
            // Provider-neutral Subagents activity for the selected thread only
            // (admission receipts + coordinator). Compact badge + popover; does
            // not touch transcript/composer or aggregate sibling threads.
            // Auto (orchestrate) always exposes the chrome so delegated workers
            // are discoverable the moment the first child receipt lands — not
            // only after the user already knows to look for a hidden badge.
            if !vm.subagentActivity.isEmpty || showSubagentActivity || vm.routingMode == .auto {
                SubagentActivityBadge(
                    snapshot: vm.subagentActivity,
                    bots: snapshotMentionableBots(),
                    now: Self.subagentActivityBadgeNow(
                        snapshotEmpty: vm.subagentActivity.isEmpty,
                        popoverPresented: showSubagentActivity,
                        currentTime: vm.currentTime
                    ),
                    isPresented: $showSubagentActivity,
                    orchestrateActive: vm.routingMode == .auto
                )
            }
            // Same action as `/side`; hidden where no host can open a side pane.
            if vm.onRequestSideChat != nil, !vm.selectedThreadIsEphemeral {
                DSIconButton("rectangle.split.2x1", help: "Side chat (/side)") {
                    vm.requestSideChat(text: "")
                }
                .disabled(vm.selectedThreadId == nil)
                .accessibilityIdentifier("agent.header.sideChat")
            }
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .dsBar(edge: .bottom)
    }

    @ViewBuilder
    private var botScreenControls: some View {
        if vm.botScreenBotID != nil {
            Button("View bot screen") { vm.viewBotScreen() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("agent.botScreen.view")
            Button(vm.botScreenControlled ? "Release" : "Take control") {
                Task { await vm.toggleBotScreenControl() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("agent.botScreen.control")
        }
    }

    // Persistent, prominent banner while full access is on, beyond the small
    // permission pill in the composer footer (UX-MAC_AGENT-004).
    private var fullAccessBanner: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text("Full access is on")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.danger)
                Text(Self.fullAccessScopeDescription)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Button("Switch to supervised") { vm.setPermissionMode(.supervised) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.danger.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.danger.opacity(0.3)).frame(height: 1) }
        .accessibilityIdentifier("agent.fullAccessBanner")
    }

    // UX-XPLAT-DELETE-UNDO: transient toast offering to restore a just-deleted
    // thread. The delete already happened; Undo re-inserts the snapshot.
    private func threadDeletionUndoBanner(_ undo: AgentAppViewModel.ThreadDeletionUndo) -> some View {
        let message = undo.count > 1 ? "\(undo.count.formatted()) threads deleted" : "Thread deleted"
        return HStack(spacing: DS.Space.sm) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
            Text(message)
                .font(DS.Font.caption.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            Spacer(minLength: 0)
            Button("Undo") { vm.undoLastThreadDeletion() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("agent.thread.delete.undo")
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.line).frame(height: 1) }
        .accessibilityIdentifier("agent.thread.delete.undoBanner")
        .onAppear {
            announceUndoToast(message, window: AgentAppViewModel.threadDeletionUndoWindow, armedAt: undo.capturedAt)
        }
        // A second delete inside the window replaces the toast in place.
        .onChange(of: undo.capturedAt) { _, _ in
            announceUndoToast(message, window: AgentAppViewModel.threadDeletionUndoWindow, armedAt: undo.capturedAt)
        }
    }

    private func checkpointRevertUndoBanner(_ toast: AgentAppViewModel.CheckpointRevertUndoToast) -> some View {
        let message = "Reverted to checkpoint \(toast.checkpointTurnCount.formatted())"
        return HStack(spacing: DS.Space.sm) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
            Text(message)
                .font(DS.Font.caption.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            Spacer(minLength: 0)
            Button("Undo") { vm.undoLastCheckpointRevert() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("agent.checkpoint.revert.undo")
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.line).frame(height: 1) }
        .accessibilityIdentifier("agent.checkpoint.revert.undoBanner")
        .onAppear {
            announceUndoToast(message, window: AgentAppViewModel.checkpointRevertUndoWindow, armedAt: toast.capturedAt)
        }
        .onChange(of: toast.capturedAt) { _, _ in
            announceUndoToast(message, window: AgentAppViewModel.checkpointRevertUndoWindow, armedAt: toast.capturedAt)
        }
    }

    /// VoiceOver does not read a view that appears on its own, and the undo
    /// window is short: say the toast when it shows. Once per arming: a toast
    /// that only changes place (see `AgentUndoToastPlacement`) is not news.
    private func announceUndoToast(_ message: String, window: TimeInterval, armedAt: Date) {
        guard announcedUndoToasts.insert(armedAt).inserted else { return }
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: (app.mainWindow as NSResponder?) ?? app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(message). Undo is available for \(Int(window)) seconds.",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private var modelLabel: String {
        if vm.routingMode == .auto { return "Auto" }
        return vm.modelOptionsForSelectedProvider.first(where: { $0.id == vm.model })?.label ?? vm.model
    }

    private var autoRoutingPrerequisitesLoading: Bool {
        vm.selectedThreadId != nil && (
            vm.providerSnapshots.isEmpty || vm.providerSnapshotsLoading || vm.modelListLoading
        )
    }
    private var autoRoutingPillLoading: Bool {
        vm.routingMode == .auto && autoRoutingPrerequisitesLoading
    }
    private var effortLabel: String { vm.reasoningEffort.displayName }
    private var serviceTierLabel: String { vm.serviceTier == .fast ? "Fast" : "Auto" }
    /// P3: VoiceOver label for the model picker pill that reads as structured
    /// text rather than the raw concatenated visual tokens.
    private var modelPillPresentation: AgentModelPillPresentation {
        AgentModelPillPresentation(
            title: modelLabel,
            loading: autoRoutingPillLoading,
            effort: (vm.routingMode == .manual && vm.supportsReasoningForSelectedModel) ? effortLabel : nil,
            serviceTier: (vm.routingMode == .manual && vm.serviceTier == .fast) ? serviceTierLabel : nil,
            contextWindow: vm.routingMode == .manual ? vm.selectedModelContextWindowLabel : nil
        )
    }

    private var modelMenuAccessibilityLabel: String {
        modelPillPresentation.accessibilityLabel
    }

    private var threadRailIntent: AdaptiveSidebarIntent {
        get { AdaptiveSidebarIntent(rawValue: threadRailIntentRaw) ?? .auto }
        nonmutating set { threadRailIntentRaw = newValue.rawValue }
    }

    // QA-MAC_AGENT-013: UI tests can pin both sidebars visible to get a stable
    // layout that resize-driven auto-collapse can't flake. Set via launch arg
    // `-agent.pinSidebars` or env `RC_AGENT_PIN_SIDEBARS=1`.
    private static let sidebarsPinnedForTesting: Bool =
        ProcessInfo.processInfo.arguments.contains("-agent.pinSidebars")
        || ProcessInfo.processInfo.environment["RC_AGENT_PIN_SIDEBARS"] == "1"

    private func applyAdaptiveSidebars(width: CGFloat, event: AdaptiveSidebarLayoutEvent) {
        if Self.sidebarsPinnedForTesting {
            showThreadRail = true
            return
        }
        applyAdaptiveThreadRail(width: width, event: event)
    }

    private func applyAdaptiveThreadRail(width: CGFloat, event: AdaptiveSidebarLayoutEvent) {
        let now = vm.currentTime().timeIntervalSinceReferenceDate
        let decision = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: width,
            contentMinimumExtent: Self.conversationMinimumWidth,
            sidebarExtent: Self.threadRailIdealWidth,
            currentVisible: showThreadRail,
            intent: threadRailIntent,
            event: event,
            now: now,
            lastAutomaticChange: lastAutomaticThreadRailChange
        )
        guard decision.isVisible != showThreadRail else { return }
        showThreadRail = decision.isVisible
        if decision.didChangeAutomatically {
            lastAutomaticThreadRailChange = now
        }
    }

    /// "1 shell" / "2 shells" — matches the Claude CLI's own wording so the two
    /// surfaces read the same. Pure, for unit testing the pluralization.
    nonisolated static func backgroundShellLabel(_ count: Int) -> String {
        count == 1 ? "1 shell" : "\(count) shells"
    }

    private func statusTone(_ s: AgentRunStatus) -> DSPill.Tone {
        switch s {
        case .running: return .accent
        case .completed: return .success
        case .failed: return .danger
        case .cancelled, .interrupted: return .warning
        default: return .neutral
        }
    }

    /// Same floating + the Bot desk shows. Only the standalone Agent App gets
    /// it; embedders (Bot desk, groups, Activity) pass their own or none.
    private var standaloneNewThreadFAB: AnyView? {
        Self.newThreadFAB(layout: layout, vm: vm).map { AnyView($0) }
    }

    static func newThreadFAB(layout: AgentAppViewLayout, vm: AgentAppViewModel) -> AgentChatNewThreadFAB? {
        guard layout == .standard else { return nil }
        return AgentChatNewThreadFAB(help: "New thread (⌘N)", identifier: "agent.thread.new.fab") {
            vm.createThread(title: "New thread")
        }
    }

    // MARK: Timeline

    // Flat, Codex-style transcript: a centered reading column, user
    // messages as right-aligned bubbles, assistant output as full-width
    // prose, tools as one dim line. No per-item cards.
    private var timeline: some View {
        AgentChatTimelineScrollContainer(
            rejoinToken: vm.focusTick &+ timelineThreadRejoinEpoch,
            followToken: workDisclosureLayoutEpoch,
            scrollToBottomIdentifier: "agent.timeline.scrollToBottom",
            accessibilityIdentifier: "agent.timeline",
            scrollTarget: vm.messageScrollTarget,
            trailingAccessory: timelineAccessory ?? standaloneNewThreadFAB,
            onReadingHistoryChanged: vm.setTranscriptReadingHistory
        ) { timelineColumnWidth in
                        // AA-25: materialize the merged entries ONCE per body; the
                        // property rebuilt two whole-thread dictionaries each read
                        // and used to be read three times per pass.
                        let mergedEntries = transcriptEntries
                        let columnPaint = Self.transcriptColumnPaint(
                            mergedEntries: paintOrderedTranscriptEntriesCached(mergedEntries),
                            status: vm.status,
                            runStartedAt: vm.runStartedAt,
                            revealCount: vm.transcriptHistoryRevealCount,
                            alreadyPaintOrdered: true,
                            readingStartID: vm.transcriptReadingStartID
                        )
                        let allEntries = columnPaint.all
                        let entries = columnPaint.visible
                        let visibleEntries = columnPaint.visible
                        let hiddenCount = Self.hiddenTranscriptCount(
                            totalCount: allEntries.count,
                            visibleCount: entries.count
                        )
                        let revealedHiddenCount = min(
                            vm.transcriptHistoryRevealCount,
                            hiddenCount
                        )
                        let paintSequence = columnPaint.paint
                        let latestLiveId: String? = paintSequence.last(where: { entry in
                            if case .turn(let turn) = entry { return !turn.finished }
                            return false
                        }).flatMap { entry -> String? in
                            if case .turn(let turn) = entry { return turn.turnId }
                            return nil
                        }
                        let flow = cachedChatFlowPaint(
                            paintSequence: paintSequence,
                            latestLiveTurnId: latestLiveId
                        )
                        let historyRows = flow.historyRows
                        let liveRows = flow.liveRows
                        let allRows = flow.allRows
                        let mentionBots = snapshotMentionableBots()
                        let relativeNow = Self.relativeTimestampNowBucket(vm.currentTime())
                        // F2: reuse paint context across chrome-only / paint-tick
                        // passes when contentGeneration is unchanged.
                        let rowPaintContext = cachedChatRowPaintContext(
                            rows: allRows,
                            visibleEntries: visibleEntries,
                            bots: mentionBots
                        )
                        VStack(alignment: .leading, spacing: 32) {
                            if vm.messageHistoryIsPartial {
                                VStack(alignment: .leading, spacing: DS.Space.xs) {
                                    Text("Showing the recent message window. Earlier messages remain stored locally.")
                                        .font(DS.Font.caption)
                                        .foregroundColor(DS.Palette.textTertiary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityIdentifier("agent.transcript.partialMessageHistory")
                                    Button {
                                        vm.loadOlderMessages()
                                    } label: {
                                        if vm.isLoadingOlderMessages {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Label("Load older messages", systemImage: "arrow.up.circle")
                                                .font(DS.Font.caption)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(vm.isLoadingOlderMessages)
                                    .accessibilityIdentifier("agent.transcript.loadOlderMessages")
                                }
                                .id("agent.transcript.partialHeader")
                            }
                            if hiddenCount > 0 {
                                runningHiddenTranscriptRow(
                                    hiddenCount,
                                    revealedCount: revealedHiddenCount,
                                    pageCount: Self.hiddenTranscriptRevealPageCount,
                                    onReveal: {
                                        vm.transcriptHistoryRevealCount = min(
                                            hiddenCount,
                                            vm.transcriptHistoryRevealCount + Self.hiddenTranscriptRevealPageCount
                                        )
                                    }
                                )
                                .id("agent.transcript.revealControl")
                            }
                            // Never LazyVStack ChatFlowRow: pid 36908 hung in
                            // LazySubviewPlacements even after liveTurnActive +
                            // resetFittedSizeCache. Eager VStack is the policy.
                            VStack(alignment: .leading, spacing: 32) {
                                ForEach(historyRows) { row in
                                    chatFlowRowView(
                                        row,
                                        columnWidth: timelineColumnWidth,
                                        groupHeader: rowPaintContext.peerGroupHeader(for: row),
                                        hideAssistantOutput: rowPaintContext.hidesAssistantOutput(for: row),
                                        mentionableBots: mentionBots,
                                        relativeNow: relativeNow
                                    )
                                    .id(row.id)
                                }
                            }
                            // Live streaming turns — eager, outside Lazy.
                            ForEach(liveRows) { row in
                                chatFlowRowView(
                                    row,
                                    columnWidth: timelineColumnWidth,
                                    groupHeader: rowPaintContext.peerGroupHeader(for: row),
                                    hideAssistantOutput: rowPaintContext.hidesAssistantOutput(for: row),
                                    mentionableBots: mentionBots,
                                    relativeNow: relativeNow
                                )
                                .id(row.id)
                            }
                            // Notice questions belong to their message row, including
                            // when that row is collapsed into the earlier history.
                            choicesTimelineTail()
                            if Self.shouldRenderActivePlan(
                                plan: vm.activePlan,
                                status: vm.status,
                                runStartedAt: vm.runStartedAt,
                                newestUserMessageAt: vm.messages.last(where: { $0.role == .user })?.createdAt
                            ), let plan = vm.activePlan {
                                activePlanRow(plan)
                                    .id("agent.activePlan")
                            }
                            if Self.shouldShowEmptyConversation(
                                messagesEmpty: vm.messages.isEmpty,
                                turnsEmpty: vm.timeline.turns.isEmpty,
                                hasTimelineError: vm.timeline.error != nil,
                                isHidden: vm.isHiddenFromSurface,
                                messagePageLoadState: vm.messagePageLoadState
                            ) {
                                emptyConversation
                                    .id("agent.emptyConversation")
                            }
                            if vm.selectedThreadRunIsStartingOrRunning {
                                AgentChatWorkingStatusStrip(
                                    startedAt: vm.runStartedAt ?? Date(),
                                    isStopping: vm.isStopping,
                                    context: activeBotPeerReviewName(in: visibleEntries).map {
                                        AgentChatWorkingContext.reviewing(peerName: $0)
                                    },
                                    hold: vm.backgroundHoldSummary,
                                    distill: vm.provider == .distill ? vm.distillLive : nil,
                                    contextTokens: vm.provider == .distill ? vm.timeline.tokenUsage?.contextTokens : nil,
                                    runningTools: AgentChatLiveTurnChrome.runningTools(in: vm.timeline.turns, since: vm.runStartedAt),
                                    onStop: { vm.stop() }
                                )
                                .id("agent.workingStatus")
                            } else if vm.selectedThreadIsPreparingRun {
                                AgentChatLoadingStatusStrip()
                                    .id("agent.loadingStatus")
                            }
                            if let err = vm.timeline.error {
                                errorRow(err)
                                    .id("agent.timeline.error")
                            }
                            if AgentAppViewModel.showsContinueAction(
                                hasRecoverableContext: vm.selectedThreadHasRecoverableContext,
                                runActive: vm.selectedThreadRunIsStartingOrRunning
                            ) {
                                interruptedContinueRow
                                    .id("agent.continue.interrupted")
                            }
                        }
        } followOverlay: { follow in
            TranscriptPaintTickScope(paintTick: vm.transcriptState.paintTick) {
                collapseAllCompletedWorkOnFinalIfNeeded()
                follow()
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $timelineDropTargeted) { providers in
            loadDroppedFileAttachments(from: providers)
        }
        .overlay {
            if timelineDropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .strokeBorder(DS.Palette.accent, lineWidth: 2)
                    .padding(DS.Space.sm)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: vm.timeline.turns.count) { _ in
            guard !vm.isHiddenFromSurface else { return }
            DispatchQueue.main.async {
                pruneExpandedItemIds()
            }
        }
        .onChange(of: vm.selectedThreadId) { _ in
            vm.transcriptHistoryRevealCount = 0
            vm.transcriptReadingStartID = nil
            pendingSessionApproval = nil
            collapseAllWorkDisclosures()
            knownFinishedWorkTurnIds = []
            timelineThreadRejoinEpoch &+= 1
        }
    }

    private func pruneExpandedItemIds() {
        var liveItemIds = Set<String>()
        for turn in vm.timeline.turns {
            for item in turn.items {
                liveItemIds.insert(item.id)
            }
        }
        if !expandedTools.isEmpty { expandedTools.formIntersection(liveItemIds) }
        // A tool group is keyed by its first item's id, so it lives in the same id space.
        if !expandedToolGroups.isEmpty { expandedToolGroups.formIntersection(liveItemIds) }
        if !toolGroupRevealByID.isEmpty {
            toolGroupRevealByID = toolGroupRevealByID.filter { liveItemIds.contains($0.key) }
        }
        if !expandedReasoning.isEmpty { expandedReasoning.formIntersection(liveItemIds) }
        let liveRequestIds = Set(vm.timeline.pendingRequests.map(\.id))
        if !expandedRequestPreviews.isEmpty { expandedRequestPreviews.formIntersection(liveRequestIds) }
        let liveTurnIds = Set(vm.timeline.turns.map(\.turnId))
        if !expandedCompletedWorkTurns.isEmpty { expandedCompletedWorkTurns.formIntersection(liveTurnIds) }
        if !userCollapsedLiveWorkTurns.isEmpty { userCollapsedLiveWorkTurns.formIntersection(liveTurnIds) }
        // AA-31: the only per-turn map that was never pruned.
        if !workDisclosureRevealByTurn.isEmpty {
            workDisclosureRevealByTurn = workDisclosureRevealByTurn.filter { liveTurnIds.contains($0.key) }
        }
    }

    // UX-MAC_AGENT-BG-AWAIT / incomplete-turn: when a thread ends incomplete
    // (background job await or multi-phase handoff), the run reads "awaiting"
    // (not a green "completed"); this banner lets the user resume it. Full-access
    // threads are also auto-nudged by the coordinator, so this is mainly supervised.
    @ViewBuilder
    private var backgroundAwaitBanner: some View {
        if let reason = vm.incompleteTurnReason {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "hourglass")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text({
                        switch reason {
                        case .workflowHandoff: return "Agent stopped mid-workflow"
                        case .uncalledToolInvocation: return "Agent emitted an unexecuted tool call"
                        case .backgroundAwait: return "Agent is waiting on a background task"
                        }
                    }())
                        .font(DS.Font.caption.weight(.semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                    Text({
                        switch reason {
                        case .workflowHandoff:
                            return "The run ended between phases. Resume it to finish the original task."
                        case .uncalledToolInvocation:
                            return "The run ended after printing tool markup instead of calling a tool. Resume it to continue."
                        case .backgroundAwait:
                            return "The run ended while standing by. Resume it to check the task and finish."
                        }
                    }())
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                Button("Continue") {
                    Task { await vm.continueAfterBackgroundWait() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.bg)
            .accessibilityIdentifier("agent.backgroundAwaitBanner")
        }
    }

    @ViewBuilder
    private var pendingCallbackRows: some View {
        if !vm.visiblePendingRequests.isEmpty || !vm.visiblePendingUserInputs.isEmpty
            || vm.openManualAction != nil || !vm.resolvedManualActions.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                AgentManualActionCard(vm: vm)
                ForEach(vm.visiblePendingRequests) { request in
                    pendingRequestRow(request)
                }
                ForEach(vm.visiblePendingUserInputs) { request in
                    pendingUserInputRow(request)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.bg)
            .accessibilityIdentifier("agent.pendingCallbacks")
            .confirmationDialog(
                "Allow this agent to act without approvals for this thread until you change it?",
                isPresented: Binding(
                    get: { pendingSessionApproval != nil },
                    set: { if !$0 { pendingSessionApproval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Allow full access", role: .destructive) {
                    if let pendingSessionApproval {
                        vm.respondToPendingRequest(
                            pendingSessionApproval.request,
                            response: .approveForSession,
                            originThreadId: pendingSessionApproval.originThreadId
                        )
                    }
                    pendingSessionApproval = nil
                }
                Button("Keep approving each action", role: .cancel) {
                    pendingSessionApproval = nil
                }
            } message: {
                Text("Full access lets the agent run tools and edits without asking. Keeping per-action approval is safer.")
            }
        }
    }

    /// Ready-made answers from the newest reply. Notice questions are rendered
    /// only by their own message row, never lifted out of collapsed history.
    @ViewBuilder
    private func choicesTimelineTail() -> some View {
        // The card reads the composer draft, which publishes on its own object:
        // observe it here so typing a draft disables the card.
        ComposerReactiveScope(composerState: vm.composerState) {
            if vm.showsBotChoices,
           let pending = AgentChatChoicesCard.Pending.latest(
                in: vm.messages,
                isRunning: vm.hasRunningWorkForChrome
            ), !dismissedChoices.contains(pending.messageID) {
                AgentChatChoicesCard(
                    choices: pending.choices,
                    identifier: "agent.choices.\(pending.messageID)",
                    // Answering goes through the composer's send; never replace a
                    // draft the user is writing.
                    isBlockedByDraft: !vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !vm.attachments.isEmpty || vm.activeReplyTarget != nil,
                    onAnswer: { answer in
                        // Re-checked at tap time: never overwrite a draft.
                        guard vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              vm.attachments.isEmpty, vm.activeReplyTarget == nil,
                              let threadID = vm.selectedThreadId,
                              AgentChatChoicesCard.Pending.latest(
                                in: vm.messages, isRunning: vm.hasRunningWorkForChrome
                              ) == pending,
                              let source = vm.messages.first(where: {
                                $0.id.value.uuidString.lowercased() == pending.messageID
                              }) else { return }
                        let question = pending.choices.question
                            ?? BotChoicesBlock.parse(source.content).text
                        let reply = AgentReplyQuote.compose(excerpt: question, text: answer)
                        vm.prompt = reply
                        Task {
                            guard vm.selectedThreadId == threadID, vm.prompt == reply else { return }
                            await vm.send()
                        }
                    },
                    onDismiss: { dismissChoices(pending.messageID) }
                )
                .id("agent.choices.\(pending.messageID)")
            }
        }
    }

    /// A notice's decision right under the message that asked it. The message's
    /// visibility controls the question too. Actions send the message id and option
    /// index to the host, never the label as a new model prompt.
    @ViewBuilder
    private func inlineNoticeCard(for message: AgentMessage) -> some View {
        // A message with a notice block renders its options inside its notice card.
        if vm.embedding?.noticeChoiceHandler != nil,
           TitioNoticeBlock.parse(message.content).block == nil,
           let pending = AgentChatChoicesCard.Pending.openNotices(in: [message], dismissed: dismissedChoices).first {
            noticeCard(pending)
        }
    }

    private func noticeCard(_ pending: AgentChatChoicesCard.Pending) -> some View {
        AgentChatChoicesCard(
            choices: pending.choices,
            identifier: "agent.choices.\(pending.messageID)",
            allowsOwnAnswer: false,
            onAnswer: { answer in
                // The ledger claims atomically; a repeated tap while the first
                // runs is answered silently.
                guard let index = pending.choices.options.firstIndex(of: answer),
                      let handler = vm.embedding?.noticeChoiceHandler else { return }
                handler(pending.messageID, index)
            },
            onDismiss: { dismissChoices(pending.messageID) }
        )
        .id("agent.choices.\(pending.messageID)")
    }

    private func dismissChoices(_ messageID: String) {
        dismissedChoices.insert(messageID)
        AgentChatChoicesCard.DismissedStore.insert(messageID)
    }

    @ViewBuilder
    private var workLogRow: some View {
        let activities = Array(vm.timeline.workActivities.suffix(8))
        if !activities.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Button {
                    withAnimation(reduceMotion ? nil : DS.Motion.micro) {
                        showWorkLog.toggle()
                    }
                } label: {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: showWorkLog ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(width: 10)
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Palette.textTertiary)
                        Text("Work log")
                            .font(DS.Font.caption.weight(.semibold))
                            .foregroundColor(DS.Palette.textSecondary)
                        Text("\(activities.count)")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agent.workLog.toggle")
                .accessibilityLabel(showWorkLog ? "Hide work log" : "Show work log")
                .help(showWorkLog ? "Hide work log" : "Show work log")
                if showWorkLog {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        ForEach(activities) { activity in
                            HStack(alignment: .top, spacing: DS.Space.sm) {
                                Image(systemName: workActivityIcon(activity))
                                    .font(.system(size: 9))
                                    .foregroundColor(workActivityColor(activity))
                                    .frame(width: 13)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(activity.title)
                                        .font(DS.Font.caption)
                                        .foregroundColor(DS.Palette.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    if let detail = Self.workLogDetailText(activity), !detail.isEmpty {
                                        Text(detail)
                                            .font(DS.Font.monoSmall)
                                            .foregroundColor(DS.Palette.textTertiary)
                                            .lineLimit(2)
                                            .truncationMode(.tail)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .transition(AgentChatMotion.transition(.fadeAndMove, reduceMotion: reduceMotion))
                }
            }
            .padding(.vertical, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("agent.workLog")
        }
    }

    /// The work log shows an error's text without the fresh-session machine
    /// marker, like the composer error row; the stored detail stays raw.
    nonisolated static func workLogDetailText(_ activity: AssistantWorkActivity) -> String? {
        guard activity.kind == .error, let detail = activity.detail else { return activity.detail }
        return AgentErrorRecoveryAction.displayText(detail)
    }

    private func workActivityIcon(_ activity: AssistantWorkActivity) -> String {
        if activity.state == AssistantItemState.streaming.rawValue { return "circle.dotted" }
        if activity.state == AssistantItemState.failed.rawValue || activity.kind == .error { return "xmark.octagon" }
        switch activity.kind {
        case .runtime: return "waveform.path.ecg"
        case .tool: return "terminal"
        case .request: return "checkmark.shield"
        case .userInput: return "questionmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private func workActivityColor(_ activity: AssistantWorkActivity) -> Color {
        if activity.state == AssistantItemState.failed.rawValue || activity.kind == .error { return DS.Palette.danger }
        if activity.state == AssistantItemState.streaming.rawValue { return DS.Palette.accent }
        return DS.Palette.textTertiary
    }

    @ViewBuilder
    private func pendingRequestRow(_ request: AssistantPendingRequest) -> some View {
        let stale = request.state == .stale
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: stale ? "exclamationmark.triangle" : "checkmark.shield")
                    .font(.system(size: 12))
                    .foregroundColor(stale ? DS.Palette.warning : DS.Palette.accent)
                Text(stale ? "Stale provider request" : "Provider approval")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                // UX-MAC_AGENT-005: label what is being approved.
                requestKindChip(request.kind)
                Spacer(minLength: 0)
            }
            Text(request.title)
                .font(DS.Font.bodyDense.weight(.semibold))
                .foregroundColor(DS.Palette.text)
                .lineLimit(2)
            // UX-MAC_AGENT-006: surface the actual command / patch so users
            // don't approve exec/applyPatch requests blind.
            requestPreview(request)
            if stale {
                Text("Restart the turn to continue.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
            } else {
                // UX-MAC_AGENT-005: emphasize the safe one-time Approve;
                // de-emphasize/warning-tint the session-wide auto-approve;
                // separate Decline.
                if declineReasonDrafts[request.id] != nil {
                    // Inline decline-with-reason form.
                    let reasonBinding = Binding(
                        get: { declineReasonDrafts[request.id] ?? "" },
                        set: { declineReasonDrafts[request.id] = $0 }
                    )
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        TextField("Reason (optional)", text: reasonBinding)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        HStack(spacing: DS.Space.sm) {
                            Button("Send Decline") {
                                let draft = declineReasonDrafts[request.id]
                                declineReasonDrafts[request.id] = nil
                                vm.respondToPendingRequest(
                                    request,
                                    response: AgentAppViewModel.declinePayload(reason: draft)
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("Cancel") { declineReasonDrafts[request.id] = nil }
                                .buttonStyle(.plain)
                                .controlSize(.small)
                        }
                    }
                } else {
                    HStack(spacing: DS.Space.sm) {
                        Button("Approve") { vm.respondToPendingRequest(request, response: .approve) }
                            .buttonStyle(.borderedProminent)
                        if request.allowsSessionApproval {
                            Button("Approve Session") {
                                if let originThreadId = vm.selectedThreadId {
                                    pendingSessionApproval = PendingSessionApprovalConfirmation(
                                        originThreadId: originThreadId,
                                        request: request
                                    )
                                }
                            }
                                .buttonStyle(.bordered)
                                .tint(DS.Palette.warning)
                                .help(Self.sessionApprovalHelp)
                        }
                        Spacer(minLength: DS.Space.md)
                        Button("Decline") { declineReasonDrafts[request.id] = "" }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .disabled(vm.selectedProviderSnapshot.map {
            !$0.effectiveCapabilities.supportsApprovals
        } ?? false)
        .accessibilityIdentifier("agent.pendingRequest.\(request.id)")
    }

    // UX-MAC_AGENT-005: a small chip naming the request kind.
    private func requestKindChip(_ kind: AssistantRequestKind) -> some View {
        Text(requestKindLabel(kind))
            .font(DS.Font.caption2.weight(.semibold))
            .foregroundColor(DS.Palette.accent)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, 1)
            .background(DS.Palette.accent.opacity(0.13))
            .clipShape(Capsule())
    }

    private func requestKindLabel(_ kind: AssistantRequestKind) -> String {
        switch kind {
        case .commandExecution, .exec: return "Run command"
        case .applyPatch: return "Apply patch"
        case .fileChange: return "Edit file"
        case .fileRead: return "Read file"
        case .toolUserInput: return "Tool input"
        case .authTokensRefresh: return "Refresh auth"
        case .dynamic: return "Tool"
        }
    }

    // UX-MAC_AGENT-006: command kinds render monospace + copy; patch kinds
    // render a collapsible diff. Other kinds fall back to the prior detail row.
    @ViewBuilder
    private func requestPreview(_ request: AssistantPendingRequest) -> some View {
        if let detail = request.detail, !detail.isEmpty {
            switch request.kind {
            case .commandExecution, .exec:
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    AgentSelectablePlainText(
                        text: detail,
                        fontSize: 12,
                        monospaced: true,
                        textColor: DS.NS.text
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.sm)
                        .background(DS.Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    AgentChatCopyButton(text: detail) { copied in
                        Image(systemName: AgentChatCopyChrome.symbolName(copied: copied))
                            .font(.system(size: 10))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityLabel("Copy command")
                    .help("Copy command")
                }
            case .applyPatch, .fileChange:
                // Prefer Cursor-style edit card when the approval detail is a real patch.
                if let model = AgentFileEditDiffPresentation.model(
                    for: AssistantItem(
                        id: request.id,
                        turnId: request.turnId ?? "",
                        type: .fileChange,
                        state: .streaming,
                        summary: request.title,
                        body: "",
                        output: detail,
                        resourcePath: nil,
                        startedAtMs: request.createdAtMs
                    )
                ), model.hasRenderableCode {
                    // Approvals keep the patch visible; transcript cards stay collapsed.
                    AgentFileEditDiffCard(model: model, initiallyExpanded: true)
                } else {
                    let expanded = expandedRequestPreviews.contains(request.id)
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Button {
                            if expanded { expandedRequestPreviews.remove(request.id) }
                            else { expandedRequestPreviews.insert(request.id) }
                        } label: {
                            HStack(spacing: DS.Space.xs) {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                                Text(expanded ? "Hide diff" : "Show diff")
                                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        if expanded {
                            DiffPreviewText(detail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(DS.Space.sm)
                                .background(DS.Palette.surface)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                        }
                    }
                }
            default:
                AgentSelectablePlainText(
                    text: detail,
                    fontSize: 11,
                    monospaced: true,
                    textColor: DS.NS.textTertiary,
                    maximumNumberOfLines: 4
                )
            }
        }
    }

    @ViewBuilder
    private func pendingUserInputRow(_ request: AssistantUserInputRequest) -> some View {
        let stale = request.state == .stale
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: stale ? "exclamationmark.triangle" : "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(stale ? DS.Palette.warning : DS.Palette.accent)
                Text(stale ? "Stale provider question" : "Provider question")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                Spacer(minLength: 0)
            }
            if request.isStructured {
                askUserQuestionContent(request, stale: stale)
            } else {
                legacyUserInputContent(request, stale: stale)
            }
            if !stale {
                Button("Cancel question", role: .cancel) {
                    vm.cancelPendingUserInput(request)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.selectedProviderSnapshot.map {
                    !$0.effectiveCapabilities.supportsUserInput
                } ?? false)
                .help("Cancel only this question and keep the provider session available.")
                .accessibilityIdentifier("agent.pendingUserInput.cancel.\(request.id)")
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .accessibilityIdentifier("agent.pendingUserInput.\(request.id)")
    }

    @ViewBuilder
    private func legacyUserInputContent(_ request: AssistantUserInputRequest, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(request.prompt)
                .font(DS.Font.bodyDense.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            if stale {
                Text("Restart the turn to continue.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
            } else if request.options.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    let draft = Binding(
                        get: { vm.userInputDrafts[vm.userInputStateKey(request)] ?? request.answer ?? "" },
                        set: { vm.userInputDrafts[vm.userInputStateKey(request)] = $0 }
                    )
                    Group {
                        if request.isSecret {
                            SecureField("Answer", text: draft)
                        } else {
                            TextField("Answer", text: draft)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button("Answer") {
                        vm.answerPendingUserInput(request, answer: vm.userInputDrafts[vm.userInputStateKey(request)] ?? request.answer ?? "")
                    }
                    .disabled((vm.userInputDrafts[vm.userInputStateKey(request)] ?? request.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if request.allowsMultipleSelection {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(spacing: DS.Space.sm) {
                        ForEach(request.identifiedOptions) { row in
                            let selected = vm.userInputSelections[vm.userInputStateKey(request)]?.contains(row.option) == true
                            Button {
                                vm.toggleUserInputOption(row.option, for: request)
                            } label: {
                                Label(row.option, systemImage: selected ? "checkmark.square.fill" : "square")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Submit") {
                        vm.answerPendingUserInput(request, answer: vm.selectedUserInputAnswer(for: request))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(vm.selectedUserInputAnswer(for: request).isEmpty)
                }
            } else {
                HStack(spacing: DS.Space.sm) {
                    ForEach(request.identifiedOptions) { row in
                        Button(row.option) { vm.answerPendingUserInput(request, answer: row.option) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // Structured Claude AskUserQuestion: render each question with its header,
    // prompt, selectable options (radio for single-select, checkbox for
    // multi-select) plus an "Other" freeform field, then submit all answers at once.
    @ViewBuilder
    private func askUserQuestionContent(_ request: AssistantUserInputRequest, stale: Bool) -> some View {
        if stale {
            Text("Restart the turn to continue.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                ForEach(request.questions) { question in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        if let header = question.header, !header.isEmpty {
                            Text(header.uppercased())
                                .font(DS.Font.caption2.weight(.semibold))
                                .foregroundColor(DS.Palette.accent)
                                .padding(.horizontal, DS.Space.xs)
                                .padding(.vertical, 1)
                                .background(DS.Palette.accent.opacity(0.13))
                                .clipShape(Capsule())
                        }
                        Text(question.prompt)
                            .font(DS.Font.bodyDense.weight(.semibold))
                            .foregroundColor(DS.Palette.text)
                        ForEach(question.identifiedOptions) { row in
                            askUserQuestionOptionButton(row.option, question: question, request: request)
                        }
                        AskUserQuestionOtherField(vm: vm, question: question, request: request)
                    }
                }
                Button("Submit") { vm.submitAskUserQuestion(request) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!vm.askUserQuestionIsComplete(request))
            }
        }
    }

    @ViewBuilder
    private func askUserQuestionOptionButton(_ option: AssistantUserInputOption, question: AssistantUserInputQuestion, request: AssistantUserInputRequest) -> some View {
        let selected = vm.askUserQuestionOptionIsSelected(option.label, question: question, request: request)
        let symbol: String = question.allowsMultipleSelection
            ? (selected ? "checkmark.square.fill" : "square")
            : (selected ? "largecircle.fill.circle" : "circle")
        Button {
            vm.selectAskUserQuestionOption(option.label, question: question, request: request)
        } label: {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundColor(selected ? DS.Palette.accent : DS.Palette.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(DS.Font.bodyDense)
                        .foregroundColor(DS.Palette.text)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Expose selection state so VoiceOver announces "<label>, selected" — matching
        // the Other radio and letting users hear which option in the group is chosen.
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("agent.askOption.\(request.id).\(question.id).\(option.label)")
    }

    /// Ordered scroll ids for one programmatic rejoin/follow pass.
    /// Always BOTTOM only — dual content+BOTTOM multipass-jumped open and stream.
    nonisolated static func programmaticScrollTargets(
        messages: [AgentMessage],
        turns: [AssistantTurnSnapshot],
        force: Bool
    ) -> [String] {
        // Keep signature stable for call sites/tests; force no longer dual-targets.
        _ = messages
        _ = turns
        _ = force
        return ["BOTTOM"]
    }

    // UX-MAC_AGENT-CONTINUE: shown when a turn was interrupted (relaunch or stalled provider).
    // One tap resumes via recoverableResumeContext without requiring a retype.
    @ViewBuilder
    private var interruptedContinueRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Palette.warning)
                Text("This turn stopped before finishing.")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            Button {
                Task { await vm.continueInterruptedThread() }
            } label: {
                Label("Continue", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("agent.continue.interrupted")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func saveLatestProposedPlan() {
        guard let plan = vm.latestProposedPlan else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = plan.exportFileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = try? vm.saveLatestProposedPlan(to: url)
    }

    // IMP-MAC_AGENT-013: write a thread's markdown export via a save panel.
    private func exportThread(_ thread: AgentThread) {
        Task { @MainActor in
            guard let export = await vm.exportThreadMarkdown(thread.id) else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = export.fileName
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? export.contents.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    @ViewBuilder
    private func assistantProse(_ text: String, cacheMarkdown: Bool = true) -> some View {
        // UX-MAC_AGENT-BG-AWAIT: the background-await self-declaration marker is an
        // internal signal the host detects on; it must never render in the transcript.
        // R4-B: live streaming rows pass cacheMarkdown: false so growing partials
        // do not thrash AgentMessageMarkdown NSCache occupancy.
        AgentMessageMarkdownView(
            // A ready-made answers block shows as the choices card instead
            // (Bot threads only: a plain agent reply is shown as written).
            text: vm.showsBotChoices
                ? BotChoicesBlock.parse(BackgroundAwaitContinuation.strippingAwaitingMarker(text)).text
                : BackgroundAwaitContinuation.strippingAwaitingMarker(text),
            cacheResults: cacheMarkdown
        )
            .foregroundColor(DS.Palette.text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // UX-MAC_AGENT-018: one-click "Copy message" for agent replies, mirroring the
    // user-message copy affordance. Copies the displayed text (for a translated
    // reply that is the human-readable translation, i.e. exactly what's on screen).
    @ViewBuilder
    private func assistantCopyBar(text: String, identifierSuffix: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Button { copyToPasteboard(text) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Copy message")
            .accessibilityIdentifier("agent.assistantMessage.copy.\(identifierSuffix)")
            .help("Copy message")
            Button { vm.onForkInNewChat?(identifierSuffix) } label: {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Branch in new chat")
            .accessibilityIdentifier("agent.assistantMessage.branch.\(identifierSuffix)")
            .help("Branch in new chat")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runningHiddenTranscriptRow(
        _ count: Int,
        revealedCount: Int,
        pageCount: Int,
        onReveal: @escaping () -> Void
    ) -> some View {
        let canRevealMore = revealedCount < count
        let nextCount = min(max(0, pageCount), max(0, count - revealedCount))
        return Button(action: { if canRevealMore { onReveal() } }) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: canRevealMore ? "ellipsis" : "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                Text(Self.hiddenTranscriptRevealLabel(
                    count: count,
                    revealedCount: revealedCount,
                    nextCount: nextCount
                ))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, 6)
            .background(DS.Palette.surface.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRevealMore)
        .accessibilityLabel(Self.hiddenTranscriptRevealAccessibilityLabel(
            count: count,
            revealedCount: revealedCount
        ))
        .accessibilityIdentifier("agent.runningHiddenTranscript")
    }

    /// Hide-drop publishes an empty timeline while the run still lives in
    /// `latestHiddenTimeline`. That 0-turn publish must not paint the empty
    /// conversation placeholder. Neither may a first page that is still being
    /// read or that failed to read: only a resolved page proves the thread
    /// has no messages.
    nonisolated static func shouldShowEmptyConversation(
        messagesEmpty: Bool,
        turnsEmpty: Bool,
        hasTimelineError: Bool,
        isHidden: Bool,
        messagePageLoadState: AgentMessagePageLoadState
    ) -> Bool {
        !isHidden && messagesEmpty && turnsEmpty && !hasTimelineError
            && messagePageLoadState == .idle
    }

    nonisolated static func hiddenTranscriptRevealLabel(
        count: Int,
        revealedCount: Int,
        nextCount: Int
    ) -> String {
        if revealedCount <= 0 {
            return "Earlier in this thread · show \(nextCount) more"
        }
        if revealedCount < count {
            return "Earlier in this thread · \(revealedCount) of \(count) shown · show more"
        }
        return "Earlier in this thread · \(count) shown, read-only"
    }

    nonisolated static func hiddenTranscriptRevealAccessibilityLabel(
        count: Int,
        revealedCount: Int
    ) -> String {
        if revealedCount <= 0 {
            return "\(count) earlier items in this thread hidden"
        }
        if revealedCount < count {
            return "\(revealedCount) of \(count) earlier items in this thread visible"
        }
        return "\(count) earlier items in this thread visible, read-only"
    }

    private func hiddenLiveTurnItemsRow(_ count: Int) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
            Text("\(count) earlier live updates hidden while this run is active")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 6)
        .background(DS.Palette.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityIdentifier("agent.hiddenLiveTurnItems")
    }

    @ViewBuilder
    private var emptyConversation: some View {
        if vm.selectedThreadIsEphemeral {
            sideChatEmptyConversation
        } else {
            AgentNewConversationEmptyState(
                title: vm.embedding?.emptyConversationTitle ?? "No messages",
                subtitle: vm.embedding?.emptyConversationSubtitle ?? "Start a new agent run."
            )
            .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
        }
    }
    private var sideChatEmptyConversation: some View {
        DSEmptyState(
            icon: "plus.circle",
            title: "Side chat",
            subtitle: "Side chats are temporary and disappear when you close the app."
        )
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
    }

    /// Parent thread running/idle indicator for a side chat.
    @ViewBuilder
    private var sideChatParentStatusStrip: some View {
        if let parentId = vm.selectedThreadParentId {
            let running = vm.isThreadStartingOrRunning(parentId)
            HStack(spacing: DS.Space.xs) {
                Circle()
                    .fill(running ? DS.Palette.warning : DS.Palette.textTertiary)
                    .frame(width: 6, height: 6)
                Text(running ? "Parent thread running" : "Parent thread idle")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("agent.sideChat.parentStatus")
        }
    }

    @ViewBuilder
    private func errorRow(_ err: String) -> some View {
        let recoverable = vm.lastErrorRecoverable
        let recoveryAction = vm.displayedErrorRecoveryAction
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .center, spacing: DS.Space.sm) {
                Image(systemName: recoverable ? "exclamationmark.triangle" : "xmark.octagon")
                    .font(.system(size: 11))
                    .foregroundColor(recoverable ? DS.Palette.warning : DS.Palette.danger)
                    .frame(width: 14, height: 14, alignment: .center)
                AgentSelectablePlainText(
                    text: AgentErrorRecoveryAction.displayText(err),
                    fontSize: 11,
                    monospaced: true,
                    textColor: recoverable ? DS.NS.warning : DS.NS.danger,
                    lineSpacing: 3
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { vm.dismissDisplayedError() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityLabel("Dismiss error")
                .accessibilityIdentifier("agent.error.dismiss")
                .help("Dismiss error")
            }
            if let recoveryAction {
                Button {
                    Task { await vm.performDisplayedErrorRecoveryAction() }
                } label: {
                    Label(
                        recoveryAction.title,
                        systemImage: recoveryAction == .signIn
                            ? "person.crop.circle.badge.checkmark"
                            : (recoveryAction == .startFresh ? "plus.message" : "arrow.clockwise")
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier(
                    recoveryAction == .retry
                        ? "agent.error.retry"
                        : "agent.error.recovery.\(recoveryAction.rawValue)"
                )
                .confirmationDialog(
                    "Retry without unavailable attachments?",
                    isPresented: Binding(
                        get: { vm.pendingAttachmentRetryConfirmation != nil },
                        set: { if !$0 { vm.cancelRetryWithoutUnavailableAttachments() } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Retry without unavailable attachments", role: .destructive) {
                        Task { await vm.confirmRetryWithoutUnavailableAttachments() }
                    }
                    Button("Cancel", role: .cancel) {
                        vm.cancelRetryWithoutUnavailableAttachments()
                    }
                } message: {
                    Text(vm.pendingAttachmentRetryConfirmation?.unavailableAttachmentNames.joined(separator: ", ") ?? "")
                }
            }
            if let recoveryStatus = vm.providerRecoveryStatusMessage {
                dismissibleStatusRow(
                    recoveryStatus,
                    identifier: "agent.error.recovery.status.dismiss",
                    color: recoveryStatus.hasPrefix("Could not") || recoveryStatus.hasPrefix("Sign-in unavailable")
                        ? DS.Palette.danger
                        : DS.Palette.textSecondary,
                    dismiss: { vm.dismissProviderRecoveryStatusMessage() }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // UX-MAC_AGENT-017: relative ("2m ago") + absolute (hover) timestamps.
    // Shared with Bots Desk so both transcripts format time the same way.
    static func relativeTimestamp(_ date: Date, now: Date = Date()) -> String {
        AgentChatTranscriptChrome.relativeTimestamp(date, now: now)
    }

    static func absoluteTimestamp(_ date: Date) -> String {
        AgentChatTranscriptChrome.absoluteTimestamp(date)
    }

    // UX-MAC_AGENT-018: composer chips classify by extension for the icon/thumbnail.
    // nonisolated: immutable Sendable set; read from both MainActor (isImagePath)
    // and nonisolated (isImageAttachment) contexts.
    nonisolated private static let imageChipExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp", "svg", "avif"
    ]
    static func isImagePath(_ path: String) -> Bool {
        imageChipExtensions.contains((path as NSString).pathExtension.lowercased())
    }
    // P3: nonisolated static so tests need no MainActor wrapper.
    nonisolated static func isImageAttachment(_ path: String) -> Bool {
        imageChipExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    // Per-turn duration from items' earliest start to latest finish.
    static func turnDurationLabel(_ turn: AssistantTurnSnapshot) -> String? {
        AgentChatLiveTurnChrome.turnDurationLabel(turn)
    }

    static func completedWorkLabel(
        _ turn: AssistantTurnSnapshot,
        live: Bool = false,
        workBlockCount: Int = 0
    ) -> String {
        AgentChatLiveTurnChrome.completedWorkLabel(turn, live: live, workBlockCount: workBlockCount)
    }

    private func collapseAllWorkDisclosures() {
        let cleared = AgentCompletedWorkExpandPolicy.clearedExpansionState()
        expandedCompletedWorkTurns = cleared.expanded
        userCollapsedLiveWorkTurns = cleared.collapsedLive
        workDisclosureRevealByTurn = [:]
        toolGroupRevealByID = [:]
        expandedLiveWorkCache.clear()
    }

    /// When a turn first gains a final answer / finishes, collapse every Work so far.
    private func collapseAllCompletedWorkOnFinalIfNeeded() {
        let update = Self.completedWorkTurnIds(
            turns: vm.timeline.turns,
            previouslyKnown: knownFinishedWorkTurnIds
        )
        knownFinishedWorkTurnIds = update.ids
        guard update.hasNewlyFinished else { return }
        collapseAllWorkDisclosures()
    }

    @ViewBuilder
    /// Tap on a reply quote: scroll to the quoted assistant message and flash it.
    /// Nil when the quote is not a reply or its source is not loaded.
    private func replyQuoteJumpAction(for msg: AgentMessage) -> (() -> Void)? {
        guard let excerpt = AgentReplyQuote.parse(msg.content)?.excerpt else { return nil }
        // Resolve on tap: scanning every earlier message per row per paint made
        // long notice threads (Titio Notifications) quadratic.
        return {
            guard let targetID = AgentReplyQuoteTarget.messageID(for: excerpt, in: vm.messages, before: msg.id) else { return }
            vm.scrollToMessage(targetID)
            quoteJumpHighlightTask?.cancel()
            quoteJumpHighlightID = targetID
            quoteJumpHighlightTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled, quoteJumpHighlightID == targetID else { return }
                quoteJumpHighlightID = nil
            }
        }
    }

    /// `messageRow` with the reply-quote jump highlight drawn over it.
    private func highlightedMessageRow(
        _ msg: AgentMessage,
        columnWidth: CGFloat,
        mentionableBots: [BotDefinition],
        relativeNow: Date?
    ) -> some View {
        messageRow(msg, columnWidth: columnWidth, mentionableBots: mentionableBots, relativeNow: relativeNow)
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.bubble)
                    .stroke(DS.Palette.accent, lineWidth: 1.5)
                    .opacity(quoteJumpHighlightID == msg.id ? 1 : 0)
                    .animation(reduceMotion ? nil : DS.Motion.micro, value: quoteJumpHighlightID)
                    .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private func messageRow(
        _ msg: AgentMessage,
        columnWidth: CGFloat = 10_000,
        mentionableBots: [BotDefinition] = [],
        relativeNow: Date? = nil
    ) -> some View {
        switch msg.role {
        case .user:
            if Self.isInternalPeerHopUserMessage(msg) {
                EmptyView()
            } else if IncompleteTurnContinuation.isSyntheticPrompt(msg.content) {
                AnyView(
                    Text("Checked on a background task · \(AgentChatTranscriptChrome.relativeTimestamp(msg.createdAt, now: relativeNow ?? Date()))")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("agent.syntheticPrompt")
                )
            } else {
            let displayText = Self.userMessageDisplayText(msg.content)
            let mentioned = Self.messagedPeers(
                in: displayText,
                bots: mentionableBots
            )
            AgentChatUserBubble(
                text: displayText,
                createdAt: msg.createdAt,
                now: relativeNow,
                columnWidth: columnWidth,
                accessibilityIdentifier: "agent.userMessageBubble",
                roleIdentifier: "agent.role.user",
                copyIdentifier: "agent.userMessage.copy.\(msg.id.value.uuidString)",
                header: mentioned.isEmpty ? nil : AnyView(
                    AgentChatMentionedPeersHeader(
                        bots: mentioned,
                        accessibilityIdentifier: "agent.peer.mentioned"
                    )
                ),
                onReplyQuoteTap: replyQuoteJumpAction(for: msg)
            )
            }
        case .assistant:
            if !hiddenPersistedAssistantMessageIDs.contains(msg.id) {
                if msg.content.isEmpty {
                    // P2: body was blanked by the 24 MB budget safety valve.
                    Text("(content omitted — message too large to display)")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Content omitted: message body was too large to display")
                } else if let activity = BotPeerTranscript.parseActivity(msg.content) {
                    AgentChatPeerActivityRow(
                        snapshot: activity,
                        startedAt: msg.createdAt,
                        avatarSymbol: Self.resolvedPeerAvatarSymbol(
                            handle: activity.handle,
                            encoded: "",
                            bots: mentionableBots
                        )
                    )
                } else if let parsed = BotPeerTranscript.parse(msg.content) {
                    let bots = mentionableBots
                    AgentChatAssistantReply(
                        text: parsed.body,
                        roleIdentifier: "agent.role.assistant",
                        copyIdentifier: "agent.assistantMessage.copy.\(msg.id.value.uuidString)",
                        branchIdentifier: "agent.assistantMessage.branch.\(msg.id.value.uuidString)",
                        onBranch: vm.onForkInNewChat == nil ? nil : { vm.onForkInNewChat?(msg.id.value.uuidString) },
                        onReply: { vm.beginReply(to: msg) },
                        stripsChoices: vm.showsBotChoices,
                        attachments: msg.attachments,
                        content: AnyView(
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                AgentChatPeerIdentityHeader(
                                    name: parsed.name,
                                    handle: parsed.handle,
                                    symbol: Self.resolvedPeerAvatarSymbol(
                                        handle: parsed.handle,
                                        encoded: parsed.avatarSymbol,
                                        bots: bots
                                    ),
                                    trailing: false,
                                    caption: parsed.caption,
                                    accessibilityIdentifier: "agent.peer.from"
                                )
                                assistantProse(parsed.body)
                            }
                        )
                    )
                } else if vm.embedding?.noticeChoiceHandler != nil,
                          let notice = TitioNoticeBlock.parse(msg.content).block {
                    ComposerReactiveScope(composerState: vm.composerState) {
                        AgentChatNoticeCard(
                            messageID: msg.id.value.uuidString.lowercased(),
                            block: notice,
                            choices: BotChoicesBlock.parse(msg.content).choices.flatMap { choices in
                                choices.notice == nil || dismissedChoices.contains(msg.id.value.uuidString.lowercased())
                                    ? nil : choices
                            },
                            createdAt: msg.createdAt,
                            content: AnyView(assistantProse(TitioNoticeBlock.visibleText(msg.content))),
                            isBlockedByDraft: !vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || !vm.attachments.isEmpty
                                || (vm.activeReplyTarget != nil && vm.activeReplyTarget?.noticeMessageID != msg.id.value.uuidString.lowercased()),
                            isSending: vm.selectedThreadIsPreparingRun,
                            onOption: { index in vm.embedding?.noticeChoiceHandler?(msg.id.value.uuidString.lowercased(), index) },
                            onReply: { text in await vm.sendNoticeReply(to: msg, text: text) },
                            onClear: vm.embedding?.noticeClearHandler == nil ? nil : { vm.clearHostMessage(msg.id) }
                        )
                    }
                } else {
                    AgentChatAssistantReply(
                        text: BackgroundAwaitContinuation.strippingAwaitingMarker(msg.content),
                        roleIdentifier: "agent.role.assistant",
                        copyIdentifier: "agent.assistantMessage.copy.\(msg.id.value.uuidString)",
                        branchIdentifier: "agent.assistantMessage.branch.\(msg.id.value.uuidString)",
                        onBranch: vm.onForkInNewChat == nil ? nil : { vm.onForkInNewChat?(msg.id.value.uuidString) },
                        onReply: vm.supportsReplies ? { vm.beginReply(to: msg) } : nil,
                        stripsChoices: vm.showsBotChoices,
                        attachments: msg.attachments,
                        onClear: vm.embedding?.noticeClearHandler == nil ? nil : { vm.clearHostMessage(msg.id) }
                    )
                }
            }
        case .system:
            AgentSelectablePlainText(
                text: msg.content,
                fontSize: 11,
                textColor: DS.NS.textSecondary
            )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func transcriptEntryRow(
        _ entry: TranscriptEntry,
        columnWidth: CGFloat,
        groupHeader: AgentChatPeerGroupHeader? = nil,
        hideAssistantOutput: Bool = false,
        mentionableBots: [BotDefinition] = [],
        relativeNow: Date? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if let groupHeader {
                groupHeader
            }
            switch entry {
            case .message(let message):
                highlightedMessageRow(
                    message,
                    columnWidth: columnWidth,
                    mentionableBots: mentionableBots,
                    relativeNow: relativeNow
                )
                if message.role == .assistant, !hiddenPersistedAssistantMessageIDs.contains(message.id) {
                    inlineNoticeCard(for: message)
                }
            case .turn(let turn):
                turnView(turn, hideAssistantOutput: hideAssistantOutput)
            }
        }
    }

    @ViewBuilder
    private func chatFlowRowView(
        _ row: ChatFlowRow,
        columnWidth: CGFloat,
        groupHeader: AgentChatPeerGroupHeader? = nil,
        hideAssistantOutput: Bool = false,
        mentionableBots: [BotDefinition] = [],
        relativeNow: Date? = nil
    ) -> some View {
        switch row {
        case .entry(let entry):
            transcriptEntryRow(
                entry,
                columnWidth: columnWidth,
                groupHeader: groupHeader,
                hideAssistantOutput: hideAssistantOutput,
                mentionableBots: mentionableBots,
                relativeNow: relativeNow
            )
        case .segment(let segment):
            turnSegmentView(segment, hideAssistantOutput: hideAssistantOutput)
        }
    }

    /// One chronological slice of a turn between interleaved bot peer rows.
    /// The first segment keeps the turn's normal chrome; live continuations
    /// paint their blocks headerless so the chat reads as one appended flow;
    /// only the last segment renders plans and the final answer.
    @ViewBuilder
    private func turnSegmentView(
        _ segment: AgentChatTurnSegmentation.TurnSegment,
        hideAssistantOutput: Bool
    ) -> some View {
        let turn = segment.snapshot
        let turnPlans: [AssistantProposedPlan] = segment.isLast
            ? vm.timeline.proposedPlans.filter {
                $0.turnId == turn.turnId
                    && !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            : []
        AgentChatLiveTurnView(
            turn: turn,
            live: !turn.finished,
            hideAssistantOutput: segment.isLast
                ? hideAssistantOutput
                : false,
            showsWorkHeader: AgentChatLiveTurnChrome.showsWorkHeader(for: segment),
            hidesWork: vm.hidesToolActivity,
            renderFinal: segment.isLast
                ? { final in
                    AnyView(agentTurnFinal(final, turn: turn))
                }
                : nil,
            afterWork: (segment.isLast && !vm.suppressesProposedPlanReview && !turnPlans.isEmpty)
                ? AnyView(
                    ForEach(turnPlans) { plan in
                        proposedPlanRow(plan)
                    }
                )
                : nil
        )
        .equatable()
    }

    private static func peerHopIdentity(
        for entry: TranscriptEntry,
        bots: [BotDefinition]
    ) -> (name: String, handle: String, symbol: String?)? {
        switch entry {
        case .message(let message) where message.role == .user:
            guard let bot = Self.messagedPeer(in: message.content, bots: bots) else { return nil }
            return (bot.name, bot.handle, bot.avatarSymbol)
        case .message(let message) where message.role == .assistant:
            guard let parsed = BotPeerTranscript.parse(message.content) else { return nil }
            return (
                parsed.name,
                parsed.handle,
                Self.resolvedPeerAvatarSymbol(
                    handle: parsed.handle,
                    encoded: parsed.avatarSymbol,
                    bots: bots
                )
            )
        default:
            return nil
        }
    }

    private static func peerHopIdentity(
        for row: ChatFlowRow,
        bots: [BotDefinition]
    ) -> (name: String, handle: String, symbol: String?)? {
        guard case .entry(let entry) = row else { return nil }
        return peerHopIdentity(for: entry, bots: bots)
    }

    @ViewBuilder
    private func turnView(
        _ turn: AssistantTurnSnapshot,
        hideAssistantOutput: Bool
    ) -> some View {
        // AA-20: the painted row (`AgentChatLiveTurnView`) composes itself from
        // `turn`; the only thing this view contributed from `turnRenderInputs`
        // was `turnPlans`. Computing the full render model here ran, for the
        // LIVE turn on every body pass, `renderableItems` → assistant-text dedupe
        // against every persisted message (O(items × messages × body length),
        // uncached above 16 KiB). Same plan filter `turnSegmentView` uses.
        let turnPlans: [AssistantProposedPlan] = vm.suppressesProposedPlanReview
            ? []
            : vm.timeline.proposedPlans.filter {
                $0.turnId == turn.turnId
                    && !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        AgentChatLiveTurnView(
            turn: turn,
            live: !turn.finished,
            hideAssistantOutput: hideAssistantOutput,
            hidesWork: vm.hidesToolActivity,
            renderFinal: { final in
                AnyView(agentTurnFinal(final, turn: turn))
            },
            afterWork: vm.suppressesProposedPlanReview
                ? nil
                : AnyView(
                    ForEach(turnPlans) { plan in
                        proposedPlanRow(plan)
                    }
                )
        )
        .equatable()
    }

    @ViewBuilder
    private func agentTurnFinal(
        _ final: String,
        turn: AssistantTurnSnapshot
    ) -> some View {
        AgentChatAssistantReply(
            text: BackgroundAwaitContinuation.strippingAwaitingMarker(final),
            roleIdentifier: "agent.role.assistant",
            copyIdentifier: "agent.assistantMessage.copy.\(turn.turnId)",
            branchIdentifier: "agent.assistantMessage.branch.\(turn.turnId)",
            onBranch: vm.onForkInNewChat == nil ? nil : { vm.onForkInNewChat?(turn.turnId) },
            onReply: vm.supportsReplies && turn.finished ? { vm.beginReply(to: final) } : nil,
            stripsChoices: vm.showsBotChoices,
            showsImages: turn.finished,
            content: AnyView(assistantProse(final, cacheMarkdown: turn.finished))
        )
    }

    @ViewBuilder
    private func completedWorkDisclosure(
        turn: AssistantTurnSnapshot,
        blocks: [TurnRenderBlock],
        workBlockCount: Int,
        live: Bool = false
    ) -> some View {
        let expanded = isCompletedWorkExpanded(for: turn)
        let reveal = workDisclosureRevealByTurn[turn.turnId] ?? 0
        let slice = AgentWorkDisclosureLayout.paintSlice(all: blocks, revealCount: reveal)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Button {
                withAnimation(reduceMotion ? nil : DS.Motion.micro) {
                    let wasExpanded = isCompletedWorkExpanded(for: turn)
                    toggleCompletedWork(for: turn)
                    if !wasExpanded {
                        workDisclosureLayoutEpoch &+= 1
                    }
                }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    if live {
                        Image(systemName: "circle.dotted")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                    Text(Self.completedWorkLabel(turn, live: live, workBlockCount: workBlockCount))
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(DS.Palette.textTertiary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide work details" : "Show work details")
            .accessibilityLabel(expanded ? "Hide work details" : "Show work details")
            .accessibilityIdentifier(live ? "agent.liveWork.\(turn.turnId)" : "agent.completedWork.\(turn.turnId)")

            if expanded {
                // paintSlice caps at expandedPaintWindow — no nested ScrollView.
                // Nested maxHeight ScrollView froze the live stream below the fold
                // and stole the outer transcript pan (iOS). Keep this bounded
                // inner list eager: nesting LazyVStack inside the transcript
                // can repeatedly place self-sizing text rows on scroll.
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    if slice.hiddenCount > 0 {
                        Button {
                            let base = max(0, blocks.count - AgentWorkDisclosureLayout.expandedPaintWindow)
                            workDisclosureRevealByTurn[turn.turnId] = AgentWorkDisclosureLayout.advancedRevealCount(
                                current: reveal,
                                hiddenBase: base
                            )
                            workDisclosureLayoutEpoch &+= 1
                        } label: {
                            Text("Show earlier steps (\(slice.hiddenCount) hidden)")
                                .font(DS.Font.caption)
                                .foregroundColor(DS.Palette.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent.work.revealEarlier.\(turn.turnId)")
                    }
                    ForEach(slice.rows) { block in
                        switch block {
                        case .item(let item):
                            itemRow(item)
                        case .toolGroup(let id, let items): toolGroupRow(id: id, items: items)
                        }
                    }
                }
                .padding(.leading, DS.Space.md)
                .transition(AgentChatMotion.transition(.fadeAndMove, reduceMotion: reduceMotion))
                .accessibilityIdentifier("agent.work.lazyList.\(turn.turnId)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    @ViewBuilder
    private func itemRow(_ item: AssistantItem) -> some View {
        switch item.type {
        case .assistantMessage:
            if Self.shouldRenderAssistantItemBody(item.body, persistedAssistantTexts: persistedAssistantTexts) {
                assistantProse(item.body, cacheMarkdown: item.state != .streaming)
            }
        case .reasoning:
            reasoningRow(item)
        case .plan:
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("PLAN").font(DS.Font.caption2.weight(.semibold)).tracking(0.6)
                    .foregroundColor(DS.Palette.accent)
                assistantProse(item.body, cacheMarkdown: item.state != .streaming)
            }
        case .imageView:
            imageViewRow(item)
        case .tool, .commandExecution, .fileChange, .mcpToolCall, .dynamicToolCall, .collabToolCall, .webSearch, .review, .contextCompaction, .error:
            toolRow(item)
        }
    }

    // UX-MAC_AGENT-010: long chain-of-thought no longer pushes the answer down.
    // It stays open while streaming, then collapses to a tappable "Thought" row.
    @ViewBuilder
    private func reasoningRow(_ item: AssistantItem) -> some View {
        let text = reasoningText(item)
        let streaming = item.state == .streaming
        let expanded = streaming || expandedReasoning.contains(item.id)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button {
                guard !streaming, !text.isEmpty else { return }
                if expanded { expandedReasoning.remove(item.id) } else { expandedReasoning.insert(item.id) }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    if !streaming, !text.isEmpty {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                    }
                    Text(streaming ? "Thinking…" : "Thought")
                        .font(DS.Font.caption2.weight(.semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(streaming ? "" : (text.isEmpty ? "" : (expanded ? "Hide reasoning" : "Show reasoning")))
            if expanded, !text.isEmpty {
                AgentSelectablePlainText(
                    text: text,
                    fontSize: 12,
                    textColor: DS.NS.textTertiary,
                    lineSpacing: 3
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent.reasoning.\(item.id)")
    }

    private func reasoningText(_ item: AssistantItem) -> String {
        item.body.isEmpty ? (AgentTimelineItemPresentation.make(for: item).detail ?? "") : item.body
    }

    @ViewBuilder
    private func imageViewRow(_ item: AssistantItem) -> some View {
        let presentation = AgentTimelineItemPresentation.make(for: item)
        let imagePresentation = AgentImageViewPresentation.make(for: item)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: presentation.icon)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Palette.textSecondary)
                Text(presentation.label)
                    .font(DS.Font.mono)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let imagePresentation {
                    Button {
                        NSWorkspace.shared.open(imagePresentation.resourceURL)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open image")
                    .accessibilityIdentifier("agent.image.open.\(item.id)")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([imagePresentation.resourceURL])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                    .accessibilityIdentifier("agent.image.reveal.\(item.id)")
                }
            }
            if let imagePresentation {
                AgentTranscriptImageThumb(
                    url: imagePresentation.resourceURL,
                    displayName: imagePresentation.displayName,
                    style: .featured,
                    accessibilityID: "agent.image.preview.\(item.id)"
                )
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
    }

    @ViewBuilder
    private func toolRow(_ item: AssistantItem) -> some View {
        // Cursor-style file edit: show path + red/green hunks inline in the thread.
        if let editModel = AgentFileEditDiffPresentation.model(for: item),
           editModel.hasRenderableCode || item.type == .fileChange {
            AgentFileEditDiffCard(
                model: editModel,
                initiallyExpanded: AgentWorkDisclosureLayout.diffDefaultExpanded
            )
        } else {
            standardToolRow(item)
        }
    }

    @ViewBuilder
    private func standardToolRow(_ item: AssistantItem) -> some View {
        // Live clocks only on background / task-wait streaming rows (1s then 5s cadence).
        // Ordinary tools keep the v1 path: no per-row TimelineView.
        if AgentTimelineItemPresentation.showsLiveToolElapsed(for: item) {
            let start = Date(timeIntervalSince1970: TimeInterval(item.startedAtMs) / 1000.0)
            TimelineView(ElapsedTickSchedule(start: start)) { context in
                let nowMs = Int64(context.date.timeIntervalSince1970 * 1000)
                standardToolRowBody(item, nowMs: nowMs)
            }
        } else {
            standardToolRowBody(item, nowMs: nil)
        }
    }

    @ViewBuilder
    private func standardToolRowBody(_ item: AssistantItem, nowMs: Int64?) -> some View {
        let presentation = AgentTimelineItemPresentation.make(for: item)
        let displayLabel = AgentTimelineItemPresentation.toolDisplayLabel(for: item)
        // Prefer uncapped raw shell for expand/copy so live body caps cannot mangle JSON.
        let commandFull = AgentTimelineItemPresentation.rawShellCommand(for: item)
            ?? AgentTimelineItemPresentation.toolCommandPreview(for: item)
        let commandSummary = AgentTimelineItemPresentation.toolCommandSummary(for: item)
        let isBackground = AgentTimelineItemPresentation.isBackgroundTool(for: item)
        let duration = AgentTimelineItemPresentation.toolDurationLabel(for: item, nowMs: nowMs)
        let output = presentation.detail
        let hasOutput = (output?.isEmpty == false)
        let activityHint = AgentTimelineItemPresentation.toolActivityHint(for: item, hasOutput: hasOutput)
        let liveElapsed = AgentTimelineItemPresentation.showsLiveToolElapsed(for: item)
        let fullDiffersFromSummary = (commandFull != nil && commandFull != commandSummary)
        // Expand when there is output, a longer full command, multi-line input,
        // or a *streaming* wait row that needs status details before stdout arrives.
        let canExpand = hasOutput
            || fullDiffersFromSummary
            || (commandFull.map { $0.count > 96 || $0.contains("\n") } ?? false)
            || AgentTimelineItemPresentation.toolCanExpandWithoutOutput(for: item)
        let expanded = expandedTools.contains(item.id)
        let statusColor: Color = {
            switch item.state {
            case .streaming: return DS.Palette.accent
            case .failed: return DS.Palette.danger
            case .cancelled: return DS.Palette.textTertiary
            case .completed: return DS.Palette.textSecondary
            }
        }()
        let streamingStatus = AgentTimelineItemPresentation.toolStreamingStatusLabel(for: item)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button {
                guard canExpand else { return }
                if expanded { expandedTools.remove(item.id) } else { expandedTools.insert(item.id) }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: presentation.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(statusColor)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    (Text("\(presentation.verb) ")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                     + Text(displayLabel)
                        .font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text))
                    .lineLimit(1).truncationMode(.tail)
                    if isBackground {
                        Text("Background")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(DS.Palette.accent.opacity(0.12))
                            .clipShape(Capsule())
                            .accessibilityLabel("Background")
                    }
                    Spacer(minLength: 0)
                    // Single status word on L1 (verb). Trailing: elapsed for live waits,
                    // plain "Running" for ordinary streaming, Failed/duration for finished.
                    if liveElapsed {
                        if let duration {
                            Text(duration)
                                .font(DS.Font.caption2.monospacedDigit().weight(.medium))
                                .foregroundColor(DS.Palette.accent)
                                .accessibilityLabel("elapsed \(duration)")
                        } else {
                            Text(streamingStatus)
                                .font(DS.Font.caption2.weight(.semibold))
                                .foregroundColor(DS.Palette.accent)
                        }
                    } else if item.state == .streaming {
                        Text("Running")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.accent)
                    } else if item.state == .failed {
                        Text("Failed")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.danger)
                    } else if let duration {
                        Text(duration)
                            .font(DS.Font.caption2.monospacedDigit())
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                    if canExpand {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(canExpand
                  ? (expanded
                     ? "Hide details"
                     : (hasOutput ? "Show command and output" : "Show status and details"))
                  : "No further detail")
            .accessibilityLabel(
                AgentTimelineItemPresentation.toolAccessibilityLabel(for: item, nowMs: nowMs)
            )
            .accessibilityHint(canExpand
                               ? (expanded ? "Collapse tool details" : "Expand tool details")
                               : "")

            // L2: collapsed command summary (not the full cd && … | distill pipeline).
            // UX-MAC_AGENT-OPEN-SPLIT: file/URL tools keep an open-in-split affordance.
            if let summary = commandSummary, !summary.isEmpty {
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    AgentSelectablePlainText(
                        text: summary,
                        fontSize: 11,
                        monospaced: true,
                        textColor: DS.NS.textSecondary,
                        maximumNumberOfLines: expanded ? nil : 1
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(commandFull ?? summary)
                    if let full = commandFull, !full.isEmpty {
                        AgentChatCopyButton(text: full) { copied in
                            Image(systemName: AgentChatCopyChrome.symbolName(copied: copied))
                                .font(.system(size: 10))
                                .foregroundColor(DS.Palette.textTertiary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .dsPointingHandCursor()
                        .help("Copy full command")
                        .accessibilityIdentifier("agent.tool.copyCommand.\(item.id)")
                        .accessibilityLabel("Copy full command")
                    }
                    if let target = AgentTimelineItemPresentation.toolOpenTarget(for: item) {
                        Button {
                            switch target {
                            case .file(let path): vm.openFileMention(path)
                            case .url(let url): vm.openLinkMention(url)
                            }
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Palette.textTertiary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .dsPointingHandCursor()
                        .help("Open in split panel")
                        .accessibilityIdentifier("agent.tool.openInSplit.\(item.id)")
                    }
                }
                .padding(.horizontal, DS.Space.sm).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            }

            // Liveness strip: one "not frozen" line (no second elapsed — trailing owns the clock).
            if let activityHint {
                HStack(alignment: .center, spacing: DS.Space.sm) {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                    Text(activityHint)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.accent.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(activityHint)
                .accessibilityIdentifier("agent.tool.activityHint.\(item.id)")
            }

            // Expanded: full command (when longer/different than the summary) + output.
            if expanded, let full = commandFull, fullDiffersFromSummary, !full.isEmpty {
                AgentSelectablePlainText(
                    text: full,
                    fontSize: 11,
                    monospaced: true,
                    textColor: DS.NS.textTertiary
                )
                    .padding(.horizontal, DS.Space.sm).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .accessibilityIdentifier("agent.tool.fullCommand.\(item.id)")
            }

            // Output, collapsed by default and capped so a noisy command can't blow up
            // the transcript. Skill tool output stays complete (source-aware exception).
            // Full text stays selectable.
            if expanded, let o = output, !o.isEmpty {
                AgentSelectablePlainText(
                    text: AgentTimelineItemPresentation.cappedDetail(o, for: item),
                    fontSize: 12,
                    monospaced: true,
                    textColor: DS.NS.textSecondary
                )
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent.tool.row.\(item.id)")
    }

    // A collapsed burst of consecutive tool calls: "Ran N commands" with a count chip,
    // expandable to the individual tool rows (each still independently expandable for
    // output). While any member streams, the header goes live ("Running N…") and a muted
    // subtitle shows the most-recent command so progress stays legible without expanding.
    // Defense: if a live wait somehow remains grouped, show Waiting + elapsed on the header.
    @ViewBuilder
    private func toolGroupRow(id: String, items: [AssistantItem]) -> some View {
        let streaming = items.contains { $0.state == .streaming }
        let failed = items.contains { $0.state == .failed }
        let liveAnchor = AgentAppView.liveElapsedAnchor(in: items)
        let expanded = expandedToolGroups.contains(id)
        let reveal = toolGroupRevealByID[id] ?? 0
        let slice = AgentWorkDisclosureLayout.toolGroupPaintSlice(all: items, revealCount: reveal)
        let imageOnly = !items.isEmpty && items.allSatisfy { $0.type == .imageView }
        let imagePresentations = AgentImageViewPresentation.presentations(
            in: AgentWorkDisclosureLayout.toolGroupThumbnailPreview(
                all: items,
                isThumbnail: { $0.type == .imageView }
            )
        )
        let headerIcon = streaming
            ? "circle.dotted"
            : (failed ? "exclamationmark.triangle" : (imageOnly ? "photo" : "terminal"))
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Button {
                withAnimation(reduceMotion ? nil : DS.Motion.micro) {
                    if expanded { expandedToolGroups.remove(id) } else { expandedToolGroups.insert(id) }
                }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .frame(width: 10)
                    Image(systemName: headerIcon)
                        .font(.system(size: 11))
                        .foregroundColor(failed ? DS.Palette.danger : DS.Palette.textSecondary)
                    Text(Self.toolGroupSummary(items))
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let liveAnchor {
                        toolGroupLiveElapsedChip(liveAnchor)
                    } else if !expanded {
                        Text("\(items.count)")
                            .font(DS.Font.caption2.weight(.semibold).monospacedDigit())
                            .foregroundColor(DS.Palette.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(DS.Palette.surface)
                            .clipShape(Capsule())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse" : "Expand \(items.count) items")

            // UX: image citations show thumbnails in the transcript immediately —
            // no need to expand "Running 2 images…" to see what the agent viewed.
            if !imagePresentations.isEmpty {
                AgentTranscriptImageThumbStrip(
                    presentations: imagePresentations,
                    accessibilityPrefix: "agent.toolGroup.\(id).thumb"
                )
                .padding(.leading, 20)
            } else if streaming, !expanded, let latest = items.last {
                // Live peek at the current non-image command without forcing open.
                // Prefer the collapsed summary so cd/distill pipelines stay scannable.
                let preview = AgentTimelineItemPresentation.toolCommandSummary(for: latest)
                    ?? AgentTimelineItemPresentation.toolCommandPreview(for: latest)
                    ?? AgentTimelineItemPresentation.toolDisplayLabel(for: latest)
                if !preview.isEmpty {
                    Text(preview)
                        .font(DS.Font.monoSmall)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 20)
                }
                if let liveAnchor,
                   let hint = AgentTimelineItemPresentation.toolActivityHint(
                    for: liveAnchor,
                    hasOutput: liveAnchor.output?.isEmpty == false
                   ) {
                    Text(hint)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 20)
                        .accessibilityIdentifier("agent.toolGroup.activityHint.\(id)")
                }
            }

            if expanded {
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    Capsule()
                        .fill(DS.Palette.line)
                        .frame(width: 1.5)
                        .padding(.leading, 4)
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        if slice.hiddenCount > 0 {
                            Button {
                                let hiddenBase = max(0, items.count - AgentWorkDisclosureLayout.toolGroupPaintWindow)
                                toolGroupRevealByID[id] = AgentWorkDisclosureLayout.toolGroupAdvancedRevealCount(
                                    current: reveal,
                                    hiddenBase: hiddenBase
                                )
                                workDisclosureLayoutEpoch &+= 1
                            } label: {
                                Text("Show earlier items (\(slice.hiddenCount) hidden)")
                                    .font(DS.Font.caption)
                                    .foregroundColor(DS.Palette.accent)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("agent.toolGroup.revealEarlier.\(id)")
                        }
                        ForEach(slice.rows, id: \.id) { item in
                            // Image members keep the thumbnail card; other tools
                            // stay on the compact command row.
                            if item.type == .imageView {
                                imageViewRow(item)
                            } else {
                                toolRow(item)
                            }
                        }
                    }
                }
                .transition(AgentChatMotion.transition(.fadeAndMove, reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.toolGroup.\(id)")
    }

    @ViewBuilder
    private func toolGroupLiveElapsedChip(_ item: AssistantItem) -> some View {
        let start = Date(timeIntervalSince1970: TimeInterval(item.startedAtMs) / 1000.0)
        TimelineView(ElapsedTickSchedule(start: start)) { context in
            let nowMs = Int64(context.date.timeIntervalSince1970 * 1000)
            let duration = AgentTimelineItemPresentation.toolDurationLabel(for: item, nowMs: nowMs)
            let status = AgentTimelineItemPresentation.toolStreamingStatusLabel(for: item)
            HStack(spacing: DS.Space.xs) {
                if let duration {
                    Text(duration)
                        .font(DS.Font.caption2.monospacedDigit().weight(.medium))
                        .foregroundColor(DS.Palette.accent)
                } else {
                    Text(status)
                        .font(DS.Font.caption2.weight(.semibold))
                        .foregroundColor(DS.Palette.accent)
                }
            }
            .accessibilityLabel(
                duration.map { "\(status), elapsed \($0)" } ?? status
            )
        }
    }

    // MARK: Composer

    @ViewBuilder
    private var queuedMessagesSection: some View {
        // Only render the queue block when there is actually something queued. A
        // lingering queueStatusMessage (e.g. the "will run" confirmation after the
        // message already drained) must not show an empty "Queued 0" header.
        if !vm.queuedMessages.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                AgentQueuedHeader(count: vm.queuedMessages.count, identifier: "agent.queued.header")
                if let message = vm.queueStatusMessage {
                    HStack(spacing: DS.Space.sm) {
                        Text(message)
                            .font(DS.Font.caption)
                            .foregroundColor(message.contains("failed") ? DS.Palette.danger : DS.Palette.textSecondary)
                        Spacer(minLength: 0)
                        Button { vm.dismissQueueStatusMessage() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityLabel("Dismiss queue status")
                        .accessibilityIdentifier("agent.queue.status.inline.dismiss")
                        .help("Dismiss")
                    }
                }
                ForEach(vm.queuedMessages, id: \.id) { message in
                    queuedMessageRow(message)
                }
                .onMove { from, to in vm.reorderQueuedMessage(from: from, to: to) }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .background(DS.Palette.bg)
            .confirmationDialog(
                queuedMessagePendingCancel?.durableState == .prepared
                    ? "Remove message with unresolved provider acceptance?"
                    : "Cancel queued message?",
                isPresented: Binding(
                    get: { queuedMessagePendingCancel != nil },
                    set: { if !$0 { queuedMessagePendingCancel = nil } }
                )
            ) {
                Button(
                    queuedMessagePendingCancel?.durableState == .prepared
                        ? "Remove from queue"
                        : "Cancel queued message",
                    role: .destructive
                ) {
                    if let queuedMessagePendingCancel {
                        vm.removeQueuedMessage(queuedMessagePendingCancel)
                    }
                    queuedMessagePendingCancel = nil
                }
                Button("Keep message", role: .cancel) {
                    queuedMessagePendingCancel = nil
                }
            } message: {
                if queuedMessagePendingCancel?.durableState == .prepared {
                    Text(
                        "The provider may already have received this message. Removing it only abandons the queue record and cannot undo provider-side work."
                    )
                }
            }
        }
    }

    private func inlineStatusBanner(
        _ message: String,
        identifier: String,
        dismiss: @escaping () -> Void,
        offersCopy: Bool = true,
        retry: (() -> Void)? = nil
    ) -> some View {
        // Center the trailing controls with the message row so the dismiss "×"
        // sits on the same optical midline as "Copy"/Retry (`.top` left the
        // glyph high relative to caption text).
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Palette.danger)
                .frame(width: 14, height: 14, alignment: .center)
            AgentSelectablePlainText(
                text: message,
                fontSize: 11,
                textColor: DS.NS.text
            )
                .frame(maxWidth: .infinity, alignment: .leading)
            if offersCopy {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                .buttonStyle(.plain)
                .font(DS.Font.caption)
                .accessibilityIdentifier("\(identifier).copy")
            }
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.plain)
                    .font(DS.Font.caption)
                    .accessibilityIdentifier("\(identifier).retry")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Dismiss error")
            .accessibilityIdentifier("\(identifier).dismiss")
            .help("Dismiss error")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.danger.opacity(0.09))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func inlineInfoBanner(
        _ message: String,
        identifier: String,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 14, height: 14, alignment: .center)
            AgentSelectablePlainText(
                text: message,
                fontSize: 11,
                textColor: DS.NS.textSecondary
            )
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Dismiss history notice")
            .accessibilityIdentifier("\(identifier).dismiss")
            .help("Dismiss history notice")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.surfaceRaised)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func dismissibleStatusRow(
        _ message: String,
        identifier: String,
        color: Color,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Text(message)
                .font(DS.Font.caption)
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Dismiss error")
            .accessibilityIdentifier(identifier)
            .help("Dismiss error")
        }
    }

    private func queuedMessageRow(_ message: AgentQueuedMessage) -> some View {
        AgentQueuedRow(
            text: message.text.isEmpty ? attachmentSummary(message) : message.text,
            identifier: "agent.queued.row.\(message.id.value.uuidString)",
            leading: AnyView(
                Text("#\(message.position)")
                    .font(DS.Font.caption.monospacedDigit().weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: 28, alignment: .leading)
            ),
            detail: AnyView(
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    if vm.editingQueuedMessage?.id == message.id {
                        TextEditor(text: $vm.queuedMessageDraft)
                            .font(DS.Font.body)
                            .frame(minHeight: 64, maxHeight: 120)
                            .scrollContentBackground(.hidden)
                            .background(DS.Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .accessibilityLabel("Edit queued message \(message.position)")
                            .accessibilityIdentifier("agent.queued.editor.\(message.id.value.uuidString)")
                    }
                    if !message.attachments.isEmpty {
                        Label("\(message.attachments.count) attachment\(message.attachments.count == 1 ? "" : "s")", systemImage: "paperclip")
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                    if let durableStatus = vm.queuedMessageDurableStatus(message) {
                        Text(durableStatus)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(
                                "agent.queued.state.\(message.id.value.uuidString)"
                            )
                    }
                }
            )
        ) {
            HStack(spacing: DS.Space.sm) {
                if vm.editingQueuedMessage?.id == message.id {
                    Button("Save") { vm.saveQueuedMessageEdit() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Cancel") {
                        vm.editingQueuedMessage = nil
                        vm.queuedMessageDraft = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        Task { await vm.forceQueuedMessageNow(message) }
                    } label: {
                        Text(vm.queuedMessageForceLabel(message))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!vm.canForceQueuedMessage(message))
                    .accessibilityLabel(vm.queuedMessagePrimaryActionAccessibilityLabel(message))
                    .accessibilityIdentifier("agent.queued.force.\(message.id.value.uuidString)")
                    Button {
                        vm.editQueuedMessage(message)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled((message.durableState ?? .queued) != .queued)
                    .accessibilityLabel("Edit queued message \(message.position)")
                    .accessibilityIdentifier("agent.queued.edit.\(message.id.value.uuidString)")
                    Button {
                        if message.durableState == .prepared {
                            queuedMessagePendingCancel = message
                        } else if message.attachments.isEmpty && message.text.count < 120 {
                            vm.removeQueuedMessage(message)
                        } else {
                            queuedMessagePendingCancel = message
                        }
                    } label: {
                        if message.durableState == .prepared {
                            Text("Remove")
                                .foregroundColor(DS.Palette.danger)
                        } else {
                            Image(systemName: "trash")
                                .foregroundColor(DS.Palette.danger)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(message.durableState == .dispatched)
                    .tint(DS.Palette.danger)
                    .foregroundColor(DS.Palette.danger)
                    .accessibilityLabel(
                        message.durableState == .prepared
                            ? "Remove queued message \(message.position) with unresolved provider acceptance"
                            : "Cancel queued message \(message.position)"
                    )
                    .accessibilityIdentifier("agent.queued.cancel.\(message.id.value.uuidString)")
                }
            }
        }
        .padding(DS.Space.md)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
    }

    private func attachmentSummary(_ message: AgentQueuedMessage) -> String {
        message.attachments.map(\.displayName).joined(separator: ", ")
    }

    // Shared composer card. Git strip and extra capsules stay Agent App slots.
    private var composer: some View {
        AgentChatComposerBar(
            text: Binding(get: { vm.prompt }, set: { vm.prompt = $0 }),
            attachments: vm.attachments,
            placeholder: vm.composerPlaceholder,
            sendEnabled: !vm.isLegacyProviderThread && !sendIdleDisabled
                && AgentComposerChromePresentation.shows(.sendStop, mode: composerChromeMode),
            runActive: vm.selectedThreadIsStoppableBusy,
            isStopping: vm.isStopping,
            attachEnabled: composerChromeMode != .relay && vm.selectedProviderCanRun && !(vm.selectedProviderSnapshot.map {
                !$0.effectiveCapabilities.supportsAttachments
            } ?? false),
            onSend: { Task { await vm.send() } },
            onStop: { vm.stop() },
            onAttach: { vm.addAttachments($0) },
            onRemoveAttachment: { vm.removeAttachment($0) },
            composerIdentifier: "agent.composer.input",
            sendIdentifier: "agent.composer.send",
            leadingControls: AnyView(composerLeadingControls),
            suggestions: vm.composerSuggestions,
            onApplySuggestion: { suggestion in
                vm.applyComposerSuggestion(suggestion)
            },
            onCursorMoved: { vm.composerCursorOffset = $0 },
            suggestionIdentifier: "agent.suggestion.popup",
            focusTick: vm.focusTick,
            onPreviousHistory: { vm.recallPreviousPrompt() },
            onNextHistory: { vm.recallNextPrompt() },
            onTextEdited: { vm.promptWasEdited() },
            header: composerHeader,
            showsAttach: AgentComposerChromePresentation.shows(.attach, mode: composerChromeMode),
            attachmentChipPrefix: "agent.attachment.",
            attachmentsIdentifier: "agent.attachments",
            runStatusCaption: vm.selectedThreadIsStoppableBusy
                ? (vm.selectedThreadIsPreparingRun ? "Preparing" : "Running")
                : nil,
            onFileDrop: { vm.insertDroppedFilePaths($0) },
            attachUnavailableReason: composerChromeMode == .relay
                ? AgentComposerChromePresentation.relayAttachUnavailable : nil,
            ultracodeBorder: AgentUltracodeBorderPresentation.shows(
                provider: vm.provider, ultracode: vm.distillExecutionMode == .ultracode)
        )
    }

    private var composerHeader: AnyView? {
        let reply = vm.activeReplyTarget
        let summary = vm.gitSummary.flatMap { $0.files.isEmpty ? nil : $0 }
        guard reply != nil || summary != nil else { return nil }
        return AnyView(VStack(spacing: 0) {
            if let reply {
                AgentChatReplyQuoteStrip(excerpt: reply.displayExcerpt, onCancel: { vm.cancelReply() })
            }
            if let summary { changedFilesStrip(summary) }
        })
    }

    private var composerLeadingControls: some View {
        HStack(spacing: DS.Space.sm) {
            if AgentComposerChromePresentation.shows(.runAsUser, mode: composerChromeMode) {
                runAsUserMenu
            }
            if AgentComposerChromePresentation.shows(.source, mode: composerChromeMode),
               AgentSourceCapsulePresentation.isVisible(entryCount: sourceMenuEntries.count) {
                sourceMenu
            }
            if AgentComposerChromePresentation.shows(.model, mode: composerChromeMode),
               !vm.isLegacyProviderThread {
                if vm.provider == .distill {
                    AgentDistillModelPills(
                        mainModel: vm.model, mainModels: vm.modelOptionsForSelectedProvider,
                        customMainModels: vm.customModelsForSelectedProvider, reasoningModel: vm.reasoningModel,
                        reasoningModels: vm.modelOptionsForSelectedProvider,
                        mainEffortSelection: vm.distillMainEffortSelection,
                        mainEfforts: vm.supportedReasoningEffortsForSelectedModel,
                        supportsMainEffortAuto: vm.selectedProviderCapabilities.supportsDistillMainEffortAuto,
                        reasoningEffortSelection: vm.distillReasoningEffortSelection,
                        reasoningEfforts: vm.distillReasoningEfforts,
                        supportsReasoningModelEffort: vm.selectedProviderCapabilities.supportsDistillReasoningModelEffort,
                        homePath: vm.selectedProviderSnapshot?.homePath,
                        mainUnavailable: vm.selectedModelUnavailableNotice != nil,
                        serviceTierLabel: vm.serviceTier == .fast ? serviceTierLabel : nil,
                        isRunning: vm.selectedThreadRunIsStartingOrRunning,
                        isDisabled: vm.selectedThreadRunIsStartingOrRunning || !vm.selectedProviderCanRun,
                        emptyListTitle: vm.modelListLoading ? "Loading models..." : "No models available",
                        workerEmptyListTitle: vm.modelListLoading ? "Loading models..." : "No models yet. Connect an account on the start screen.",
                        menuWidth: compactModelMenuWidth,
                        mainIdentifier: "agent.model.menu", mainPopoverIdentifier: "agent.model.popover",
                        workerIdentifier: "agent.reasoningModel.menu", workerPopoverIdentifier: "agent.reasoningModel.popover",
                        onSelectMainModel: vm.setModel, onSelectCustomMainModel: vm.setCustomModel,
                        onSelectMainEffort: vm.setDistillMainEffortSelection,
                        onSelectWorkerModel: vm.setReasoningModel,
                        onSelectWorkerEffort: vm.setDistillReasoningEffortSelection,
                        onMainPopoverClosed: { showCustomModelField = false; customModelDraft = "" },
                        mainIsPresented: $showModelOptions,
                        statusHeader: { modelListStatusHeader },
                        mainFooter: {
                            if vm.supportsCustomModelForSelectedProvider {
                                if showCustomModelField { customModelInlineField }
                                else { compactMenuRow("Custom...", selected: false) {
                                    customModelDraft = vm.modelOptionsForSelectedProvider.contains(where: { $0.id == vm.model }) ? "" : vm.model
                                    showCustomModelField = true
                                }.disabled(vm.selectedThreadRunIsStartingOrRunning || !vm.selectedProviderCanRun) }
                            }
                        }
                    )
                    // Built-in list came from a failed discovery: retry live on open.
                    .onChange(of: showModelOptions) { isShowing in
                        if isShowing, vm.availableModelsAreFallback, !vm.modelListLoading {
                            Task { await vm.refreshModelList() }
                        }
                    }
                    AgentExecutionModeCapsule(
                        selected: vm.distillExecutionMode,
                        disabled: vm.selectedThreadRunIsStartingOrRunning || !vm.selectedProviderCanRun,
                        accessibilityIdentifier: "agent.distill.mode",
                        onSelect: { vm.setDistillExecutionMode($0) }
                    )
                } else { modelMenu }
            }
            if AgentComposerChromePresentation.shows(.permission, mode: composerChromeMode) {
                permissionMenu
            }
            if AgentComposerChromePresentation.shows(.execution, mode: composerChromeMode) {
                executionMenu
            }
        }
    }

    private func changedFilesStrip(_ s: GitSummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Text("\(s.files.count) file\(s.files.count == 1 ? "" : "s") changed")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    // IMP-MAC_AGENT-008: per-file +/- breakdown on hover, so users
                    // can preview the changed-files detail without leaving the
                    // composer to open the Git panel.
                    .help(changedFilesBreakdown(s))
                Text("+\(s.totalAdditions)")
                    .font(DS.Font.caption.monospacedDigit()).foregroundColor(DS.Palette.success)
                Text("−\(s.totalDeletions)")
                    .font(DS.Font.caption.monospacedDigit()).foregroundColor(DS.Palette.danger)
                Spacer(minLength: 0)
                Button { vm.onReviewRequested?() } label: {
                    Text("Review here")
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Review changes in the Git panel")
                .help("Review changes in the Git panel")
            }
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
        }
    }

    // IMP-MAC_AGENT-008: a per-file "path  +A −B" listing for the changed-files
    // hover tooltip; caps the list so a large change set stays readable.
    private func changedFilesBreakdown(_ s: GitSummary) -> String {
        let maxRows = 20
        var rows = s.files.prefix(maxRows).map { "\($0.path)  +\($0.additions) −\($0.deletions)" }
        if s.files.count > maxRows {
            rows.append("… \(s.files.count - maxRows) more")
        }
        return rows.joined(separator: "\n")
    }

    // MARK: System status strip + working phase strip

    @ViewBuilder
    private var systemStatusStrip: some View {
        let queueStandalone = Self.standaloneQueueStatusMessage(
            vm.queueStatusMessage,
            queuedCount: vm.queuedMessages.count
        )
        let candidates = AgentSystemStripPresentation.items(
            historyReplayNotice: vm.historyReplayNotice,
            statusMessage: Self.visibleStatusMessage(vm.statusMessage),
            providerSnapshotStatus: vm.providerThreadSnapshotStatusMessage,
            standaloneQueueStatus: queueStandalone
        )
        let collapsed = AgentSystemStripPresentation.collapse(candidates)
        if !collapsed.visible.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(collapsed.visible) { item in
                    systemStripRow(item)
                }
                if collapsed.overflowCount > 0 {
                    Text("+\(collapsed.overflowCount) more status")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .padding(.horizontal, DS.Space.lg)
                        .accessibilityIdentifier("agent.systemStrip.overflow")
                }
            }
            .accessibilityIdentifier("agent.systemStrip")
        }
    }

    private var deletedBotBanner: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 14, height: 14, alignment: .center)
            Text("This bot has been deleted. This conversation is read-only.")
                .font(.system(size: 11))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if vm.canContinueWithoutBot {
                Button("Continue without bot") {
                    continueWithoutBot()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("agent.deletedBot.continueWithoutBot")
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.deletedBot.banner")
    }

    private func continueWithoutBot() {
        guard let id = vm.selectedThreadId else { return }
        vm.startHandoffThread(from: id, actor: .none)
    }

    private var legacyProviderBanner: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 14, height: 14, alignment: .center)
            Text(vm.legacyProviderBannerText)
                .font(.system(size: 11))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("New Distill conversation") {
                vm.createThread(title: "New thread")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("agent.legacyProvider.newThread")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.legacyProvider.banner")
    }

    @ViewBuilder
    private func systemStripRow(_ item: AgentSystemStripItem) -> some View {
        if item.severity == .error {
            // Same strip as a failed page read: one error row for the chat.
            AgentChatErrorStrip(
                message: item.message,
                identifier: item.id,
                offersCopy: item.offersCopy,
                onRetry: item.offersRetry ? { retrySystemStripItem(item.id) } : nil,
                onDismiss: item.offersDismiss ? { dismissSystemStripItem(item.id) } : nil
            )
        } else {
            systemStripStatusRow(item)
        }
    }

    private func retrySystemStripItem(_ id: String) {
        switch id {
        case "agent.provider.snapshot.stale":
            vm.retryProviderThreadSnapshotRead()
        case "agent.queue.status":
            Task { await vm.send() }
        default:
            break
        }
    }

    private func dismissSystemStripItem(_ id: String) {
        switch id {
        case "agent.history.replay.notice":
            vm.dismissHistoryReplayNotice()
        case "agent.status.message":
            vm.dismissStatusMessage()
        case "agent.provider.snapshot.stale":
            vm.dismissProviderThreadSnapshotStatusMessage()
        case "agent.queue.status":
            vm.dismissQueueStatusMessage()
        default:
            break
        }
    }

    /// Warning and info rows. Errors go through `AgentChatErrorStrip`.
    private func systemStripStatusRow(_ item: AgentSystemStripItem) -> some View {
        let tone: Color = {
            switch item.severity {
            case .error: return DS.Palette.danger
            case .warning: return DS.Palette.warning
            case .info: return DS.Palette.textSecondary
            }
        }()
        let icon: String = {
            switch item.severity {
            case .error: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .info: return "info.circle"
            }
        }()
        return HStack(alignment: .center, spacing: DS.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tone)
                .frame(width: 14, height: 14, alignment: .center)
            AgentSelectablePlainText(
                text: item.message,
                fontSize: 11,
                textColor: item.severity == .info ? DS.NS.textSecondary : DS.NS.text
            )
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.offersCopy {
                AgentChatCopyButton(text: item.message) { AgentChatCopyWordLabel(copied: $0) }
                .font(DS.Font.caption)
                .accessibilityLabel("Copy")
                .accessibilityIdentifier("\(item.id).copy")
            }
            if item.offersRetry {
                Button("Retry") { retrySystemStripItem(item.id) }
                .buttonStyle(.plain)
                .font(DS.Font.caption)
                .accessibilityIdentifier("\(item.id).retry")
            }
            if item.offersDismiss {
                Button {
                    dismissSystemStripItem(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("\(item.id).dismiss")
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.surfaceRaised)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(item.id)
    }

    @ViewBuilder
    private var workingPhaseStrip: some View {
        let runLive = vm.selectedThreadRunIsStartingOrRunning
        let activeSubagents = vm.subagentActivity.activeCount
        let phase = AgentWorkingStripPresentation.phase(
            runIsLive: runLive,
            isAwaitingBackground: vm.isAwaitingBackgroundWork,
            backgroundShellCount: vm.backgroundShellCount,
            activeSubagentCount: activeSubagents,
            hasStreamingTools: Self.hasStreamingGroupableTools(in: vm.timeline.turns)
        )
        let elapsed: Int? = {
            guard runLive || vm.isAwaitingBackgroundWork else { return nil }
            guard let start = vm.runStartedAt else { return nil }
            return max(0, Int(vm.currentTime().timeIntervalSince(start)))
        }()
        if let label = AgentWorkingStripPresentation.label(
            phase: phase,
            elapsedSeconds: elapsed,
            hold: vm.backgroundHoldSummary
        ) {
            let tone: DSPill.Tone = {
                switch phase {
                case .awaitingBackground: return .warning
                case .subagents, .tools, .thinking: return .accent
                case .idle: return .neutral
                }
            }()
            let holdHelp = vm.backgroundHoldSummary.map {
                $0.accessibilityLabel(elapsedSeconds: elapsed ?? 0)
            }
            AgentChatWorkingPill(
                label: label,
                identifier: "agent.workingPhase",
                tone: tone,
                help: vm.backgroundHoldSummary?.helpText ?? phase.accessibilityLabel,
                accessibilityLabelText: holdHelp ?? phase.accessibilityLabel,
                padded: false
            )
        } else {
            AgentChatWorkingPill(
                label: vm.statusLabel,
                identifier: "agent.status.pill",
                tone: vm.openManualAction != nil ? .warning : statusTone(vm.status),
                padded: false
            )
        }
    }

    private var permissionMenu: some View {
        AgentPermissionCapsule(
            selected: vm.permissionMode,
            modes: vm.linkedBotVMRequiresFullAccess ? [.fullAccess] : AgentPermissionMode.allCases,
            unavailableReason: { vm.permissionModeUnavailableReason($0) },
            disabled: vm.activeRunConfigurationLocked || !vm.selectedProviderCanRun,
            help: vm.providerExecutionUnavailableReason
                ?? (vm.activeRunConfigurationLocked ? "Permission is fixed for the active run" : "Permission mode"),
            accessibilityIdentifier: "agent.permission.menu",
            onSelect: { vm.setPermissionMode($0) }
        )
    }

    private var executionMenu: some View {
        Button { showExecutionSheet = true } label: {
            AgentComposerCapsule {
                AgentComposerCapsuleLabel(
                    icon: vm.executionMode == .worktree ? "arrow.triangle.branch" : "folder",
                    title: vm.executionMode == .worktree ? "Worktree" : "Local",
                    chevron: true
                )
            }
        }
        .buttonStyle(.plain).fixedSize()
        .disabled(vm.executionLocked || !vm.selectedProviderCanRun)
        .help(vm.providerExecutionUnavailableReason
            ?? (vm.executionLocked ? "Execution mode locks after the first message" : "Execution mode"))
        .accessibilityIdentifier("agent.execution.menu")
        .sheet(isPresented: $showExecutionSheet) { executionSheet }
    }

    private var executionSheet: some View {
        AgentChoiceSheet(
            icon: "folder",
            title: "Where should it run?",
            subtitle: "Choose how changes land in this workspace.",
            width: 520,
            accessibilityIdentifier: "agent.execution.sheet",
            onClose: { showExecutionSheet = false }
        ) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    AgentChoiceSectionHeader("Mode")
                    AgentChoiceCard(
                        title: "Local",
                        subtitle: "Edit files directly in this workspace.",
                        selected: vm.executionMode == .local,
                        disabledReason: vm.executionLocked ? "Execution mode locks after the first message" : nil,
                        accessibilityIdentifier: "agent.execution.local",
                        action: { vm.setExecutionMode(.local) }
                    ) {
                        AgentChoiceIconTile(systemName: "folder")
                    }
                    AgentChoiceCard(
                        title: "Worktree",
                        subtitle: "Work in an isolated git worktree, then review the changes.",
                        selected: vm.executionMode == .worktree,
                        disabledReason: vm.executionLocked ? "Execution mode locks after the first message" : nil,
                        accessibilityIdentifier: "agent.execution.worktree",
                        action: { vm.setExecutionMode(.worktree) }
                    ) {
                        AgentChoiceIconTile(systemName: "arrow.triangle.branch")
                    }
                }
                if vm.executionMode == .worktree {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        AgentChoiceSectionHeader("Base branch")
                        TextField("Base branch", text: Binding(
                            get: { vm.baseBranch },
                            set: { vm.setBaseBranch($0) }
                        ))
                        .textFieldStyle(.plain)
                        .font(DS.Font.bodyDense)
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.sm)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.surfaceRaised))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                        if let path = vm.worktreePath, !path.isEmpty {
                            Text(path)
                                .font(DS.Font.caption.monospaced())
                                .foregroundColor(DS.Palette.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    AgentChoiceSectionHeader("Open a pull request")
                    TextField("PR URL", text: $vm.pullRequestURL)
                        .textFieldStyle(.plain)
                        .font(DS.Font.bodyDense)
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.sm)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.surfaceRaised))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    Button(vm.pullRequestPreparing ? "Opening..." : "Open PR as thread") {
                        Task { await vm.preparePullRequestThread() }
                    }
                    .disabled(vm.pullRequestPreparing || vm.pullRequestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.executionLocked)
                    if let message = vm.pullRequestStatusMessage {
                        dismissibleStatusRow(
                            message,
                            identifier: "agent.pr.status.dismiss",
                            color: message.hasPrefix("PR preparation failed") ? DS.Palette.danger : DS.Palette.textSecondary,
                            dismiss: { vm.dismissPullRequestStatusMessage() }
                        )
                    }
                }
            }
        } footer: {
            HStack {
                Spacer(minLength: 0)
                Button("Done") { showExecutionSheet = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Run-as capsule: macOS user + Bot actor. Left of provider source + model.
    private var runAsUserMenu: some View {
        let selected = vm.runAsUser ?? AgentRunAsUser.current()
        return AgentRunAsUserCapsule(
            usersProvider: { vm.availableRunAsUsers.isEmpty ? MacOSLocalUserCatalog.listEligibleUsers() : vm.availableRunAsUsers },
            selected: selected,
            runLocked: vm.selectedThreadRunIsStartingOrRunning,
            identityLocked: vm.runActorLocked,
            accessibilityIdentifier: "agent.runAsUser.menu",
            actor: vm.selectedRunActor,
            botsProvider: { vm.mentionableBotsProvider() },
            botName: { vm.botNameProvider($0) },
            canContinueWithoutBot: vm.canContinueWithoutBot,
            executionTarget: { vm.executionTarget(for: $0) },
            onSelect: { vm.setRunAsUser($0) },
            onSelectActor: { vm.setRunActor($0) },
            onContinueWithoutBot: { continueWithoutBot() },
            onHandoffToBot: { botID in
                guard let id = vm.selectedThreadId else { return }
                vm.startHandoffThread(from: id, actor: .bot(botID))
            },
            onAppear: { vm.refreshAvailableRunAsUsers() },
            workspaceID: vm.embedding == nil ? vm.workspaceID : nil,
            onNewBot: vm.createBotInWorkspace.map { create in { create(vm.workspaceID) } }
        )
    }

    /// Dedicated provider-instance source capsule (CODEX_HOME isolation).
    /// Reuses provider snapshots + `setProviderInstance` so personal/work
    /// CLI configs stay the single selection authority (not a second state).
    ///
    /// Always openable (Button + popover), matching the model pill. A SwiftUI
    /// `Menu` that collapses to a static label when locked made "click does
    /// nothing" the common report after the first message — fail loud instead.
    private var sourceMenu: some View {
        AgentSourceCapsule(
            label: sourceCapsuleLabel,
            entries: sourceMenuEntries,
            runLocked: vm.selectedThreadRunIsStartingOrRunning,
            providerLocked: vm.providerLocked,
            unavailableReason: vm.providerExecutionUnavailableReason,
            rowWidth: compactModelMenuWidth,
            accessibilityIdentifier: "agent.source.menu",
            popoverIdentifier: "agent.source.popover",
            isPresented: $showSourceOptions,
            onSelect: selectSourceMenuEntry
        )
    }

    private var sourceCanSwitch: Bool {
        AgentSourceCapsulePresentation.isInteractive(
            enabledSourceCount: sourceMenuEntries.count,
            providerLocked: vm.providerLocked,
            // Only an in-flight run blocks switching. An unauthenticated /
            // unavailable *current* provider must not trap the user — they need
            // the menu open to pick a working account.
            runLocked: vm.selectedThreadRunIsStartingOrRunning
        )
    }

    private var sourceCapsuleLabel: String {
        AgentSourceCapsulePresentation.capsuleLabel(
            selected: vm.selectedProviderSnapshot,
            fallbackProvider: vm.provider,
            fallbackInstanceId: vm.providerInstanceId,
            snapshots: vm.providerSnapshots
        )
    }

    private var sourceMenuEntries: [AgentSourceCapsulePresentation.MenuEntry] {
        AgentSourceCapsulePresentation.menuEntries(
            snapshots: vm.providerSnapshots,
            selectedSnapshotId: vm.selectedProviderSnapshot?.id,
            selectedProvider: vm.provider,
            providerDisplayName: { vm.providerDisplayName($0) }
        )
    }

    private func selectSourceMenuEntry(_ entry: AgentSourceCapsulePresentation.MenuEntry) {
        guard sourceCanSwitch else { return }
        if vm.providerSnapshots.contains(where: { $0.id == entry.id }) {
            vm.setProviderInstance(entry.id)
            return
        }
        if let provider = AgentProvider(rawValue: entry.id) {
            vm.setProvider(provider)
            Task {
                await vm.loadModels()
                await MainActor.run { vm.persistThreadConfig() }
            }
        }
    }

    private var modelMenu: some View {
        Button {
            showModelOptions.toggle()
        } label: {
            AgentModelPillLabel(presentation: modelPillPresentation, width: currentModelMenuLabelWidth)
        }
        .buttonStyle(.plain)
        // P3: expose a meaningful VoiceOver label instead of the raw concatenated
        // pill text (e.g. "gpt-5.5 · medium · ..." becomes "Model gpt-5.5, effort medium").
        .accessibilityLabel(modelMenuAccessibilityLabel)
        .accessibilityIdentifier("agent.model.menu")
        // UX-MAC_AGENT-016: keep the menu openable while running so the user can
        // read the current model/effort/tier; the mutating rows inside disable
        // themselves (see modelOptionsPopover) so nothing changes mid-run.
        .popover(isPresented: $showModelOptions, arrowEdge: .bottom) {
            modelOptionsPopover
        }
        .onChange(of: showModelOptions) { isShowing in
            if !isShowing {
                showAllModelOptions = false
                showCustomModelField = false
                customModelDraft = ""
            }
        }
        // Source/account selection lives on the dedicated left capsule so the
        // model popover stays model/effort/tier only.
        .help("Model · reasoning effort · service tier")
    }

    /// Loading / retry / fallback header shared by the Main and Reasoning
    /// popovers so both Distill pills report list health identically.
    private var modelListStatusHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.modelListLoading {
                Text("Loading models...")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            // P2: retry stays enabled while running so a model-list failure
            // mid-run can be recovered without stopping the agent.
            if vm.modelListStatusMessage != nil || vm.providerSnapshotStatusMessage != nil {
                compactMenuRow("Retry loading models", selected: false) {
                    Task {
                        await vm.loadProviderSnapshots()
                        await vm.loadModels()
                    }
                }
                .disabled(vm.modelListLoading)
            }
            if let modelListStatus = vm.modelListStatusMessage {
                dismissibleStatusRow(
                    modelListStatus,
                    identifier: "agent.modelList.status.dismiss",
                    color: DS.Palette.danger,
                    dismiss: { vm.dismissModelListStatusMessage() }
                )
            }
            if let providerSnapshotStatus = vm.providerSnapshotStatusMessage {
                dismissibleStatusRow(
                    providerSnapshotStatus,
                    identifier: "agent.providerSnapshot.status.dismiss",
                    color: DS.Palette.danger,
                    dismiss: { vm.dismissProviderSnapshotStatusMessage() }
                )
            }
            // F33: no provider gate — codex's baked-in list must surface
            // the same fallback notice + refresh affordance as claude.
            if vm.displayedModelListIsFallback {
                Text("Live model list unavailable. Refresh to check available models.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                compactMenuRow("Refresh model list", selected: false) {
                    // F11: reloads snapshots (the rows the picker shows)
                    // and bypasses the discovery TTL, not just loadModels.
                    Task { await vm.refreshModelList() }
                }
                .disabled(vm.modelListLoading)
            }
        }
    }

    private var modelOptionsPopover: some View {
        // P2: "Retry loading models" must remain tappable even mid-run so a
        // failed model-list fetch can be retried without stopping the run.
        // Only mutation rows (set provider/model/effort/tier) are disabled
        // while running; the retry and recovery rows are excluded.
        let running = vm.selectedThreadRunIsStartingOrRunning
        let configurationLocked = running || !vm.selectedProviderCanRun
        let showsAutoRouting = vm.provider != .distill
        let presentation = AgentModelPopoverPresentation.current(
            mode: vm.routingMode,
            autoRoutingLoading: autoRoutingPrerequisitesLoading
        )
        return AgentModelPopoverChrome(
            presentation: presentation,
            autoEnabled: Binding(
                get: { vm.routingMode == .auto },
                set: { _ = vm.setAutoModelRoutingEnabled($0) }
            ),
            toggleDisabled: running || !presentation.autoToggleEnabled,
            showsAutoRouting: showsAutoRouting,
            // The shared Main section owns its title and subtitle.
            title: "Model"
        ) {
            // UX-MAC_AGENT-016: readable while running; mutation rows disable below.
            if running {
                Text("Read-only while running")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            let modelOptions = vm.modelOptionsForSelectedProvider
            let customModels = vm.customModelsForSelectedProvider
            modelListStatusHeader
                if !modelOptions.isEmpty || !customModels.isEmpty {
                    // F9: a pinned model missing from the displayed list is kept —
                    // explain why no row is checked instead of silently swapping.
                    if let unavailableNotice = vm.selectedModelUnavailableNotice {
                        Text(unavailableNotice)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.warning)
                    }
                    compactMenuSection("Model")
                    let visibleModelCount = showAllModelOptions ? modelOptions.count : min(3, modelOptions.count)
                    let visibleCustomModelCount = showAllModelOptions ? customModels.count : max(0, 3 - visibleModelCount)
                    let visibleModels = Array(modelOptions.prefix(visibleModelCount))
                    let visibleCustomModels = Array(customModels.prefix(visibleCustomModelCount))
                    ForEach(visibleModels, id: \.id) { model in
                        compactMenuRow(model.label, selected: model.id == vm.model) {
                            vm.setModel(model.id)
                            showModelOptions = false
                        }
                        .disabled(configurationLocked)
                    }
                    ForEach(visibleCustomModels, id: \.self) { customModel in
                        compactMenuRow(customModel, selected: customModel == vm.model) {
                            vm.setCustomModel(customModel)
                            showModelOptions = false
                        }
                        .disabled(configurationLocked)
                    }
                    if modelOptions.count + customModels.count > 3, !showAllModelOptions {
                        compactMenuRow("More...", selected: false) {
                            showAllModelOptions = true
                        }
                    }
                }
                if vm.supportsCustomModelForSelectedProvider {
                    if showCustomModelField {
                        customModelInlineField
                    } else {
                        compactMenuRow("Custom...", selected: false) {
                            customModelDraft = vm.modelOptionsForSelectedProvider.contains(where: { $0.id == vm.model }) ? "" : vm.model
                            showCustomModelField = true
                        }
                        .disabled(configurationLocked)
                    }
                }
            if (vm.provider != .distill && vm.supportsReasoningForSelectedModel)
                || vm.supportsServiceTierForSelectedModel {
                compactMenuDivider
            }
            if vm.provider != .distill && vm.routingMode == .manual && vm.supportsReasoningForSelectedModel {
                compactMenuSection("Reasoning effort")
                ForEach(vm.supportedReasoningEffortsForSelectedModel, id: \.self) { effort in
                    compactMenuRow(effort.displayName, selected: effort == vm.reasoningEffort) {
                        vm.setReasoningEffort(effort)
                        showModelOptions = false
                    }
                    .disabled(configurationLocked)
                    // F34: bare names don't distinguish Ultracode/Max/Extra
                    // High — say what each level buys before it is selected.
                    .help(effort.pickerHelpText)
                }
            }
            if vm.routingMode == .manual && vm.supportsServiceTierForSelectedModel {
                compactMenuSection("Service tier")
                compactMenuRow("Auto", selected: vm.serviceTier == .auto) {
                    vm.setServiceTier(.auto)
                    showModelOptions = false
                }
                .disabled(configurationLocked)
                compactMenuRow("Fast", selected: vm.serviceTier == .fast) {
                    vm.setServiceTier(.fast)
                    showModelOptions = false
                }
                .disabled(configurationLocked)
            }
            if let providerStatus = vm.providerStatusMessage {
                compactMenuDivider
                dismissibleStatusRow(
                    providerStatus,
                    identifier: "agent.provider.status.dismiss",
                    color: DS.Palette.danger,
                    dismiss: { vm.dismissProviderStatusMessage() }
                )
            }
            if let actionTitle = vm.providerRecoveryActionTitle {
                compactMenuRow(vm.providerRecoveryActionRunning ? "Working..." : actionTitle, selected: false) {
                    Task { await vm.performProviderRecoveryAction() }
                }
                .disabled(vm.providerRecoveryActionRunning)
            }
            if let actionStatus = vm.providerRecoveryStatusMessage {
                dismissibleStatusRow(
                    actionStatus,
                    identifier: "agent.providerRecovery.status.dismiss",
                    color: actionStatus.hasPrefix("Update failed") || actionStatus.hasPrefix("Could not") || actionStatus.hasPrefix("Sign-in unavailable")
                        ? DS.Palette.danger
                        : DS.Palette.textSecondary,
                    dismiss: { vm.dismissProviderRecoveryStatusMessage() }
                )
            }
        }
        .accessibilityIdentifier("agent.model.popover")
    }

    private func compactMenuSection(_ title: String) -> some View {
        AgentCompactMenuSection(title)
    }

    private func compactMenuRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        AgentCompactMenuRow(title, selected: selected, width: compactModelMenuWidth, action: action)
    }

    private var compactMenuDivider: some View {
        AgentCompactMenuDivider(width: compactModelMenuWidth)
    }

    // UX-MAC_AGENT-013: inline custom-model field, no blocking modal. Validates
    // non-empty (trimmed) before saving; Esc/blur-style Cancel dismisses it.
    private var customModelInlineField: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            TextField("Model ID", text: $customModelDraft)
                .textFieldStyle(.roundedBorder)
                .font(DS.Font.caption)
                .frame(width: compactModelMenuWidth)
                .onSubmit { commitCustomModelDraft() }
                .accessibilityIdentifier("agent.model.custom.input")
            HStack(spacing: DS.Space.xs) {
                Button("Save") { commitCustomModelDraft() }
                    .controlSize(.small)
                    .disabled(customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("agent.model.custom.save")
                Button("Cancel") {
                    showCustomModelField = false
                    customModelDraft = ""
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, DS.Space.xs)
        .disabled(vm.selectedThreadRunIsStartingOrRunning || !vm.selectedProviderCanRun)
    }

    private func commitCustomModelDraft() {
        let trimmed = customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vm.selectedThreadRunIsStartingOrRunning,
              vm.selectedProviderCanRun,
              !trimmed.isEmpty else { return }
        vm.setCustomModel(trimmed)
        showCustomModelField = false
        customModelDraft = ""
        showModelOptions = false
    }

    // PERF-MAC_AGENT-009: the menu width was recomputed (build title array +
    // max width) on every popover re-render and inside every row's layout.
    // Memoize it, recomputing only when the option set actually changes.
    private final class ModelMenuWidthCache {
        var signature: String?
        var width: CGFloat = 112
    }
    private let modelMenuWidthCache = ModelMenuWidthCache()

    private var compactModelMenuWidth: CGFloat {
        // Source/account titles moved to the dedicated capsule; this width is
        // only for model/effort/tier rows inside the model popover.
        var titles: [String] = []
        let modelOptions = vm.modelOptionsForSelectedProvider
        let customModels = vm.customModelsForSelectedProvider
        let visibleModelCount = showAllModelOptions ? modelOptions.count : min(3, modelOptions.count)
        let visibleCustomModelCount = showAllModelOptions ? customModels.count : max(0, 3 - visibleModelCount)
        titles.append(contentsOf: modelOptions.prefix(visibleModelCount).map(\.label))
        titles.append(contentsOf: customModels.prefix(visibleCustomModelCount))
        if vm.supportsCustomModelForSelectedProvider {
            titles.append("Custom...")
        }
        if modelOptions.count + customModels.count > 3, !showAllModelOptions {
            titles.append("More...")
        }
        if vm.routingMode == .manual && vm.supportsReasoningForSelectedModel {
            titles.append(contentsOf: vm.supportedReasoningEffortsForSelectedModel.map(\.displayName))
        }
        if vm.routingMode == .manual && vm.supportsServiceTierForSelectedModel {
            titles.append(contentsOf: ["Auto", "Fast"])
        }
        if vm.providerRecoveryActionTitle != nil {
            titles.append(vm.providerRecoveryActionRunning ? "Working..." : (vm.providerRecoveryActionTitle ?? ""))
        }
        let signature = titles.joined(separator: "\u{1}")
        if modelMenuWidthCache.signature == signature {
            return modelMenuWidthCache.width
        }
        let width = AgentModelMenuWidth.estimatedWidth(titles: titles)
        modelMenuWidthCache.signature = signature
        modelMenuWidthCache.width = width
        return width
    }

    private var currentModelMenuLabelWidth: CGFloat {
        let parts = currentModelMenuLabelParts
        let measured = Self.measureCurrentModelMenuLabel(parts.joined(separator: " · "))
        let spacing = CGFloat(parts.count + 1) * DS.Space.xs
        let loadingWidth = autoRoutingPillLoading ? 14 + DS.Space.xs : 0
        return min(max(ceil(measured + 8 + loadingWidth + spacing), 44), 260)
    }

    private var currentModelMenuLabelParts: [String] {
        if vm.routingMode == .auto { return ["Auto"] }
        var parts = [modelLabel]
        if vm.supportsReasoningForSelectedModel { parts.append(effortLabel) }
        if vm.serviceTier == .fast { parts.append(serviceTierLabel) }
        if let ctx = vm.selectedModelContextWindowLabel { parts.append(ctx) }
        return parts
    }

    private static func measureCurrentModelMenuLabel(_ label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        return (label as NSString).size(withAttributes: [.font: font]).width
    }

    private func loadDroppedFileAttachments(from providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { vm.insertDroppedFilePaths([url.path]) }
            }
        }
        return true
    }

    private var sendIdleDisabled: Bool {
        let empty =
            vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && vm.attachments.isEmpty
        // S5: block concurrent same-thread prep; Stop/Escape handle cancellation.
        // Disable Send while preparing; active runs keep queue/send affordances.
        return empty || autoRoutingPillLoading || vm.selectedThreadIsPreparingRun
    }

    private func selectThreadRow(_ thread: AgentThread) {
        if NSEvent.modifierFlags.contains(.shift),
           let lastSelectedThreadId,
           let last = vm.threads.firstIndex(where: { $0.id == lastSelectedThreadId }),
           let current = vm.threads.firstIndex(where: { $0.id == thread.id }) {
            let range = min(last, current)...max(last, current)
            selectedThreadIds.formUnion(vm.threads[range].map(\.id))
        } else {
            selectedThreadIds = [thread.id]
            lastSelectedThreadId = thread.id
        }
        vm.selectThread(thread.id)
    }

    private func deleteSelectedThreads() {
        let fallback = vm.selectedThreadId.map { Set([$0]) } ?? []
        let ids = selectedThreadIds.isEmpty ? fallback : selectedThreadIds
        guard !ids.isEmpty else { return }
        // P1: route through confirmation dialog — destructive and instant.
        pendingDeleteThreadIds = ids
    }

    private func deleteThreads(_ ids: Set<AgentThreadID>) {
        guard !ids.isEmpty else { return }
        Task {
            guard await vm.deleteThreads(ids) else { return }
            selectedThreadIds.subtract(ids)
            if let lastSelectedThreadId, ids.contains(lastSelectedThreadId) {
                self.lastSelectedThreadId = selectedThreadIds.first
            }
        }
    }

    private func commitPendingDelete() {
        let ids = pendingDeleteThreadIds
        pendingDeleteThreadIds = []
        deleteThreads(ids)
    }

    private func commitClearAllThreads() {
        pendingClearAllThreads = false
        Task {
            _ = await vm.clearAllThreads()
        }
    }

    private func activePlanRow(_ plan: AssistantActivePlan) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                Text("Active plan")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                Spacer(minLength: 0)
            }
            if let explanation = plan.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(DS.Font.bodyDense)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(plan.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                        Image(systemName: step.status.iconName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(step.status.tint)
                            .frame(width: 16)
                        Text(step.title)
                            .font(DS.Font.bodyDense)
                            .foregroundColor(DS.Palette.text)
                        Spacer(minLength: DS.Space.sm)
                        Text(step.status.label)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                }
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .accessibilityIdentifier("agent.activePlan")
    }

    private func proposedPlanRow(_ plan: AssistantProposedPlan) -> some View {
        let markdown = proposedPlanExpanded ? plan.markdown : plan.collapsedPreview
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: plan.implementedAtMs == nil ? "list.bullet.clipboard" : "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.implementedAtMs == nil ? "Proposed plan" : "Implementation started")
                        .font(DS.Font.caption.weight(.semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                    Text(plan.exportTitle)
                        .font(DS.Font.bodyDense.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                }
                Spacer(minLength: 0)
            }
            AgentMessageMarkdownView(text: markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DS.Space.xs) {
                if plan.showsImplementationActions {
                    Button {
                        Task { await vm.implementLatestPlan(newThread: false) }
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Task { await vm.rejectLatestPlan() }
                    } label: {
                        Label("Reject", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Task { await vm.implementLatestPlan(newThread: true) }
                    } label: {
                        Label("New thread", systemImage: "plus.message")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    copyToPasteboard(markdown)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Button {
                    saveLatestProposedPlan()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                if plan.markdown != plan.collapsedPreview {
                    Button {
                        proposedPlanExpanded.toggle()
                    } label: {
                        Label(proposedPlanExpanded ? "Collapse" : "Show all",
                              systemImage: proposedPlanExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .accessibilityIdentifier("agent.proposedPlan.\(plan.id)")
    }
}

private extension AssistantPlanStepStatus {
    var iconName: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .inProgress: return "In progress"
        case .completed: return "Done"
        }
    }

    var tint: Color {
        switch self {
        case .pending: return DS.Palette.textTertiary
        case .inProgress: return DS.Palette.accent
        case .completed: return DS.Palette.success
        }
    }
}

enum PromptComposerKeyAction: Equatable {
    case send
    case insertNewline
    case previousHistory
    case nextHistory
    case ignore

    static func action(for event: NSEvent) -> PromptComposerKeyAction {
        action(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    // QA-MAC_AGENT-012: pure key mapping, testable without building an NSEvent.
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> PromptComposerKeyAction {
        if modifiers.intersection([.command, .control, .option]).isEmpty {
            if keyCode == 126 { return .previousHistory }
            if keyCode == 125 { return .nextHistory }
        }
        guard keyCode == 36 || keyCode == 76 else { return .ignore }
        // P2: Shift+Enter and Option+Enter both insert a newline; plain Enter sends.
        let wantsNewline = modifiers.contains(.shift) || modifiers.contains(.option)
        return wantsNewline ? .insertNewline : .send
    }

    /// Whether this key should go through AppKit text input (`interpretKeyEvents`)
    /// instead of send/history/popup routing.
    ///
    /// Dead keys (ABNT/US-International acute, tilde, circumflex, …) often arrive
    /// with empty `characters` and no Option modifier on the first press. Those
    /// MUST still use text input so marked-text composition can commit ç/á/é/…
    /// into the prompt. Only Return/arrows/Esc stay on the command routes.
    static func shouldInterpretTextInput(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?
    ) -> Bool {
        guard modifiers.intersection([.command, .control]).isEmpty else { return false }
        switch keyCode {
        case 36, 76, 125, 126, 53:
            return false
        default:
            return true
        }
    }

    /// Whether the SwiftUI binding / cursor observers may sync from the NSTextView.
    ///
    /// WHY: publishing preedit/marked text into SwiftUI re-enters `updateNSView`,
    /// which can replace `string` and abort dead-key composition (á/é/í, CJK).
    /// Keep the text view as sole owner until `hasMarkedText` clears.
    static func shouldSyncComposerBinding(hasMarkedText: Bool) -> Bool {
        !hasMarkedText
    }

    // macos:32: resolves a keystroke given whether the caret-anchored suggestion
    // popup is open. When the popup is CLOSED this ALWAYS defers to the existing
    // 2-arg `action(keyCode:modifiers:)` via `.passthrough`, so send/history
    // behavior is byte-for-byte identical to today. When the popup is OPEN, the
    // navigation keys (up/down/Return/Esc, with no disqualifying modifiers) are
    // intercepted; everything else still passes through. The existing 2-arg fn
    // is left UNCHANGED.
    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, popupOpen: Bool) -> ComposerKeyResolution {
        let passthrough = ComposerKeyResolution.passthrough(action(keyCode: keyCode, modifiers: modifiers))
        guard popupOpen else { return passthrough }
        let hasHardModifier = !modifiers.intersection([.command, .control, .option]).isEmpty
        switch keyCode {
        case 126 where !hasHardModifier && !modifiers.contains(.shift):
            return .navUp
        case 125 where !hasHardModifier && !modifiers.contains(.shift):
            return .navDown
        case 36, 76:
            // Plain Return applies the selection; Shift/Option-Return must still
            // insert a newline (passthrough), so the user can compose multiline
            // prompts while the popup is visible.
            if modifiers.contains(.shift) || modifiers.contains(.option) { return passthrough }
            return .applySelected
        case 53:
            return .dismissPopup
        default:
            return passthrough
        }
    }
}

// macos:32: outcome of a keystroke when the suggestion popup may be open.
enum ComposerKeyResolution: Equatable {
    case navUp
    case navDown
    case applySelected
    case dismissPopup
    case passthrough(PromptComposerKeyAction)
}

// Radio + freeform field for the auto-provided "Other" choice of a structured
// AskUserQuestion. The Other field is a real member of the radio group: tapping the
// radio claims the single selection (clearing any chosen option) so the user is no
// longer stuck with an option's radio marked, and typing also claims it via the
// binding. Owns its own @FocusState so focusing the field on a radio tap does not
// invalidate the perf-sensitive AgentAppView body.
private struct AskUserQuestionOtherField: View {
    @ObservedObject var vm: AgentAppViewModel
    let question: AssistantUserInputQuestion
    let request: AssistantUserInputRequest
    @FocusState private var focused: Bool

    var body: some View {
        let selected = vm.askUserQuestionOtherIsSelected(question: question, request: request)
        // Other is mutually exclusive with the listed options in BOTH single- and
        // multi-select questions (selecting Other replaces any chosen option), so it
        // always reads as a radio. A checkbox glyph would falsely promise it combines
        // with checked boxes when the model actually replaces them.
        let symbol = selected ? "largecircle.fill.circle" : "circle"
        let draft = Binding(
            get: { vm.userInputDrafts[vm.askUserQuestionKey(request, question)] ?? "" },
            set: { vm.setAskUserQuestionOther($0, question: question, request: request) }
        )
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Button {
                vm.selectAskUserQuestionOther(question: question, request: request)
                if vm.askUserQuestionOtherIsSelected(question: question, request: request) {
                    focused = true
                }
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundColor(selected ? DS.Palette.accent : DS.Palette.textTertiary)
                    // Pad the glyph so the radio has a comfortable tap target instead of a
                    // razor-thin 12pt hit area; the listed option rows are fully tappable.
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Other")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("agent.askOther.\(request.id).\(question.id)")
            TextField("Other…", text: draft)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($focused)
        }
    }
}

// macos:32: pure, value-type navigation logic for the composer suggestion
// popup. Holds NO view state and is unit-testable in isolation. `selectedIndex`
// is the highlighted row (nil == nothing highlighted yet).
struct ComposerSuggestionNavigation: Equatable {
    var selectedIndex: Int?

    static func reset() -> Int? { nil }

    // Down: from nil -> 0; otherwise advance with wrap-around. count==0 -> nil.
    static func moveDown(selected: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current = selected else { return 0 }
        let clamped = max(0, min(current, count - 1))
        return (clamped + 1) % count
    }

    // Up: from nil -> last row; otherwise retreat with wrap-around. count==0 -> nil.
    static func moveUp(selected: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current = selected else { return count - 1 }
        let clamped = max(0, min(current, count - 1))
        return (clamped - 1 + count) % count
    }

    // The popup is open iff there is at least one suggestion and the user has
    // not dismissed it (Esc) for the current token.
    static func isOpen(count: Int, dismissed: Bool) -> Bool {
        count > 0 && !dismissed
    }
}

// WHY: layout for the slash/skill panel must stay pure and testable. The panel
// owns vertical space between the editor and toolbar so it never collides with
// composer controls (the previous caret-overlay + place-below path did).
public struct ComposerSuggestionPlacement: Equatable {
    public var height: CGFloat
    public var rowHeight: CGFloat
    public var maxVisibleRows: Int

    public static let defaultRowHeight: CGFloat = 30
    public static let defaultMaxVisibleRows = 6

    public static func layout(
        suggestionCount: Int,
        rowHeight: CGFloat = defaultRowHeight,
        maxVisibleRows: Int = defaultMaxVisibleRows
    ) -> ComposerSuggestionPlacement {
        let visible = min(max(suggestionCount, 0), max(maxVisibleRows, 0))
        return ComposerSuggestionPlacement(
            height: CGFloat(visible) * rowHeight,
            rowHeight: rowHeight,
            maxVisibleRows: maxVisibleRows
        )
    }
}

// MARK: - ScrollBottomGeometry (pure, testable)

/// Flipped-aware bottom gap / max origin for NSScrollView clip math.
/// WHY: hard-coded `content - (origin + visible)` assumes a flipped document;
/// non-flipped AppKit hosts invert both gap and "scroll up" origin delta.
enum ScrollBottomGeometry {
    /// Distance from the visible rect to the reading-order bottom of the document.
    /// 0 means flush at bottom (within floating error).
    nonisolated static func gap(
        documentHeight: CGFloat,
        visibleOriginY: CGFloat,
        visibleHeight: CGFloat,
        isFlipped: Bool
    ) -> CGFloat {
        if isFlipped {
            return documentHeight - (visibleOriginY + visibleHeight)
        }
        // Non-flipped: origin.y == 0 is the bottom of the document.
        return visibleOriginY
    }

    /// Clip origin.y that places the reading-order bottom flush in the viewport.
    nonisolated static func maxScrollOriginY(
        documentHeight: CGFloat,
        visibleHeight: CGFloat,
        isFlipped: Bool
    ) -> CGFloat {
        if isFlipped {
            return max(0, documentHeight - visibleHeight)
        }
        return 0
    }

    /// Negative when the user scrolls toward the top (older content).
    /// Flipped: origin decreases on scroll-up. Non-flipped: origin increases.
    nonisolated static func originDeltaTowardTop(
        previousOriginY: CGFloat,
        currentOriginY: CGFloat,
        isFlipped: Bool
    ) -> CGFloat {
        if isFlipped {
            return currentOriginY - previousOriginY
        }
        return previousOriginY - currentOriginY
    }

    /// Whether SwiftUI `configure(pinned:)` may re-arm a locally detached follower.
    /// Force token change = FAB / send / thread open. Stale stream body must not re-pin.
    nonisolated static func shouldAcceptSwiftUIPin(
        localPinned: Bool,
        swiftUIPinned: Bool,
        forceTokenChanged: Bool,
        geometricallyAtBottom: Bool
    ) -> Bool {
        if !swiftUIPinned { return false }
        if localPinned { return true }
        // Detached: only explicit force rejoin or user returned to bottom.
        return forceTokenChanged || geometricallyAtBottom
    }
}

// MARK: - ScrollPinPolicy (pure, testable)

/// Pure pin/unpin decision extracted from TimelineScrollFollower for unit-testing.
///
/// Callers supply the geometry they already have; this type owns NO AppKit state.
/// Extracted to support T040 (PERF-MAC_AGENT-021 regression harness).
enum ScrollPinTransition {
    /// Gap has closed to <= slack: re-pin.
    case reachedBottom
    /// Origin moved toward top by more than the noise threshold while NOT at the bottom:
    /// a genuine user scroll-up (delta already normalized by ScrollBottomGeometry).
    case scrolledAway
    /// Neither condition: no state change.
    case unchanged
}

enum ScrollPinPolicy {
    /// `NSApp.currentEvent` retains the last event after dispatch. Accept its
    /// scroll-wheel fallback only while that event is genuinely in flight;
    /// otherwise later layout growth is misclassified as a user scroll.
    nonisolated static func isRecentScrollInput(
        eventTimestamp: TimeInterval,
        now: TimeInterval,
        maximumAge: TimeInterval = 0.25
    ) -> Bool {
        let age = now - eventTimestamp
        return age >= 0 && age <= maximumAge
    }

    /// Decide the pin-state transition that a clip-bounds change implies.
    ///
    /// UX contract (Agent App iOS + macOS):
    /// - **User-owned** scroll **up** while away from bottom → unpin (audit mode).
    /// - Reach bottom (gap ≤ slack) → re-pin (auto-follow resumes).
    /// - Content growth, Lazy materialize, and programmatic snaps move origin too —
    ///   they must NOT unpin (iOS `AgentScrollPinPolicy.userOwned` parity). Origin-only
    ///   unpin false-fired the FAB mid-stream when layout jitter exceeded 0.5pt.
    ///
    /// - Parameters:
    ///   - originDelta: flip-normalized delta; negative means motion toward top.
    ///   - gap: distance from the bottom of visible content to the bottom of the document.
    ///   - slack: tolerance in points; gap <= slack is treated as "at bottom".
    ///   - userOwned: true only for live user scroll (trackpad/wheel/scrollbar), never
    ///     for programmatic `scrollTo` / AppKit snaps / content-frame growth.
    /// - Returns: The transition, if any.
    nonisolated static func evaluate(
        originDelta: CGFloat,
        gap: CGFloat,
        slack: CGFloat,
        userOwned: Bool
    ) -> ScrollPinTransition {
        if gap <= slack {
            return .reachedBottom
        } else if userOwned && originDelta < -0.5 {
            return .scrolledAway
        }
        return .unchanged
    }

    /// Programmatic stream/scroll must never re-pin an auditor.
    /// force=true is reserved for FAB, send, and thread open.
    nonisolated static func shouldProgrammaticFollow(pinned: Bool, force: Bool) -> Bool {
        force || pinned
    }
}

// PERF-MAC_AGENT-004: 1s cadence for the first minute, 5s after, so the
// "Working for Xs" row stops forcing a re-render every second on long runs.
// Perf CH-12: honour `mode == .lowFrequency` (SwiftUI passes it while the
// view is occluded / its window is minimized) by pinning the 5s cadence, so
// hidden live tool clocks are not a steady 1s wake-up source. Mirrors
// `AgentChatElapsedTickSchedule`.
struct ElapsedTickSchedule: TimelineSchedule {
    let start: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let current = next
            let elapsed = current.timeIntervalSince(start)
            let step: TimeInterval = (elapsed < 60 && mode != .lowFrequency) ? 1 : 5
            next = current.addingTimeInterval(step)
            return current
        }
    }
}

/// Pure presentation rules for the composer account/source capsule.
/// Extracted so personal/work label, lock, and menu identity can be unit-tested
/// without mounting the Agent App surface.
public enum AgentSourceCapsulePresentation {
    public struct MenuEntry: Equatable, Sendable {
        public let id: String
        public let title: String
        public let isSelected: Bool

        public init(id: String, title: String, isSelected: Bool) {
            self.id = id
            self.title = title
            self.isSelected = isSelected
        }
    }

    /// True only when selecting a different account would take effect.
    /// Callers still open the capsule so locked / single-source states can
    /// explain themselves (fail loud). `runLocked` means an in-flight run —
    /// not "current provider cannot execute" (that must leave the menu usable
    /// so the user can switch to a working account).
    public static func isInteractive(
        enabledSourceCount: Int,
        providerLocked: Bool,
        runLocked: Bool
    ) -> Bool {
        enabledSourceCount > 1 && !providerLocked && !runLocked
    }

    /// Visible capsule label. Prefer configured displayName, then accountLabel,
    /// then provider/instance fallback. Never invent "Personal"/"Work" from paths.
    public static func capsuleLabel(
        selected: AgentProviderSnapshot?,
        fallbackProvider: AgentProvider,
        fallbackInstanceId: String,
        snapshots: [AgentProviderSnapshot]
    ) -> String {
        let base = primaryLabel(
            selected: selected,
            fallbackProvider: fallbackProvider,
            fallbackInstanceId: fallbackInstanceId
        )
        let enabled = snapshots.filter(\.enabled)
        guard enabled.count > 1 else { return base }
        let collisions = enabled.filter {
            primaryLabel(selected: $0, fallbackProvider: $0.provider, fallbackInstanceId: $0.id) == base
        }
        guard collisions.count > 1, let selected else { return base }
        let providerToken = selected.provider.rawValue.capitalized
        if base.localizedCaseInsensitiveContains(providerToken) {
            // Same provider + same display name → keep id so work/personal
            // clones remain distinguishable without guessing from HOME.
            return "\(base) · \(selected.id)"
        }
        return "\(providerToken) · \(base)"
    }

    /// The capsule only exists when there is a real choice between Distill instances.
    public static func isVisible(entryCount: Int) -> Bool { entryCount > 1 }

    public static func menuEntries(
        snapshots: [AgentProviderSnapshot],
        selectedSnapshotId: String?,
        selectedProvider: AgentProvider,
        providerDisplayName: (AgentProvider) -> String
    ) -> [MenuEntry] {
        // Only selectable (Distill) accounts are offered; legacy-provider rows never appear.
        let snapshots = snapshots.filter { $0.provider.isSelectable }
        if snapshots.isEmpty {
            return AgentProvider.selectable.map { provider in
                MenuEntry(
                    id: provider.rawValue,
                    title: providerDisplayName(provider),
                    isSelected: provider == selectedProvider
                )
            }
        }

        let enabled = snapshots.filter(\.enabled)
        // Always surface the currently selected snapshot even if disabled so
        // a locked/missing instance is not silently rewritten in the menu.
        var rows: [AgentProviderSnapshot] = enabled
        if let selectedSnapshotId,
           let selected = snapshots.first(where: { $0.id == selectedSnapshotId }),
           !rows.contains(where: { $0.id == selected.id }) {
            rows.append(selected)
        }

        let covered = Set(rows.map(\.provider))
        for provider in AgentProvider.selectable where !covered.contains(provider) {
            if let any = snapshots.first(where: { $0.provider == provider }) {
                rows.append(any)
            }
        }

        var entries = rows.map { snapshot in
            let title = capsuleLabel(
                selected: snapshot,
                fallbackProvider: snapshot.provider,
                fallbackInstanceId: snapshot.id,
                snapshots: snapshots
            )
            return MenuEntry(
                id: snapshot.id,
                title: title,
                isSelected: snapshot.id == selectedSnapshotId
            )
        }

        let coveredAfter = Set(rows.map(\.provider))
        for provider in AgentProvider.selectable where !coveredAfter.contains(provider) {
            entries.append(MenuEntry(
                id: provider.rawValue,
                title: providerDisplayName(provider),
                isSelected: false
            ))
        }

        // If snapshot id did not match (stale "codex" vs "codex-cli"), mark
        // the first row for the selected provider so the menu shows a check.
        if !entries.contains(where: \.isSelected) {
            if let idx = entries.firstIndex(where: { entry in
                if let snap = rows.first(where: { $0.id == entry.id }) {
                    return snap.provider == selectedProvider
                }
                return entry.id == selectedProvider.rawValue
            }) {
                let e = entries[idx]
                entries[idx] = MenuEntry(id: e.id, title: e.title, isSelected: true)
            }
        }

        return entries
    }

    public static func helpText(
        canSwitch: Bool,
        runLocked: Bool,
        providerLocked: Bool,
        unavailableReason: String?
    ) -> String {
        if runLocked { return "Account is fixed while a run is active" }
        if providerLocked {
            return "Account is fixed after the first message. Start a new thread to use a different account."
        }
        if let unavailableReason, !unavailableReason.isEmpty { return unavailableReason }
        if !canSwitch { return "Account / source for this agent run" }
        return "Choose the provider or account that runs this thread"
    }

    public static func switchHint(canSwitch: Bool, helpText: String) -> String {
        canSwitch
            ? "Choose which Distill instance runs this thread"
            : helpText
    }

    public struct LockNotice: Equatable {
        public let text: String
        public let isWarning: Bool
        public let wraps: Bool
    }

    public static func lockNotice(
        runLocked: Bool,
        providerLocked: Bool,
        unavailableReason: String?,
        entryCount: Int
    ) -> LockNotice? {
        if runLocked {
            return LockNotice(text: "Account is fixed while a run is active", isWarning: false, wraps: false)
        }
        if providerLocked {
            return LockNotice(
                text: "Account is fixed after the first message. Start a new thread to use a different account.",
                isWarning: false,
                wraps: true
            )
        }
        if let unavailableReason, !unavailableReason.isEmpty {
            return LockNotice(text: unavailableReason, isWarning: true, wraps: true)
        }
        if entryCount <= 1 {
            return LockNotice(text: "Only one account is available", isWarning: false, wraps: false)
        }
        return nil
    }

    private static func primaryLabel(
        selected: AgentProviderSnapshot?,
        fallbackProvider: AgentProvider,
        fallbackInstanceId: String
    ) -> String {
        if let selected {
            let displayName = selected.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayName.isEmpty { return displayName }
            let account = selected.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !account.isEmpty { return account }
            return selected.provider.rawValue.capitalized
        }
        let instance = fallbackInstanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instance.isEmpty, instance != fallbackProvider.rawValue {
            return instance
        }
        return fallbackProvider.rawValue.capitalized
    }
}

enum AgentThreadRowPresentation {
    static func isRunning(threadStatus: AgentRunStatus, selected: Bool, surfaceStatus: AgentRunStatus) -> Bool {
        AgentThreadStopEligibility.isEligible(threadStatus: threadStatus)
            || (selected && AgentThreadStopEligibility.isEligible(threadStatus: surfaceStatus))
    }

    static func showsLeadingStatus(
        threadStatus: AgentRunStatus,
        selected: Bool,
        surfaceStatus: AgentRunStatus,
        hasUnread: Bool,
        pinned: Bool
    ) -> Bool {
        pinned || threadStatus == .failed || !hasUnread
            || isRunning(threadStatus: threadStatus, selected: selected, surfaceStatus: surfaceStatus)
    }

    static func showsSelectionCheck(
        threadStatus: AgentRunStatus,
        selected: Bool,
        surfaceStatus: AgentRunStatus,
        multiSelected: Bool
    ) -> Bool {
        multiSelected && !selected && !isRunning(threadStatus: threadStatus, selected: selected, surfaceStatus: surfaceStatus)
    }
}

/// Pure eligibility helper for per-thread stop affordances in the thread rail.
/// Determines whether a stop action is available for a given thread and, if so,
/// which threadId should be targeted. Extracted as a pure type so it can be
/// tested without touching any MainActor surface.
public enum AgentThreadStopEligibility {
    /// True while provider work is starting or running.
    public static func isEligible(threadStatus: AgentRunStatus) -> Bool {
        threadStatus == .pending || threadStatus == .running
    }

    /// Returns the threadId to target with stopThread(_:) when eligible, nil otherwise.
    public static func targetThreadId(thread: AgentThread) -> AgentThreadID? {
        isEligible(threadStatus: thread.status) ? thread.id : nil
    }
}

private struct AgentThreadDropDelegate: DropDelegate {
    let vm: AgentAppViewModel
    @Binding var draggingThreadId: AgentThreadID?
    let target: AgentThread

    func dropEntered(info: DropInfo) {
        guard let draggingThreadId, draggingThreadId != target.id else { return }
        vm.reorderThread(draggingThreadId, before: target.id)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingThreadId = nil
        return true
    }
}


public enum AgentAppSurfaceCheckpointRevealError: LocalizedError {
    case notFound
    public var errorDescription: String? { "Checkpoint not found for this run and file." }
}

public enum AgentAppSurfaceMessageRevealError: LocalizedError {
    case messageNotFound(AgentMessageID)
    case historyLoadFailed(String)
    case selectionChanged

    public var errorDescription: String? {
        switch self {
        case .messageNotFound(let id): return "Message not found: \(id.value.uuidString)"
        case .historyLoadFailed(let message): return message
        case .selectionChanged: return "Message reveal superseded by a newer thread selection or request"
        }
    }
}

@MainActor
public final class AgentAppSurface: NSObject, Surface {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    public let viewModel: AgentAppViewModel
    /// EventBus subscription so socket-driven thread mutations refresh
    /// this already-open surface (wired by AppCommandRouter, like Feed).
    public var subscriptionToken: AnyHashable?
    /// Called once by close() to release the EventBus subscription.
    /// Set by AppCommandRouter immediately after subscribe (mirrors Feed pattern).
    public var onClose: (() -> Void)?

    public init(workspaceID: WorkspaceID, cwd: String, coordinator: AgentRunCoordinator, threadRepo: AgentThreadRepository, messageRepo: AgentMessageRepository, draftRepo: AgentThreadDraftRepository? = nil, attachmentStore: AgentAttachmentStore? = nil, queuedMessageRepo: AgentQueuedMessageRepository? = nil, providerSessionRepo: ProviderSessionRuntimeRepository? = nil, pendingCallbackRepo: ProviderPendingCallbackRepository? = nil, proposedPlanRepo: AgentProposedPlanRepository? = nil, checkpointRepo: AgentTurnCheckpointRepository? = nil, promptHistoryStore: PromptHistoryStore? = nil, customModelStore: AgentCustomModelStore? = nil, planNotesStore: PlanNotesStore? = nil, title: String = "Agent App", initialThreadId: AgentThreadID? = nil, sideThreadId: AgentThreadID? = nil, orchestrationRuntime: AgentOrchestrationRuntime = AgentOrchestrationRuntime(), openAccountsSettings: (() -> Void)? = nil) {
        var metadata = ["workspace": workspaceID.value.uuidString, "cwd": cwd]
        if let binding = sideThreadId ?? initialThreadId { metadata["selected_thread"] = binding.value.uuidString }
        self.descriptor = SurfaceDescriptor(type: .agentApp, title: title, iconName: "sparkle", metadata: metadata)
        self.viewModel = AgentAppViewModel(workspaceID: workspaceID, cwd: cwd, coordinator: coordinator, threadRepo: threadRepo, messageRepo: messageRepo, draftRepo: draftRepo, attachmentStore: attachmentStore, queuedMessageRepo: queuedMessageRepo, providerSessionRepo: providerSessionRepo, pendingCallbackRepo: pendingCallbackRepo, proposedPlanRepo: proposedPlanRepo, checkpointRepo: checkpointRepo, promptHistoryStore: promptHistoryStore, customModelStore: customModelStore, planNotesStore: planNotesStore, initialThreadId: initialThreadId, sideThreadId: sideThreadId, initialRoutingMode: .auto, newThreadDefaultsStore: .shared, orchestrationRuntime: orchestrationRuntime)
        let host = NSHostingView(rootView: AgentAppView(vm: viewModel, openAccountsSettings: openAccountsSettings))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        self.view = container
        super.init()
    }

    public func revealMessage(id: AgentMessageID) async throws {
        try await viewModel.revealMessage(id: id)
    }

    public func focus() {
        viewModel.focusTick &+= 1
        view.window?.makeFirstResponder(view)
    }
    public func unfocus() {}
    public func didBecomeHidden() {
        viewModel.setVisibility(.hidden)
    }
    public func didBecomeVisible() {
        viewModel.setVisibility(.visible)
    }
    public func close() {
        // Drop coordinator fan-out + heavy transcript state before unregister.
        // Multi-tab freezes were amplified by closed surfaces still buffering
        // stream events until ARC collected the weak observer.
        viewModel.dispose()
        onClose?()
        onClose = nil
    }
    public func sendText(_ text: String) {
        viewModel.prompt = (viewModel.prompt.isEmpty ? text : viewModel.prompt + "\n" + text)
    }
    public func readText() -> String {
        viewModel.messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
    }
    public func snapshot() -> [String: String] {
        ["selected_thread": viewModel.selectedThreadId?.value.uuidString ?? "",
         "provider": viewModel.provider.rawValue,
         "model": viewModel.model]
    }

    // A3: drives the tab/workspace spinner.
    public var isBusy: Bool { viewModel.hasRunningWorkForChrome }
}

// Pure keyboard-navigation helper for the thread rail.
// Non-MainActor + pure so the movement math is testable without any UI.
//
// moveThreadSelection(current:direction:count:)
//   direction: +1 = down, -1 = up.
//   Returns nil when count == 0 (empty rail -- no movement, no crash).
//   Clamps result to 0..<count so callers never receive an out-of-range index.
//   nil current with count > 0 returns 0 (first row) regardless of direction.
enum AgentThreadRailKeyboardNav {
    static func moveThreadSelection(current: Int?, direction: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let idx = current else { return 0 }
        return max(0, min(count - 1, idx + direction))
    }
}

private struct TabColorMenuLabel: View {
    let title: String
    let swatchImage: NSImage

    init(_ color: TabColor) {
        self.title = color.label
        self.swatchImage = Self.swatchImage(hex: color.hex)
    }

    private init(title: String, swatchImage: NSImage) {
        self.title = title
        self.swatchImage = swatchImage
    }

    static var none: TabColorMenuLabel {
        TabColorMenuLabel(title: "None", swatchImage: noneSwatchImage())
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: swatchImage)
                .renderingMode(.original)
        }
    }

    private static func swatchImage(hex: UInt32) -> NSImage {
        menuImage { rect in
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 2, dy: 2),
                xRadius: 3,
                yRadius: 3
            )
            NSColor(hex: hex).setFill()
            path.fill()
            DS.NS.lineStrong.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private static func noneSwatchImage() -> NSImage {
        menuImage { rect in
            let box = NSBezierPath(
                roundedRect: rect.insetBy(dx: 2, dy: 2),
                xRadius: 3,
                yRadius: 3
            )
            DS.NS.textTertiary.withAlphaComponent(0.9).setStroke()
            box.lineWidth = 1
            box.stroke()

            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 4, y: rect.minY + 4))
            slash.line(to: NSPoint(x: rect.maxX - 4, y: rect.maxY - 4))
            slash.lineWidth = 1.25
            slash.stroke()
        }
    }

    private static func menuImage(draw: @escaping (NSRect) -> Void) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Clickable transcript mentions (UX-MAC_AGENT-OPEN-SPLIT)
// File paths and links mentioned in transcript prose (and tool rows) are tappable.
// The VM resolves the raw mention against the thread's working directory and hands
// an absolute path / URL to the router callbacks, which open (or reuse) a split
// panel to the right of the surface.
extension AgentAppViewModel {
    /// Routes a tapped transcript link. Returns true when handled here (file
    /// mention or web link); false lets the system handler take over.
    @discardableResult
    public func handleTranscriptLink(_ url: URL) -> Bool {
        if let raw = AgentMessageMarkdown.filePath(fromFileLink: url) {
            openFileMention(raw)
            return true
        }
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https":
            openLinkMention(url)
            return true
        case "file":
            openFileMention(url.path)
            return true
        case "":
            // Markdown relative targets (`[plan](./plan)`) parse with no scheme.
            // Treat path-shaped tokens as file mentions so they open the Files split
            // the same way auto-detected `./plan` links do.
            if let raw = Self.relativeFileMentionToken(from: url),
               Self.isPathShapedFileMention(raw) {
                openFileMention(raw)
                return true
            }
            return false
        default:
            return false
        }
    }

    /// Best-effort path token from a scheme-less / relative markdown URL.
    nonisolated static func relativeFileMentionToken(from url: URL) -> String? {
        if let raw = AgentMessageMarkdown.filePath(fromFileLink: url) { return raw }
        let candidates = [url.relativeString, url.absoluteString, url.path]
        for c in candidates {
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t != "/", !t.hasPrefix("http://"), !t.hasPrefix("https://") else { continue }
            // Strip accidental percent-encoding from markdown-produced URLs.
            let decoded = t.removingPercentEncoding ?? t
            if isPathShapedFileMention(decoded) { return decoded }
        }
        return nil
    }

    public func openLinkMention(_ url: URL) {
        if let onOpenURLInSplit {
            onOpenURLInSplit(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    public func openFileMention(_ raw: String) {
        guard let resolved = Self.resolveFileMention(raw, root: worktreePath ?? cwd) else {
            NSSound.beep()
            return
        }
        if let onOpenFileInSplit {
            onOpenFileInSplit(resolved)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: resolved))
        }
    }

    /// Path-shaped mention (`./plan`, `../x`, `/abs`, `foo/bar`) vs bare filename.
    /// Path shapes may open Files at the workspace root when the leaf is missing;
    /// bare filenames must not (too ambiguous).
    nonisolated static func isPathShapedFileMention(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix(".") { return true }
        return t.contains("/")
    }

    /// Resolves a raw file mention to an existing absolute path: strips a
    /// `:line(:col)` suffix, expands `~`, resolves relative tokens against `root`,
    /// falls back to a bounded workspace search for bare filenames, then to the
    /// nearest existing ancestor directory (a mention of a since-deleted file still
    /// lands near it). Path-shaped mentions may land on the workspace root so
    /// `./plan` opens the Files split even before the file exists. nil when
    /// nothing on disk plausibly matches.
    nonisolated static func resolveFileMention(_ raw: String, root: String, fileManager: FileManager = .default) -> String? {
        let token = strippingLineSuffix(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !token.isEmpty else { return nil }
        let expanded = (token as NSString).expandingTildeInPath
        let candidate: String
        if expanded.hasPrefix("/") {
            candidate = (expanded as NSString).standardizingPath
        } else {
            candidate = ((root as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
        }
        if fileManager.fileExists(atPath: candidate) { return candidate }
        if !token.contains("/"), let hit = searchWorkspace(filename: token, root: root, fileManager: fileManager) {
            return hit
        }
        // Nearest existing ancestor. Bare filenames must not degrade to the
        // workspace root. Single-segment path shapes (`./plan`) may open the root
        // so planned deliverables still open the Files split before they exist.
        // Deep nonsense paths (`nowhere/at/all.xyz`) still refuse.
        let standardizedRoot = (root as NSString).standardizingPath
        let allowsRootFallback = Self.allowsWorkspaceRootFallback(forCandidate: candidate, root: standardizedRoot)
        var dir = candidate
        while dir.count > 1 {
            dir = (dir as NSString).deletingLastPathComponent
            if dir.isEmpty || dir == "/" { return nil }
            if dir == standardizedRoot {
                if allowsRootFallback, fileManager.fileExists(atPath: dir) { return dir }
                return nil
            }
            if fileManager.fileExists(atPath: dir) { return dir }
        }
        return nil
    }

    /// `./plan` / `plan.html` (one leaf under root) may open Files at the workspace
    /// root when missing. Multi-segment missing trees do not.
    nonisolated static func allowsWorkspaceRootFallback(forCandidate candidate: String, root: String) -> Bool {
        let standardizedRoot = (root as NSString).standardizingPath
        let standardizedCandidate = (candidate as NSString).standardizingPath
        guard standardizedCandidate.hasPrefix(standardizedRoot + "/") else { return false }
        let relative = String(standardizedCandidate.dropFirst(standardizedRoot.count + 1))
        let parts = relative.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
        return parts.count == 1
    }

    /// "path.swift:12" / "path.swift:12:5" → "path.swift". Only digit-only
    /// trailing segments are stripped, so "http://host:8080" shapes are safe.
    nonisolated static func strippingLineSuffix(_ token: String) -> String {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return token }
        var end = parts.count
        while end > 1, !parts[end - 1].isEmpty, parts[end - 1].allSatisfy(\.isNumber) { end -= 1 }
        return parts[0..<end].joined(separator: ":")
    }

    /// Bounded search for a bare filename mention ("Reducer.swift") under the
    /// workspace root. Skips hidden directories and common dependency/build dirs;
    /// caps visited entries so a huge tree cannot stall the click.
    nonisolated static func searchWorkspace(filename: String, root: String, fileManager: FileManager = .default, visitLimit: Int = 25_000) -> String? {
        let skippedDirectories: Set<String> = ["node_modules", "DerivedData", "Pods", "dist", "build", "target", "vendor"]
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > visitLimit { return nil }
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory, name.hasPrefix(".") || skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            // standardizingPath: the enumerator yields /private/var/... forms for
            // symlinked roots; callers compare against the standardized root.
            if name == filename { return (url.path as NSString).standardizingPath }
        }
        return nil
    }
}
