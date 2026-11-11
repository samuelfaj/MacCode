import Foundation
import CoreModel

// MARK: - System status strip (severity-ordered, capped)

/// Severity for the unified system strip above the composer.
/// Higher raw value wins when collapsing overflow.
public enum AgentSystemStripSeverity: Int, Sendable, Comparable, Equatable {
    case info = 0
    case warning = 1
    case error = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One dismissible/actionable status row candidate before collapse.
public struct AgentSystemStripItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let severity: AgentSystemStripSeverity
    public let message: String
    public let offersCopy: Bool
    public let offersRetry: Bool
    public let offersDismiss: Bool

    public init(
        id: String,
        severity: AgentSystemStripSeverity,
        message: String,
        offersCopy: Bool = true,
        offersRetry: Bool = false,
        offersDismiss: Bool = true
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.offersCopy = offersCopy
        self.offersRetry = offersRetry
        self.offersDismiss = offersDismiss
    }
}

/// Pure collapse for stacked banners → single strip.
/// WHY: stacked history/status/snapshot/queue banners compete for attention and
/// re-layout the composer; collapse keeps errors first and caps visible rows.
public enum AgentSystemStripPresentation {
    public static let defaultMaxVisible = 2

    public static func collapse(
        _ items: [AgentSystemStripItem],
        maxVisible: Int = defaultMaxVisible
    ) -> (visible: [AgentSystemStripItem], overflowCount: Int) {
        let cleaned = items.filter {
            !$0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Stable sort: severity desc, then original order.
        let ranked = cleaned.enumerated().sorted { a, b in
            if a.element.severity != b.element.severity {
                return a.element.severity > b.element.severity
            }
            return a.offset < b.offset
        }.map(\.element)
        let cap = max(1, maxVisible)
        if ranked.count <= cap {
            return (ranked, 0)
        }
        return (Array(ranked.prefix(cap)), ranked.count - cap)
    }

    /// Build candidates from the classic Agent column banner sources.
    public static func items(
        historyReplayNotice: String?,
        statusMessage: String?,
        providerSnapshotStatus: String?,
        standaloneQueueStatus: String?
    ) -> [AgentSystemStripItem] {
        var out: [AgentSystemStripItem] = []
        if let message = normalized(historyReplayNotice) {
            out.append(AgentSystemStripItem(
                id: "agent.history.replay.notice",
                severity: .info,
                message: message,
                offersCopy: false,
                offersRetry: false
            ))
        }
        if let message = normalized(statusMessage) {
            let isFailure = message.localizedCaseInsensitiveContains("fail")
                || message.localizedCaseInsensitiveContains("error")
            out.append(AgentSystemStripItem(
                id: "agent.status.message",
                severity: isFailure ? .error : .warning,
                message: message,
                offersCopy: true,
                offersRetry: false
            ))
        }
        if let message = normalized(providerSnapshotStatus) {
            out.append(AgentSystemStripItem(
                id: "agent.provider.snapshot.stale",
                severity: .warning,
                message: message,
                offersCopy: true,
                offersRetry: true
            ))
        }
        if let message = normalized(standaloneQueueStatus) {
            let isFailure = message.localizedCaseInsensitiveContains("fail")
            out.append(AgentSystemStripItem(
                id: "agent.queue.status",
                severity: isFailure ? .error : .warning,
                message: message,
                offersCopy: true,
                offersRetry: true
            ))
        }
        return out
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Working phase strip

public enum AgentWorkingPhase: Sendable, Equatable {
    case idle
    case thinking
    case tools
    case awaitingBackground
    case subagents(Int)

    public var accessibilityLabel: String {
        switch self {
        case .idle: return L("Idle")
        case .thinking: return L("Thinking")
        case .tools: return L("Running tools")
        case .awaitingBackground: return L("Awaiting background work")
        case .subagents(let n): return n == 1 ? L("1 subagent active") : L("%1$@ subagents active", n)
        }
    }
}

/// Pure working-phase resolution for the unified header strip.
/// WHY: separate status/awaiting/shells/subagent pills duplicate signal; one phase
/// + optional elapsed is enough for run awareness without chrome noise.
public enum AgentWorkingStripPresentation {
    public static func phase(
        runIsLive: Bool,
        isAwaitingBackground: Bool,
        backgroundShellCount: Int,
        activeSubagentCount: Int,
        hasStreamingTools: Bool
    ) -> AgentWorkingPhase {
        if isAwaitingBackground || backgroundShellCount > 0 {
            return .awaitingBackground
        }
        if activeSubagentCount > 0 {
            return .subagents(activeSubagentCount)
        }
        if runIsLive {
            return hasStreamingTools ? .tools : .thinking
        }
        return .idle
    }

    public static func label(
        phase: AgentWorkingPhase,
        elapsedSeconds: Int?,
        hold: AgentBackgroundHoldSummary? = nil
    ) -> String? {
        let base: String
        switch phase {
        case .idle:
            return nil
        case .thinking:
            base = L("Thinking")
        case .tools:
            base = L("Tools")
        case .awaitingBackground:
            // Prefer the CLI's own noun ("1 shell — Wait for CI") over a
            // generic "Awaiting" that hides what is holding Stop.
            if let hold, !hold.isEmpty {
                base = hold.pillBase
            } else {
                base = L("Awaiting")
            }
        case .subagents(let n):
            base = n == 1 ? L("1 subagent") : L("%1$@ subagents", n)
        }
        guard let elapsedSeconds, elapsedSeconds > 0 else { return base }
        return "\(base) · \(formatElapsed(elapsedSeconds))"
    }

    public static func formatElapsed(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        if m < 60 { return r == 0 ? "\(m)m" : "\(m)m \(r)s" }
        let h = m / 60
        let rm = m % 60
        return rm == 0 ? "\(h)h" : "\(h)h \(rm)m"
    }
}

/// Named background work holding a live run (shells / async agents).
///
/// One line for the header pill and Stop strip; extra descriptions go to
/// help / a caption so the composer does not grow with every task.
public struct AgentBackgroundHoldSummary: Sendable, Equatable {
    public let tasks: [AgentBackgroundTask]

    public init(tasks: [AgentBackgroundTask]) {
        self.tasks = tasks
    }

    public var isEmpty: Bool { tasks.isEmpty }

    // Single pass: agent/shell split together, no filter intermediate.
    // nounLabel reads both counts, so the old pair scanned tasks twice.
    private var counts: (agent: Int, shell: Int) {
        var agent = 0
        var shell = 0
        for task in tasks {
            if task.kind == .agent { agent += 1 } else { shell += 1 }
        }
        return (agent, shell)
    }

    /// Unknown kinds use shell wording so older id-only snapshots still match
    /// the Claude CLI's `1 shell` status line.
    public var shellCount: Int { counts.shell }
    public var agentCount: Int { counts.agent }

    public var nounLabel: String {
        var parts: [String] = []
        if shellCount > 0 { parts.append(Self.countNoun(shellCount, singular: "shell", plural: "shells")) }
        if agentCount > 0 { parts.append(Self.countNoun(agentCount, singular: "agent", plural: "agents")) }
        if parts.isEmpty { return Self.countNoun(max(tasks.count, 1), singular: "shell", plural: "shells") }
        return parts.joined(separator: " · ")
    }

    public var descriptions: [String] {
        tasks.compactMap(\.description)
    }

    /// Only when exactly one task has a description — otherwise the pill would
    /// imply the other jobs are that one title.
    public var primaryDescription: String? {
        tasks.count == 1 && descriptions.count == 1 ? descriptions[0] : nil
    }

    public var pillBase: String {
        if let primaryDescription { return "\(nounLabel) — \(primaryDescription)" }
        return nounLabel
    }

    public var holdingHeadline: String {
        if let primaryDescription { return L("Holding: %1$@ — %2$@", nounLabel, primaryDescription) }
        return L("Holding: %1$@", nounLabel)
    }

    public var extraDescriptionsLine: String? {
        guard descriptions.count > 1 else { return nil }
        return descriptions.joined(separator: " · ")
    }

    public var helpText: String {
        if tasks.isEmpty { return L("Waiting on background work") }
        let lines = tasks.map { task -> String in
            let kind = task.kind == .agent ? L("Agent") : L("Shell")
            if let description = task.description { return "\(kind): \(description)" }
            return kind
        }
        return lines.joined(separator: "\n")
    }

    public func statusLine(elapsedSeconds: Int) -> String {
        "\(holdingHeadline) · \(AgentWorkingStripPresentation.formatElapsed(elapsedSeconds))"
    }

    public func accessibilityLabel(elapsedSeconds: Int) -> String {
        var parts = [statusLine(elapsedSeconds: elapsedSeconds)]
        if let extraDescriptionsLine { parts.append(extraDescriptionsLine) }
        return parts.joined(separator: ". ")
    }

    public static func countNoun(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(plural)"
    }
}

public enum AgentChatWorkingContext: Sendable, Equatable {
    case agent(name: String)
    case reviewing(peerName: String)
}

public enum AgentPeerActivityPresentation {
    public static func title(for snapshot: BotPeerActivitySnapshot) -> String {
        switch snapshot.phase {
        case .waiting:
            return L("Waiting for %1$@", snapshot.name)
        case .needsAttention:
            return L("%1$@ could not reply", snapshot.name)
        }
    }

    public static func detail(
        for snapshot: BotPeerActivitySnapshot,
        elapsedSeconds: Int
    ) -> String {
        switch snapshot.phase {
        case .waiting:
            return AgentChatWorkingCopy.statusLabel(
                context: .agent(name: snapshot.name),
                elapsedSeconds: elapsedSeconds
            )
        case .needsAttention:
            return L("The run stopped. Send a new instruction to retry the handoff.")
        }
    }

    public static func accessibilityLabel(
        for snapshot: BotPeerActivitySnapshot,
        elapsedSeconds: Int
    ) -> String {
        "\(title(for: snapshot)). \(detail(for: snapshot, elapsedSeconds: elapsedSeconds))"
    }
}

public enum AgentChatWorkingCopy {
    public static func statusLabel(
        context: AgentChatWorkingContext?,
        elapsedSeconds: Int,
        seed: UInt64 = 0,
        hold: AgentBackgroundHoldSummary? = nil
    ) -> String {
        if let hold, !hold.isEmpty {
            return hold.statusLine(elapsedSeconds: elapsedSeconds)
        }
        let elapsed = AgentWorkingStripPresentation.formatElapsed(elapsedSeconds)
        switch context {
        case .agent(let name):
            return L("%1$@ is working for %2$@", name, elapsed)
        case .reviewing(let peerName):
            return L("Reviewing %1$@'s reply for %2$@", peerName, elapsed)
        case nil:
            return AgentWorkingCatCopy.statusLabel(elapsedSeconds: elapsedSeconds, seed: seed)
        }
    }

    public static func accessibilityLabel(
        context: AgentChatWorkingContext?,
        elapsedSeconds: Int,
        hold: AgentBackgroundHoldSummary? = nil
    ) -> String {
        if let hold, !hold.isEmpty {
            return hold.accessibilityLabel(elapsedSeconds: elapsedSeconds)
        }
        switch context {
        case .agent, .reviewing:
            return statusLabel(context: context, elapsedSeconds: elapsedSeconds)
        case nil:
            return AgentWorkingCatCopy.accessibilityLabel(elapsedSeconds: elapsedSeconds)
        }
    }
}

// MARK: - Cat working strip (pet parity)

/// Rotating kitten activity verbs for the in-flight "… for Ns" strip.
///
/// WHY: Remote Code's pet is a cat — long runs feel friendlier when the
/// working line cycles through cat-like activities instead of a static
/// "Working for". Phrase is pure English; rotation is deterministic from
/// elapsed seconds (no extra timers, no locale).
public enum AgentWorkingCatCopy {
    /// Seconds each activity stays on screen before the next.
    public static let rotationSeconds: Int = 15

    /// 100 English cat activities (gerund / short phrase). Order is stable —
    /// index is `elapsed / rotationSeconds % count`.
    public static let activities: [String] = [
        "Working",
        L("Scratching the Sofa"),
        "Hunting Mice",
        "Eating Kibble",
        "Sleeping",
        "Purring",
        L("Kneading the Blanket"),
        "Chasing Laser Dots",
        L("Staring Out the Window"),
        L("Knocking Pens Off the Desk"),
        L("Zooming Down the Hall"),
        L("Guarding the Cardboard Box"),
        L("Napping on the Keyboard"),
        "Batting Yarn Balls",
        L("Climbing the Cat Tree"),
        L("Hiding Under the Bed"),
        "Watching Birds",
        "Grooming Fur",
        "Stretching in a Sunbeam",
        L("Meowing at the Fridge"),
        L("Claiming the Warm Laptop"),
        "Pouncing on Dust Bunnies",
        L("Investigating the Grocery Bag"),
        L("Sitting in the Empty Sink"),
        L("Loafing on the Couch"),
        "Chirping at Squirrels",
        L("Stealing the Warm Seat"),
        "Batting Cap Lids",
        L("Inspecting the Suitcase"),
        L("Rolling on the Rug"),
        L("Headbutting the Monitor"),
        "Snoozing on Clean Laundry",
        L("Chasing the Red Dot"),
        L("Perching on the Fridge"),
        "Burying Treats",
        L("Patrolling the Bookshelf"),
        "Licking a Paw",
        L("Fluffing the Cat Bed"),
        "Stalking Socks",
        L("Hiding in the Closet"),
        L("Scratching the Post"),
        "Blinking Slowly",
        L("Begging for Tuna"),
        "Sitting on Open Mail",
        "Chasing Tail",
        L("Guarding the Doorway"),
        L("Sniffing the Shoes"),
        "Curling Up in a Circle",
        L("Watching the Fish Tank"),
        L("Pawing the Curtain"),
        "Napping in a Box",
        "Meowing at 3 AM",
        L("Claiming the Windowsill"),
        "Batting Ice Cubes",
        L("Investigating the Trash"),
        "Stretching Like a Yawn",
        L("Sitting on the Newspaper"),
        "Chasing Shadows",
        "Grooming Whiskers",
        L("Loafing on the Desk"),
        "Hunting Crumbs",
        L("Purring on the Lap"),
        "Zooming at Midnight",
        "Knocking Over Cups",
        "Staring at Nothing",
        L("Claiming the Suitcase"),
        "Batting Phone Cords",
        L("Sleeping on the Router"),
        L("Patrolling the Counter"),
        L("Sniffing the Delivery Box"),
        "Kneading a Sweater",
        "Chirping at Bugs",
        L("Guarding the Food Bowl"),
        "Rolling in Catnip",
        L("Climbing the Drapes"),
        L("Hiding Behind the Curtain"),
        "Watching Raindrops",
        "Pouncing on Toes",
        L("Sitting in the Laundry Basket"),
        L("Meowing for Attention"),
        L("Napping on the Printer"),
        "Batting Hair Ties",
        L("Inspecting the Keyboard"),
        L("Stealing the Armchair"),
        "Chasing Moths",
        L("Stretching on the Carpet"),
        L("Loafing by the Heater"),
        "Hunting String",
        L("Purring on the Pillow"),
        "Knocking Down Magnets",
        L("Claiming the Scanner Tray"),
        L("Staring Into the Void"),
        "Grooming After Dinner",
        "Zooming Across Tiles",
        "Batting Bottle Caps",
        L("Sleeping on the Charger"),
        L("Guarding the Mousepad"),
        L("Sniffing the Coffee Cup"),
        L("Kneading the Cushion"),
        L("Watching the Cursor"),
    ]

    /// Activity phrase for the current elapsed window (no " for" suffix).
    ///
    /// - First 15s window is always **Working**.
    /// - Later windows pick a **pseudo-random** cat activity (stable for that
    ///   window so TimelineView ticks do not flicker). `seed` should come from
    ///   the run start so different runs shuffle differently.
    public static func activity(
        elapsedSeconds: Int,
        seed: UInt64 = 0,
        activities: [String] = activities,
        rotationSeconds: Int = rotationSeconds
    ) -> String {
        let list = activities.isEmpty ? ["Working"] : activities
        let period = max(1, rotationSeconds)
        let window = max(0, elapsedSeconds) / period
        if window == 0 {
            return "Working"
        }
        // Random among everything except the mandatory first "Working".
        let pool: [String] = {
            if list.count <= 1 { return list }
            if list[0] == "Working" { return Array(list.dropFirst()) }
            return list
        }()
        let index = Int(mix(seed: seed, window: UInt64(window)) % UInt64(pool.count))
        return pool[index]
    }

    /// Display line: `"Purring for 20m 3s"`.
    public static func statusLabel(
        elapsedSeconds: Int,
        seed: UInt64 = 0,
        activities: [String] = activities,
        rotationSeconds: Int = rotationSeconds
    ) -> String {
        let phrase = activity(
            elapsedSeconds: elapsedSeconds,
            seed: seed,
            activities: activities,
            rotationSeconds: rotationSeconds
        )
        return L("%1$@ for %2$@", phrase, AgentWorkingStripPresentation.formatElapsed(elapsedSeconds))
    }

    /// SplitMix64-style mix so (seed, window) → stable non-sequential index.
    nonisolated static func mix(seed: UInt64, window: UInt64) -> UInt64 {
        var z = seed &+ (window &+ 1) &* 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Stable VoiceOver / UITest label so assistive tech and tests still hear
    /// "Working for …" while the visible line rotates cat activities.
    public static func accessibilityLabel(elapsedSeconds: Int) -> String {
        L("Working for %1$@", AgentWorkingStripPresentation.formatElapsed(elapsedSeconds))
    }
}

// MARK: - Composer chrome Simple / Power

public enum AgentComposerChromeMode: String, Sendable, Equatable, CaseIterable {
    case simple
    case power
    /// The composer only relays the message (a bot group room): no provider,
    /// model, source, run-as-user, permission or execution choice applies.
    case relay

    public mutating func toggle() {
        self = self == .simple ? .power : .simple
    }
}

public enum AgentComposerChromeControl: String, Sendable, Equatable, CaseIterable {
    case attach
    case model
    case sendStop
    case source
    case permission
    case execution
    case runAsUser
    case effort
}

/// Pure control visibility for composer Simple vs Power chrome.
/// macOS Agent App always paints `.power` (no collapse toggle). The simple set
/// remains for unit tests and any non-macOS caller that still densifies.
public enum AgentComposerChromePresentation {
    public static func controls(for mode: AgentComposerChromeMode) -> Set<AgentComposerChromeControl> {
        switch mode {
        case .simple:
            return [.attach, .model, .sendStop]
        case .power:
            return Set(AgentComposerChromeControl.allCases)
        case .relay:
            return [.attach, .sendStop]
        }
    }

    /// Relay surfaces never take attachments: the button stays, disabled, with this reason.
    public static let relayAttachUnavailable = L("Attachments are not supported in group conversations yet.")

    public static func shows(_ control: AgentComposerChromeControl, mode: AgentComposerChromeMode) -> Bool {
        controls(for: mode).contains(control)
    }
}

/// Pure policy for the animated purple composer border shown while Ultracode is on.
public enum AgentUltracodeBorderPresentation {
    public static let lapSeconds: Double = 4

    public static func shows(provider: AgentProvider, ultracode: Bool) -> Bool {
        provider == .distill && ultracode
    }

    public static func isAnimated(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// The rotation only advances where someone can see it: a key window with the
    /// composer on screen. Otherwise it holds its angle instead of ticking at 30 Hz.
    public static func isTicking(reduceMotion: Bool, windowIsKey: Bool, onScreen: Bool) -> Bool {
        isAnimated(reduceMotion: reduceMotion) && windowIsKey && onScreen
    }
}

// MARK: - Completed work density (perf)

/// Pure gate: whether finished-turn work blocks must be fully built.
/// WHY: stream ticks must not allocate tool groups when the disclosure is collapsed.
public enum AgentCompletedWorkPresentation {
    public static func shouldBuildBlocks(expandCompletedWork: Bool, workItemCount: Int) -> Bool {
        expandCompletedWork && workItemCount > 0
    }

    public static func collapsedLabel(workBlockCount: Int, durationText: String?) -> String {
        if let durationText, !durationText.isEmpty {
            return L("Worked for %1$@", durationText)
        }
        if workBlockCount <= 0 { return L("Worked") }
        return workBlockCount == 1 ? L("Worked · 1 step") : L("Worked · %1$@ steps", workBlockCount)
    }
}

// MARK: - Transcript order (anti-disorder)

/// Stable total order for chat rows. Used by merge, paint window, and Lazy lists.
/// Order key: (sortTime ascending, id ascending). Rematerialization MUST preserve
/// the id sequence from the last structural merge — never re-sort by live payloads.
public enum AgentTranscriptOrder {
    public static func ordersBefore(
        lhsTime: TimeInterval,
        lhsId: String,
        rhsTime: TimeInterval,
        rhsId: String
    ) -> Bool {
        if lhsTime == rhsTime { return lhsId < rhsId }
        return lhsTime < rhsTime
    }

    /// True when each adjacent pair is non-decreasing under the total order.
    public static func isOrdered(
        times: [TimeInterval],
        ids: [String]
    ) -> Bool {
        guard times.count == ids.count, times.count > 1 else { return true }
        for i in 1..<times.count {
            if ordersBefore(
                lhsTime: times[i],
                lhsId: ids[i],
                rhsTime: times[i - 1],
                rhsId: ids[i - 1]
            ) {
                return false
            }
        }
        return true
    }

    /// Returns `entries` unchanged when already ordered; otherwise a fully sorted copy.
    public static func ensuringOrdered<T>(
        _ entries: [T],
        time: (T) -> TimeInterval,
        id: (T) -> String
    ) -> [T] {
        guard entries.count > 1 else { return entries }
        let times = entries.map(time)
        let ids = entries.map(id)
        if isOrdered(times: times, ids: ids) { return entries }
        return entries.sorted {
            ordersBefore(lhsTime: time($0), lhsId: id($0), rhsTime: time($1), rhsId: id($1))
        }
    }

    /// Rematerialize payloads by id map while **preserving** `orderedIds` sequence.
    /// Unknown ids are dropped (never inserted mid-list) so Lazy identity stays stable.
    public static func rematerializePreservingOrder<T>(
        orderedIds: [String],
        payloadsById: [String: T]
    ) -> [T] {
        var out: [T] = []
        out.reserveCapacity(orderedIds.count)
        for id in orderedIds {
            if let payload = payloadsById[id] {
                out.append(payload)
            }
        }
        return out
    }

    /// Chat rule: **Work so far** (turn row) → **final answer** (persisted assistant message).
    ///
    /// On open/hydration a durable assistant message can sort *before* its turn when
    /// `message.createdAt` is earlier than the turn's first-item sort anchor. That paints
    /// the long final answer above the "Work so far · N steps" disclosure. Move each
    /// matching assistant message to immediately after its turn so order stays stable.
    ///
    /// - Messages that already sit after their turn are left alone.
    /// - Prefer the **last** matching turn when several finals collide on text.
    public static func placingMatchingFinalsAfterTurns<Entry>(
        _ entries: [Entry],
        turnFinalText: (Entry) -> String?,
        assistantMessageText: (Entry) -> String?,
        normalizedText: (String) -> String
    ) -> [Entry] {
        guard entries.count > 1 else { return entries }

        var turnFinals: [(index: Int, normalized: String)] = []
        turnFinals.reserveCapacity(entries.count)
        var lastTurnIndexByExactText: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            if let final = turnFinalText(entry)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !final.isEmpty {
                let normalized = normalizedText(final)
                guard !normalized.isEmpty else { continue }
                turnFinals.append((index, normalized))
                lastTurnIndexByExactText[normalized] = index
            }
        }
        guard !turnFinals.isEmpty else { return entries }

        // messageIndex → turnIndex to insert after
        var moveAfterTurn: [Int: Int] = [:]
        for (index, entry) in entries.enumerated() {
            guard let text = assistantMessageText(entry)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            let normalized = normalizedText(text)
            guard !normalized.isEmpty else { continue }
            let matchIndex = lastTurnIndexByExactText[normalized]
                ?? turnFinals.last(where: {
                    normalizedFinalTextsMatch(normalized, $0.normalized)
                })?.index
            guard let matchIndex else { continue }
            // Only lift messages that currently paint *above* their Work so far turn.
            if index < matchIndex {
                moveAfterTurn[index] = matchIndex
            }
        }
        guard !moveAfterTurn.isEmpty else { return entries }

        var pendingAfterTurn: [Int: [Entry]] = [:]
        for (messageIndex, turnIndex) in moveAfterTurn {
            pendingAfterTurn[turnIndex, default: []].append(entries[messageIndex])
        }
        let moved = Set(moveAfterTurn.keys)
        var out: [Entry] = []
        out.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            if moved.contains(index) { continue }
            out.append(entry)
            if let pending = pendingAfterTurn[index] {
                out.append(contentsOf: pending)
            }
        }
        return out
    }

    /// Lightweight final-text match for order repairs (no UI caches).
    /// Treats equal normalized/compact forms as the same answer.
    public static func finalTextsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = compactFinalText(lhs)
        let b = compactFinalText(rhs)
        return normalizedFinalTextsMatch(a, b)
    }

    public static func normalizedFinalText(_ text: String) -> String {
        compactFinalText(text)
    }

    private static func normalizedFinalTextsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs
        let b = rhs
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    private static func compactFinalText(_ text: String) -> String {
        // Cap is high enough for long "Phases" tables; still bounded for cost.
        let limit = 32_768
        var out = String()
        out.reserveCapacity(min(text.utf8.count, limit))
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            out.unicodeScalars.append(scalar)
            if out.utf8.count >= limit { break }
        }
        return out
    }
}

// MARK: - Turn chat composition (macOS ↔ iOS parity)

/// Single rule for every turn in the Agent chat:
/// **user message** (transcript) → **Work so far** (all non-final work) → **final agent message** only outside.
/// Live turns have no outside tool/group rows; the active stream lives inside Work so far when expanded.
public enum AgentTurnChatComposition {
    /// Split renderable turn items into work (disclosure) vs outside (final answer only).
    /// - Live / unfinished: everything is work; outside is empty.
    /// - Finished: `finalItemIDs` paint outside (or only via finalMessage field); rest is work.
    public static func splitItems<Item>(
        _ items: [Item],
        turnFinished: Bool,
        isFinalItem: (Item) -> Bool
    ) -> (work: [Item], outside: [Item]) {
        if !turnFinished {
            return (items, [])
        }
        var work: [Item] = []
        var outside: [Item] = []
        work.reserveCapacity(items.count)
        for item in items {
            if isFinalItem(item) {
                outside.append(item)
            } else {
                work.append(item)
            }
        }
        return (work, outside)
    }

