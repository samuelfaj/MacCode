import CoreModel
import DesignSystemKit
import Persistence
import SwiftUI

/// Settings for several agents working in one repository: what a file-lease conflict does and
/// what a new local run does when another run is already editing the same checkout.
struct ConcurrentWorkSettingsSection: View {
    @ObservedObject var vm: SettingsViewModel

    static func title(_ mode: FileLeaseMode) -> String {
        switch mode {
        case .warn: return L("Warn the agent and continue")
        case .block: return L("Block the edit")
        }
    }

    static func title(_ policy: LocalRunConflictPolicy) -> String {
        switch policy {
        case .warn: return L("Warn and run here")
        case .autoWorktree: return L("Run in a new worktree")
        case .ask: return L("Ask me")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG(L("Concurrent work"))
            choiceRow(
                label: L("When a file is being edited by another run"),
                detail: L("Another run holds the file. Warn lets the edit through and tells the agent; Block refuses it. A write over a file that changed outside the session is always refused."),
                picker: Picker("", selection: Binding(
                    get: { vm.appSettings.concurrentLeaseMode },
                    set: { vm.setConcurrentLeaseMode($0) }
                )) {
                    ForEach(FileLeaseMode.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                },
                identifier: "settings.concurrentWork.leaseMode.picker"
            )
            choiceRow(
                label: L("A new local run where another run is editing"),
                detail: L("Applies to the first message of a thread that runs in the project folder."),
                picker: Picker("", selection: Binding(
                    get: { vm.appSettings.localRunConflictPolicy },
                    set: { vm.setLocalRunConflictPolicy($0) }
                )) {
                    ForEach(LocalRunConflictPolicy.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                },
                identifier: "settings.concurrentWork.localRunPolicy.picker"
            )
        }
        .dsPanel(padding: DS.Space.lg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.concurrentWork")
    }

    private func choiceRow<P: View>(label: String, detail: String, picker: P, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(label).font(DS.Font.body).foregroundColor(DS.Palette.text)
                    Spacer(minLength: DS.Space.md)
                    control(picker, label: label, identifier: identifier)
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(label).font(DS.Font.body).foregroundColor(DS.Palette.text)
                    control(picker, label: label, identifier: identifier)
                }
            }
            Text(detail)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DS.Space.sm)
    }

    private func control<P: View>(_ picker: P, label: String, identifier: String) -> some View {
        picker
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}
