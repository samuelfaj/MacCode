import CoreModel
import AppKit
import CoreGraphics
import CryptoKit
import Persistence
import SwiftUI

private final class PetPopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum PetAccessibilityIdentifier {
    // PERF: nibble table instead of per-byte `String(format:)` so every
    // attention/active row identity hash avoids 32 formatter calls on paint.
    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    static func row(_ raw: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(raw.utf8)) {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }
}

enum PetAttentionVisualStatus: Equatable {
    case completed
    case failed
    case interrupted
    case needsAttention

    static func resolve(_ kind: PetAttentionItemKind) -> PetAttentionVisualStatus {
        switch kind {
        case .callback:
            return .needsAttention
        case .agentOutcome(let outcome):
            switch outcome {
            case .completed: return .completed
            case .failed: return .failed
            case .interrupted: return .interrupted
            }
        case .notification(let category):
            switch category {
            case .gitFailed, .projectScriptFailed, .sshTransferFailed, .providerUpdateFailed:
                return .failed
            case .sshUnexpectedDisconnect, .fileConflict, .serverListenerFailed, .notificationsDenied, .agentAttention:
                return .needsAttention
            case .gitCompleted, .projectScriptCompleted, .sshTransferCompleted:
                return .completed
            }
        }
    }

    var systemImage: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .interrupted: return "exclamationmark.triangle.fill"
        case .needsAttention: return "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .completed: return .teal
        case .failed: return .red
        case .interrupted, .needsAttention: return .orange
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .needsAttention: return "Needs attention"
        }
    }
}

enum PetPopoverSizing {
    static let preferredWidth: CGFloat = 360
    static let minimumHeight: CGFloat = 120
    static let maximumHeight: CGFloat = 520
    static let screenMargin: CGFloat = 12

    static func contentWidth(visibleFrame: CGRect) -> CGFloat {
        min(preferredWidth, max(0, visibleFrame.width - screenMargin * 2))
    }

    static func resolve(fittingSize: CGSize, visibleFrame: CGRect) -> CGSize {
        let width = contentWidth(visibleFrame: visibleFrame)
        let maximumScreenHeight = max(0, visibleFrame.height - screenMargin * 2)
        let requestedHeight = max(minimumHeight, fittingSize.height)
        return CGSize(
            width: width,
            height: min(maximumHeight, maximumScreenHeight, requestedHeight)
        )
    }
}

