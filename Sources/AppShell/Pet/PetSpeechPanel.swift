import AppKit
import CoreModel
import OSLog
import Persistence
import SwiftUI

private let petSpeechLog = Logger(subsystem: "io.remotecode.app", category: "pet-speech")

/// One line Titio says from the pet for a new notice (hub spec §9). The text is
/// the notice's own preview, so the bubble, banner, push and inbox all agree.
public struct PetSpeech: Equatable, Sendable, Identifiable {
    public static let maxCharacters = TitioNoticeSpeech.maxCharacters

    public let id: UUID
    public let text: String
    public let urgency: TitioNoticeUrgency
    public let messageID: AgentMessageID
    public let botID: BotID
    public let conversationID: BotConversationID

    public init(
        id: UUID = UUID(),
        text: String,
        urgency: TitioNoticeUrgency,
        messageID: AgentMessageID,
        botID: BotID,
        conversationID: BotConversationID
    ) {
        self.id = id
        self.text = Self.clip(text)
        self.urgency = urgency
        self.messageID = messageID
        self.botID = botID
        self.conversationID = conversationID
    }

    init(_ notice: TitioNoticeSpeech) {
        self.init(
            text: notice.text,
            urgency: notice.urgency,
            messageID: notice.messageID,
            botID: notice.botID,
            conversationID: notice.conversationID
        )
    }

    /// Seconds on screen: a quick glance for info, longer for what needs a reply.
    public var timeToLive: TimeInterval {
        urgency == .info ? 6 : 12
    }

    /// The same `[String: String]` map a Titio banner click carries, so a click
    /// on the bubble goes through `AppDelegate.routeFromNotification` like one.
    public var routeUserInfo: [String: String] {
        [
            "botId": botID.value.uuidString.lowercased(),
            "conversationId": conversationID.value.uuidString.lowercased(),
            "messageId": messageID.value.uuidString.lowercased()
        ]
    }

    private static func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > maxCharacters else { return flat }
        return String(flat.prefix(maxCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// What the pet has to say, in order. Pure: time comes in as an argument.
///
/// - At most `maxCount` bubbles wait, the one showing included.
/// - Info is transient: a newer info replaces an older one, shown or waiting,
///   and an alert or decision cuts a showing info short. The notice itself
///   stays in the inbox either way.
/// - Alerts and decisions wait their turn behind each other.
struct PetSpeechQueue: Equatable {
    static let maxCount = 3

    private(set) var current: PetSpeech?
    private(set) var currentExpiresAt: Date?
    private(set) var waiting: [PetSpeech] = []

    var count: Int { (current == nil ? 0 : 1) + waiting.count }

    /// Returns true when the bubble on screen changed.
    @discardableResult
    mutating func enqueue(_ speech: PetSpeech, now: Date) -> Bool {
        if speech.urgency == .info {
            waiting.removeAll { $0.urgency == .info }
        }
        if current == nil || current?.urgency == .info {
            show(speech, now: now)
            trim()
            return true
        }
        waiting.append(speech)
        trim()
        return false
    }

    /// Moves to the next bubble once the current one's time is up. Returns true
    /// when the bubble on screen changed.
    @discardableResult
    mutating func advance(now: Date) -> Bool {
        guard let expiresAt = currentExpiresAt, now >= expiresAt else { return false }
        showNext(now: now)
        return true
    }

    /// Drops everything (a click, or a rule that hides the bubble).
    mutating func clear() {
        current = nil
        currentExpiresAt = nil
        waiting.removeAll()
    }

    private mutating func show(_ speech: PetSpeech, now: Date) {
        current = speech
        currentExpiresAt = now.addingTimeInterval(speech.timeToLive)
    }

    private mutating func showNext(now: Date) {
        if waiting.isEmpty {
            current = nil
            currentExpiresAt = nil
        } else {
            show(waiting.removeFirst(), now: now)
        }
    }

    /// Over the cap, the oldest waiting bubble goes; the one showing stays.
    private mutating func trim() {
        while count > Self.maxCount, !waiting.isEmpty {
            waiting.removeFirst()
        }
    }
}

/// When the pet keeps quiet (hub spec §9). Banners keep their own rules; this
/// only decides the bubble.
enum PetSpeechSuppression {
    struct Inputs: Equatable {
        var speechEnabled: Bool
        var petEnabled: Bool
        var petVisible: Bool
        var popoverOpen: Bool
        /// The Mac desk shows that conversation in the key window.
        var inboxIsKeyDesk: Bool
    }

    enum Reason: String, Equatable {
        case speechDisabled
        case petDisabled
        case petHidden
        case popoverOpen
        case inboxViewed
    }

    static func reason(_ inputs: Inputs) -> Reason? {
        if !inputs.speechEnabled { return .speechDisabled }
        if !inputs.petEnabled { return .petDisabled }
        if !inputs.petVisible { return .petHidden }
        if inputs.popoverOpen { return .popoverOpen }
        if inputs.inboxIsKeyDesk { return .inboxViewed }
        return nil
    }
}

/// Bubble motion: grows out of the pet with a strong ease-out, leaves faster.
enum PetSpeechMotion {
    static let enterDuration: TimeInterval = 0.18
    static let exitDuration: TimeInterval = 0.12
    static let enterScale: CGFloat = 0.96
    /// cubic-bezier(0.23, 1, 0.32, 1)
    static let enterCurve = (c0x: 0.23, c0y: 1.0, c1x: 0.32, c1y: 1.0)

    static func enterAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: enterDuration)
            : .timingCurve(enterCurve.c0x, enterCurve.c0y, enterCurve.c1x, enterCurve.c1y, duration: enterDuration)
    }
}

enum PetSpeechSizing {
    static let maxWidth: CGFloat = 260
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 9
    static let cornerRadius: CGFloat = 16
    static let tailWidth: CGFloat = 14
    static let tailHeight: CGFloat = 7
    static let accentDotSize: CGFloat = 7
    static let accentDotSpacing: CGFloat = 7
    static let fontSize: CGFloat = 13
    static let minTextWidth: CGFloat = 40
    /// Gap between the bubble's tail and the pet window.
    static let spacing: CGFloat = 2

