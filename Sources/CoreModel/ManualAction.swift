import Foundation

public enum ManualActionKind: String, Codable, CaseIterable, Sendable {
    case login
    case captcha
    case twoFactor = "2fa"
    case payment
    case confirm
    /// The bot needs a file from the user's Mac copied into its VM.
    case file
    case other
}

public enum ManualActionState: String, Codable, Sendable {
    case open
    case taken
    case continued
    case declined
    case expired

    public var isOpen: Bool { self == .open || self == .taken }
}

public struct ManualActionRequest: Codable, Equatable, Sendable, Identifiable {
    public static let maxReasonLength = 280
    public static let defaultReason = "The bot asked you to take over"

    /// Tool result for `bot_request_user_action`. The run must end after it.
    public static let pauseReply =
        "Paused: waiting for the user. End your turn now. Their answer arrives as a new message."
    /// Returned instead of executing act/exec/browser act while the user controls the computer.
    public static let refusalPhrase =
        "The user has taken control of this computer, so this call was NOT executed. Do not retry: the screen is changing. Pause the task, say you are waiting for the user to hand control back, and take a fresh screenshot before the next action."
    public static let declineFollowUp =
        "The user declined the manual action. Continue without it, or stop and explain."

    public var id: UUID
    public var botID: BotID
    /// Nil when the caller env carried no thread; the host fills it from the bot's active thread.
    public var threadID: AgentThreadID?
    public var kind: ManualActionKind
    public var reason: String
    public var screenshotRef: String?
    public var createdAt: Date
    public var state: ManualActionState
    public var resolvedAt: Date?
    public var note: String?

    public init(
        id: UUID = UUID(),
        botID: BotID,
        threadID: AgentThreadID? = nil,
        kind: ManualActionKind,
        reason: String,
        screenshotRef: String? = nil,
        createdAt: Date = Date(),
        state: ManualActionState = .open,
        resolvedAt: Date? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.botID = botID
        self.threadID = threadID
        self.kind = kind
        self.reason = Self.normalizedReason(reason)
        self.screenshotRef = screenshotRef
        self.createdAt = createdAt
        self.state = state
        self.resolvedAt = resolvedAt
        self.note = note
    }

    public static func normalizedReason(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultReason }
        return String(trimmed.prefix(maxReasonLength))
    }

    public static func continueFollowUp(kind: ManualActionKind, note: String?) -> String {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shown = trimmed.isEmpty ? "none" : trimmed
        return "The user finished the manual action (\(kind.rawValue)). Note: \(shown). Take a fresh screenshot before acting."
    }
}

/// In-memory "who drives this computer" registry, keyed by bot. State is never
/// persisted: a restarted app hands control back to the bot.
public final class BotComputerControl: @unchecked Sendable {
    public static let shared = BotComputerControl()

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var controlled: [BotID: BotID] = [:]
    private var resourceLookup: @Sendable (BotID, AgentThreadID?) -> BotID = { bot, _ in bot }
    private var requests: [BotID: ManualActionRequest] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func configureResourceLookup(_ lookup: @escaping @Sendable (BotID, AgentThreadID?) -> BotID) {
        lock.withLock { resourceLookup = lookup }
    }

    public func isControlledByUser(_ bot: BotID, resourceID: BotID? = nil) -> Bool {
        let lookup = lock.withLock { resourceLookup }
        let resource = resourceID ?? lookup(bot, nil)
        return lock.withLock { controlled[bot] != nil || controlled.values.contains(resource) }
    }

    public func openRequest(_ bot: BotID) -> ManualActionRequest? {
        lock.withLock { requests[bot] }
    }

    /// The user starts driving. An open request becomes `taken`.
    public func take(_ bot: BotID, threadID: AgentThreadID? = nil) {
        let lookup = lock.withLock { resourceLookup }
        let resource = lookup(bot, threadID ?? openRequest(bot)?.threadID)
        let changed = lock.withLock {
            let inserted = controlled[bot] != resource
            controlled[bot] = resource
            if var request = requests[bot], request.state == .open {
                request.state = .taken
                requests[bot] = request
            }
            return inserted
        }
        if changed { postChanged(bot) }
    }

    /// Hands control back to the bot. The request stays until `dismiss`.
    public func release(_ bot: BotID) {
        let lookup = lock.withLock { resourceLookup }
        let current = lookup(bot, nil)
        let released = lock.withLock { () -> [BotID] in
            let resource = controlled[bot] ?? current
            let owners = controlled.filter { $0.value == resource }.map(\.key)
            owners.forEach { controlled[$0] = nil }
            return owners
        }
        released.forEach(postChanged)
    }

    /// `.botComputerControlChanged` after the lock is released, so observers may read this control.
    private func postChanged(_ bot: BotID) {
        NotificationCenter.default.post(
            name: .botComputerControlChanged,
            object: self,
            userInfo: [BotHostNotificationKey.botID: bot]
        )
    }

