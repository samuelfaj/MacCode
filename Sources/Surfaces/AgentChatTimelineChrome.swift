import AppKit
import DesignSystemKit
import SwiftUI
import CoreModel

/// Shared Agent App / Desk transcript history layout.
///
/// Self-sizing `AgentLinkedInlineText` NSTextView rows must never sit in
/// `LazyVStack`. Live sample pid 36908 (binary already had `liveTurnActive`
/// and `resetFittedSizeCache`) still spent 100% of the main thread in
/// `LazySubviewPlacements.placeSubviews`. Eager VStack is the policy that
/// removes that placement loop. `entryCount` / `liveTurnActive` stay in the
/// signature so existing call sites compile.
public enum AgentChatTimelineHistoryLayout {
    public static let eagerEntryLimit = 8

    public static func usesLazyLayout(entryCount _: Int, liveTurnActive _: Bool = false) -> Bool {
        false
    }
}

/// Shared Agent App / Desk timeline viewport constants.
public struct AgentChatTimelineScrollTarget: Equatable {
    public let anchor: String
    public let requestID: UUID

    public init(anchor: String, requestID: UUID = UUID()) {
        self.anchor = anchor
        self.requestID = requestID
    }
}

public enum AgentChatTimelineScrollChrome {
    public static let bottomAnchorID = "BOTTOM"
    public static let bottomRevealSlack: CGFloat = 4
    public static let scrollDownButtonBottomInset: CGFloat = 22
    /// Gap between scroll-to-latest and a trailing accessory stacked under it.
    public static let trailingAccessorySpacing: CGFloat = DS.Space.sm
}

/// Hop off the current AttributeGraph transaction before touching SwiftUI
/// `@State` or the SwiftUI-backed `NSScrollView` offset.
///
/// WHY: macOS 26 SwiftUI stores scroll clipping in `@Observable`
/// `ScrollEnvironmentStorage`. `NSViewRepresentable.updateNSView` and
/// `NSView.boundsDidChangeNotification` run re-entrantly while
/// `NSHostingView.beginTransaction` is already in
/// `ObservationRegistrar.access` for
/// `isScrollViewTransformClippingEnabled`. Nested CoW on that access list
/// SIGSEGVs in `swift_isUniquelyReferenced_nonNull_native` (fault
/// `0x4036…0008` on the main run-loop observer).
enum AgentChatScrollGraphHop {
    static func afterCurrentUpdate(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}

/// Shared Agent App / Desk timeline viewport: pin, FAB, BOTTOM anchor,
/// and AppKit follow. Callers own the rows.
public struct AgentChatTimelineScrollContainer<Content: View, FollowOverlay: View>: View {

    public let rejoinToken: Int
    public let followToken: Int
    public let scrollToBottomIdentifier: String
    public let accessibilityIdentifier: String
    public let scrollTarget: AgentChatTimelineScrollTarget?
    public let horizontalPadding: CGFloat
    public let verticalPadding: CGFloat
    public let columnGutter: CGFloat
    /// Host action pinned to the bottom-trailing corner, above the composer
    /// (Bots Desk new-thread +). Scroll-to-latest stacks above it.
    private let trailingAccessory: AnyView?
    private let onReadingHistoryChanged: (Bool) -> Void
    private let content: (CGFloat) -> Content
    private let followOverlay: (@escaping () -> Void) -> FollowOverlay

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sticksToBottom = true
    @State private var showScrollDownButton = false
    @State private var pinForceToken = 0
    @State private var scrollScheduler = AgentChatTimelineScrollScheduler()

    public init(
        rejoinToken: Int,
        followToken: Int,
        scrollToBottomIdentifier: String,
        accessibilityIdentifier: String,
        scrollTarget: AgentChatTimelineScrollTarget? = nil,
        horizontalPadding: CGFloat = 22,
        verticalPadding: CGFloat = 32,
        columnGutter: CGFloat = 44,
        trailingAccessory: AnyView? = nil,
        onReadingHistoryChanged: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder content: @escaping (CGFloat) -> Content,
        @ViewBuilder followOverlay: @escaping (@escaping () -> Void) -> FollowOverlay
    ) {
        self.rejoinToken = rejoinToken
        self.followToken = followToken
        self.scrollToBottomIdentifier = scrollToBottomIdentifier
        self.accessibilityIdentifier = accessibilityIdentifier
        self.scrollTarget = scrollTarget
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.columnGutter = columnGutter
        self.trailingAccessory = trailingAccessory
        self.onReadingHistoryChanged = onReadingHistoryChanged
        self.content = content
        self.followOverlay = followOverlay
    }

