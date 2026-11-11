import Foundation
import AppKit
import SwiftUI
import Combine
import CoreModel
import DesignSystemKit

/// Lightweight "feed" panel inspired by cmux's Feed (`docs/feed.md`).
/// Subscribes to the in-process event bus exposed through a callback
/// (kept dependency-free: SocketServer's EventBus is wired in
/// AppCommandRouter at construction time), and displays a reverse-
/// chronological log of agent / domain events.
@MainActor
public final class FeedPanelViewModel: ObservableObject {
    public struct Item: Identifiable, Equatable {
        public let id: Int64
        public let kind: String
        public let title: String
        public let ts: Date
        /// Precomputed lowercased haystack so the filter scan doesn't
        /// allocate a fresh `lowercased()` per item per keystroke (PERF-004).
        let searchKey: String
        /// Absolute hover label. The 1s relative-time tick used to allocate
        /// a FormatStyle per visible row even though `ts` never changes.
        public let absoluteTimestampLabel: String

        public init(id: Int64, kind: String, title: String, ts: Date) {
            self.id = id; self.kind = kind; self.title = title; self.ts = ts
            self.searchKey = (kind + " " + title).lowercased()
            self.absoluteTimestampLabel = Self.absoluteTimestampLabel(for: ts)
        }

        /// Same style as the previous `.formatted(date: .abbreviated, time: .standard)`
        /// help string, computed once at ingest.
        nonisolated public static func absoluteTimestampLabel(for ts: Date) -> String {
            ts.formatted(date: .abbreviated, time: .standard)
        }
    }

    /// Newest-last storage: events append at the end (O(1)) and the view
    /// renders `displayed` reversed, avoiding the O(n) `insert(at:0)` per
    /// event and the per-event full-array trim at cap (PERF-003).
    @Published public private(set) var items: [Item] = []
    @Published public var filter: String = "" { didSet { recomputeFiltered() } }
    /// When paused, incoming events are buffered (not dropped) so the user
    /// can read without the list jumping; resume flushes them (UX-008).
    @Published public var paused: Bool = false { didSet { if !paused { flushPending() } } }

    /// Cached newest-first filtered view; recomputed only when `items` or
    /// `filter` change rather than on every body pass (PERF-004).
    @Published public private(set) var filtered: [Item] = []

    private var pending: [Item] = []

    /// Pure drop-oldest trim: returns `buffer` capped to `cap` items (newest kept).
    /// Called on the pending buffer after every enqueue while paused (PERF-PENDING-CAP).
    /// Extracted as a `nonisolated static` so it can be unit-tested without @MainActor.
    nonisolated public static func trimmed(_ buffer: [Item], cap: Int) -> [Item] {
        guard buffer.count > cap else { return buffer }
        return Array(buffer.suffix(cap))
    }

    /// Number of buffered events waiting to be flushed when the feed resumes.
    public var pendingCount: Int { pending.count }

    /// Pure helper: badge text to show on the pause control.
    /// Returns nil when not paused or when there is nothing buffered.
    nonisolated public static func pauseBadgeText(isPaused: Bool, pendingCount: Int) -> String? {
        guard isPaused, pendingCount > 0 else { return nil }
        return "\(pendingCount)"
    }

    private static let cap = 200
    /// Trim only when crossing this slack threshold, not every event (PERF-003).
    private static let trimAt = 256

    /// Injectable clock so snapshot tests get deterministic timestamps
    /// instead of `Date()`-derived live values (QA-009).
    private let now: () -> Date
    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    /// Token-rate / terminal-chunk kinds already live-only for EventLog and
    /// prefiltered by Pet. Ingesting them here hops every EventBus publish
    /// to MainActor, FormatStyle-s at 30 Hz, and evicts the 200-row cap.
    /// Domain / lifecycle kinds still ingest. Matches the empty-state copy.
    nonisolated public static func shouldIngest(kind: String) -> Bool {
        switch kind {
        case "agent.item.delta", "agent.item.progress",
             "surface.output", "surface.output.summary":
            return false
        default:
            return true
        }
    }

    public func receive(seq: Int64, kind: String, title: String, ts: Double) {
        guard Self.shouldIngest(kind: kind) else { return }
        let item = Item(id: seq, kind: kind, title: title, ts: Date(timeIntervalSince1970: ts))
        if paused {
            pending.append(item)
            if pending.count > Self.cap { pending = Self.trimmed(pending, cap: Self.cap) }
            return
        }
        append(item)
    }

