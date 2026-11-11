import CoreModel
import SwiftUI
import DesignSystemKit
import SocketServer

@MainActor
final class BotContextExportModel: ObservableObject, Identifiable {
    struct Origin: Equatable {
        let hostID: String
        let botID: String
        let contextKey: String
        let contextVersion: Int
        let policyRevision: Int64
        let conversationID: String
        let hostLabel: String
        let botLabel: String
        let sourceLabel: String

        var parameters: [String: JSONValue] {
            [
                "host_id": .string(hostID),
                "bot_id": .string(botID),
                "context_key": .string(contextKey),
                "context_version": .number(Double(contextVersion)),
                "policy_revision": .number(Double(policyRevision)),
                "conversation_id": .string(conversationID)
            ]
        }
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let role: String
        let text: String
    }

    struct Target: Identifiable, Equatable {
        let key: String
        let revision: Int64
        let label: String
        var id: String { key }
    }

    struct Review: Equatable {
        let request: [String: JSONValue]
        let digest: String
        let summary: String
        let targetLabel: String
    }

    let origin: Origin
    let rows: [Row]
    let targets: [Target]
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var targetKey: String?
    @Published private(set) var review: Review?
    @Published private(set) var isBusy = false
    @Published private(set) var copied = false
    @Published private(set) var continuedConversationID: String?
    @Published private(set) var invalidated = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var unavailableMessage: String?

    private let request: (String, [String: JSONValue]) async throws -> JSONValue
    private let currentSource: () -> Bool
    private let copy: (String) -> Void
    private var generation: UInt64 = 0

    init(
        origin: Origin,
        rows: [Row],
        targets: [Target],
        request: @escaping (String, [String: JSONValue]) async throws -> JSONValue,
        currentSource: @escaping () -> Bool,
        copy: @escaping (String) -> Void
    ) {
        self.origin = origin
        self.rows = rows
        self.targets = targets
        self.request = request
        self.currentSource = currentSource
        self.copy = copy
        if targets.isEmpty {
            unavailableMessage = L("No active send destination is available for this Bot.")
        } else if rows.isEmpty {
            unavailableMessage = L("No saved user or assistant excerpts are available.")
        }
    }

    var selectionCount: Int { selectedIDs.count }
    var selectedTarget: Target? { targets.first { $0.key == targetKey } }
    var sourceIsCurrent: Bool { !invalidated && currentSource() }

    func toggle(_ row: Row) {
        guard !invalidated, !isBusy, review == nil, rows.contains(row) else { return }
        errorMessage = nil
        if selectedIDs.contains(row.id) {
            selectedIDs.remove(row.id)
        } else if selectedIDs.count < 32 {
            selectedIDs.insert(row.id)
        } else {
            errorMessage = L("Select no more than 32 excerpts.")
        }
    }

    func chooseTarget(_ key: String?) {
        guard !invalidated, !isBusy, review == nil else { return }
        targetKey = targets.first(where: { $0.key == key })?.key
        errorMessage = nil
    }

    func preview() {
        guard !isBusy, review == nil else { return }
        guard validateSource() else { return }
        guard (1...32).contains(selectedIDs.count), let target = selectedTarget else {
            errorMessage = selectedIDs.isEmpty || selectedIDs.count > 32
                ? L("Select between 1 and 32 excerpts.")
                : L("Choose a destination.")
            return
        }
        var params = origin.parameters
        params["target_context_key"] = .string(target.key)
        params["target_policy_revision"] = .number(Double(target.revision))
        params["message_ids"] = .array(rows.filter { selectedIDs.contains($0.id) }.map { .string($0.id) })
        run(method: "bot.conversation.export.preview", params: params) { [weak self] response, owner in
            guard let self, self.owns(owner), self.validateSource() else { return }
            guard let digest = response["selection_sha256"]?.stringValue,
                  digest.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil,
                  let summary = response["summary"]?.stringValue, !summary.isEmpty,
                  self.responseMatches(response, target: target),
                  self.responseMessageIDs(response) == params["message_ids"]?.arrayValue?.compactMap(\.stringValue) else {
                self.errorMessage = L("The export preview did not match the selected source and destination.")
                return
            }
            self.review = Review(request: params, digest: digest, summary: summary, targetLabel: target.label)
        }
    }

    func back() {
        guard !isBusy else { return }
        generation &+= 1
        review = nil
        copied = false
        continuedConversationID = nil
        errorMessage = nil
    }

