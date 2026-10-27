import CoreModel
import DesignSystemKit
import SwiftUI

/// Status shown on a Titio notice card: the open kind's label, or the
/// resolution's label once the host rewrote the block's `state`.
public enum AgentNoticeStatus {
    public enum Tone: Equatable, Sendable {
        case success, danger, warning, accent, neutral
    }

    public static func of(_ block: TitioNoticeBlock) -> (label: String, symbol: String, tone: Tone) {
        if block.isOpen {
            guard let kind = TitioNoticeKind(rawValue: block.kind) else { return update }
            return open(kind)
        }
        switch block.state {
        case "answered": return ("Answered", "bubble.left.fill", .neutral)
        case "approved": return ("Approved", "checkmark.circle.fill", .neutral)
        case "declined": return ("Declined", "xmark.circle.fill", .neutral)
        case "done": return ("Done", "checkmark.circle.fill", .neutral)
        case "elsewhere": return ("Handled elsewhere", "arrow.up.right.circle.fill", .neutral)
        case "expired": return ("Expired", "clock.fill", .neutral)
        case "acknowledged": return ("Seen", "eye.fill", .neutral)
        case "failed": return ("Didn't go through", "xmark.octagon.fill", .neutral)
        case "unknown_effect": return ("Unconfirmed", "questionmark.circle.fill", .neutral)
        default: return update
        }
    }

    private static let update = (label: "Update", symbol: "info.circle.fill", tone: Tone.neutral)

    private static func open(_ kind: TitioNoticeKind) -> (label: String, symbol: String, tone: Tone) {
        switch kind {
        case .runCompleted, .gitCompleted, .scriptCompleted, .transferCompleted:
            return ("Done", "checkmark.circle.fill", .success)
        case .runFailed, .scriptFailed, .gitFailed, .scheduledFailed, .transferFailed,
             .providerUpdateFailed, .serverListenerFailed:
            return ("Failed", "xmark.octagon.fill", .danger)
        case .runInterrupted:
            return ("Interrupted", "pause.circle.fill", .warning)
        case .botReply:
            return ("Replied", "bubble.left.fill", .accent)
        case .botBlocked:
            return ("Stuck", "exclamationmark.triangle.fill", .warning)
        case .approval:
            return ("Needs approval", "checkmark.shield.fill", .warning)
        case .userInput, .botQuestion:
            return ("Question", "questionmark.circle.fill", .accent)
        case .manualAction:
            return ("Action needed", "hand.raised.fill", .warning)
        case .sshDisconnected, .fileConflict, .notificationsDenied, .external:
            return update
        }
    }
}

extension AgentNoticeStatus.Tone {
    var color: Color {
        switch self {
        case .success: return DS.Palette.success
        case .danger: return DS.Palette.danger
        case .warning: return DS.Palette.warning
        case .accent: return DS.Palette.accent
        case .neutral: return DS.Palette.textSecondary
        }
    }
}

/// Titio inbox message that carries a `notice` block: status, provenance,
/// prose, open options and a reply field. Caller supplies the prose as `content`.
public struct AgentChatNoticeCard: View {
    public let messageID: String
    public let block: TitioNoticeBlock
    /// Options of the message's open `choices` block, if any.
    public let choices: BotChoicesBlock?
    public let createdAt: Date
    public let content: AnyView
    /// Relative-time anchor shared with the transcript, so cards do not tick on their own.
    public let now: Date?
    /// Observed only by the options and reply field, so typing in the composer
    /// does not re-render every card's prose.
    public let composerState: AgentComposerState
    /// The composer holds a draft or attachments: answering here would replace them.
    public let isBlockedByDraft: () -> Bool
    public let isSending: Bool
    public let onOption: (Int) -> Void
    /// Returns false when the reply failed; the text then stays in the field.
    public let onReply: (String) async -> Bool
    public let onClear: (() -> Void)?

    private static let collapsedHeight: CGFloat = 180

    @State private var replyText = ""
    @State private var expanded = false
    @State private var contentOverflows = false