    public var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                let columnWidth = max(0, viewport.size.width - columnGutter)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        AgentChatTimelineScrollFollower(
                            slack: AgentChatTimelineScrollChrome.bottomRevealSlack,
                            pinned: sticksToBottom,
                            pinForceToken: pinForceToken,
                            onScrolledAway: onScrolledAway,
                            onReturnedToBottom: onReturnedToBottom
                        )
                        .frame(width: 1, height: 1)
                        .opacity(0.001)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                        content(columnWidth)
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .id(AgentChatTimelineScrollChrome.bottomAnchorID)
                    .frame(width: viewport.size.width, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(DS.Palette.bg)
                // FAB must not be a conditional ZStack sibling of the
                // ScrollView: inserting/removing that sibling recreates
                // SwiftUI's ScrollEnvironmentStorage while AttributeGraph
                // still tracks `isScrollViewTransformClippingEnabled`.
                .overlay(alignment: .bottomTrailing) {
                    VStack(alignment: .trailing, spacing: AgentChatTimelineScrollChrome.trailingAccessorySpacing) {
                        if showScrollDownButton {
                            Button {
                                rejoin(proxy)
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(DS.Palette.onAccent)
                                    .frame(width: 44, height: 44)
                                    .background(DS.Palette.accent)
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("Scroll to latest message"))
                            .accessibilityIdentifier(scrollToBottomIdentifier)
                            .help(L("Scroll to latest message"))
                            .transition(AgentChatMotion.transition(.fadeAndScale, reduceMotion: reduceMotion))
                        }
                        if let trailingAccessory {
                            trailingAccessory
                        }
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, AgentChatTimelineScrollChrome.scrollDownButtonBottomInset)
                }
            }
            .onAppear { rejoin(proxy) }
            .overlay(alignment: .topLeading) {
                followOverlay { scheduleScrollToBottom(proxy, force: false) }
            }
            .onChange(of: rejoinToken) { _ in
                rejoin(proxy)
            }
            .onChange(of: followToken) { _ in
                scheduleScrollToBottom(proxy, force: false)
            }
            .onChange(of: scrollTarget) { target in
                guard let target else { return }
                sticksToBottom = false
                scrollScheduler.followGeneration &+= 1
                DispatchQueue.main.async {
                    proxy.scrollTo(target.anchor, anchor: .center)
                }
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func rejoin(_ proxy: ScrollViewProxy) {
        onReadingHistoryChanged(false)
        sticksToBottom = true
        showScrollDownButton = false
        pinForceToken &+= 1
        scheduleScrollToBottom(proxy, force: true)
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy, force: Bool) {
        scrollScheduler.forcePending = scrollScheduler.forcePending || force
        let generation = scrollScheduler.followGeneration
        guard !scrollScheduler.scheduled else { return }
        scrollScheduler.scheduled = true
        DispatchQueue.main.async {
            let shouldForce = scrollScheduler.forcePending
            scrollScheduler.forcePending = false
            scrollScheduler.scheduled = false
            guard shouldForce || generation == scrollScheduler.followGeneration else { return }
            scrollToBottom(proxy, force: shouldForce)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, force: Bool) {
        guard ScrollPinPolicy.shouldProgrammaticFollow(pinned: sticksToBottom, force: force) else { return }
        if force {
            sticksToBottom = true
            showScrollDownButton = false
        }
        proxy.scrollTo(AgentChatTimelineScrollChrome.bottomAnchorID, anchor: .bottom)
    }

    private func onReturnedToBottom() {
        guard !sticksToBottom || showScrollDownButton else { return }
        sticksToBottom = true
        showScrollDownButton = false
        onReadingHistoryChanged(false)
    }

    private func onScrolledAway() {
        scrollScheduler.followGeneration &+= 1
        guard sticksToBottom || !showScrollDownButton else { return }
        sticksToBottom = false
        showScrollDownButton = true
        onReadingHistoryChanged(true)
    }
}

public extension AgentChatTimelineScrollContainer where FollowOverlay == EmptyView {
    init(
        rejoinToken: Int,
        followToken: Int,
        scrollToBottomIdentifier: String,
        accessibilityIdentifier: String,
        scrollTarget: AgentChatTimelineScrollTarget? = nil,
        horizontalPadding: CGFloat = 22,
        verticalPadding: CGFloat = 32,
        columnGutter: CGFloat = 44,
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) {
        self.init(
            rejoinToken: rejoinToken,
            followToken: followToken,
            scrollToBottomIdentifier: scrollToBottomIdentifier,
            accessibilityIdentifier: accessibilityIdentifier,
            scrollTarget: scrollTarget,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            columnGutter: columnGutter,
            content: content,
            followOverlay: { _ in EmptyView() }
        )
    }
}

private struct AgentChatTimelineScrollScheduler {
    var scheduled = false
    var forcePending = false
    var followGeneration = 0
}

/// AppKit pin probe. Must live inside the scroll document.
struct AgentChatTimelineScrollFollower: NSViewRepresentable {
    let slack: CGFloat
    let pinned: Bool
    let pinForceToken: Int
    let onScrolledAway: () -> Void
    let onReturnedToBottom: () -> Void

    func makeNSView(context: Context) -> FollowerView {
        let view = FollowerView()
        view.configure(
            slack: slack,
            pinned: pinned,
            pinForceToken: pinForceToken,
            onScrolledAway: onScrolledAway,
            onReturnedToBottom: onReturnedToBottom
        )
        return view
    }

    func updateNSView(_ view: FollowerView, context: Context) {
        view.configure(
            slack: slack,
            pinned: pinned,
            pinForceToken: pinForceToken,
            onScrolledAway: onScrolledAway,
            onReturnedToBottom: onReturnedToBottom
        )
        AgentChatScrollGraphHop.afterCurrentUpdate { [weak view] in
            view?.attach()
        }
    }

    final class FollowerView: NSView {
        private var slack: CGFloat = 4
        private var pinned: Bool = true
        private var lastPinForceToken: Int = 0
        private var onScrolledAway: (() -> Void)?
        private var onReturnedToBottom: (() -> Void)?

        private weak var scrollView: NSScrollView?
        private var clipObserver: NSObjectProtocol?
        private var docObserver: NSObjectProtocol?
        private var liveScrollStartObserver: NSObjectProtocol?
        private var liveScrollEndObserver: NSObjectProtocol?
        private var userOwnedLiveScroll = false
        private var lastOriginY: CGFloat = 0
        private var lastAtBottom: Bool?
        private var pendingBottomSnap = false
        private var pendingBottomSnapWorkItem: DispatchWorkItem?
        private var snapDirty = false
        private var lastBottomSnapAt: TimeInterval = 0
        private let minimumBottomSnapInterval: TimeInterval = 0.05
        private var attachRetryCount = 0
        private let maxAttachRetries = 8
        #if DEBUG
        private var didLogDetach = false
        #endif

        func configure(
            slack: CGFloat,
            pinned: Bool,
            pinForceToken: Int,
            onScrolledAway: @escaping () -> Void,
            onReturnedToBottom: @escaping () -> Void
        ) {
            self.slack = slack
            self.onScrolledAway = onScrolledAway
            self.onReturnedToBottom = onReturnedToBottom

            let forceTokenChanged = pinForceToken != lastPinForceToken
            if forceTokenChanged {
                lastPinForceToken = pinForceToken
            }

            if !pinned {
                if self.pinned {
                    cancelPendingSnap()
                }
                self.pinned = false
            } else {
                let atBottom = geometry()?.atBottom ?? false
                let accept = ScrollBottomGeometry.shouldAcceptSwiftUIPin(
                    localPinned: self.pinned,
                    swiftUIPinned: true,
                    forceTokenChanged: forceTokenChanged,
                    geometricallyAtBottom: atBottom
                )
                if accept {
                    self.pinned = true
                    if forceTokenChanged {
                        scheduleScrollToBottom()
                    }
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachRetryCount = 0
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        deinit {
            removeObservers()
            pendingBottomSnapWorkItem?.cancel()
        }

        private func removeObservers() {
            if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
            if let docObserver { NotificationCenter.default.removeObserver(docObserver) }
            if let liveScrollStartObserver {
                NotificationCenter.default.removeObserver(liveScrollStartObserver)
            }
            if let liveScrollEndObserver {
                NotificationCenter.default.removeObserver(liveScrollEndObserver)
            }
            clipObserver = nil
            docObserver = nil
            liveScrollStartObserver = nil
            liveScrollEndObserver = nil
        }

        func attach() {
            guard let scroll = enclosingScrollView else {
                if attachRetryCount < maxAttachRetries {
                    attachRetryCount += 1
                    DispatchQueue.main.async { [weak self] in self?.attach() }
                } else {
                    #if DEBUG
                    if !didLogDetach {
                        didLogDetach = true
                        NSLog("AgentChatTimelineScrollFollower: enclosingScrollView nil after retries — auto-scroll pin inactive")
                    }
                    #endif
                }
                return
            }
            attachRetryCount = 0
            guard scroll !== scrollView else { return }
            removeObservers()
            scrollView = scroll
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            clipObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.handleScroll() }
            if let doc = scroll.documentView {
                doc.postsFrameChangedNotifications = true
                docObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: doc, queue: .main
                ) { [weak self] _ in self?.handleContentGrowth() }
            }
            liveScrollStartObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scroll,
                queue: .main
            ) { [weak self] _ in self?.userOwnedLiveScroll = true }
            liveScrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scroll,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.userOwnedLiveScroll = false
                self.handleScroll()
            }
            lastOriginY = clip.bounds.origin.y
            AgentChatScrollGraphHop.afterCurrentUpdate { [weak self] in
                self?.handleScroll()
            }
        }

        private var isUserOwnedScroll: Bool {
            if userOwnedLiveScroll { return true }
            guard let event = NSApp.currentEvent else { return false }
            switch event.type {
            case .scrollWheel, .magnify:
                return ScrollPinPolicy.isRecentScrollInput(
                    eventTimestamp: event.timestamp,
                    now: ProcessInfo.processInfo.systemUptime
                )
            default:
                return false
            }
        }

        private func geometry() -> (origin: CGFloat, gap: CGFloat, atBottom: Bool, isFlipped: Bool)? {
            guard let scroll = scrollView, let doc = scroll.documentView else { return nil }
            let origin = scroll.contentView.bounds.origin.y
            let visible = scroll.contentView.bounds.height
            let content = max(doc.bounds.height, doc.frame.height)
            let flipped = doc.isFlipped
            let gap = ScrollBottomGeometry.gap(
                documentHeight: content,
                visibleOriginY: origin,
                visibleHeight: visible,
                isFlipped: flipped
            )
            return (origin, gap, gap <= slack, flipped)
        }

        private func handleScroll() {
            guard let g = geometry() else { return }
            let delta = ScrollBottomGeometry.originDeltaTowardTop(
                previousOriginY: lastOriginY,
                currentOriginY: g.origin,
                isFlipped: g.isFlipped
            )
            defer { lastOriginY = g.origin }
            if pendingBottomSnap {
                if g.atBottom { report(atBottom: true) }
                return
            }
            switch ScrollPinPolicy.evaluate(
                originDelta: delta,
                gap: g.gap,
                slack: slack,
                userOwned: isUserOwnedScroll
            ) {
            case .reachedBottom: report(atBottom: true)
            case .scrolledAway: report(atBottom: false)
            case .unchanged: break
            }
        }

        private func handleContentGrowth() {
            guard let g = geometry() else { return }
            if pinned, g.gap > slack {
                scheduleScrollToBottom()
            } else if g.atBottom {
                report(atBottom: true)
            }
        }

        private func cancelPendingSnap() {
            pendingBottomSnapWorkItem?.cancel()
            pendingBottomSnapWorkItem = nil
            pendingBottomSnap = false
            snapDirty = false
        }

        private func scheduleScrollToBottom() {
            snapDirty = true
            guard !pendingBottomSnap else { return }
            pendingBottomSnap = true
            let now = ProcessInfo.processInfo.systemUptime
            let delay = max(0, minimumBottomSnapInterval - (now - lastBottomSnapAt))
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingBottomSnap = false
                self.pendingBottomSnapWorkItem = nil
                guard self.pinned else {
                    self.snapDirty = false
                    return
                }
                let hadWork = self.snapDirty
                self.snapDirty = false
                guard hadWork, let g = self.geometry() else { return }
                if g.gap > self.slack {
                    self.scrollToBottom()
                    if let after = self.geometry(), after.gap > self.slack, self.pinned {
                        self.scrollToBottom()
                    }
                } else if g.atBottom {
                    self.report(atBottom: true)
                }
                if self.snapDirty && self.pinned {
                    self.scheduleScrollToBottom()
                }
            }
            pendingBottomSnapWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func scrollToBottom() {
            AgentChatScrollGraphHop.afterCurrentUpdate { [weak self] in
                self?.performScrollToBottom()
            }
        }

        private func performScrollToBottom() {
            guard let scroll = scrollView, let doc = scroll.documentView else { return }
            let visible = scroll.contentView.bounds.height
            let content = max(doc.bounds.height, doc.frame.height)
            let targetY = ScrollBottomGeometry.maxScrollOriginY(
                documentHeight: content,
                visibleHeight: visible,
                isFlipped: doc.isFlipped
            )
            scroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scroll.reflectScrolledClipView(scroll.contentView)
            lastOriginY = targetY
            lastBottomSnapAt = ProcessInfo.processInfo.systemUptime
        }

        private func report(atBottom: Bool) {
            guard atBottom != lastAtBottom else { return }
            lastAtBottom = atBottom
            pinned = atBottom
            if !atBottom {
                cancelPendingSnap()
            }
            let callback = atBottom ? onReturnedToBottom : onScrolledAway
            AgentChatScrollGraphHop.afterCurrentUpdate { [weak self] in
                guard self != nil else { return }
                callback?()
            }
        }
    }
}