    /// The text column's width: one line when it fits, else the max width and
    /// two lines. Measured with the same font the bubble draws.
    static func textWidth(for text: String, showsAccentDot: Bool) -> CGFloat {
        let chrome = horizontalPadding * 2 + (showsAccentDot ? accentDotSize + accentDotSpacing : 0)
        let available = maxWidth - chrome
        let single = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
        return min(available, max(minTextWidth, ceil(single) + 1))
    }

    /// Where the tail sits along the bubble's edge: under the pet's center,
    /// kept clear of the rounded corners.
    static func tailCenterX(anchorMidX: CGFloat, bubbleFrame: CGRect) -> CGFloat {
        let inset = cornerRadius + tailWidth / 2
        let x = anchorMidX - bubbleFrame.minX
        guard bubbleFrame.width > inset * 2 else { return bubbleFrame.width / 2 }
        return min(max(x, inset), bubbleFrame.width - inset)
    }
}

enum PetSpeechTailEdge: Equatable {
    case top
    case bottom
}

/// Rounded rectangle and tail as one path, so the material and the hairline
/// stroke run around both without a seam.
struct PetSpeechBubbleShape: Shape {
    var tailEdge: PetSpeechTailEdge
    var tailCenterX: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = PetSpeechSizing.cornerRadius
        let tw = PetSpeechSizing.tailWidth
        let th = PetSpeechSizing.tailHeight
        // Built with the tail at the bottom, then flipped for a top tail.
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, rect.height - th))
        let radius = min(r, body.height / 2, body.width / 2)
        let tailX = min(max(tailCenterX, body.minX + radius + tw / 2), body.maxX - radius - tw / 2)
        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                    tangent2End: CGPoint(x: body.maxX, y: body.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                    tangent2End: CGPoint(x: body.maxX - radius, y: body.maxY), radius: radius)
        path.addLine(to: CGPoint(x: tailX + tw / 2, y: body.maxY))
        path.addLine(to: CGPoint(x: tailX, y: body.maxY + th))
        path.addLine(to: CGPoint(x: tailX - tw / 2, y: body.maxY))
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                    tangent2End: CGPoint(x: body.minX, y: body.maxY - radius), radius: radius)
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                    tangent2End: CGPoint(x: body.minX + radius, y: body.minY), radius: radius)
        path.closeSubpath()
        guard tailEdge == .top else { return path }
        return path.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY * 2 + rect.height))
    }
}