    /// One open request per bot: a second call returns the existing id and keeps its reason.
    @discardableResult
    public func requestHelp(_ request: ManualActionRequest) -> UUID {
        lock.withLock {
            if let existing = requests[request.botID] { return existing.id }
            var stored = request
            stored.state = .open
            stored.resolvedAt = nil
            requests[request.botID] = stored
            return stored.id
        }
    }

    /// Closes the open request with `state` (continued or declined) and returns it.
    @discardableResult
    public func dismiss(
        _ id: UUID,
        as state: ManualActionState = .continued,
        note: String? = nil
    ) -> ManualActionRequest? {
        close(id, state: state, note: note)
    }

    /// Only closes when `id` is still the current request, so a stale timer cannot close a newer one.
    @discardableResult
    public func expire(_ id: UUID) -> ManualActionRequest? {
        close(id, state: .expired, note: nil)
    }

    public func forget(_ bot: BotID) {
        let wasControlled = lock.withLock {
            requests[bot] = nil
            return controlled.removeValue(forKey: bot) != nil
        }
        if wasControlled { postChanged(bot) }
    }

    private func close(_ id: UUID, state: ManualActionState, note: String?) -> ManualActionRequest? {
        lock.withLock {
            guard let entry = requests.first(where: { $0.value.id == id }) else { return nil }
            var request = entry.value
            request.state = state
            request.resolvedAt = now()
            request.note = note
            requests[entry.key] = nil
            return request
        }
    }
}

/// In-process notifications from the host apply path to the app layer that
/// persists them into the thread. Posted on the caller's (background) thread;
/// observers must hop to their own actor. All payloads are in `userInfo`.
public extension Notification.Name {
    /// userInfo: `request` ManualActionRequest, `screenshotPNG` Data?
    static let botManualActionRequested = Notification.Name("io.remotecode.bot.manual-action-requested")
    /// userInfo: `botID` BotID, `threadID` AgentThreadID?, `jpeg` Data, `reason` String, `kind` String
    static let botScreenshotPosted = Notification.Name("io.remotecode.bot.screenshot-posted")
    /// userInfo: `botID` BotID, `threadID` AgentThreadID?, `reason` String
    static let botMacExecutionRequested = Notification.Name("io.remotecode.bot.mac-execution-requested")
    /// userInfo: `botID` BotID, `threadID` AgentThreadID. A rebuild that held the bot finished;
    /// `threadID` is the send that queued meanwhile and now drains.
    static let botVMRebuildReleased = Notification.Name("io.remotecode.bot.vm-rebuild-released")
    /// userInfo: `botID` BotID. The idle sweep stopped that VM.
    static let botGuestStoppedWhenIdle = Notification.Name("io.remotecode.bot.guest-stopped-when-idle")
    /// userInfo: `botID` BotID (the VM resource), `screenURL` URL. Any provision proved that VM's screen.
    static let botGuestReady = Notification.Name("io.remotecode.bot.guest-ready")
    /// userInfo: `threadID` AgentThreadID. Posted after a manual-action take/resolve so every view model refreshes.
    static let manualActionStateChanged = Notification.Name("io.remotecode.bot.manual-action-state-changed")
    /// object: the `BotComputerControl`; userInfo: `botID` BotID. Who drives that bot's computer
    /// changed (Mac card, Mac screen toggle or `bot.guest.control`). Posted on the caller's thread.
    static let botComputerControlChanged = Notification.Name("io.remotecode.bot.computer-control-changed")
}

public enum BotHostNotificationKey {
    public static let request = "request"
    public static let screenshotPNG = "screenshotPNG"
    public static let botID = "botID"
    public static let threadID = "threadID"
    public static let jpeg = "jpeg"
    public static let reason = "reason"
    public static let kind = "kind"
    public static let screenURL = "screenURL"
    /// true when the request's thread was guessed (no caller thread), so the host must not stop its run.
    public static let threadIsFallback = "threadIsFallback"
}

public enum ManualActionHost {
    /// Opens a request unless the bot already has one; posts `.botManualActionRequested` only for a new one.
    @discardableResult
    public static func request(
        control: BotComputerControl,
        botID: BotID,
        threadID: AgentThreadID?,
        kind: ManualActionKind,
        reason: String,
        screenshotPNG: Data?,
        threadIsFallback: Bool = false,
        center: NotificationCenter = .default
    ) -> UUID {
        let candidate = ManualActionRequest(botID: botID, threadID: threadID, kind: kind, reason: reason)
        let id = control.requestHelp(candidate)
        if id == candidate.id {
            var userInfo: [String: Any] = [BotHostNotificationKey.request: candidate]
            if let screenshotPNG { userInfo[BotHostNotificationKey.screenshotPNG] = screenshotPNG }
            if threadIsFallback { userInfo[BotHostNotificationKey.threadIsFallback] = true }
            center.post(name: .botManualActionRequested, object: nil, userInfo: userInfo)
        }
        return id
    }
}