    /// Live Work so far must own every non-final step (no active-tail leak outside).
    public static func liveOutsideBlocksMustBeEmpty() -> Bool { true }
}

// MARK: - Work disclosure layout (lazy viewport + densify)

/// Viewport bounds for expanded Work so far so only on-screen steps mount.
/// Nested LazyVStack only virtualizes when height is bounded (inner ScrollView).
public enum AgentWorkDisclosureLayout {
    /// Max height of the expanded work list (points).
    public static let maxViewportHeight: CGFloat = 420
    /// Hint for estimated step row height (layout assist / tests).
    public static let estimatedStepMinHeight: CGFloat = 36
    /// Max step blocks painted in the lazy list before "show earlier".
    public static let expandedPaintWindow = 48
    public static let expandedRevealPage = 48
    /// A grouped run is one outer block, so it needs its own strict member cap.
    public static let toolGroupPaintWindow = 24
    public static let toolGroupRevealPage = 24
    /// Bound eager thumbnail decoding while the group remains collapsed.
    public static let toolGroupThumbnailPreviewWindow = 8
    /// Diff card: collapsed by default; preview this many non-meta lines when open.
    public static let diffDefaultExpanded = false
    public static let diffPreviewLineLimit = 32

    /// Slice work blocks for paint: oldest may stay folded behind a reveal control.
    public static func paintSlice<T>(
        all: [T],
        revealCount: Int,
        window: Int = expandedPaintWindow
    ) -> (hiddenCount: Int, rows: [T]) {
        let cap = max(1, window)
        guard all.count > cap else { return (0, all) }
        let hiddenBase = all.count - cap
        let revealed = min(max(0, revealCount), hiddenBase)
        let start = hiddenBase - revealed
        return (hiddenBase - revealed, Array(all[start...]))
    }