enum PetScreenGeometry {
    /// Physical placement envelope for the pet.
    ///
    /// The pet may share the Dock's bottom edge when it is beside the Dock, so
    /// `visibleFrame` cannot be used as the complete placement rect. Keep the
    /// menu-bar clearance from `visibleFrame.maxY`, then resolve any actual Dock
    /// overlap separately with `frameAvoidingDock`.
    static func petPlacementFrame(screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let topEdge = min(screenFrame.maxY, max(screenFrame.minY, visibleFrame.maxY))
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: max(0, topEdge - screenFrame.minY)
        )
    }

    /// Clamps a pet to the physical envelope while keeping it out of the
    /// Dock's occupied strip. The Dock can split the bottom edge into two free
    /// regions, so a single rectangular `visibleFrame` is too conservative.
    /// Returns `nil` when neither the physical envelope nor the fallback can
    /// contain a non-overlapping panel.
    static func frameAvoidingDock(
        frame: CGRect,
        placementFrame: CGRect,
        dockFrame: CGRect?,
        fallbackFrame: CGRect? = nil
    ) -> CGRect? {
        let clamped = PetPlacement.clamped(frame: frame, to: placementFrame)
        guard let dockFrame,
              clamped.intersection(dockFrame).area > 0 else {
            return clamped
        }

        let candidateOrigins = [
            CGPoint(x: dockFrame.minX - clamped.width, y: clamped.minY),
            CGPoint(x: dockFrame.maxX, y: clamped.minY),
            CGPoint(x: clamped.minX, y: dockFrame.minY - clamped.height),
            CGPoint(x: clamped.minX, y: dockFrame.maxY)
        ]
        // PERF: single pass tracks the nearest side-route and nearest
        // above/below-route directly, avoiding the compactMap + filter + map
        // intermediates and the duplicate min scans.
        func distance(_ frame: CGRect) -> CGFloat {
            hypot(frame.minX - clamped.minX, frame.minY - clamped.minY)
        }
        var nearestSide: (distance: CGFloat, frame: CGRect)?
        var nearestVertical: (distance: CGFloat, frame: CGRect)?
        for (index, origin) in candidateOrigins.enumerated() {
            let candidate = PetPlacement.clamped(
                frame: CGRect(origin: origin, size: clamped.size),
                to: placementFrame
            )
            guard candidate.intersection(dockFrame).area == 0 else { continue }
            let entry = (distance: distance(candidate), frame: candidate)
            if index < 2 {
                if nearestSide == nil || entry.distance < nearestSide!.distance {
                    nearestSide = entry
                }
            } else if nearestVertical == nil || entry.distance < nearestVertical!.distance {
                nearestVertical = entry
            }
        }

        // Prefer a left/right route so a corner anchor can share the Dock's
        // bottom edge whenever there is horizontal room. Move above/below
        // only when neither side can contain the panel.
        if let nearest = nearestSide?.frame {
            return nearest
        }
        if let nearest = nearestVertical?.frame {
            return nearest
        }

        // If the Dock leaves no physical route for this size, fall back to
        // AppKit's conservative safe rect instead of placing the pet under it.
        if let fallbackFrame {
            // `fallbackFrame` is normally `NSScreen.visibleFrame`; validate it
            // anyway because transient or synthetic geometry can be malformed.
            let fallback = PetPlacement.clamped(frame: clamped, to: fallbackFrame)
            if fallback.intersection(dockFrame).area == 0 {
                return fallback
            }
        }
        // No safe frame exists in the supplied geometry. Fail closed instead
        // of returning a frame known to intersect the Dock.
        return nil
    }

    /// Returns the largest rectangle inside `visibleFrame` that is also
    /// disjoint from a trusted Dock footprint. Usually this is just
    /// `visibleFrame`; the extra subtraction handles AX bounds that include a
    /// few points of Dock glass beyond AppKit's rounded safe-area edge.
    static func safeFallbackFrame(
        visibleFrame: CGRect,
        dockFrame: CGRect
    ) -> CGRect? {
        let overlap = visibleFrame.intersection(dockFrame)
        guard overlap.area > 0 else { return visibleFrame }

        let candidates = [
            CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: max(0, overlap.minX - visibleFrame.minX),
                height: visibleFrame.height
            ),
            CGRect(
                x: overlap.maxX,
                y: visibleFrame.minY,
                width: max(0, visibleFrame.maxX - overlap.maxX),
                height: visibleFrame.height
            ),
            CGRect(
                x: visibleFrame.minX,
                y: overlap.maxY,
                width: visibleFrame.width,
                height: max(0, visibleFrame.maxY - overlap.maxY)
            ),
            CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width,
                height: max(0, overlap.minY - visibleFrame.minY)
            )
        ].filter { $0.area > 0 && $0.intersection(dockFrame).area == 0 }

        return candidates.max { lhs, rhs in lhs.area < rhs.area }
    }

    static func largestPositiveIntersectionIndex(
        frame: CGRect,
        screenFrames: [CGRect]
    ) -> Int? {
        screenFrames.enumerated()
            .map { (index: $0.offset, area: $0.element.intersection(frame).area) }
            .filter { $0.area > 0 }
            .max { lhs, rhs in lhs.area < rhs.area }?
            .index
    }
}

/// Observes only the frame, so animation ticks never re-run PetSpriteView's body.
private struct PetSpriteFrameView: View {
    @ObservedObject var frame: PetFrameModel

    var body: some View {
        if let image = frame.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}

private struct PetSpriteView: View {
    @ObservedObject var model: PetViewModel
    let onActivate: () -> Void

    var body: some View {
        ZStack {
            PetSpriteFrameView(frame: model.frameModel)

            VStack {
                HStack(alignment: .top) {
                    // Blue (left): agent threads running now. Red (right): what
                    // needs you. Both carry their count, capped at "99+".
                    if let active = model.activeBadgeText {
                        PetCountDot(text: active, color: .blue)
                            .help("\(active) running")
                            .accessibilityIdentifier("pet.activeBadge")
                    }
                    Spacer(minLength: 0)
                    if let badge = model.badgeText {
                        PetCountDot(text: badge, color: .red)
                            .help(PetAttentionCountFormatter.needYouText(badgeText: badge))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Titio")
        .accessibilityValue(model.accessibilityValue)
        .accessibilityHint("Opens MacCode pet status")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onActivate() }
        .accessibilityIdentifier("pet.status")
    }


}

/// A count on a colored dot. One digit stays a circle; more digits stretch it,
/// so the dot never clips its number.
private struct PetCountDot: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 3.5)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(color))
            .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .padding(4)
    }
}

