import Foundation
import CoreModel

public enum PetAttentionOutcome: Sendable, Equatable {
    case completed
    case failed
    case interrupted
}

public enum PetAttentionOperationOutcome: Sendable, Equatable {
    case succeeded
    case failed
}

public enum PetAttentionKind: Sendable, Equatable {
    case agentOutcome(PetAttentionOutcome)
    case agentRunning
    case approval
    case question(isSecret: Bool)
    case fileConflict
    case gitDelivery(PetAttentionOperationOutcome)
    case projectScript(PetAttentionOperationOutcome)
    case sshTransfer(PetAttentionOperationOutcome)
    case providerUpdateFailed
    case serverListenerFailed
}

public struct PetAttentionContext: Sendable, Equatable {
    public let workspaceName: String?
    public let providerName: String?
    /// Agent thread display title (user-visible label). Credentials are redacted.
    public let threadTitle: String?
    /// Fixed human label for approval/request kind (never raw command text).
    public let actionLabel: String?
    /// Preformatted elapsed label for in-flight runs (e.g. "2m").
    public let elapsedLabel: String?

    public init(
        workspaceName: String? = nil,
        providerName: String? = nil,
        threadTitle: String? = nil,
        actionLabel: String? = nil,
        elapsedLabel: String? = nil
    ) {
        self.workspaceName = workspaceName
        self.providerName = providerName
        self.threadTitle = threadTitle
        self.actionLabel = actionLabel
        self.elapsedLabel = elapsedLabel
    }
}

/// Raw provider/operation text may be supplied by integration code for diagnostics,
/// but is deliberately ignored by `PetAttentionPresentation.safe` (not used as primary title).
public struct PetAttentionRawContent: Sendable, Equatable {
    public let title: String?
    public let detail: String?