    public static func advancedRevealCount(current: Int, hiddenBase: Int, page: Int = expandedRevealPage) -> Int {
        min(hiddenBase, max(0, current) + max(1, page))
    }

    public static func toolGroupPaintSlice<T>(
        all: [T],
        revealCount: Int
    ) -> (hiddenCount: Int, rows: [T]) {
        paintSlice(all: all, revealCount: revealCount, window: toolGroupPaintWindow)
    }

    public static func toolGroupAdvancedRevealCount(current: Int, hiddenBase: Int) -> Int {
        advancedRevealCount(current: current, hiddenBase: hiddenBase, page: toolGroupRevealPage)
    }

    public static func toolGroupThumbnailPreview<T>(
        all: [T],
        isThumbnail: (T) -> Bool
    ) -> [T] {
        var reversedPreview: [T] = []
        reversedPreview.reserveCapacity(toolGroupThumbnailPreviewWindow)
        for item in all.reversed() where isThumbnail(item) {
            reversedPreview.append(item)
            if reversedPreview.count == toolGroupThumbnailPreviewWindow { break }
        }
        return reversedPreview.reversed()
    }

    /// Visible code lines for a diff card (non-meta), with optional full expand.
    public static func visibleDiffLines<Line>(
        _ lines: [Line],
        isMeta: (Line) -> Bool,
        showAll: Bool,
        previewLimit: Int = diffPreviewLineLimit
    ) -> (rows: [Line], hiddenCount: Int) {
        let code = lines.filter { !isMeta($0) }
        if showAll || code.count <= previewLimit {
            return (code, 0)
        }
        return (Array(code.prefix(previewLimit)), code.count - previewLimit)
    }
}

// MARK: - Work so far expand policy

/// Pure policy for default-open latest live "Work so far" and collapse-all on final.
/// UI only stores user overrides; this decides painted expanded state.
public enum AgentCompletedWorkExpandPolicy {
    /// - isLive / isLatestLiveTurn: only the current unfinished turn defaults open.
    /// - userExplicitlyExpanded: finished (or non-default) turns the user opened.
    /// - userCollapsedWhileLive: user hid the live default-open disclosure.
    public static func isExpanded(
        isLive: Bool,
        isLatestLiveTurn: Bool,
        userExplicitlyExpanded: Bool,
        userCollapsedWhileLive: Bool
    ) -> Bool {
        if isLive && isLatestLiveTurn {
            return !userCollapsedWhileLive
        }
        return userExplicitlyExpanded
    }