/// The bubble's root. Each new speech gets a fresh identity, so it enters
/// with its own animation; a re-layout of the same speech does not replay it.
struct PetSpeechBubbleView: View {
    let speech: PetSpeech
    let tailEdge: PetSpeechTailEdge
    let tailCenterX: CGFloat
    let reduceMotion: Bool
    let onActivate: () -> Void

    var body: some View {
        PetSpeechBubbleCard(
            speech: speech,
            tailEdge: tailEdge,
            tailCenterX: tailCenterX,
            reduceMotion: reduceMotion,
            onActivate: onActivate
        )
        .id(speech.id)
    }
}

/// The bubble itself: the popover card's material, radius and hairline, two
/// lines at most, and a quiet accent dot when Titio needs a decision.
private struct PetSpeechBubbleCard: View {
    let speech: PetSpeech
    let tailEdge: PetSpeechTailEdge
    let tailCenterX: CGFloat
    let reduceMotion: Bool
    let onActivate: () -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var showsAccentDot: Bool { speech.urgency == .decision }

    var body: some View {
        let reduce = reduceMotion || systemReduceMotion
        let shape = PetSpeechBubbleShape(tailEdge: tailEdge, tailCenterX: tailCenterX)
        HStack(alignment: .firstTextBaseline, spacing: PetSpeechSizing.accentDotSpacing) {
            if showsAccentDot {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: PetSpeechSizing.accentDotSize, height: PetSpeechSizing.accentDotSize)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .accessibilityHidden(true)
            }
            Text(speech.text)
                .font(.system(size: PetSpeechSizing.fontSize))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    width: PetSpeechSizing.textWidth(for: speech.text, showsAccentDot: showsAccentDot),
                    alignment: .leading
                )
        }
        .padding(.horizontal, PetSpeechSizing.horizontalPadding)
        .padding(.vertical, PetSpeechSizing.verticalPadding)
        .padding(tailEdge == .top ? .top : .bottom, PetSpeechSizing.tailHeight)
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
        .contentShape(shape)
        // Grows out of the pet; with reduced motion, a plain fade.
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduce ? 1 : PetSpeechMotion.enterScale,
                     anchor: tailEdge == .top ? .top : .bottom)
        .onAppear {
            withAnimation(PetSpeechMotion.enterAnimation(reduceMotion: reduce)) { appeared = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Titio: %1$@", speech.text))
        .accessibilityHint(L("Opens Titio's Notifications at this message"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onActivate() }
        .accessibilityIdentifier("pet.speech")
    }
}

/// One click target for the whole bubble. Accepts the first click so a single
/// click works while another app is active, and never becomes key.
final class PetSpeechHostingView: NSHostingView<PetSpeechBubbleView> {
    var onClick: (() -> Void)?
    /// The pointer entered (true) or left (false) the bubble.
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }
}

private final class PetSpeechWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The bubble's own borderless, non-activating window, so the sprite window
/// never clips it and showing it never takes focus from what the user is doing.
@MainActor
final class PetSpeechPanel {
    private var window: PetSpeechWindow?
    private var hosting: PetSpeechHostingView?
    private var speech: PetSpeech?
    private var reduceMotion = false
    private var onClick: (() -> Void)?
    private var onHover: ((Bool) -> Void)?
    /// Latest-wins: a fade-out that finishes after a newer show must not hide it.
    private var generation = 0

    var isVisible: Bool { window?.isVisible == true && speech != nil }
    var windowForTests: NSPanel? { window }
    var hostingForTests: PetSpeechHostingView? { hosting }