    private func append(_ item: Item) {
        items.append(item)
        if items.count > Self.trimAt { items = Self.trimmed(items, cap: Self.cap) }
        recomputeFiltered()
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        items.append(contentsOf: pending)
        pending.removeAll()
        if items.count > Self.trimAt { items = Self.trimmed(items, cap: Self.cap) }
        recomputeFiltered()
    }

    /// UX-008: drop all events and reset the stream.
    public func clear() {
        items.removeAll()
        pending.removeAll()
        recomputeFiltered()
    }

    private func recomputeFiltered() {
        let reversed = items.reversed()
        if filter.isEmpty {
            filtered = Array(reversed)
        } else {
            let q = filter.lowercased()
            filtered = reversed.filter { $0.searchKey.contains(q) }
        }
    }

    /// IMP-007: serialize an event's fields to pretty JSON for the per-row
    /// "Copy JSON" action — lets users grab a raw event for debugging.
    public func json(for item: Item) -> String {
        let obj: [String: Any] = [
            "seq": item.id,
            "kind": item.kind,
            "title": item.title,
            "ts": item.ts.timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"seq\":\(item.id),\"kind\":\"\(item.kind)\"}"
        }
        return s
    }

    /// Compact "12s ago" relative label for the row timestamp (UX-008).
    public func relativeTime(for item: Item) -> String {
        let secs = Int(now().timeIntervalSince(item.ts))
        if secs < 2 { return "now" }
        if secs < 60 { return L("%1$@s ago", secs) }
        if secs < 3600 { return L("%1$@m ago", secs / 60) }
        if secs < 86_400 { return L("%1$@h ago", secs / 3600) }
        return L("%1$@d ago", secs / 86_400)
    }
}

/// Admission seam for the Feed's relative-time clock.
///
/// The clock has useful work only while at least one row is visible. Keeping
/// this decision pure makes the SwiftUI task's idle behavior deterministic in
/// tests without changing the one-second cadence of visible timestamps.
public enum FeedTimestampTickPolicy {
    public static func shouldTick(visibleItemCount: Int) -> Bool {
        visibleItemCount > 0
    }
}