    /// Final assistant answer / turn finish: collapse every work disclosure.
    public static func clearedExpansionState() -> (expanded: Set<String>, collapsedLive: Set<String>) {
        ([], [])
    }

    /// Apply a user toggle. Returns updated override sets.
    public static func toggle(
        turnId: String,
        currentlyExpanded: Bool,
        isLive: Bool,
        isLatestLiveTurn: Bool,
        userExpanded: Set<String>,
        userCollapsedLive: Set<String>
    ) -> (expanded: Set<String>, collapsedLive: Set<String>) {
        var expanded = userExpanded
        var collapsed = userCollapsedLive
        if currentlyExpanded {
            expanded.remove(turnId)
            if isLive && isLatestLiveTurn {
                collapsed.insert(turnId)
            }
        } else {
            collapsed.remove(turnId)
            expanded.insert(turnId)
        }
        return (expanded, collapsed)
    }
}

// MARK: - Expanded work block growth (append-friendly)

/// Pure helpers so live expanded "Work so far" prefers append / prefix reuse
/// over treating every stream tick as a brand-new full block list.
public enum AgentCompletedWorkBlockGrowth {
    public static func isPrefixStableAppend(previousIds: [String], nextIds: [String]) -> Bool {
        guard nextIds.count >= previousIds.count else { return false }
        for i in previousIds.indices where previousIds[i] != nextIds[i] {
            return false
        }
        return true
    }