private struct PetAttentionPopoverView: View {
    @ObservedObject var model: PetViewModel
    let onOpen: (PetAttentionItem) -> Void
    let onOpenActive: (PetActiveThreadItem) -> Void
    let onOpenApp: () -> Void
    let onOpenTitio: () -> Void
    let onSendToTitio: (String) -> Void
    let onClose: () -> Void
    let contentWidth: CGFloat
    /// The corner nearest the pet; the card grows out of it.
    let growthAnchor: UnitPoint
    let showsQuickChatShortcut: Bool
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            // The whole card is a way to talk to Titio: type and press Return.
            TitioComposerField(
                size: .compact,
                identifier: "pet.titioField",
                onSubmit: onSendToTitio,
                onCancel: onClose
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            // What is running right now stays one glance away; everything else lives in Activity.
            if !model.activeThreads.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        activeGroupedSection(Array(model.activeThreads.prefix(50)))
                    }
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 260)
            }

            Divider()
            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            if let routeError = model.routeError {
                Text(routeError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("pet.routeError")
            }
        }
        .frame(width: contentWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        // Grows out of the pet: short, ease-out, never from zero.
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96, anchor: growthAnchor)
        .onAppear {
            withAnimation(reduceMotion
                ? .easeOut(duration: 0.12)
                : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)) { appeared = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pet.popover")
        .onExitCommand { onClose() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onOpenTitio) {
                TitioAvatarView(size: 44)
            }
            .buttonStyle(TitioPressableStyle())
            .help("Open Titio's chat")
            .accessibilityLabel("Open Titio's chat")
            .accessibilityIdentifier("pet.avatar")

            VStack(alignment: .leading, spacing: 4) {
                Text(L("Titio"))
                    .font(.title3.weight(.semibold))
                statusChips
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(PetPopoverHoverStyle(cornerRadius: 12))
            .help("Close")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("pet.close")
        }
    }

    /// Counts are shortcuts: each one opens Activity, where that work lives.
    @ViewBuilder
    private var statusChips: some View {
        let counts = model.activityCounts
        if !counts.isAvailable {
            Text(L("Activity status unavailable"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if counts.running == 0, counts.needsYou == 0 {
            Text(L("All quiet. Ask me anything."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pet.status.quiet")
        } else {
            HStack(spacing: 4) {
                if counts.running > 0 {
                    statusChip(
                        text: "\(PetActiveThreadCountFormatter.badgeText(count: counts.running) ?? "\(counts.running)") running",
                        color: .blue,
                        identifier: "pet.status.running"
                    )
                }
                if counts.needsYou > 0 {
                    statusChip(
                        text: PetAttentionCountFormatter.needYouText(
                            badgeText: PetAttentionCountFormatter.badgeText(count: counts.needsYou, isEnabled: true) ?? "\(counts.needsYou)"
                        ),
                        color: .red,
                        identifier: "pet.status.needsYou"
                    )
                }
            }
        }
    }

    private func statusChip(text: String, color: Color, identifier: String) -> some View {
        Button(action: onOpenApp) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(PetPopoverHoverStyle(cornerRadius: 10))
        .help("Open Activity")
        .accessibilityLabel("\(text). Open Activity")
        .accessibilityIdentifier(identifier)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if showsQuickChatShortcut {
                HStack(spacing: 5) {
                    Text(L("\u{2325}Space"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                        )
                    Text(L("from anywhere"))
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Option Space opens Titio from anywhere")
            }
            Spacer(minLength: 4)
            footerButton("Activity", systemImage: "tray.full", identifier: "pet.openActivity", action: onOpenApp)
            footerButton("Open Chat", systemImage: "bubble.left.and.bubble.right", identifier: "pet.openTitio", action: onOpenTitio)
        }
    }

    private func footerButton(
        _ title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
        }
        .buttonStyle(PetPopoverHoverStyle(cornerRadius: 7))
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func activeGroupedSection(_ items: [PetActiveThreadItem]) -> some View {
        if !items.isEmpty {
            sectionHeader("Active", identifier: "pet.section.active")
            let groups = PetPopoverGrouping.active(items)
            let showWorkspaceHeaders = groups.count > 1
                || groups.first?.name != PetPopoverGrouping.unknownWorkspaceName
            ForEach(groups) { group in
                if showWorkspaceHeaders {
                    workspaceHeader(group.name, prefix: "pet.workspace.active")
                }
                ForEach(group.items) { item in
                    activeRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private func attentionGroupedSection(_ title: String, items: [PetAttentionItem]) -> some View {
        if !items.isEmpty {
            sectionHeader(title, identifier: nil)
            let groups = PetPopoverGrouping.attention(items)
            let showWorkspaceHeaders = groups.count > 1
                || groups.first?.name != PetPopoverGrouping.unknownWorkspaceName
            ForEach(groups) { group in
                if showWorkspaceHeaders {
                    workspaceHeader(group.name, prefix: "pet.workspace.attention")
                }
                ForEach(group.items) { item in
                    attentionRow(item)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, identifier: String?) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier ?? "pet.section.\(title)")
    }

    private func workspaceHeader(_ name: String, prefix: String) -> some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("\(prefix).\(PetAccessibilityIdentifier.row(name))")
    }

    private func activeRow(_ item: PetActiveThreadItem) -> some View {
        Button { onOpenActive(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.blue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .help(detail)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        }
        .buttonStyle(PetPopoverHoverStyle(cornerRadius: 10))
        .padding(.horizontal, 8)
        .accessibilityLabel(Self.rowAccessibilityLabel(status: "Active", title: item.title, detail: item.detail))
        .accessibilityHint("Opens the thread")
        .accessibilityIdentifier("pet.activeRow.\(PetAccessibilityIdentifier.row(item.id))")
    }

    private func attentionRow(_ item: PetAttentionItem) -> some View {
        let status = PetAttentionVisualStatus.resolve(item.kind)
        return HStack(spacing: 12) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(detail)
                }
            }
            Spacer(minLength: 8)
            Button(item.classification == .needsYou ? "Review" : "Open") { onOpen(item) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("pet.row.\(PetAccessibilityIdentifier.row(item.id)).open")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.rowAccessibilityLabel(
            status: status.accessibilityLabel,
            title: item.title,
            detail: item.detail
        ))
        .accessibilityIdentifier("pet.row.\(PetAccessibilityIdentifier.row(item.id))")
    }

    private static func rowAccessibilityLabel(status: String, title: String, detail: String?) -> String {
        if let detail, !detail.isEmpty {
            return "\(status), \(title), \(detail)"
        }
        return "\(status), \(title)"
    }
}

/// Quiet hover and press wash for the popover's clickable rows, chips and
/// footer actions, so every target answers the pointer.
private struct PetPopoverHoverStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .background(shape.fill(Color.primary.opacity(
                    configuration.isPressed ? 0.12 : hovering ? 0.07 : 0
                )))
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

@MainActor
public final class PetWindowController: NSObject {
    private struct PetPlacementContext {
        let placementFrame: CGRect
        let dockFrame: CGRect?
        let fallbackFrame: CGRect?
    }

    private struct DockPlacementCacheEntry {
        let visibleFrame: CGRect
        let context: PetPlacementContext
    }

    public var onOpenItem: ((PetAttentionItem) -> Void)?
    public var onOpenActiveThread: ((PetActiveThreadItem) -> Void)?
    public var onOpenRemoteCode: (() -> Void)?
    public var onOpenTitio: (() -> Void)?
    public var onSendToTitio: ((String) -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onHidePet: (() -> Void)?
    public var onToggleAnimations: (() -> Void)?
    public var onAdoptFreePosition: (() -> Void)?
    public var onInteraction: (() -> Void)?
    public var onCareAction: ((PetCareAction) -> Void)?
    public var onDragStateChanged: ((Bool) -> Void)?
    /// The popover is about to open; the speech bubble yields to it.
    var onPopoverWillOpen: (() -> Void)?

    private let model: PetViewModel
    private let placementStore: PetPlacementStore
    private var petPanel: NSPanel?
    private var spriteView: PetSpriteHostingView<PetSpriteView>?
    private var popoverPanel: PetPopoverPanel?
    private var speechPanel: PetSpeechPanel?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var popoverLocalMonitor: Any?
    private var popoverGlobalMonitor: Any?
    private weak var keyWindowBeforePopover: NSWindow?
    private var pendingGlobalMousePoint: CGPoint?
    private var globalMouseMoveTask: Task<Void, Never>?
    private(set) var globalMouseMoveProcessCountForTests = 0
    private(set) var lastProcessedGlobalMousePointForTests: CGPoint?
    var keyWindowProviderForTests: (() -> NSWindow?)?
    /// Deterministic geometry seam for placement tests; production reads the
    /// live Dock window hit shape instead.
    var dockFrameProviderForTests: ((NSScreen) -> CGRect?)?
    private(set) var dockFrameProviderCallCountForTests = 0
    private var dockPlacementCacheByDisplayID: [String: DockPlacementCacheEntry] = [:]
    private var dockPlacementObservationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var dockPlacementRevalidateTask: Task<Void, Never>?

    public init(model: PetViewModel, placementStore: PetPlacementStore) {
        self.model = model
        self.placementStore = placementStore
        super.init()
        installDockPlacementCacheObservers()
    }

    public var isVisible: Bool { petPanel?.isVisible == true }
    public var isPopoverVisible: Bool { popoverPanel?.isVisible == true }
    var petPanelForTests: NSPanel? { petPanel }
    var popoverPanelForTests: NSPanel? { popoverPanel }
    var speechPanelForTests: NSPanel? { speechPanel?.windowForTests }
    var speechHostingForTests: PetSpeechHostingView? { speechPanel?.hostingForTests }
    public var isSpeechVisible: Bool { speechPanel?.isVisible == true }
    var spriteAccessibilityViewForTests: NSView? { spriteView }
    var dragLifecycleForTests: (active: Bool, monitoring: Bool, cursorPushed: Bool)? {
        spriteView?.dragLifecycleForTests
    }
    func beginDragForTests() { spriteView?.beginActiveDragForTests() }
    func completeDragForTests(asDrop: Bool) { spriteView?.completeActiveDragForTests(asDrop: asDrop) }
    func routeMouseUpForTests() { spriteView?.routeMouseUpForTests() }
    func fallbackMouseUpForTests() { spriteView?.fallbackMouseUpForTests() }
    func finishDragForTests(frame: CGRect) { finishDrag(frame: frame) }
    func contextMenuForTests() -> NSMenu { contextMenu() }
    func invokeCareMenuItemForTests(_ item: NSMenuItem) { contextCareAction(item) }

    public func show() {
        ensurePetPanel()
        applySettings(model.settings)
        guard isVisible else { return }
        petPanel?.orderFrontRegardless()
        installMouseMonitors()
    }

    public func hide() {
        closePopover()
        hideSpeech(animated: false)
        cancelActiveDrag()
        petPanel?.orderOut(nil)
        removeMouseMonitors()
    }

    func cancelActiveDrag() {
        spriteView?.cancelActiveDrag()
    }

    public func stop() {
        hide()
        uninstallDockPlacementCacheObservers()
        petPanel?.close()
        popoverPanel?.close()
        speechPanel?.close()
        petPanel = nil
        popoverPanel = nil
        speechPanel = nil
        spriteView = nil
    }

    public func applySettings(_ settings: AppSettings) {
        guard settings.petEnabled else {
            hide()
            return
        }
        ensurePetPanel()
        let size = petSize(scale: settings.petSize)
        guard let frame = resolvePetFrame(size: size, settings: settings),
              let panel = petPanel else {
            hide()
            return
        }
        panel.setContentSize(size)
        panel.setFrame(frame, display: true)
        if !isVisible {
            petPanel?.orderFrontRegardless()
            installMouseMonitors()
        }
        if isPopoverVisible { positionPopover() }
        if isSpeechVisible { positionSpeech() }
    }

    public func resetPosition() {
        placementStore.reset()
        applySettings(model.settings)
    }

    public func screensDidChange() {
        invalidateDockPlacementCache()
        applySettings(model.settings)
    }

    func invalidateDockPlacementCacheForTests() {
        invalidateDockPlacementCache()
    }

    public func togglePopover() {
        isPopoverVisible ? closePopover() : openPopover()
    }

    func openPopoverForTests() { openPopover() }

    public func closePopover(restoringPreviousKeyWindow: Bool = true) {
        let windowToRestore = restoringPreviousKeyWindow ? keyWindowBeforePopover : nil
        popoverPanel?.orderOut(nil)
        removePopoverMonitors()
        petPanel?.orderFrontRegardless()
        keyWindowBeforePopover = nil
        if let windowToRestore,
           windowToRestore !== popoverPanel,
           windowToRestore.isVisible,
           windowToRestore.canBecomeKey {
            windowToRestore.makeKeyAndOrderFront(nil)
        }
    }

    private func ensurePetPanel() {
        guard petPanel == nil else { return }
        let size = petSize(scale: model.settings.petSize)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("pet.window")
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let activate: () -> Void = { [weak self] in self?.activatePet() }
        let hosting = PetSpriteHostingView(rootView: PetSpriteView(
            model: model,
            onActivate: activate
        ))
        hosting.identifier = NSUserInterfaceItemIdentifier("pet.window")
        hosting.setAccessibilityElement(true)
        hosting.setAccessibilityRole(.button)
        hosting.setAccessibilityLabel("Titio")
        hosting.setAccessibilityHelp("Open MacCode pet status")
        hosting.setAccessibilityIdentifier("pet.status")
        hosting.onClick = activate
        hosting.onRightClick = { [weak self, weak hosting] event in
            guard let self, let hosting else { return }
            self.onInteraction?()
            self.showContextMenu(event: event, in: hosting)
        }
        hosting.onDragEnded = { [weak self] frame in
            guard let self else { return }
            self.finishDrag(frame: self.petPanel?.frame ?? frame)
        }
        hosting.onDragStateChanged = { [weak self] isDragging in
            self?.onDragStateChanged?(isDragging)
        }
        hosting.imageProvider = { [weak self] in self?.model.currentFrame?.displayImage }
        hosting.attentionBadgeVisibleProvider = { [weak self] in self?.model.badgeText != nil }
        hosting.activeBadgeVisibleProvider = { [weak self] in self?.model.activeBadgeText != nil }
        hosting.accessibilityValueProvider = { [weak self] in
            self?.model.accessibilityValue ?? "Pet status unavailable"
        }
        panel.contentView = hosting
        self.petPanel = panel
        self.spriteView = hosting
    }

    private func openPopover() {
        ensurePetPanel()
        onPopoverWillOpen?()
        hideSpeech(animated: false)
        let panel: PetPopoverPanel
        if let existing = popoverPanel {
            panel = existing
        } else {
            panel = PetPopoverPanel(
                contentRect: CGRect(x: 0, y: 0, width: 360, height: 220),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.identifier = NSUserInterfaceItemIdentifier("pet.popover")
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isExcludedFromWindowsMenu = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            popoverPanel = panel
        }

        if !panel.isVisible, let keyWindow = currentKeyWindow(), keyWindow !== panel {
            keyWindowBeforePopover = keyWindow
        }

        let visibleFrame = popoverTargetScreen()?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: PetPopoverSizing.preferredWidth + 24, height: 544)
        let contentWidth = PetPopoverSizing.contentWidth(visibleFrame: visibleFrame)
        // Orientation depends only on where the pet sits, not on the card's size.
        let orientation = petPanel.map {
            PetPopoverPlacement.resolve(
                anchorFrame: $0.frame,
                requestedSize: panel.frame.size,
                visibleFrame: visibleFrame
            ).orientation
        }
        let hosting = NSHostingView(rootView: PetAttentionPopoverView(
            model: model,
            onOpen: { [weak self] in self?.onOpenItem?($0) },
            onOpenActive: { [weak self] in self?.onOpenActiveThread?($0) },
            onOpenApp: { [weak self] in self?.onOpenRemoteCode?() },
            onOpenTitio: { [weak self] in self?.onOpenTitio?() },
            onSendToTitio: { [weak self] in self?.onSendToTitio?($0) },
            onClose: { [weak self] in self?.closePopover() },
            contentWidth: contentWidth,
            growthAnchor: Self.growthAnchor(for: orientation),
            showsQuickChatShortcut: TitioQuickChatController.isHotKeyRegistered
        ))
        hosting.setAccessibilityIdentifier("pet.popover")
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(PetPopoverSizing.resolve(
            fittingSize: hosting.fittingSize,
            visibleFrame: visibleFrame
        ))
        positionPopover()
        panel.makeKeyAndOrderFront(nil)
        installPopoverMonitors()
    }

    /// The card's corner that sits next to the pet.
    static func growthAnchor(for orientation: PetPopoverOrientation?) -> UnitPoint {
        guard let orientation else { return .bottom }
        switch (orientation.vertical, orientation.horizontal) {
        case (.above, .leading): return .bottomLeading
        case (.above, .trailing): return .bottomTrailing
        case (.below, .leading): return .topLeading
        case (.below, .trailing): return .topTrailing
        }
    }

    private func positionPopover() {
        guard let anchor = petPanel?.frame,
              let panel = popoverPanel,
              let screen = popoverTargetScreen() else { return }
        let placement = PetPopoverPlacement.resolve(
            anchorFrame: anchor,
            requestedSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(placement.frame, display: true)
    }

    /// Shows Titio's speech bubble next to the pet, in its own window. False
    /// when the pet is not on screen to speak from.
    @discardableResult
    func showSpeech(
        _ speech: PetSpeech,
        reduceMotion: Bool,
        onClick: @escaping () -> Void,
        onHover: @escaping (Bool) -> Void = { _ in }
    ) -> Bool {
        guard isVisible, !isPopoverVisible,
              let anchor = petPanel?.frame,
              let screen = popoverTargetScreen() else { return false }
        let panel = speechPanel ?? PetSpeechPanel()
        speechPanel = panel
        panel.show(
            speech,
            anchorFrame: anchor,
            visibleFrame: screen.visibleFrame,
            reduceMotion: reduceMotion,
            onClick: onClick,
            onHover: onHover
        )
        return true
    }

    func hideSpeech(animated: Bool) {
        speechPanel?.hide(animated: animated)
    }

    private func positionSpeech() {
        guard let anchor = petPanel?.frame, let screen = popoverTargetScreen() else { return }
        speechPanel?.reposition(anchorFrame: anchor, visibleFrame: screen.visibleFrame)
    }

    private func finishDrag(frame: CGRect) {
        guard let panel = petPanel,
              let screen = screen(containing: frame) ?? fallbackScreen() else { return }
        let context = petPlacementContext(for: screen)
        guard let clamped = resolvedPetFrame(frame, in: context) else {
            // A transient Dock snapshot left no safe route. Reconcile against
            // the last persisted position instead of committing an unsafe drop.
            applySettings(model.settings)
            return
        }
        panel.setFrame(clamped, display: true)
        placementStore.save(PetStoredPlacement(
            displayID: displayID(for: screen),
            position: PetPlacement.normalizedPosition(for: clamped, in: context.placementFrame)
        ))
        onAdoptFreePosition?()
        if isPopoverVisible { positionPopover() }
        if isSpeechVisible { positionSpeech() }
    }

    private func resolvePetFrame(size: CGSize, settings: AppSettings) -> CGRect? {
        let stored = placementStore.load()
        let existingScreen = petPanel?.isVisible == true
            ? petPanel.flatMap { screen(containing: $0.frame) }
            : nil
        let targetScreen = stored.flatMap { stored in
            NSScreen.screens.first { displayID(for: $0) == stored.displayID }
        } ?? existingScreen
            ?? fallbackScreen()
        guard let targetScreen else { return nil }

        let normalized: PetNormalizedPosition
        switch settings.petPosition {
        case "bottomLeft": normalized = PetNormalizedPosition(x: 0, y: 0)
        case "free": normalized = stored?.position ?? PetNormalizedPosition(x: 1, y: 0)
        default: normalized = PetNormalizedPosition(x: 1, y: 0)
        }
        let context = petPlacementContext(for: targetScreen)
        return resolvedPetFrame(
            PetPlacement.frame(
                size: size,
                normalizedPosition: normalized,
                in: context.placementFrame
            ),
            in: context
        )
    }

    func animationFrameDidChange() {
        guard let panel = petPanel else { return }
        let size = petSize(scale: model.settings.petSize)
        guard abs(panel.frame.width - size.width) > 0.01
                || abs(panel.frame.height - size.height) > 0.01 else { return }

        let targetScreen = screen(containing: panel.frame) ?? fallbackScreen()
        let context = targetScreen.map { petPlacementContext(for: $0) }
        let normalized = context.map {
            PetPlacement.normalizedPosition(for: panel.frame, in: $0.placementFrame)
        }
        panel.setContentSize(size)
        if let context, let normalized {
            let frame = PetPlacement.frame(
                size: size,
                normalizedPosition: normalized,
                in: context.placementFrame
            )
            if let resolved = resolvedPetFrame(frame, in: context) {
                panel.setFrame(resolved, display: true)
            } else {
                hide()
                return
            }
        } else if let resolved = resolvePetFrame(size: size, settings: model.settings) {
            panel.setFrame(resolved, display: true)
        } else {
            hide()
            return
        }
        if isPopoverVisible { positionPopover() }
        if isSpeechVisible { positionSpeech() }
    }

    private func petSize(scale: Double) -> CGSize {
        let scale = CGFloat([0.75, 1, 1.25, 1.5].contains(scale) ? scale : 1)
        guard let image = model.currentFrame?.displayImage else {
            return CGSize(width: 118 * scale, height: 128 * scale)
        }
        let sourcePixelScale = CGFloat(118.0 / 192.0)
        return CGSize(
            width: (CGFloat(image.width) * sourcePixelScale * scale).rounded(),
            height: (CGFloat(image.height) * sourcePixelScale * scale).rounded()
        )
    }

    private func screen(containing frame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = PetScreenGeometry.largestPositiveIntersectionIndex(
            frame: frame,
            screenFrames: screens.map(\.frame)
        ) else { return nil }
        return screens[index]
    }

    private func petPlacementContext(for screen: NSScreen) -> PetPlacementContext {
        let id = displayID(for: screen)
        let visibleFrame = screen.visibleFrame
        if let cached = dockPlacementCacheByDisplayID[id], cached.visibleFrame == visibleFrame {
            return cached.context
        }
        let context = makePetPlacementContext(for: screen)
        dockPlacementCacheByDisplayID[id] = DockPlacementCacheEntry(
            visibleFrame: visibleFrame,
            context: context
        )
        return context
    }

    private func makePetPlacementContext(for screen: NSScreen) -> PetPlacementContext {
        dockFrameProviderCallCountForTests += 1
        let physicalFrame = PetScreenGeometry.petPlacementFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        let dockFrame: CGRect?
        if let dockFrameProviderForTests {
            dockFrame = dockFrameProviderForTests(screen)
        } else {
            dockFrame = PetDockFrameProvider.frame(for: screen)
        }
        guard let dockFrame else {
            // Without the Dock's actual occupied strip, retain the conservative
            // AppKit bounds rather than risk restoring the pet beneath it.
            return PetPlacementContext(
                placementFrame: screen.visibleFrame,
                dockFrame: nil,
                fallbackFrame: nil
            )
        }
        return PetPlacementContext(
            placementFrame: physicalFrame,
            dockFrame: dockFrame,
            fallbackFrame: PetScreenGeometry.safeFallbackFrame(
                visibleFrame: screen.visibleFrame,
                dockFrame: dockFrame
            )
        )
    }

    private func invalidateDockPlacementCache() {
        dockPlacementCacheByDisplayID.removeAll()
    }

    private func installDockPlacementCacheObservers() {
        guard dockPlacementObservationTokens.isEmpty else { return }
        observeDockPlacement(
            NotificationCenter.default,
            name: NSApplication.didChangeScreenParametersNotification
        )
        observeDockPlacement(
            DistributedNotificationCenter.default(),
            name: Notification.Name("com.apple.dock.prefchanged")
        )
        // PL-04: the 30 s revalidation loop hit-tested the Dock against the
        // WindowServer for every screen on the main thread (~130 ms per tick in
        // the 2026-09-14 sample) even though the notifications above already
        // invalidate the cache and `petPlacementContext(for:)` recomputes lazily
        // on the next use. Invalidation-only; no periodic work.
        dockPlacementRevalidateTask?.cancel()
        dockPlacementRevalidateTask = nil
    }

    private func observeDockPlacement(_ center: NotificationCenter, name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.invalidateDockPlacementCache() }
        }
        dockPlacementObservationTokens.append((center, token))
    }

    private func uninstallDockPlacementCacheObservers() {
        for (center, token) in dockPlacementObservationTokens {
            center.removeObserver(token)
        }
        dockPlacementObservationTokens.removeAll()
        dockPlacementRevalidateTask?.cancel()
        dockPlacementRevalidateTask = nil
        invalidateDockPlacementCache()
    }

    private func resolvedPetFrame(
        _ frame: CGRect,
        in context: PetPlacementContext
    ) -> CGRect? {
        PetScreenGeometry.frameAvoidingDock(
            frame: frame,
            placementFrame: context.placementFrame,
            dockFrame: context.dockFrame,
            fallbackFrame: context.fallbackFrame
        )
    }

    private func popoverTargetScreen() -> NSScreen? {
        guard let anchor = petPanel?.frame else { return fallbackScreen() }
        return screen(containing: anchor) ?? fallbackScreen()
    }

    private func fallbackScreen() -> NSScreen? {
        currentKeyWindow()?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func currentKeyWindow() -> NSWindow? {
        keyWindowProviderForTests?() ?? NSApp.keyWindow
    }

    private func displayID(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.stringValue ?? screen.localizedName
    }

    private func installMouseMonitors() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateMousePassThrough(at: NSEvent.mouseLocation)
            return event
        }
        // Global monitor handlers run on the main thread; filter there instead of hopping
        // a Task per mouse move made anywhere on screen.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handleGlobalMouseMove(at: point) }
        }
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        pendingGlobalMousePoint = nil
        globalMouseMoveTask?.cancel()
        globalMouseMoveTask = nil
        petPanel?.ignoresMouseEvents = false
    }

    func enqueueGlobalMouseMoveForTests(_ point: CGPoint) {
        handleGlobalMouseMove(at: point)
    }

    /// Moves outside the panel matter only to restore input after the panel was left
    /// ignoring events; once it accepts events again they change nothing, so they stop here.
    private func handleGlobalMouseMove(at point: CGPoint) {
        guard let panel = petPanel else { return }
        guard panel.ignoresMouseEvents || panel.frame.insetBy(dx: -2, dy: -2).contains(point) else { return }
        enqueueGlobalMouseMove(at: point)
    }

    private func enqueueGlobalMouseMove(at point: CGPoint) {
        pendingGlobalMousePoint = point
        guard globalMouseMoveTask == nil else { return }
        globalMouseMoveTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard !Task.isCancelled else {
                self.globalMouseMoveTask = nil
                return
            }
            guard let latest = self.pendingGlobalMousePoint else {
                self.globalMouseMoveTask = nil
                return
            }
            self.pendingGlobalMousePoint = nil
            self.globalMouseMoveTask = nil
            self.lastProcessedGlobalMousePointForTests = latest
            self.globalMouseMoveProcessCountForTests += 1
            self.updateMousePassThrough(at: latest)
        }
    }

    private func updateMousePassThrough(at screenPoint: CGPoint) {
        guard let panel = petPanel, panel.isVisible, let spriteView else { return }
        guard panel.frame.contains(screenPoint), !spriteView.didDrag else {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            return
        }
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let localPoint = spriteView.convert(windowPoint, from: nil)
        let ignores = !spriteView.isOpaque(at: localPoint)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    private func installPopoverMonitors() {
        removePopoverMonitors()
        popoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissPopoverIfOutside(NSEvent.mouseLocation)
            return event
        }
        popoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.dismissPopoverIfOutside(point) }
        }
    }

    private func removePopoverMonitors() {
        if let popoverLocalMonitor { NSEvent.removeMonitor(popoverLocalMonitor) }
        if let popoverGlobalMonitor { NSEvent.removeMonitor(popoverGlobalMonitor) }
        popoverLocalMonitor = nil
        popoverGlobalMonitor = nil
    }

    private func dismissPopoverIfOutside(_ point: CGPoint) {
        guard popoverPanel?.frame.contains(point) != true,
              petPanel?.frame.contains(point) != true else { return }
        closePopover()
    }

    private func activatePet() {
        onInteraction?()
        togglePopover()
    }

    private func showContextMenu(event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: view)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "MacCode Pet")
        menu.addItem(menuItem("Chat with Titio", #selector(contextOpenTitio)))
        menu.addItem(menuItem("Open MacCode", #selector(contextOpenRemoteCode)))
        menu.addItem(menuItem("Open ready items", #selector(contextOpenReadyItems)))
        menu.addItem(.separator())
        let careItem = NSMenuItem(title: L("Care"), action: nil, keyEquivalent: "")
        let careMenu = NSMenu(title: "Care")
        for action in PetCareAction.allCases {
            let item = menuItem(action.title, #selector(contextCareAction(_:)))
            item.representedObject = action.rawValue
            careMenu.addItem(item)
        }
        careItem.submenu = careMenu
        menu.addItem(careItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(
            model.settings.petAnimationsEnabled ? "Pause animations" : "Resume animations",
            #selector(contextToggleAnimations)
        ))
        menu.addItem(menuItem("Settings…", #selector(contextOpenSettings)))
        menu.addItem(menuItem("Hide pet", #selector(contextHidePet)))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func contextOpenTitio() { onOpenTitio?() }
    @objc private func contextOpenRemoteCode() { onOpenRemoteCode?() }
    @objc private func contextOpenReadyItems() { openPopover() }
    @objc private func contextToggleAnimations() { onToggleAnimations?() }
    @objc private func contextCareAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let action = PetCareAction(rawValue: rawValue) else { return }
        onCareAction?(action)
    }
    @objc private func contextOpenSettings() { onOpenSettings?() }
    @objc private func contextHidePet() { onHidePet?() }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
