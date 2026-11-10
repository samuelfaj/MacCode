import Foundation
import SwiftUI
import CoreModel
import AgentRuntime
import DesignSystemKit

/// Incremental reader of a Distill child session's `updates.jsonl`, replayed
/// through the same ACP mapper as a live run so tool rows look identical.
final class DistillSubagentTranscriptReader: @unchecked Sendable {
    struct Batch: Sendable {
        var events: [AssistantEvent] = []
        var prompt = ""
        var found = false
    }

    let sessionId: String
    private let sessionsRoot: URL
    private let mapper: DistillACPEventMapper
    private var fileURL: URL?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var sawAgentOutput = false
    private var finished = false

    init(sessionId: String, distillHome: URL) {
        self.sessionId = sessionId
        self.sessionsRoot = distillHome.appendingPathComponent("sessions", isDirectory: true)
        self.mapper = DistillACPEventMapper(sessionId: sessionId)
    }

    static func defaultDistillHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["DISTILL_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".distill", isDirectory: true)
    }

    /// Sessions live under `sessions/<encoded cwd>/<session id>/`; the child's cwd is not known here.
    static func locate(sessionId: String, sessionsRoot: URL) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: sessionsRoot.path) else { return nil }
        for dir in dirs {
            let url = sessionsRoot.appendingPathComponent(dir, isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
                .appendingPathComponent("updates.jsonl")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Reads only bytes appended since the last call. Calls must not overlap.
    func read(finish: Bool) -> Batch {
        var batch = Batch()
        if fileURL == nil { fileURL = Self.locate(sessionId: sessionId, sessionsRoot: sessionsRoot) }
        guard let url = fileURL, let handle = try? FileHandle(forReadingFrom: url) else { return batch }
        defer { try? handle.close() }
        batch.found = true
        if batch.events.isEmpty, offset == 0 { batch.events += mapper.beginTurn() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        partial.append(data)
        if let newline = partial.lastIndex(of: 0x0A) {
            let complete = partial[partial.startIndex..<newline]
            partial = Data(partial[partial.index(after: newline)...])
            for line in complete.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let params = object["params"] as? [String: Any],
                      let update = params["update"] as? [String: Any],
                      let kind = update["sessionUpdate"] as? String else { continue }
                if kind == "user_message_chunk" {
                    if !sawAgentOutput,
                       let content = update["content"] as? [String: Any],
                       let text = content["text"] as? String {
                        batch.prompt += text
                    }
                    continue
                }
                sawAgentOutput = true
                batch.events += mapper.consumeSessionUpdate(update)
            }
        }
        if finish, !finished {
            finished = true
            batch.events += mapper.finishTurn(stopReason: "end_turn", usage: nil)
        }
        return batch
    }
}

@MainActor
final class DistillSubagentTranscriptModel: ObservableObject {
    @Published private(set) var timeline = AssistantTimelineState()
    @Published private(set) var prompt = ""
    @Published private(set) var loaded = false
    @Published private(set) var found = false
    private let reader: DistillSubagentTranscriptReader

    init(sessionId: String, distillHome: URL = DistillSubagentTranscriptReader.defaultDistillHome()) {
        reader = DistillSubagentTranscriptReader(sessionId: sessionId, distillHome: distillHome)
    }

    func poll(finish: Bool) async {
        let reader = reader
        let batch = await Task.detached(priority: .utility) { reader.read(finish: finish) }.value
        if !batch.events.isEmpty {
            var next = timeline
            for event in batch.events { next.apply(event) }
            timeline = next
        }
        if !batch.prompt.isEmpty { prompt += batch.prompt }
        found = found || batch.found
        loaded = true
    }
}

/// Side pane that shows what one Distill subagent is doing, refreshed while it runs.
struct DistillSubagentTranscriptPane: View {
    let item: SubagentActivityItem
    let onClose: () -> Void
    @StateObject private var model: DistillSubagentTranscriptModel
    @State private var promptExpanded = false

    init(item: SubagentActivityItem, onClose: @escaping () -> Void) {
        self.item = item
        self.onClose = onClose
        let sessionId = (item.runId?.value.uuidString ?? "").lowercased()
        _model = StateObject(wrappedValue: DistillSubagentTranscriptModel(sessionId: sessionId))
    }

    static func canOpen(_ item: SubagentActivityItem) -> Bool {
        item.provider == .distill && item.runId != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    if !model.prompt.isEmpty { promptBlock }
                    ForEach(model.timeline.turns, id: \.turnId) { turn in
                        AgentChatLiveTurnView(turn: turn, live: !turn.finished)
                    }
                    if model.loaded, !model.found {
                        Text(L("This subagent's session file is not on this Mac yet."))
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                            .accessibilityIdentifier("agent.subagentPane.missing")
                    } else if !model.loaded {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            Text(L("Read-only view of the subagent. The main agent collects its result."))
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .padding(DS.Space.md)
        }
        .background(DS.Palette.bg)
        .task(id: item.isActive) {
            while !Task.isCancelled {
                await model.poll(finish: !item.isActive)
                guard item.isActive else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        .accessibilityIdentifier("agent.subagentPane")
    }

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            SubagentCatAvatar(cat: item.cat, size: 40)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(item.cat.name)
                    .font(DS.Font.bodyStrong)
                    .lineLimit(1)
                    .help("\(item.cat.breed) · \(item.displayName) · \(item.id.uuidString)")
                HStack(spacing: DS.Space.xs) {
                    SubagentStatusPill(item: item)
                    Text(item.providerModelLabel ?? item.cat.breed)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.providerModelLabel ?? item.cat.breed)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .help("Close subagent view")
                .accessibilityLabel("Close subagent view")
                .accessibilityIdentifier("agent.subagentPane.close")
        }
        .padding(DS.Space.md)
        .dsBar(edge: .bottom)
    }

    private var promptBlock: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(L("Task"))
                .font(DS.Font.caption2.weight(.semibold))
                .foregroundColor(DS.Palette.textTertiary)
            Text(model.prompt)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .lineLimit(promptExpanded ? nil : 4)
                .textSelection(.enabled)
            Button(promptExpanded ? "Show less" : "Show full task") { promptExpanded.toggle() }
                .buttonStyle(.plain)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.accent)
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityIdentifier("agent.subagentPane.task")
    }
}

extension DistillSubagentTranscriptReader {
    /// What a child session's `summary.json` records: the model it actually ran, its effort,
    /// agent type and title. Used when no live `subagent_progress` reached this view
    /// (a reopened conversation, a Bot desk, Activity).
    static func summaryDetail(sessionId: String, distillHome: URL = defaultDistillHome()) -> DistillLiveStatus.SubagentDetail? {
        let root = distillHome.appendingPathComponent("sessions", isDirectory: true)
        guard let updates = locate(sessionId: sessionId, sessionsRoot: root),
              let data = try? Data(contentsOf: updates.deletingLastPathComponent().appendingPathComponent("summary.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            (json[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        return DistillLiveStatus.SubagentDetail(
            type: string("agent_name") ?? "",
            description: string("generated_title") ?? string("session_summary") ?? "",
            model: string("current_model_id"),
            effort: string("reasoning_effort"),
            tokensUsed: 0,
            durationMs: 0,
            activity: nil
        )
    }
}