    /// First item index that must be re-blocked when growing previous → next.
    /// `previousIds.count` means fully reusable (identical length). `0` = full rebuild.
    public static func rebuildFromItemIndex(
        previousIds: [String],
        previousGroupable: [Bool],
        nextIds: [String]
    ) -> Int {
        guard isPrefixStableAppend(previousIds: previousIds, nextIds: nextIds) else {
            return 0
        }
        if nextIds.count == previousIds.count {
            return previousIds.count
        }
        // Trailing open groupable run may absorb newly settled tools.
        var openRunStart = previousIds.count
        while openRunStart > 0,
              openRunStart - 1 < previousGroupable.count,
              previousGroupable[openRunStart - 1] {
            openRunStart -= 1
        }
        return openRunStart
    }

    /// Longest leading block-id prefix shared by previous and next full builds.
    public static func reusableBlockPrefixCount(
        previousBlockIds: [String],
        nextBlockIds: [String]
    ) -> Int {
        var n = 0
        let limit = min(previousBlockIds.count, nextBlockIds.count)
        while n < limit && previousBlockIds[n] == nextBlockIds[n] {
            n += 1
        }
        return n
    }

    /// Documents growth mode for tests and callers.
    /// - reuse: same settled ids → keep previous block identities
    /// - append: previous block ids are a strict prefix of next → only suffix is new
    /// - in_place_last_plus_append: last block id stable (group grew) + optional new blocks
    /// - full_rebuild: not prefix-stable
    /// - partial_rebuild: reuse common block id prefix only
    public static func growthDecision(
        previousItemIds: [String],
        previousBlockIds: [String],
        nextItemIds: [String],
        nextBlockIds: [String]
    ) -> (mode: String, reusedCount: Int, appendedBlockIds: [String]) {
        guard isPrefixStableAppend(previousIds: previousItemIds, nextIds: nextItemIds) else {
            return ("full_rebuild", 0, nextBlockIds)
        }
        if nextItemIds.count == previousItemIds.count {
            return ("reuse", previousBlockIds.count, [])
        }
        if previousBlockIds.isEmpty {
            return ("append", 0, nextBlockIds)
        }
        if nextBlockIds.starts(with: previousBlockIds) {
            return ("append", previousBlockIds.count, Array(nextBlockIds.dropFirst(previousBlockIds.count)))
        }
        let common = reusableBlockPrefixCount(
            previousBlockIds: previousBlockIds,
            nextBlockIds: nextBlockIds
        )
        if common == previousBlockIds.count - 1,
           common < nextBlockIds.count,
           previousBlockIds.last == nextBlockIds[common] {
            return (
                "in_place_last_plus_append",
                common + 1,
                Array(nextBlockIds.dropFirst(common + 1))
            )
        }
        return ("partial_rebuild", common, Array(nextBlockIds.dropFirst(common)))
    }
}

// MARK: - File edit diff (Cursor-style timeline card)

/// Pure extraction + line model for agent file edits shown inline in the thread.
/// WHY: users need to see what changed (path + red/green hunks), not a raw JSON/tool dump.
public enum AgentFileEditDiffPresentation {
    public enum LineKind: Sendable, Equatable {
        case meta
        case hunk
        case context
        case addition
        case deletion
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public var id: Int
        public var kind: LineKind
        /// Source text without the leading unified-diff marker for code lines.
        public var text: String
        public var oldLineNumber: Int?
        public var newLineNumber: Int?