    private var identifier: String { "agent.notice.\(messageID)" }
    private var status: (label: String, symbol: String, tone: AgentNoticeStatus.Tone) { AgentNoticeStatus.of(block) }
    private func canSend(blocked: Bool) -> Bool {
        block.isOpen && !blocked && !isSending
            && !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        messageID: String,
        block: TitioNoticeBlock,
        choices: BotChoicesBlock?,
        createdAt: Date,
        content: AnyView,
        now: Date? = nil,
        composerState: AgentComposerState,
        isBlockedByDraft: @escaping () -> Bool,
        isSending: Bool,
        onOption: @escaping (Int) -> Void,
        onReply: @escaping (String) async -> Bool,
        onClear: (() -> Void)?
    ) {
        self.messageID = messageID
        self.block = block
        self.choices = choices
        self.createdAt = createdAt
        self.content = content
        self.now = now
        self.composerState = composerState
        self.isBlockedByDraft = isBlockedByDraft
        self.isSending = isSending
        self.onOption = onOption
        self.onReply = onReply
        self.onClear = onClear
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            header
            if !block.source.isEmpty {
                AgentChoiceProvenanceRow(source: block.source, identifier: identifier)
            }
            content
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: NoticeContentHeightKey.self, value: proxy.size.height)
                    }
                )
                .frame(maxHeight: expanded ? nil : Self.collapsedHeight, alignment: .top)
                .clipped()
                .onPreferenceChange(NoticeContentHeightKey.self) { contentOverflows = $0 > Self.collapsedHeight }
                .opacity(block.isOpen ? 1 : 0.75)
            if contentOverflows {
                Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(DS.Font.captionStrong)
                    .foregroundColor(DS.Palette.accent)
                    .accessibilityIdentifier("\(identifier).expand")
            }
            if block.isOpen, let choices {
                NoticeDraftGate(composerState: composerState, isBlocked: isBlockedByDraft) { blocked in
                VStack(spacing: DS.Space.sm) {
                    ForEach(Array(choices.options.enumerated()), id: \.offset) { index, option in
                        AgentChoiceOptionRow(
                            index: index,
                            option: option,
                            isSelected: false,
                            multiple: false,
                            identifier: identifier
                        ) { onOption(index) }
                    }
                }
                .disabled(blocked)
                .opacity(blocked ? 0.5 : 1)
                }
            }
            if block.isOpen {
                NoticeDraftGate(composerState: composerState, isBlocked: isBlockedByDraft) { blocked in
                    replyField(blocked: blocked)
                }
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
        HStack(spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: status.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(status.tone.color)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(status.tone.color.opacity(0.16))
                    )
                    .accessibilityHidden(true)
                Text(status.label)
                    .font(DS.Font.captionStrong)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(identifier).status")
            Spacer(minLength: DS.Space.md)
            Text(AgentChatTranscriptChrome.relativeTimestamp(createdAt, now: now ?? Date()))
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
                .lineLimit(1)
                .fixedSize()
            if let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss notice")
                .accessibilityIdentifier("\(identifier).clear")
            }
        }
    }

    private func replyField(blocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.md) {
                TextField("Reply to Titio about this…", text: $replyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(DS.Palette.text)
                    .onSubmit { send(blocked: blocked) }
                    .disabled(blocked)
                    .accessibilityIdentifier("\(identifier).reply")
                Button { send(blocked: blocked) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(canSend(blocked: blocked) ? DS.Palette.accent : DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend(blocked: blocked))
                .accessibilityLabel("Send reply")
                .accessibilityIdentifier("\(identifier).send")
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .frame(minHeight: 40)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .stroke(DS.Palette.lineStrong, lineWidth: 1)
            )
            if blocked {
                Text(AgentChatChoicesCard.blockedByDraftMessage)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("\(identifier).blocked")
            }
        }
    }

    private func send(blocked: Bool) {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend(blocked: blocked) else { return }
        Task {
            if await onReply(text) { replyText = "" }
        }
    }
}

/// Re-renders only its content when the composer draft changes.
private struct NoticeDraftGate<Content: View>: View {
    @ObservedObject var composerState: AgentComposerState
    let isBlocked: () -> Bool
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(isBlocked()) }
}

private struct NoticeContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
