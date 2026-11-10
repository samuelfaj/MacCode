import CoreModel
import DesignSystemKit
import SwiftUI

/// Pure text and ordering rules for the Distill `/loop` strip and sidebar glyph.
public enum DistillLoopPresentation {
    public static let maxVisibleRows = 3
    public static let expiredText = "Expired after 7 days"
    public static let sidebarSymbol = "arrow.clockwise"

    public static func title(_ loop: DistillLoopState) -> String {
        "Loop · \(loop.humanSchedule)"
    }

    /// "next in 2m 05s", "due now", or nil when no fire time is known.
    public static func countdownText(nextFireAt: Date?, now: Date) -> String? {
        guard let nextFireAt else { return nil }
        let remaining = Int(nextFireAt.timeIntervalSince(now).rounded(.up))
        guard remaining > 0 else { return "due now" }
        return "next in \(compactDuration(remaining))"
    }

    public static func compactDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) }
        if s >= 60 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return "\(s)s"
    }

    public static func runsText(_ loop: DistillLoopState) -> String? {
        guard loop.iterations > 0 else { return nil }
        return loop.iterations == 1 ? "1 run" : "\(loop.iterations) runs"
    }

    public static func runningText(_ loop: DistillLoopState) -> String? {
        loop.runningSubagentID == nil ? nil : "Running iteration \(loop.iterations + 1)"
    }

    public static func pausedText(_ loop: DistillLoopState) -> String {
        guard let reason = loop.pausedReason, !reason.isEmpty else { return "Paused" }
        return "Paused · \(reason)"
    }

    public static func accessibilityLabel(_ loop: DistillLoopState, now: Date) -> String {
        var parts = ["Loop \(loop.humanSchedule)"]
        switch loop.state {
        case .paused: parts.append(pausedText(loop))
        case .expired, .stopped: parts.append(expiredText)
        case .active:
            if let running = runningText(loop) {
                parts.append(running)
            } else if let next = loop.nextFireAt {
                let remaining = Int(next.timeIntervalSince(now).rounded(.up))
                parts.append(remaining > 0 ? "next run in \(spokenDuration(remaining))" : "next run due now")
            }
        }
        if let runs = runsText(loop) { parts.append(runs) }
        return parts.joined(separator: ", ")
    }

    public static func spokenDuration(_ seconds: Int) -> String {
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if seconds >= 3600 { return unit(seconds / 3600, "hour") }
        if seconds >= 60 { return unit(seconds / 60, "minute") }
        return unit(seconds, "second")
    }

    /// First rows up to the cap, plus how many were folded into "+N more".
    public static func visible(_ loops: [DistillLoopState]) -> (rows: [DistillLoopState], hidden: Int) {
        let rows = Array(loops.prefix(maxVisibleRows))
        return (rows, loops.count - rows.count)
    }

    /// Loops that keep a thread's sidebar glyph lit.
    public static func activeLoops(_ loops: [DistillLoopState]) -> [DistillLoopState] {
        loops.filter { $0.state == .active }
    }

    public static func sidebarAccessibilityLabel(_ loops: [DistillLoopState]) -> String? {
        guard let first = activeLoops(loops).first else { return nil }
        return "Loop active, \(first.humanSchedule)"
    }

    public static func durationText(ms: Int) -> String {
        ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms) ms"
    }

    public static func iterationSummary(_ it: DistillLoopIteration) -> String {
        var parts = [it.status.rawValue.capitalized]
        if let ms = it.durationMs { parts.append(durationText(ms: ms)) }
        if let tokens = it.tokensUsed { parts.append("\(tokens) tokens") }
        return parts.joined(separator: " · ")
    }
}

/// Strip above the composer listing Distill `/loop` tasks of the open thread.
public struct DistillLoopStrip: View {
    public let loops: [DistillLoopState]
    public let onStop: (String) async throws -> Void
    public let onDismissExpired: (String) -> Void
    public let onResume: ((String) async throws -> Void)?

    public init(
        loops: [DistillLoopState],
        onStop: @escaping (String) async throws -> Void,
        onDismissExpired: @escaping (String) -> Void,
        onResume: ((String) async throws -> Void)? = nil
    ) {
        self.loops = loops
        self.onStop = onStop
        self.onDismissExpired = onDismissExpired
        self.onResume = onResume
    }

    public var body: some View {
        let shown = DistillLoopPresentation.visible(loops.filter { $0.state != .stopped })
        if !shown.rows.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(shown.rows, id: \.taskID) { loop in
                    DistillLoopRow(loop: loop, onStop: onStop, onDismissExpired: onDismissExpired, onResume: onResume)
                }
                if shown.hidden > 0 {
                    Text(L("+%1$@ more", shown.hidden))
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .padding(.leading, DS.Space.lg)
                        .accessibilityIdentifier("agent.loop.more")
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm)
            .accessibilityIdentifier("agent.loop.strip")
        }
    }
}