        public init(
            id: Int,
            kind: LineKind,
            text: String,
            oldLineNumber: Int? = nil,
            newLineNumber: Int? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.oldLineNumber = oldLineNumber
            self.newLineNumber = newLineNumber
        }

        /// Number column: prefer new side for additions/context, old for deletions.
        public var displayLineNumber: Int? {
            switch kind {
            case .deletion: return oldLineNumber
            case .addition, .context: return newLineNumber ?? oldLineNumber
            case .meta, .hunk: return nil
            }
        }
    }

    public struct Model: Sendable, Equatable {
        public var path: String?
        public var lines: [Line]
        public var hiddenLineCount: Int

        public init(path: String?, lines: [Line], hiddenLineCount: Int = 0) {
            self.path = path
            self.lines = lines
            self.hiddenLineCount = hiddenLineCount
        }

        public var hasRenderableCode: Bool {
            lines.contains { $0.kind == .addition || $0.kind == .deletion || $0.kind == .context }
        }
    }

    public static let defaultMaxLines = 160

    /// True when this timeline item should paint as an Edit diff card.
    public static func shouldPresent(item: AssistantItem) -> Bool {
        if item.type == .fileChange { return model(for: item) != nil }
        // Claude Edit/Write and similar tools store structured JSON in body.
        if item.type == .tool || item.type == .commandExecution || item.type == .dynamicToolCall {
            return model(for: item) != nil
        }
        return false
    }

    private final class DiffModelBox { let value: Model?; init(_ v: Model?) { value = v } }
    /// Perf CH-03: the live tool row re-ran the full diff extraction (2-4
    /// JSONSerialization passes over the whole blob + full-text splits) on every
    /// body pass — even for Bash tools whose 50 KB output is not a diff. Cached
    /// per item growth signature (byte counts invalidate on growth).
    static let diffModelCacheCountLimit = 256
    static let diffModelCacheCostLimit = 2 * 1_024 * 1_024
    private static let diffModelCache: NSCache<NSString, DiffModelBox> = {
        let cache = NSCache<NSString, DiffModelBox>()
        cache.countLimit = diffModelCacheCountLimit
        cache.totalCostLimit = diffModelCacheCostLimit
        return cache
    }()
    #if DEBUG
    nonisolated(unsafe) static var diffModelComputeCountForTesting = 0
    #endif

    public static func model(for item: AssistantItem, maxLines: Int = defaultMaxLines) -> Model? {
        let key = "\(item.id)|\(item.state.rawValue)|\(item.body.utf8.count)|\(item.output?.utf8.count ?? 0)|\(item.summary?.utf8.count ?? 0)|\(item.resourcePath?.utf8.count ?? 0)|\(maxLines)" as NSString
        if let cached = diffModelCache.object(forKey: key) { return cached.value }
        #if DEBUG
        diffModelComputeCountForTesting &+= 1
        #endif
        let result = computeModel(for: item, maxLines: maxLines)
        let cost = max(1, (item.body.utf8.count + (item.output?.utf8.count ?? 0)) / 8)
        diffModelCache.setObject(DiffModelBox(result), forKey: key, cost: cost)
        return result
    }

    private static func computeModel(for item: AssistantItem, maxLines: Int) -> Model? {
        let path = extractPath(from: item)
        guard let raw = extractDiffText(from: item), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let parsed = parseUnifiedDiff(raw, maxLines: maxLines)
        guard parsed.lines.contains(where: {
            $0.kind == .addition || $0.kind == .deletion || $0.kind == .context || $0.kind == .hunk
        }) else {
            // Still show path-only edits with a single meta line when we only know the path.
            if let path, !path.isEmpty {
                return Model(
                    path: path,
                    lines: [Line(id: 0, kind: .meta, text: L("File updated"))],
                    hiddenLineCount: 0
                )
            }
            return nil
        }
        let resolvedPath = path ?? parsed.inferredPath
        return Model(path: resolvedPath, lines: parsed.lines, hiddenLineCount: parsed.hidden)
    }

    public static func extractPath(from item: AssistantItem) -> String? {
        if let resource = item.resourcePath?.trimmingCharacters(in: .whitespacesAndNewlines), !resource.isEmpty {
            return resource
        }
        if let fromSummary = pathCandidate(in: item.summary ?? ""), !fromSummary.isEmpty {
            return fromSummary
        }
        for blob in [item.body, item.output ?? ""] {
            if let p = pathFromJSON(blob) { return p }
            if let p = pathFromUnifiedDiff(blob) { return p }
        }
        return nil
    }

    public static func extractDiffText(from item: AssistantItem) -> String? {
        for blob in [item.output ?? "", item.body] {
            guard !blob.isEmpty else { continue }
            // r11: do not copy the whole blob via trimmingCharacters on the
            // common non-diff Bash miss. Streaming tool output misses the
            // growth-keyed cache every token; a 50 KB trim was the miss tax.
            // Positive diff hits still trim so parseUnifiedDiff does not
            // promote leading blank lines to context.
            if looksLikeDiff(blob) {
                let trimmed = blob.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
                continue
            }
            // Perf CH-03: JSON payloads must start with { or [ — skip both
            // JSONSerialization attempts for plain text (the common Bash case).
            // Scan only leading whitespace instead of allocating a trimmed copy.
            if let first = firstNonWhitespace(in: blob), first == "{" || first == "[" {
                if let fromJSON = diffFromJSONChanges(blob) { return fromJSON }
                if let fromEdit = synthesizeDiffFromEditJSON(blob) { return fromEdit }
            }
            if let fromPatch = extractApplyPatchBlock(blob) { return fromPatch }
        }
        return nil
    }