    func confirmAndCopy() {
        guard !isBusy, !copied, let review, validateSource() else { return }
        var params = review.request
        params["approved"] = .bool(true)
        params["selection_sha256"] = .string(review.digest)
        run(method: "bot.conversation.export", params: params) { [weak self] response, owner in
            guard let self, self.owns(owner), self.validateSource() else { return }
            let target = self.targets.first { $0.key == review.request["target_context_key"]?.stringValue }
            guard let target,
                  self.responseMatches(response, target: target),
                  response["exported"]?.boolValue == true,
                  response["selection_sha256"]?.stringValue == review.digest,
                  response["summary"]?.stringValue == review.summary,
                  self.responseMessageIDs(response) == review.request["message_ids"]?.arrayValue?.compactMap(\.stringValue) else {
                self.review = nil
                self.errorMessage = L("Export was not confirmed. Nothing was copied.")
                return
            }
            self.copy(review.summary)
            self.copied = true
        }
    }

    /// Starts a new canonical conversation in the reviewed destination and holds the
    /// approved summary there as an unsent queued message. Nothing is executed.
    func continueInDestination() {
        guard !isBusy, copied, continuedConversationID == nil, let review, validateSource(),
              let target = targets.first(where: { $0.key == review.request["target_context_key"]?.stringValue }) else { return }
        let create: [String: JSONValue] = [
            "client_request_id": .string(UUID().uuidString.lowercased()),
            "host_id": origin.parameters["host_id"] ?? .string(origin.hostID),
            "bot_id": .string(origin.botID),
            "title": .string(L("Continued from %1$@", origin.sourceLabel)),
            "context_key": .string(target.key),
            "context_version": .number(Double(origin.contextVersion)),
            "policy_revision": .number(Double(target.revision)),
        ]
        run(method: "bot.conversation.create", params: create) { [weak self] response, owner in
            guard let self, self.owns(owner), self.validateSource() else { return }
            guard let readback = response["readback"]?.objectValue,
                  let conversationID = readback["conversation_id"]?.stringValue,
                  readback["context_key"] == .string(target.key),
                  readback["policy_revision"] == .number(Double(target.revision)) else {
                self.errorMessage = L("The destination conversation could not be confirmed. Nothing was queued.")
                return
            }
            var queue = create
            queue["client_request_id"] = .string(UUID().uuidString.lowercased())
            queue["conversation_id"] = .string(conversationID)
            queue["text"] = .string(review.summary)
            queue.removeValue(forKey: "title")
            self.run(method: "bot.conversation.enqueue", params: queue) { [weak self] response, owner in
                guard let self, self.owns(owner), self.validateSource() else { return }
                guard let readback = response["readback"]?.objectValue,
                      readback["enqueued"]?.boolValue == true,
                      readback["requires_user_send"]?.boolValue == true,
                      readback["conversation_id"] == .string(conversationID) else {
                    self.errorMessage = L("The approved summary was not queued in the destination.")
                    return
                }
                self.continuedConversationID = conversationID
            }
        }
    }

    func cancel() {
        invalidated = true
        generation &+= 1
        isBusy = false
        review = nil
        selectedIDs = []
        targetKey = nil
        errorMessage = nil
    }

    func invalidate() {
        invalidated = true
        generation &+= 1
        isBusy = false
        review = nil
        selectedIDs = []
        targetKey = nil
        errorMessage = L("The source conversation changed. Close this sheet and reopen export.")
    }

    private func validateSource() -> Bool {
        guard sourceIsCurrent else {
            invalidate()
            return false
        }
        return true
    }

