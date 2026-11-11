import CoreModel
import DesignSystemKit
import SwiftUI

/// Ready-made answers under a reply: lettered options the user taps, plus
/// "Type your own answer". One component for every chat that shows a reply
/// with a `choices` block (`BotChoicesBlock`).
public struct AgentChatChoicesCard: View {
    public let choices: BotChoicesBlock
    public let identifier: String
    /// The composer holds a draft or attachments: answering here would
    /// replace them, so the card waits.
    public let isBlockedByDraft: Bool
    /// False for a Titio notice card: only the options the host stored can be
    /// acted on, so there is no "Type your own answer" field.
    public let allowsOwnAnswer: Bool
    public let onAnswer: (String) -> Void
    public let onDismiss: () -> Void

    public static let blockedByDraftMessage = L("Send or clear your draft to answer here.")

    @State private var selected: Set<Int> = []
    @State private var ownAnswer = ""
    @FocusState private var ownAnswerFocused: Bool

    public init(
        choices: BotChoicesBlock,
        identifier: String,
        isBlockedByDraft: Bool = false,
        allowsOwnAnswer: Bool = true,
        onAnswer: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.choices = choices
        self.identifier = identifier
        self.isBlockedByDraft = isBlockedByDraft
        self.allowsOwnAnswer = allowsOwnAnswer
        self.onAnswer = onAnswer
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if choices.notice != nil, !choices.source.isEmpty {
                AgentChoiceProvenanceRow(source: choices.source, identifier: identifier)
            }
            header
            VStack(spacing: DS.Space.sm) {
                ForEach(Array(choices.options.enumerated()), id: \.offset) { index, option in
                    AgentChoiceOptionRow(
                        index: index,
                        option: option,
                        isSelected: selected.contains(index),
                        multiple: choices.multiple,
                        identifier: identifier
                    ) { choose(index) }
                }
            }
            .disabled(isBlockedByDraft)
            .opacity(isBlockedByDraft ? 0.5 : 1)
            if isBlockedByDraft {
                Text(Self.blockedByDraftMessage)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("\(identifier).blocked")
            } else if allowsOwnAnswer {
                ownAnswerField
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if let question = choices.question {
                    Text(question)
                        .font(DS.Font.title3)
                        .foregroundColor(DS.Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let hint = choices.hint ?? (choices.multiple ? L("Pick one or more.") : nil) {
                    Text(hint)
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.md)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Dismiss"))
            .accessibilityLabel(L("Dismiss choices"))
            .accessibilityIdentifier("\(identifier).dismiss")
        }
    }

    private func choose(_ index: Int) {
        if choices.multiple {
            if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
        } else if let answer = choices.answer(selecting: [index]) {
            onAnswer(answer)
        }
    }

    private var ownAnswerField: some View {
        HStack(spacing: DS.Space.md) {
            TextField(L("Type your own answer"), text: $ownAnswer)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(DS.Palette.text)
                .focused($ownAnswerFocused)
                .onSubmit(sendOwnAnswer)
                .accessibilityIdentifier("\(identifier).own")
            if choices.multiple && ownAnswer.isEmpty {
                Button(L("Send")) {
                    if let answer = choices.answer(selecting: selected) { onAnswer(answer) }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("\(identifier).send")
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .frame(minHeight: 40)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .stroke(ownAnswerFocused ? DS.Palette.accent : DS.Palette.lineStrong, lineWidth: 1)
        )
        .animation(DS.Motion.micro, value: ownAnswerFocused)
    }

    private func sendOwnAnswer() {
        let text = ownAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ownAnswer = ""
        onAnswer(text)
    }
}

extension AgentChatChoicesCard {
    /// The reply whose choices still wait for an answer: the newest message,
    /// from the assistant, while nothing runs.
    public struct Pending: Equatable {
        public let messageID: String
        public let choices: BotChoicesBlock

        /// Never a notice card: a notice is answered by (message id, option
        /// index) through the host's notice stack. Drawn here, its label would
        /// be sent as chat text, which acts on nothing (a surface without the
        /// notice hook, such as a desk mounted before the inbox was known).
        public static func latest(in messages: [AgentMessage], isRunning: Bool) -> Pending? {
            guard !isRunning,
                  let last = messages.last(where: { $0.role != .system }),
                  last.role == .assistant,
                  let choices = BotChoicesBlock.parse(last.content).choices,
                  choices.notice == nil else { return nil }
            return Pending(messageID: last.id.value.uuidString.lowercased(), choices: choices)
        }

        /// Every assistant message whose choices carry a `notice` key, in
        /// chronological order, minus the dismissed ones (hub spec §7). A
        /// message keeps its card until the host resolves the notice and
        /// rewrites it without the block, so clients keep no decision state.
        public static func openNotices(in messages: [AgentMessage], dismissed: Set<String>) -> [Pending] {
            messages.compactMap { message in
                guard message.role == .assistant,
                      let choices = BotChoicesBlock.parse(message.content).choices,
                      choices.notice != nil else { return nil }
                let id = message.id.value.uuidString.lowercased()
                return dismissed.contains(id) ? nil : Pending(messageID: id, choices: choices)
            }
        }

    }

    /// Cards the user closed stay closed after RemoteCode reopens.
    public enum DismissedStore {
        static let key = "agent.choices.dismissed.v1"
        static let limit = 200

        public static func load(_ defaults: UserDefaults = .standard) -> Set<String> {
            Set(defaults.stringArray(forKey: key) ?? [])
        }

        public static func insert(_ messageID: String, _ defaults: UserDefaults = .standard) {
            var ids = defaults.stringArray(forKey: key) ?? []
            ids.removeAll { $0 == messageID }
            ids.append(messageID)
            defaults.set(Array(ids.suffix(limit)), forKey: key)
        }
    }
}

/// Workspace › Bot › conversation chips; wraps to a column when too narrow.
struct AgentChoiceProvenanceRow: View {
    let source: [String: String]
    let identifier: String

    private static let sources: [(key: String, name: String, symbol: String)] = [
        ("workspace", L("Workspace"), "folder"),
        ("bot", L("Bot"), "person.crop.circle"),
        ("conversation", L("Conversation"), "bubble.left.and.bubble.right"),
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.xs) { chips(separated: true) }
            VStack(alignment: .leading, spacing: DS.Space.xs) { chips(separated: false) }
        }
        .font(DS.Font.caption)
        .foregroundColor(DS.Palette.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(identifier).source")
    }

    @ViewBuilder
    private func chips(separated: Bool) -> some View {
        let present = Self.sources.filter { !(source[$0.key] ?? "").isEmpty }
        ForEach(Array(present.enumerated()), id: \.element.key) { index, item in
            if separated, index > 0 {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            sourceChip(name: item.name, symbol: item.symbol, value: source[item.key] ?? "")
        }
    }

    private func sourceChip(name: String, symbol: String, value: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Palette.textTertiary)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 3)
        .background(Capsule().fill(DS.Palette.surfaceRaised))
        .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        .accessibilityLabel("\(name): \(value)")
    }
}

/// One lettered option card: tap fires `action`; multiple choice shows check marks.
struct AgentChoiceOptionRow: View {
    let index: Int
    let option: String
    let isSelected: Bool
    let multiple: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.lg) {
                Text(BotChoicesBlock.letter(at: index))
                    .font(DS.Font.captionStrong)
                    .foregroundColor(isSelected ? DS.Palette.onAccent : DS.Palette.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(isSelected ? DS.Palette.accent : DS.Palette.surfaceOverlay)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .stroke(DS.Palette.lineStrong, lineWidth: isSelected ? 0 : DS.Border.hairline)
                    )
                Text(option)
                    .font(.system(size: 14))
                    .foregroundColor(DS.Palette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if multiple {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(isSelected ? DS.Palette.accent : DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(AgentChatChoiceRowStyle(isSelected: isSelected))
        .accessibilityLabel("\(BotChoicesBlock.letter(at: index)), \(option)")
        .accessibilityAddTraits(multiple && isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(identifier).option.\(index)")
    }
}

/// Hover wash and a quick press dip for one option row.
private struct AgentChatChoiceRowStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, isSelected: isSelected)
    }

    /// Each option is its own card: raised fill, hairline border that turns
    /// accent on hover or selection.
    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            configuration.label
                .background(
                    shape.fill(
                        configuration.isPressed ? DS.Palette.surfaceOverlay
                            : hovering ? DS.Palette.hover : DS.Palette.surfaceRaised
                    )
                )
                .overlay(
                    shape.strokeBorder(
                        isSelected || hovering ? DS.Palette.accent.opacity(isSelected ? 0.9 : 0.5) : DS.Palette.line,
                        lineWidth: isSelected ? 1 : DS.Border.hairline
                    )
                )
                .clipShape(shape)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}