    /// First non-whitespace Character, or nil when the string is empty/whitespace.
    /// Stops at the first payload byte so a 50 KB Bash dump is not copied.
    static func firstNonWhitespace(in text: String) -> Character? {
        for ch in text where !ch.isWhitespace {
            return ch
        }
        return nil
    }

    public static func looksLikeDiff(_ text: String) -> Bool {
        // Perf CH-03: do not eager-split the whole blob into `[String]`.
        // r11: walk Substring slices (hasPrefix without String(line)) and stop
        // after 80 non-empty lines — one pass instead of prefix(60)+prefix(80).
        var plus = 0, minus = 0
        var scanned = 0
        var start = text.startIndex
        while start < text.endIndex, scanned < 80 {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[start..<end]
            start = end == text.endIndex ? end : text.index(after: end)
            if line.isEmpty { continue }
            scanned += 1
            if scanned <= 60 {
                if line.hasPrefix("diff --git ") || line.hasPrefix("@@")
                    || line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                    return true
                }
                if line.hasPrefix("*** Begin Patch") || line.hasPrefix("*** Update File:")
                    || line.hasPrefix("*** Add File:") {
                    return true
                }
            }
            if line.hasPrefix("+") && !line.hasPrefix("++") { plus += 1 }
            if line.hasPrefix("-") && !line.hasPrefix("--") { minus += 1 }
        }
        return plus + minus >= 2 && (plus > 0 || minus > 0)
    }

    /// Parse unified / apply-patch style text into numbered display lines.
    public static func parseUnifiedDiff(_ text: String, maxLines: Int = defaultMaxLines) -> (lines: [Line], hidden: Int, inferredPath: String?) {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [Line] = []
        out.reserveCapacity(min(rawLines.count, maxLines))
        var oldN = 0
        var newN = 0
        var inferredPath: String?
        var index = 0
        for raw in rawLines {
            if out.count >= maxLines { break }
            let line = raw
            if line.hasPrefix("diff --git ") {
                inferredPath = inferredPath ?? pathFromDiffGitLine(line)
                out.append(Line(id: index, kind: .meta, text: line)); index += 1
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                if line.hasPrefix("+++ ") {
                    inferredPath = inferredPath ?? pathFromDiffFileHeader(line)
                } else if inferredPath == nil {
                    inferredPath = pathFromDiffFileHeader(line)
                }
                out.append(Line(id: index, kind: .meta, text: line)); index += 1
                continue
            }
            if line.hasPrefix("*** Update File:") || line.hasPrefix("*** Add File:") || line.hasPrefix("*** Delete File:") {
                inferredPath = inferredPath ?? line.split(separator: ":", maxSplits: 1).last.map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
                out.append(Line(id: index, kind: .meta, text: line)); index += 1
                continue
            }
            if line.hasPrefix("*** Begin Patch") || line.hasPrefix("*** End Patch") {
                out.append(Line(id: index, kind: .meta, text: line)); index += 1
                continue
            }
            if line.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(line) {
                    oldN = o
                    newN = n
                }
                out.append(Line(id: index, kind: .hunk, text: line)); index += 1
                continue
            }
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                let text = String(line.dropFirst())
                out.append(Line(id: index, kind: .addition, text: text, oldLineNumber: nil, newLineNumber: newN))
                newN += 1
                index += 1
                continue
            }
            if line.hasPrefix("-") && !line.hasPrefix("---") {
                let text = String(line.dropFirst())
                out.append(Line(id: index, kind: .deletion, text: text, oldLineNumber: oldN, newLineNumber: nil))
                oldN += 1
                index += 1
                continue
            }
            // Context (leading space or plain)
            let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
            if line.hasPrefix(" ") || (!line.isEmpty && !line.hasPrefix("\\")) {
                out.append(Line(id: index, kind: .context, text: text, oldLineNumber: oldN, newLineNumber: newN))
                if !line.isEmpty {
                    oldN += 1
                    newN += 1
                }
                index += 1
            } else if line.hasPrefix("\\") {
                out.append(Line(id: index, kind: .meta, text: line)); index += 1
            }
        }
        let hidden = max(0, rawLines.count - out.count)
        return (out, hidden, inferredPath)
    }

    /// Claude Edit/Write JSON → synthetic unified-ish hunk.
    public static func synthesizeDiffFromEditJSON(_ body: String) -> String? {
        guard let obj = jsonObject(body) else { return nil }
        let path = (obj["file_path"] as? String)
            ?? (obj["path"] as? String)
            ?? (obj["filePath"] as? String)
            ?? "file"
        if let oldS = obj["old_string"] as? String, let newS = obj["new_string"] as? String {
            return buildSyntheticDiff(path: path, oldText: oldS, newText: newS)
        }
        if let content = (obj["content"] as? String) ?? (obj["new_string"] as? String),
           obj["old_string"] == nil {
            // Write / create: all additions
            var lines = ["*** Add File: \(path)", "@@"]
            for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("+\(line)")
            }
            return lines.joined(separator: "\n")
        }
        return nil
    }

    // MARK: - Internals

    private static func buildSyntheticDiff(path: String, oldText: String, newText: String) -> String {
        let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out = [
            "*** Update File: \(path)",
            "@@ -\(1),\(oldLines.count) +\(1),\(newLines.count) @@"
        ]
        for line in oldLines { out.append("-\(line)") }
        for line in newLines { out.append("+\(line)") }
        return out.joined(separator: "\n")
    }

    private static func diffFromJSONChanges(_ body: String) -> String? {
        let json: Any
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let obj = AgentTimelineItemPresentation.toolInputObject(forBody: trimmed) {
            json = obj
        } else {
            guard let data = body.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
            json = parsed
        }
        // { "changes": [ ... ] } or bare array
        let changes: [[String: Any]]
        if let dict = json as? [String: Any] {
            if let patch = dict["patch"] as? String, looksLikeDiff(patch) { return patch }
            if let diff = dict["diff"] as? String, looksLikeDiff(diff) { return diff }
            if let arr = dict["changes"] as? [[String: Any]] {
                changes = arr
            } else {
                return nil
            }
        } else if let arr = json as? [[String: Any]] {
            changes = arr
        } else {
            return nil
        }
        var chunks: [String] = []
        for change in changes {
            let path = (change["path"] as? String)
                ?? (change["file"] as? String)
                ?? (change["filename"] as? String)
                ?? "file"
            if let diff = (change["diff"] as? String)
                ?? (change["patch"] as? String)
                ?? (change["unified_diff"] as? String)
                ?? (change["unifiedDiff"] as? String),
               !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if looksLikeDiff(diff) {
                    chunks.append(diff)
                } else {
                    chunks.append("*** Update File: \(path)\n@@\n\(diff)")
                }
                continue
            }
            if let oldS = change["old_string"] as? String, let newS = change["new_string"] as? String {
                chunks.append(buildSyntheticDiff(path: path, oldText: oldS, newText: newS))
            }
        }
        guard !chunks.isEmpty else { return nil }
        return chunks.joined(separator: "\n")
    }

    private static func extractApplyPatchBlock(_ text: String) -> String? {
        guard text.contains("*** Begin Patch") || text.contains("*** Update File:") else { return nil }
        return text
    }

    private static func pathFromJSON(_ body: String) -> String? {
        guard let obj = jsonObject(body) else { return nil }
        for key in ["file_path", "path", "filePath", "filename", "file"] {
            if let p = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                return p
            }
        }
        if let changes = obj["changes"] as? [[String: Any]],
           let first = changes.first {
            for key in ["path", "file", "filename"] {
                if let p = (first[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                    return p
                }
            }
        }
        return nil
    }

    private static func pathFromUnifiedDiff(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(20) {
            let s = String(line)
            if s.hasPrefix("diff --git ") { return pathFromDiffGitLine(s) }
            if s.hasPrefix("+++ ") { return pathFromDiffFileHeader(s) }
            if s.hasPrefix("*** Update File:") || s.hasPrefix("*** Add File:") {
                return s.split(separator: ":", maxSplits: 1).last.map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    // PERF: compile once — pathCandidate/parseHunkHeader run on tool-detail paint
    // (path summary + every @@ hunk line of multi-KB diffs).
    private static let pathCandidateRegex = try! NSRegularExpression(
        pattern: #"(/[^\s]+|\S+\.\w{1,8})"#
    )
    private static let hunkHeaderRegex = try! NSRegularExpression(
        pattern: #"@@\s*-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s*@@"#
    )

    private static func pathCandidate(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains("/") || t.contains(".") else { return nil }
        // "Changed path/to/file.swift" / "1 file change · foo.ts"
        let full = NSRange(t.startIndex..<t.endIndex, in: t)
        guard let match = pathCandidateRegex.firstMatch(in: t, options: [], range: full),
              let range = Range(match.range, in: t) else {
            return nil
        }
        return String(t[range])
    }

    private static func pathFromDiffGitLine(_ line: String) -> String? {
        // diff --git a/foo b/foo
        let parts = line.split(separator: " ")
        guard parts.count >= 4 else { return nil }
        let b = String(parts[3])
        if b.hasPrefix("b/") { return String(b.dropFirst(2)) }
        return b
    }

    private static func pathFromDiffFileHeader(_ line: String) -> String? {
        // +++ b/path or --- a/path
        var rest = line
        if rest.hasPrefix("+++ ") || rest.hasPrefix("--- ") {
            rest = String(rest.dropFirst(4))
        }
        if rest == "/dev/null" { return nil }
        if rest.hasPrefix("a/") || rest.hasPrefix("b/") {
            return String(rest.dropFirst(2))
        }
        return rest.split(separator: "\t").first.map(String.init)
    }

    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        // @@ -12,4 +12,10 @@
        let ns = line as NSString
        guard let match = hunkHeaderRegex.firstMatch(
            in: line,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ),
              match.numberOfRanges >= 3,
              let oldR = Range(match.range(at: 1), in: line),
              let newR = Range(match.range(at: 2), in: line),
              let old = Int(line[oldR]),
              let new = Int(line[newR]) else { return nil }
        return (old, new)
    }

    private static func jsonObject(_ body: String) -> [String: Any]? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        // Reuse the live-tool JSON cache so Edit/diff extraction does not
        // JSONSerialization-parse a body already decoded for tool rows.
        return AgentTimelineItemPresentation.toolInputObject(forBody: trimmed)
    }
}