    func show(
        _ speech: PetSpeech,
        anchorFrame: CGRect,
        visibleFrame: CGRect,
        reduceMotion: Bool,
        onClick: @escaping () -> Void,
        onHover: @escaping (Bool) -> Void = { _ in }
    ) {
        generation &+= 1
        self.speech = speech
        self.reduceMotion = reduceMotion
        self.onClick = onClick
        self.onHover = onHover
        let window = ensureWindow()
        layout(anchorFrame: anchorFrame, visibleFrame: visibleFrame)
        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    /// Follows the pet when it moves or resizes.
    func reposition(anchorFrame: CGRect, visibleFrame: CGRect) {
        guard isVisible else { return }
        layout(anchorFrame: anchorFrame, visibleFrame: visibleFrame)
    }

    func hide(animated: Bool) {
        generation &+= 1
        let owner = generation
        speech = nil
        onClick = nil
        guard let window, window.isVisible else { return }
        // The exit is an opacity fade only, so reduced motion keeps it too.
        guard animated else {
            window.orderOut(nil)
            window.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = PetSpeechMotion.exitDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, self.generation == owner, let window else { return }
                window.orderOut(nil)
                window.alphaValue = 1
            }
        })
    }

    func close() {
        generation &+= 1
        speech = nil
        onClick = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        hosting = nil
    }

    private func ensureWindow() -> PetSpeechWindow {
        if let window { return window }
        let window = PetSpeechWindow(
            contentRect: CGRect(x: 0, y: 0, width: PetSpeechSizing.maxWidth, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("pet.speech")
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.window = window
        return window
    }

    private func layout(anchorFrame: CGRect, visibleFrame: CGRect) {
        guard let window, let speech else { return }
        let click: () -> Void = { [weak self] in self?.onClick?() }
        // Size first (the tail's edge does not change it), then place, then
        // point the tail at the pet from the side the placement chose.
        let probe = view(speech, tailEdge: .bottom, tailCenterX: 0, onActivate: click)
        let hosting: PetSpeechHostingView
        if let existing = self.hosting {
            hosting = existing
            hosting.rootView = probe
        } else {
            hosting = PetSpeechHostingView(rootView: probe)
            hosting.setAccessibilityIdentifier("pet.speech")
            self.hosting = hosting
            window.contentView = hosting
        }
        hosting.onClick = click
        hosting.onHoverChanged = { [weak self] hovering in self?.onHover?(hovering) }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let placement = PetPopoverPlacement.resolve(
            anchorFrame: anchorFrame,
            requestedSize: size,
            visibleFrame: visibleFrame,
            spacing: PetSpeechSizing.spacing
        )
        let tailEdge: PetSpeechTailEdge = placement.orientation.vertical == .above ? .bottom : .top
        hosting.rootView = view(
            speech,
            tailEdge: tailEdge,
            tailCenterX: PetSpeechSizing.tailCenterX(anchorMidX: anchorFrame.midX, bubbleFrame: placement.frame),
            onActivate: click
        )
        window.setFrame(placement.frame, display: true)
        window.invalidateShadow()
    }

    private func view(
        _ speech: PetSpeech,
        tailEdge: PetSpeechTailEdge,
        tailCenterX: CGFloat,
        onActivate: @escaping () -> Void
    ) -> PetSpeechBubbleView {
        PetSpeechBubbleView(
            speech: speech,
            tailEdge: tailEdge,
            tailCenterX: tailCenterX,
            reduceMotion: reduceMotion,
            onActivate: onActivate
        )
    }
}

/// Drives the queue: TTL timers, suppression and the click route. Time and
/// timers are injected so tests run on a manual clock.
@MainActor
final class PetSpeechController {
    /// Runs `fire` after `delay` seconds; returns a cancel closure.
    typealias Schedule = @MainActor (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void

    static let liveSchedule: Schedule = { delay, fire in
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            fire()
        }
        return { task.cancel() }
    }

    private let model: PetViewModel
    private let now: () -> Date
    private let schedule: Schedule
    private(set) var queue = PetSpeechQueue()
    private var cancelTimer: (() -> Void)?
    private var timerGeneration = 0
    /// The pointer is over the bubble: it never expires under the pointer.
    private(set) var isHovering = false
    /// After the pointer leaves an expired bubble, it stays this long.
    static let hoverGrace: TimeInterval = 2

    /// The bubble appears in a non-activating panel that never takes focus,
    /// so VoiceOver would not notice it: announce it (decisions first).
    static let liveAnnounce: (PetSpeech) -> Void = { speech in
        guard let app = NSApp else { return }
        let priority: NSAccessibilityPriorityLevel = speech.urgency == .info ? .medium : .high
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: L("Titio: %1$@", speech.text),
                .priority: priority.rawValue,
            ]
        )
    }
    var announce: (PetSpeech) -> Void = PetSpeechController.liveAnnounce

    /// The suppression inputs for a speech about this conversation.
    var inputs: (BotConversationID) -> PetSpeechSuppression.Inputs = { _ in
        PetSpeechSuppression.Inputs(
            speechEnabled: false, petEnabled: false, petVisible: false, popoverOpen: false, inboxIsKeyDesk: false
        )
    }
    /// Puts the bubble on screen; false when the pet window cannot show it.
    var present: (PetSpeech, _ onClick: @escaping () -> Void) -> Bool = { _, _ in false }
    var dismiss: (_ animated: Bool) -> Void = { _ in }
    var openRoute: ([String: String]) -> Void = { _ in }
    /// A new bubble appeared (the pet pounces with it).
    var onSpoke: (PetSpeech) -> Void = { _ in }

    init(model: PetViewModel, now: @escaping () -> Date = Date.init, schedule: Schedule? = nil) {
        self.model = model
        self.now = now
        self.schedule = schedule ?? Self.liveSchedule
    }

    func speak(_ speech: PetSpeech) {
        if let reason = PetSpeechSuppression.reason(inputs(speech.conversationID)) {
            petSpeechLog.debug("pet.speech.suppressed reason=\(reason.rawValue, privacy: .public)")
            return
        }
        if queue.enqueue(speech, now: now()) {
            showCurrent()
        }
    }

    /// The bubble was clicked: open the inbox at that message, and go quiet.
    /// Opening the inbox makes every waiting bubble redundant.
    func click() {
        guard let speech = queue.current else { return }
        clear(animated: false)
        openRoute(speech.routeUserInfo)
    }

    /// Settings, popover or desk changed: hide the bubble if a rule now says so.
    func reevaluate() {
        guard let current = queue.current,
              PetSpeechSuppression.reason(inputs(current.conversationID)) != nil else { return }
        clear(animated: true)
    }

    func clear(animated: Bool) {
        isHovering = false
        queue.clear()
        cancelTimer?()
        cancelTimer = nil
        timerGeneration &+= 1
        model.setSpeech(nil)
        dismiss(animated)
    }

    private func showCurrent() {
        guard let current = queue.current else {
            clear(animated: true)
            return
        }
        if PetSpeechSuppression.reason(inputs(current.conversationID)) != nil {
            clear(animated: true)
            return
        }
        model.setSpeech(current)
        guard present(current, { [weak self] in self?.click() }) else {
            clear(animated: false)
            return
        }
        onSpoke(current)
        announce(current)
        armTimer()
    }

    /// Hovering pauses the TTL; leaving re-arms it, with `hoverGrace` left at
    /// least, so the bubble never vanishes as the user reaches for it.
    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            cancelTimer?()
            cancelTimer = nil
            timerGeneration &+= 1
        } else if queue.current != nil {
            armTimer(minimumDelay: Self.hoverGrace)
        }
    }

    private func armTimer(minimumDelay: TimeInterval = 0) {
        cancelTimer?()
        timerGeneration &+= 1
        let owner = timerGeneration
        guard !isHovering, let expiresAt = queue.currentExpiresAt else {
            cancelTimer = nil
            return
        }
        cancelTimer = schedule(max(minimumDelay, expiresAt.timeIntervalSince(now()))) { [weak self] in
            guard let self, self.timerGeneration == owner, !self.isHovering else { return }
            if self.queue.advance(now: self.now()) {
                self.showCurrent()
            } else {
                self.armTimer()
            }
        }
    }
}