public struct FeedPanelView: View {
    @ObservedObject var vm: FeedPanelViewModel
    // UX-P2: re-render relative timestamps every second so "12s ago" stays
    // accurate instead of going stale while the feed is paused or idle.
    @State private var timestampTick: Int = 0
    // UX-P2: require confirmation before clearing -- irreversible and instant.
    @State private var showClearConfirm: Bool = false
    public init(vm: FeedPanelViewModel) { self.vm = vm }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.md) {
                Text(L("FEED")).font(DS.Font.caption2.weight(.semibold))
                    .tracking(0.6).foregroundColor(DS.Palette.textTertiary)
                // UX-009: subtle "N of M" so an empty list reads as
                // "filter excludes everything" vs "no events".
                if !vm.filter.isEmpty {
                    Text(L("%1$@ of %2$@", vm.filtered.count, vm.items.count))
                        .font(DS.Font.caption2.monospacedDigit())
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityIdentifier("feed.resultCount")
                }
                Spacer()
                // UX-008: pause freezes the stream while reading; clear resets it.
                HStack(spacing: DS.Space.xs) {
                    DSIconButton(vm.paused ? "play.fill" : "pause.fill",
                                 help: vm.paused ? L("Resume feed") : L("Pause feed")) { vm.paused.toggle() }
                        .accessibilityLabel(vm.paused ? L("Resume feed") : L("Pause feed"))
                        .accessibilityIdentifier("feed.pause")
                    if let badge = FeedPanelViewModel.pauseBadgeText(isPaused: vm.paused,
                                                                      pendingCount: vm.pendingCount) {
                        Text(badge)
                            .font(DS.Font.caption2.monospacedDigit().weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, DS.Space.xs)
                            .padding(.vertical, 1)
                            .background(DS.Palette.accent)
                            .clipShape(Capsule())
                            .accessibilityLabel(L("%1$@ buffered events", badge))
                            .accessibilityIdentifier("feed.pause.badge")
                    }
                }
                // UX-P2: confirm before clearing -- instant and irreversible.
                DSIconButton("trash", help: L("Clear feed")) { showClearConfirm = true }
                    .accessibilityLabel(L("Clear feed"))
                    .accessibilityIdentifier("feed.clear")
                    .disabled(vm.items.isEmpty)
                    .confirmationDialog(L("Clear all feed events?"), isPresented: $showClearConfirm) {
                        Button(L("Clear Feed"), role: .destructive) { vm.clear() }
                        Button(L("Cancel"), role: .cancel) {}
                    } message: {
                        Text(L("This removes all events and cannot be undone."))
                    }
                HStack(spacing: DS.Space.xs) {
                    TextField(L("filter"), text: $vm.filter)
                        .textFieldStyle(.plain)
                        .font(DS.Font.caption)
                        .accessibilityIdentifier("feed.filter")
                    if !vm.filter.isEmpty {
                        Button { vm.filter = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityLabel(L("Clear filter"))
                        .accessibilityIdentifier("feed.filter.clear")
                    }
                }
                .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.xs)
                .background(DS.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                .frame(maxWidth: 150)
            }
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
            .dsBar(edge: .bottom)
            if vm.filtered.isEmpty {
                DSEmptyState(icon: "dot.radiowaves.left.and.right",
                             title: vm.filter.isEmpty ? L("No activity") : L("No matches"),
                             subtitle: vm.filter.isEmpty
                                ? L("Domain events (workspace, surface, notification, window) stream here as they happen.")
                                : L("No events match \"%1$@\". Clear the filter to see all activity.", vm.filter))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(vm.filtered) { item in
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                HStack(spacing: DS.Space.sm) {
                                    Text(L("#%1$@", item.id))
                                        .font(DS.Font.caption2.monospacedDigit())
                                        .foregroundColor(DS.Palette.textTertiary)
                                    DSPill(item.kind, tone: kindTone(item.kind))
                                    Spacer()
                                    Text(relativeLabel(for: item))
                                        .font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary)
                                        .help(item.absoluteTimestampLabel)
                                }
                                if !item.title.isEmpty {
                                    Text(item.title).font(DS.Font.caption)
                                        .foregroundColor(DS.Palette.textSecondary).lineLimit(2)
                                }
                            }
                            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                            .accessibilityIdentifier("feed.item.\(item.id)")
                            // IMP-007: grab an event's raw payload as JSON.
                            .contextMenu {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(vm.json(for: item), forType: .string)
                                } label: {
                                    Label(L("Copy JSON"), systemImage: "curlybraces")
                                }
                                .accessibilityIdentifier("feed.item.\(item.id).copyJSON")
                            }
                        }
                    }.padding(DS.Space.md)
                }
                .background(DS.Palette.bg)
            }
        }
        .background(DS.Palette.surface)
        // Lifetime pulse — `Timer.publish` in `body` allocated a new
        // publisher and resubscribed on every ingest/`timestampTick`
        // rebuild (and starved the 1s fire during EventBus bursts).
        .task(id: vm.filtered.isEmpty) {
            guard FeedTimestampTickPolicy.shouldTick(visibleItemCount: vm.filtered.count) else {
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                timestampTick &+= 1
            }
        }
    }

    /// Relative timestamp for a row. Touches `timestampTick` so the 1s timer
    /// refreshes labels without remounting LazyVStack cells (a prior
    /// `.id("ts-\(id)-\(tick)")` forced identity thrash every second — PERF).
    private func relativeLabel(for item: FeedPanelViewModel.Item) -> String {
        _ = timestampTick
        return vm.relativeTime(for: item)
    }

    private func kindTone(_ k: String) -> DSPill.Tone {
        if k.hasPrefix("notification") { return .warning }
        if k.hasPrefix("workspace") { return .accent }
        if k.hasPrefix("surface") { return .success }
        if k.hasPrefix("window") { return .accent }
        return .neutral
    }
}

@MainActor
public final class FeedPanelSurface: NSObject, Surface {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    public let viewModel = FeedPanelViewModel()
    public var subscriptionToken: AnyHashable?
    /// Teardown hook set by the surface factory so `close()` releases the
    /// EventBus subscription without this module depending on SocketServer
    /// (PERF-MAC_DIFF_FEED_MARKDOWN-001).
    public var onClose: (() -> Void)?

    public init(workspaceID: WorkspaceID, title: String = L("Feed")) {
        self.descriptor = SurfaceDescriptor(type: .rightSidebarTool, title: title,
                                            iconName: "list.bullet.rectangle.portrait",
                                            metadata: ["workspace": workspaceID.value.uuidString, "tool": "feed"])
        let host = NSHostingView(rootView: FeedPanelView(vm: viewModel))
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

    public func focus() { view.window?.makeFirstResponder(view) }
    public func unfocus() {}
    public func close() { onClose?(); onClose = nil }
    public func sendText(_ text: String) {}
    public func readText() -> String { viewModel.items.map(\.title).joined(separator: "\n") }
    public func snapshot() -> [String: String] { ["count": String(viewModel.items.count)] }
}