// MARK: - Thread rail row copy

/// Pure thread-row subtitle + monogram for denser rail scanning.
public enum AgentThreadRailRowCopy {
    public static func monogram(for provider: AgentProvider) -> String {
        switch provider {
        case .codex: return "X"
        case .claude: return "C"
        case .grok: return "G"
        case .distill: return "D"
        }
    }

    public static func subtitle(
        provider: AgentProvider,
        model: String,
        updatedAt: Date,
        now: Date = Date()
    ) -> String {
        let modelPart = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = relativeTime(from: updatedAt, now: now)
        if modelPart.isEmpty {
            return "\(provider.rawValue) · \(time)"
        }
        return "\(provider.rawValue) · \(shortModel(modelPart)) · \(time)"
    }

    public static func shortModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 28 { return trimmed }
        return String(trimmed.prefix(25)) + "…"
    }

    public static func relativeTime(from date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 45 { return "now" }
        if seconds < 3600 { return "\(max(1, seconds / 60))m" }
        if seconds < 86_400 { return "\(max(1, seconds / 3600))h" }
        if seconds < 86_400 * 7 { return "\(max(1, seconds / 86_400))d" }
        return "\(max(1, seconds / (86_400 * 7)))w"
    }
}

// MARK: - Shared thread-rail chrome copy

/// One header/search/clear-all contract for Agent App and dest.
/// Surfaces mount the same chrome; they must not fork this copy.
public enum AgentChatThreadRailCopy {
    public static let emptyTitle = L("No threads")
    public static let emptyIcon = "bubble.left.and.bubble.right"
    public static let searchPlaceholder = L("Search threads")
    public static let clearAllTitle = L("Clear All")
    public static let hideHelp = L("Hide threads")
    public static let showHelp = L("Show threads")
    public static let newHelp = L("New thread")
    public static let clearSearchLabel = L("Clear search")
    public static let clearAllHelp = L("Delete all threads")

    public static func headerTitle(activeCount: Int) -> String {
        activeCount > 0 ? L("Threads · %1$@ active", activeCount) : L("Threads")
    }

    public static func noMatchText(query: String) -> String {
        L("No threads match \"%1$@\"", query)
    }

    public static func showsClearAll(isEmpty: Bool) -> Bool {
        !isEmpty
    }

    public static func matches(title: String, extra: String = "", query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(q)
            || extra.localizedCaseInsensitiveContains(q)
    }

    /// Running rows stay above idle/unread matches, preserving relative
    /// order inside each group. Agent App and dest mount the same sort so
    /// a new idle thread cannot bury a live run.
    public static func orderingActiveFirst<T>(_ items: [T], isActive: (T) -> Bool) -> [T] {
        var active: [T] = []
        var rest: [T] = []
        active.reserveCapacity(items.count)
        rest.reserveCapacity(items.count)
        for item in items {
            if isActive(item) {
                active.append(item)
            } else {
                rest.append(item)
            }
        }
        return active + rest
    }
}