struct DistillLoopRow: View {
    let loop: DistillLoopState
    let onStop: (String) async throws -> Void
    let onDismissExpired: (String) -> Void
    var onResume: ((String) async throws -> Void)?

    @State private var stopping = false
    @State private var resuming = false
    @State private var resumeError: String?
    @State private var stopError: String?
    @State private var showDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let label = DistillLoopPresentation.accessibilityLabel(loop, now: context.date)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.md) {
                    Image(systemName: DistillLoopPresentation.sidebarSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(loop.state == .active ? DS.Palette.accent : DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                    summary(now: context.date)
                    Spacer(minLength: DS.Space.md)
                    trailing
                }
                if let resumeError {
                    Text(resumeError)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.danger)
                        .lineLimit(2)
                        .padding(.leading, DS.Space.xl)
                        .accessibilityIdentifier("agent.loop.resumeError")
                }
                if let stopError {
                    Text(stopError)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.danger)
                        .lineLimit(2)
                        .padding(.leading, DS.Space.xl)
                        .accessibilityIdentifier("agent.loop.stopError")
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm)
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityActions {
                if loop.state == .expired {
                    Button(L("Dismiss")) { onDismissExpired(loop.taskID) }
                } else if !stopping {
                    if loop.state == .paused, onResume != nil, !resuming {
                        Button(L("Resume")) { resume() }
                    }
                    Button(L("Stop")) { stop() }
                }
                Button(L("Details")) { showDetails = true }
            }
        }
    }

    @ViewBuilder
    private func summary(now: Date) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text(DistillLoopPresentation.title(loop))
                .font(DS.Font.caption.weight(.semibold))
                .foregroundColor(DS.Palette.text)
                .lineLimit(1)
            switch loop.state {
            case .paused:
                Text(DistillLoopPresentation.pausedText(loop))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
                    .lineLimit(1)
            case .expired, .stopped:
                Text(DistillLoopPresentation.expiredText)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1)
            case .active:
                if let running = DistillLoopPresentation.runningText(loop) {
                    DSBusySpinner(label: running)
                    Text(running)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                } else if let next = DistillLoopPresentation.countdownText(nextFireAt: loop.nextFireAt, now: now) {
                    Text(next)
                        .font(DS.Font.caption.monospacedDigit())
                        .foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            if let runs = DistillLoopPresentation.runsText(loop) {
                Text(L("· %1$@", runs))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: DS.Space.md) {
            Button { showDetails.toggle() } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Details")
            .accessibilityLabel("Details")
            .accessibilityIdentifier("agent.loop.details")
            .popover(isPresented: $showDetails, arrowEdge: .top) { details }
            if loop.state == .expired {
                Button(L("Dismiss")) { onDismissExpired(loop.taskID) }
                    .buttonStyle(.plain)
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("agent.loop.dismiss")
            } else {
                if loop.state == .paused, onResume != nil {
                    Button { resume() } label: {
                        Text(resuming ? "Resuming…" : "Resume")
                            .font(DS.Font.caption.weight(.semibold))
                            .foregroundColor(resuming ? DS.Palette.textTertiary : DS.Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(resuming)
                    .accessibilityIdentifier("agent.loop.resume")
                }
                Button { stop() } label: {
                    Text(stopping ? "Stopping…" : "Stop")
                        .font(DS.Font.caption.weight(.semibold))
                        .foregroundColor(stopping ? DS.Palette.textTertiary : DS.Palette.danger)
                }
                .buttonStyle(.plain)
                .disabled(stopping)
                .accessibilityIdentifier("agent.loop.stop")
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(DistillLoopPresentation.title(loop))
                .font(DS.Font.body.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            Text(loop.prompt)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .textSelection(.enabled)
            if let last = loop.lastIteration {
                Divider()
                Text(L("Last iteration · %1$@", DistillLoopPresentation.iterationSummary(last)))
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.text)
                if let preview = last.outputPreview, !preview.isEmpty {
                    Text(preview)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(DS.Space.lg)
        .frame(minWidth: 240, idealWidth: 320, maxWidth: 320, alignment: .leading)
        .accessibilityIdentifier("agent.loop.detailsPopover")
    }

    private func stop() {
        guard !stopping else { return }
        stopping = true
        stopError = nil
        let id = loop.taskID
        Task { @MainActor in
            do {
                try await onStop(id)
            } catch {
                stopping = false
                stopError = "Couldn't stop loop: \(error.localizedDescription)"
            }
        }
    }

    private func resume() {
        guard !resuming, let onResume else { return }
        resuming = true
        resumeError = nil
        let id = loop.taskID
        Task { @MainActor in
            do {
                try await onResume(id)
            } catch {
                resumeError = "Couldn't resume loop: \(error.localizedDescription)"
            }
            resuming = false
        }
    }
}