    private func run(
        method: String,
        params: [String: JSONValue],
        completion: @escaping ([String: JSONValue], UInt64) -> Void
    ) {
        generation &+= 1
        let owner = generation
        isBusy = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.request(method, params)
                guard self.owns(owner) else { return }
                self.isBusy = false
                guard self.currentSource() else {
                    self.invalidate()
                    return
                }
                guard let object = response.objectValue else {
                    self.errorMessage = L("The export service returned an invalid response.")
                    return
                }
                completion(object, owner)
            } catch {
                guard self.owns(owner) else { return }
                self.isBusy = false
                if !self.currentSource() {
                    self.invalidate()
                } else {
                    self.review = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func owns(_ owner: UInt64) -> Bool { generation == owner }

    private func responseMessageIDs(_ response: [String: JSONValue]) -> [String]? {
        guard let rows = response["messages"]?.arrayValue else { return nil }
        let ids = rows.compactMap { $0.objectValue?["id"]?.stringValue }
        return ids.count == rows.count ? ids : nil
    }

    private func responseMatches(_ response: [String: JSONValue], target: Target) -> Bool {
        origin.parameters.allSatisfy { response[$0.key] == $0.value }
            && response["target_context_key"] == .string(target.key)
            && response["target_policy_revision"] == .number(Double(target.revision))
    }
}

struct BotContextExportSheet: View {
    @ObservedObject var model: BotContextExportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(L("Export selected excerpts"))
                .font(DS.Font.title2)
            metadata(L("Host"), model.origin.hostLabel)
            metadata(L("Bot"), model.origin.botLabel)
            metadata(L("Source"), model.origin.sourceLabel)
            if let unavailable = model.unavailableMessage {
                Text(unavailable).foregroundStyle(.secondary)
            } else if !model.sourceIsCurrent {
                Text(L("Source access is unavailable or has changed.")).foregroundStyle(.secondary)
            } else if let review = model.review {
                metadata(L("Destination"), review.targetLabel)
                ScrollView {
                    Text(review.summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.disabled)
                        .padding(DS.Space.sm)
                }
                .accessibilityLabel(L("Export preview"))
                HStack {
                    Button(L("Back")) { model.back() }
                    Spacer()
                    Button(L("Confirm and Copy")) { model.confirmAndCopy() }
                        .accessibilityIdentifier("bots.desk.export.confirmCopy")
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy || model.copied || !model.sourceIsCurrent)
                }
            } else {
                Picker(L("Destination"), selection: Binding(get: { model.targetKey ?? "" }, set: { model.chooseTarget($0.isEmpty ? nil : $0) })) {
                    Text(L("Choose a destination")).tag("")
                    ForEach(model.targets) { target in Text(target.label).tag(target.key) }
                }
                .accessibilityIdentifier("bots.desk.export.target")
                .disabled(model.isBusy)
                List(model.rows) { row in
                    Button {
                        model.toggle(row)
                    } label: {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            Text(row.role.capitalized).font(DS.Font.caption).foregroundStyle(.secondary)
                            Text(row.text).lineLimit(3).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.role): \(row.text)")
                    .accessibilityValue(model.selectedIDs.contains(row.id) ? L("Selected") : L("Not selected"))
                    .accessibilityIdentifier("bots.desk.export.message.\(row.id)")
                    .overlay(alignment: .trailing) {
                        if model.selectedIDs.contains(row.id) { Image(systemName: "checkmark.circle.fill") }
                    }
                }
                .disabled(model.isBusy)
                Text(L("%1$@ of 32 excerpts selected", model.selectionCount))
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(L("Preview")) { model.preview() }
                        .accessibilityIdentifier("bots.desk.export.preview")
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy || model.selectionCount == 0 || model.selectedTarget == nil || !model.sourceIsCurrent)
                }
            }
            if model.isBusy { ProgressView(L("Preparing export…")) }
            if let error = model.errorMessage { Text(error).foregroundStyle(DS.Palette.danger).accessibilityIdentifier("bots.desk.export.error") }
            if model.copied { Text(L("Copied.")).foregroundStyle(.secondary) }
            if model.copied, model.review != nil {
                if model.continuedConversationID != nil {
                    Text(L("Summary held in the destination. Review and send it there."))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("bots.desk.export.continued")
                } else {
                    Button(L("Continue in Destination")) { model.continueInDestination() }
                        .accessibilityIdentifier("bots.desk.export.continue")
                        .disabled(model.isBusy || !model.sourceIsCurrent)
                }
            }
            HStack {
                Spacer()
                Button(L("Close")) { model.cancel(); dismiss() }
                    .accessibilityIdentifier("bots.desk.export.close")
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DS.Space.lg)
        .frame(minWidth: 360, idealWidth: 520, minHeight: 420)
        .onChange(of: model.sourceIsCurrent) { _, current in
            if !current { model.invalidate() }
        }
        .accessibilityIdentifier("bots.desk.export.sheet")
        .onDisappear { model.cancel() }
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
            .font(DS.Font.body)
            .accessibilityElement(children: .combine)
    }
}
