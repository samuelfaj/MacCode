import CoreModel
import DesignSystemKit
import SwiftUI

/// Thread header notice: other runs are editing files in this checkout. Opens the list of who and what.
public struct ConcurrentWorkNotice: View {
    let snapshot: ConcurrentWorkSnapshot
    let now: Date
    @Binding var isPresented: Bool

    public init(snapshot: ConcurrentWorkSnapshot, now: Date = Date(), isPresented: Binding<Bool>) {
        self.snapshot = snapshot
        self.now = now
        self._isPresented = isPresented
    }

    public static func title(runCount: Int) -> String {
        runCount == 1
            ? L("Also editing here: %1$@ run", runCount)
            : L("Also editing here: %1$@ runs", runCount)
    }

    public var body: some View {
        let title = Self.title(runCount: snapshot.runs.count)
        Button { isPresented.toggle() } label: {
            DSPill(title, tone: .warning)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsHoverFill()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(isPresented ? L("Expanded") : L("Collapsed"))
        .accessibilityIdentifier("agent.concurrentWork.notice")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { panel }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(L("Other runs editing this project"))
                .font(DS.Font.caption.weight(.semibold))
                .foregroundColor(DS.Palette.textSecondary)
            ForEach(snapshot.runs, id: \.runID) { run in
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(snapshot.label(for: run))
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let branch = run.branch {
                        Text(branch)
                            .font(DS.Font.caption2.monospaced())
                            .foregroundColor(DS.Palette.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    ForEach(Array(run.editingFiles.prefix(5)), id: \.path) { file in
                        Text(file.path)
                            .font(DS.Font.caption.monospaced())
                            .foregroundColor(DS.Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if run.editingFiles.count > 5 {
                        Text(L("… %1$@ more", run.editingFiles.count - 5))
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(DS.Space.lg)
        .frame(minWidth: 220, idealWidth: 320, maxWidth: 360, alignment: .leading)
        .accessibilityIdentifier("agent.concurrentWork.panel")
    }
}
