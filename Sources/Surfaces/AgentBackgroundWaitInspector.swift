import CoreModel
import DesignSystemKit
import SwiftUI

struct AgentBackgroundWaitInspector: View {
    @ObservedObject var vm: AgentAppViewModel
    let threadID: AgentThreadID
    @State private var isPresented = false

    var body: some View {
        Button(L("See task")) { isPresented = true }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("agent.backgroundAwait.seeTask")
            .popover(isPresented: $isPresented) {
                if threadID == vm.selectedThreadId, vm.incompleteTurnReason == .backgroundAwait {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        HStack {
                            Text(L("Background task details")).font(DS.Font.title3)
                            Spacer()
                            Button(L("Close")) { isPresented = false }.keyboardShortcut(.cancelAction)
                        }
                        Divider()
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                                if !vm.hidesToolActivity {
                                    let records = Self.recordedTasks(in: vm.timeline.turns.last)
                                    if let check = records.first(where: AgentTimelineItemPresentation.isTaskWaitTool(for:)) {
                                        let ids = Self.taskIDs(in: check)
                                        if !ids.isEmpty {
                                            Text(L("Last task check")).font(DS.Font.bodyStrong)
                                            Text(verbatim: ids.joined(separator: ", ")).font(DS.Font.monoSmall)
                                        }
                                    }
                                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                                        let active = vm.coordinator.reportedBackgroundTasks(threadId: threadID)
                                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                                            Text(L("Reported active in this conversation")).font(DS.Font.bodyStrong)
                                            if active.isEmpty {
                                                Text(L("No active task reported.")).foregroundStyle(DS.Palette.textSecondary)
                                            }
                                            ForEach(active.indices, id: \.self) { index in
                                                let task = active[index]
                                                if let description = task.description { Text(verbatim: description) }
                                                Text(verbatim: task.id).font(DS.Font.monoSmall)
                                            }
                                        }
                                    }
                                    if !records.isEmpty {
                                        Text(L("Recorded in the waiting turn")).font(DS.Font.bodyStrong)
                                        ForEach(records) { item in recordedTask(item) }
                                    }
                                }
                                let report = BackgroundAwaitContinuation.strippingAwaitingMarker(vm.latestFinalAssistantMessage ?? "")
                                if !report.isEmpty {
                                    Text(L("Agent’s last message")).font(DS.Font.bodyStrong)
                                    Text(verbatim: AgentAppView.cappedVisibleText(report, limit: 4000))
                                } else if vm.hidesToolActivity {
                                    Text(L("No task details recorded."))
                                }
                            }
                            .font(DS.Font.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(DS.Space.lg)
                    .frame(width: 440, height: 340)
                    .accessibilityIdentifier("agent.backgroundAwait.details")
                }
            }
    }

    /// A persisted report may outlive its timeline. Never borrow tool rows from a previous turn.
    static func recordedTasks(in turn: AssistantTurnSnapshot?) -> [AssistantItem] {
        guard let turn, IncompleteTurnContinuation.classify(turn.finalAssistantMessage) == .backgroundAwait else { return [] }
        return turn.items.reversed().filter { item in
            guard [.tool, .mcpToolCall, .dynamicToolCall, .commandExecution, .collabToolCall].contains(item.type) else { return false }
            if AgentTimelineItemPresentation.isBackgroundTool(for: item) || AgentTimelineItemPresentation.isTaskWaitTool(for: item) { return true }
            let input = AgentTimelineItemPresentation.toolInputObject(for: item)
            if item.summary == "monitor" { return true }
            if item.summary == "workflow", let source = input?["source"] as? [String: Any] {
                return input?["validate_only"] as? Bool != true && !["stop", "pause"].contains(source["type"] as? String ?? "")
            }
            let command = AgentTimelineItemPresentation.rawShellCommand(for: item)
                ?? (item.type == .commandExecution ? item.body : "")
            return !command.isEmpty && BackgroundAwaitContinuation.commandDetachesShellWork(command)
                || item.output?.hasPrefix("<task-id>") == true
        }
    }

    static func taskIDs(in item: AssistantItem) -> [String] {
        let input = AgentTimelineItemPresentation.toolInputObject(for: item)
        return (input?["task_ids"] as? [String]) ?? [input?["task_id"] as? String, input?["bash_id"] as? String].compactMap { $0 }
    }

    private func recordedTask(_ item: AssistantItem) -> some View {
        let input = AgentTimelineItemPresentation.toolInputObject(for: item)
        let ids = Self.taskIDs(in: item)
        let command = AgentTimelineItemPresentation.rawShellCommand(for: item) ?? (input == nil ? item.body : "")
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(verbatim: input?["description"] as? String ?? AgentTimelineItemPresentation.toolDisplayLabel(for: item)).font(DS.Font.captionStrong)
            if !ids.isEmpty { Text(verbatim: ids.joined(separator: ", ")) }
            else if item.summary == "Background shell" || item.summary == "Background agent" { Text(verbatim: item.id) }
            if !command.isEmpty { Text(verbatim: AgentAppView.cappedVisibleText(command, limit: AgentAppView.commandPreviewCharacterLimit)) }
            if let output = item.output, !output.isEmpty {
                Text(verbatim: AgentAppView.cappedVisibleTextTail(output, limit: AgentAppView.liveTurnOutputCharacterLimit))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .font(DS.Font.monoSmall)
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.control))
    }
}