    public init(title: String? = nil, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

public struct PetAttentionPresentation: Sendable, Equatable {
    public let title: String
    public let detail: String?

    public init(title: String, detail: String?) {
        self.title = title
        self.detail = detail
    }

    /// Secondary line format: `workspace - provider - thread title - elapsed`
    /// (missing parts omitted).
    public static let detailSeparator = " - "

    public static func safe(
        kind: PetAttentionKind,
        context: PetAttentionContext = PetAttentionContext(),
        untrusted: PetAttentionRawContent? = nil
    ) -> PetAttentionPresentation {
        // Primary title stays fixed (outcome / action type only). Untrusted provider
        // prompts/commands never become the headline. Workspace, provider, thread
        // title, and elapsed appear only on the secondary line after credential
        // redaction + length caps.
        _ = untrusted

        let title: String
        switch kind {
        case .agentOutcome(.completed): title = L("Agent run completed")
        case .agentOutcome(.failed): title = L("Agent run failed")
        case .agentOutcome(.interrupted): title = L("Agent run interrupted")
        case .agentRunning: title = L("Agent run in progress")
        case .approval:
            if let action = PetAttentionRedactor.safeContextLabel(context.actionLabel) {
                title = L("Approve: %1$@", action)
            } else {
                title = L("Approval required")
            }
        case .question(isSecret: false): title = L("Input requested")
        case .question(isSecret: true): title = L("Secret input requested")
        case .fileConflict: title = L("File conflict needs review")
        case .gitDelivery(.succeeded): title = L("Git delivery completed")
        case .gitDelivery(.failed): title = L("Git delivery failed")
        case .projectScript(.succeeded): title = L("Project script completed")
        case .projectScript(.failed): title = L("Project script failed")
        case .sshTransfer(.succeeded): title = L("SSH transfer completed")
        case .sshTransfer(.failed): title = L("SSH transfer failed")
        case .providerUpdateFailed: title = L("Provider update failed")
        case .serverListenerFailed: title = L("Restore remote access")
        }

        let displayThreadTitle = Self.safeThreadTitle(context.threadTitle)
        let contextParts = [
            context.workspaceName,
            context.providerName,
            displayThreadTitle,
            context.elapsedLabel
        ].compactMap(PetAttentionRedactor.safeContextLabel)
        return PetAttentionPresentation(
            title: title,
            detail: contextParts.isEmpty ? nil : contextParts.joined(separator: detailSeparator)
        )
    }

    /// Truncates for row density and drops placeholder thread names.
    public static func safeThreadTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard !AgentThreadTitle.isPlaceholder(raw) else { return nil }
        return AgentThreadTitle.display(raw)
    }
}

public enum PetApprovalActionLabel {
    /// Fixed copy for pending-request kinds. Never returns command text or paths.
    public static func label(for kind: AssistantRequestKind) -> String {
        switch kind {
        case .commandExecution, .exec: return L("Run command")
        case .applyPatch: return L("Apply patch")
        case .fileChange: return L("Edit file")
        case .fileRead: return L("Read file")
        case .toolUserInput: return L("Tool input")
        case .authTokensRefresh: return L("Refresh auth")
        case .dynamic: return L("Tool")
        }
    }
}

public enum PetElapsedFormatter {
    /// Compact elapsed for always-on-top rows. Nil when start is in the future or invalid.
    public static func label(from startedAt: Date, now: Date = Date()) -> String? {
        let seconds = Int(now.timeIntervalSince(startedAt))
        guard seconds >= 0 else { return nil }
        if seconds < 60 { return "\(max(seconds, 0))s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        if hours < 48 {
            return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
        }
        let days = hours / 24
        return "\(days)d"
    }
}

public enum PetAttentionCountFormatter {
    public static func badgeText(count: Int, isEnabled: Bool = true) -> String? {
        guard isEnabled, count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    /// "1 needs you" / "3 need you" / "99+ need you" from a badge text.
    public static func needYouText(badgeText: String) -> String {
        badgeText == "1" ? L("1 needs you") : L("%1$@ need you", badgeText)
    }

    public static func accessibilityValue(count: Int) -> String {
        switch max(0, count) {
        case 0: return L("No items need attention")
        case 1: return L("1 item needs attention")
        case let count: return L("%1$@ items need attention", count)
        }
    }
}

/// Blue pet badge for in-flight agent threads. Always enabled when count > 0;
/// membership must come from the live active-run projection, not DB status.
public enum PetActiveThreadCountFormatter {
    public static func badgeText(count: Int) -> String? {
        PetAttentionCountFormatter.badgeText(count: count, isEnabled: true)
    }

    public static func accessibilityValue(count: Int) -> String {
        switch max(0, count) {
        case 0: return L("No active agent threads")
        case 1: return L("1 active agent thread")
        case let count: return L("%1$@ active agent threads", count)
        }
    }

    /// Sidebar/Active Threads count also includes busy terminals.
    public static func activeItemsAccessibilityValue(count: Int) -> String {
        switch max(0, count) {
        case 0: return L("Nothing running")
        case 1: return L("1 item running")
        case let count: return L("%1$@ items running", count)
        }
    }

    public static func combinedAccessibilityValue(activeCount: Int, attentionCount: Int) -> String {
        let active = accessibilityValue(count: activeCount)
        let attention = PetAttentionCountFormatter.accessibilityValue(count: attentionCount)
        if max(0, activeCount) == 0 { return attention }
        if max(0, attentionCount) == 0 { return active }
        return "\(active). \(attention)"
    }
}

public enum PetAttentionRedactor {
    public static let maximumContextCharacters = 80

    public static func safeContextLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.replacingOccurrences(
            of: #"(?i)\bbearer\s+[^\s,;]+"#,
            with: "Bearer [redacted]",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\b(password|passwd|(?:(?:access|refresh|id)[_-]?)?token|client[_-]?secret|secret|api[_-]?key|private[_-]?key|authorization|cookie)\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            with: "$1=[redacted]",
            options: .regularExpression
        )
        value = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(maximumContextCharacters))
    }
}
