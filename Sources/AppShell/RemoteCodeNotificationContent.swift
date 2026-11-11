import CoreModel
import Persistence
import Foundation
import UserNotifications

public struct RemoteCodeNotificationContent: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String
    public let categoryIdentifier: String
    public let threadIdentifier: String
    public let userInfo: [String: String]
    public let soundEnabled: Bool

    public static let threadUpdateCategoryIdentifier = "RemoteCodeThreadUpdate"
    public static let openActionIdentifier = "thread.open"
    /// Titio notices (hub spec §8, §9): Open action only.
    public static let titioNoticeCategoryIdentifier = "RemoteCodeTitioNotice"
    public static let titioQuestionCategoryIdentifier = "RemoteCodeTitioQuestion"
    /// Groups every Titio banner in Notification Center.
    public static let titioThreadIdentifier = "bot.titio"

    /// A Titio notice banner: title "Titio", body = the message's first line
    /// (markdown stripped), userInfo = the §8 push data map. `identifier` is
    /// the notice key (or `titio.digest.<messageId>`), so the relay and
    /// `SystemNotifier.postedIdentifiers` deduplicate a re-post.
    public static func titioNotice(
        identifier: String,
        body: String,
        userInfo: [String: String],
        soundEnabled: Bool = true,
        canReply: Bool = false
    ) -> RemoteCodeNotificationContent {
        RemoteCodeNotificationContent(
            identifier: identifier,
            title: TitioNoticeCopy.bannerTitle,
            body: TitioNoticeCopy.preview(body),
            categoryIdentifier: canReply ? titioQuestionCategoryIdentifier : titioNoticeCategoryIdentifier,
            threadIdentifier: titioThreadIdentifier,
            userInfo: userInfo,
            soundEnabled: soundEnabled
        )
    }

    /// The §8 push `data` / banner userInfo map for a Titio message.
    ///
    /// - `botId` is set only when `profileId` is known: an iOS bot route needs
    ///   `profileId` + `hostId`, and without them it would resolve to nil, so
    ///   iOS falls back to the legacy thread / Activity keys instead. The Mac
    ///   banner passes `includeBotIdWithoutProfile` so its own click still
    ///   opens the inbox.
    /// - The legacy keys (`threadId`, `workspaceId`, `runId`, `finalMessageId`,
    ///   `activityItemId`, `outcome`) keep old clients routing as today.
    public static func titioNoticeUserInfo(
        botID: String,
        conversationID: String,
        messageID: String,
        noticeKey: String?,
        identifier: String,
        profileID: String?,
        hostID: String?,
        legacy: [String: String] = [:],
        includeBotIdWithoutProfile: Bool = false,
        canReply: Bool = false
    ) -> [String: String] {
        var info: [String: String] = [:]
        for key in ["threadId", "workspaceId", "runId", "finalMessageId", "activityItemId", "outcome"] {
            if let value = legacy[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                info[key] = value
            }
        }
        info["category"] = canReply ? titioQuestionCategoryIdentifier : titioNoticeCategoryIdentifier
        let profile = profileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = hostID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !profile.isEmpty { info["profileId"] = profile }
        if !host.isEmpty { info["hostId"] = host }
        if !profile.isEmpty || includeBotIdWithoutProfile { info["botId"] = botID }
        info["attentionItemId"] = "titio.inbox.\(conversationID)"
        info["acknowledgeBotOnOpen"] = "false"
        info["conversationId"] = conversationID
        info["messageId"] = messageID
        if let noticeKey, !noticeKey.isEmpty { info["noticeKey"] = noticeKey }
        info["idempotencyKey"] = identifier
        return info
    }

    /// Agent App visible push policy (main agent only).
    ///
    /// - Subagent / nested orchestration workers never produce push banners.
    /// - Main agent banners only for terminal outcomes or user-action requests
    ///   (approval / question). Mid-run progress stays stream-only.
    public enum AgentAppPushPolicy: Sendable {
        /// Orchestration receipts with a parent are nested workers (subagents).
        public static func isNestedWorker(
            parentReceiptId: UUID?,
            nodeId: String?
        ) -> Bool {
            if parentReceiptId != nil { return true }
            guard let nodeId else { return false }
            let trimmed = nodeId.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != "root"
        }

        public static func allowsNotification(
            isAction: Bool,
            workspaceId: String?,
            settings: AppSettings
        ) -> Bool {
            if let workspaceId,
               settings.notificationMutedWorkspaceIDs.contains(where: {
                   (UUID(uuidString: $0)?.uuidString ?? $0) == (UUID(uuidString: workspaceId)?.uuidString ?? workspaceId)
               }) {
                return false
            }
            return isAction ? settings.notificationActionAlertsEnabled : settings.notificationCompletionAlertsEnabled
        }

        public static func shouldNotifyThreadOutcome(
            phase: AgentRunStatus,
            isNestedWorker: Bool
        ) -> Bool {
            guard !isNestedWorker else { return false }
            switch phase {
            case .completed, .failed, .interrupted, .cancelled:
                return true
            case .pending, .running:
                return false
            }
        }

        public static func shouldNotifyUserAction(isNestedWorker: Bool) -> Bool {
            !isNestedWorker
        }

        /// Remote terminal APNs banner when a Live Activity card can already
        /// show the outcome. Attention (approval/question) is never gated here.
        ///
        /// - Not armed → always deliver (no LA cover).
        /// - Armed + cancelled → still deliver: LA soft-maps cancel toward a
        ///   "ready" phase, so the explicit "Thread cancelled" banner is the
        ///   only clear stop signal.
        /// - Armed + completed/failed/interrupted → suppress (LA covers it).
        public static func shouldDeliverRemoteFinishAlert(
            phase: AgentRunStatus,
            liveActivityUpdateChannelArmed: Bool
        ) -> Bool {
            guard liveActivityUpdateChannelArmed else { return true }
            switch phase {
            case .cancelled:
                return true
            case .completed, .failed, .interrupted:
                return false
            case .pending, .running:
                return false
            }
        }

        /// Host-side armed check: a **current** activity_update courier (not
        /// push-to-start / legacy liveActivityToken). Legacy start tokens latch
        /// for the life of the install and would suppress finish banners forever
        /// even with no card on Lock Screen.
        public static func isLiveActivityUpdateChannelArmed(
            activityUpdateTokens: [String]
        ) -> Bool {
            activityUpdateTokens.contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    /// Pure helper: maps a run outcome to (title, body, identifier suffix, threadIdentifier).
    /// Extracted for testability without touching UNUserNotificationCenter.
    nonisolated static func outcomeNotificationParts(
        threadId: String,
        displayTitle: String,
        phase: AgentRunStatus
    ) -> (title: String, body: String, identifierSuffix: String, threadIdentifier: String)? {
        switch phase {
        case .completed:
            return (
                title: L("Thread finished"),
                body: L("Run response is ready."),
                identifierSuffix: "completed",
                threadIdentifier: threadId
            )
        case .failed, .interrupted:
            return (
                title: L("Thread failed"),
                body: L("Run ended with an error."),
                identifierSuffix: "failed",
                threadIdentifier: threadId
            )
        case .cancelled:
            return (
                title: L("Thread cancelled"),
                body: L("Run was stopped before finishing."),
                identifierSuffix: "cancelled",
                threadIdentifier: threadId
            )
        case .pending, .running:
            return nil
        }
    }

    public static func threadOutcome(
        threadId: String,
        runId: String = "",
        workspaceId: String? = nil,
        title: String?,
        phase: AgentRunStatus,
        isNestedWorker: Bool = false,
        finalMessageId: String? = nil
    ) -> RemoteCodeNotificationContent? {
        guard AgentAppPushPolicy.shouldNotifyThreadOutcome(
            phase: phase,
            isNestedWorker: isNestedWorker
        ) else { return nil }

        _ = title

        guard let parts = outcomeNotificationParts(
            threadId: threadId,
            displayTitle: L("Run"),
            phase: phase
        ) else { return nil }

        let outcome = parts.identifierSuffix
        // userInfo doubles as the remote-push `data` dictionary. The iOS tap
        // handler (AppRouter.routeIntent) reads workspaceId + threadId to open the
        // exact thread; `category` lets it pick the right notification actions.
        // Without workspaceId the tap can only fall back to the Activity tab.
        var userInfo: [String: String] = [
            "threadId": threadId,
            "outcome": outcome,
            "category": Self.threadUpdateCategoryIdentifier,
        ]
        if !runId.isEmpty { userInfo["runId"] = runId }
        if let finalMessageId, !finalMessageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userInfo["finalMessageId"] = finalMessageId
        }
        if let workspaceId, !workspaceId.trimmingCharacters(in: .whitespaces).isEmpty {
            userInfo["workspaceId"] = workspaceId
        }
        return RemoteCodeNotificationContent(
            identifier: runId.isEmpty ? "thread.\(threadId).\(outcome)" : "run.\(runId).\(outcome)",
            title: parts.title,
            body: parts.body,
            categoryIdentifier: Self.threadUpdateCategoryIdentifier,
            threadIdentifier: parts.threadIdentifier,
            userInfo: userInfo,
            soundEnabled: false
        )
    }

    /// Visible push when the main agent needs the user (approval / question).
    /// Never used for nested/subagent workers.
    public static func userActionNeeded(
        threadId: String,
        workspaceId: String? = nil,
        threadTitle: String?,
        actionTitle: String,
        requestId: String,
        isNestedWorker: Bool = false
    ) -> RemoteCodeNotificationContent? {
        guard AgentAppPushPolicy.shouldNotifyUserAction(isNestedWorker: isNestedWorker) else {
            return nil
        }
        _ = threadTitle
        _ = actionTitle
        let action = L("Action needed")
        var userInfo: [String: String] = [
            "threadId": threadId,
            "outcome": "attention",
            "requestId": requestId,
            "category": Self.threadUpdateCategoryIdentifier,
        ]
        if let workspaceId, !workspaceId.trimmingCharacters(in: .whitespaces).isEmpty {
            userInfo["workspaceId"] = workspaceId
        }
        return RemoteCodeNotificationContent(
            identifier: "thread.\(threadId).attention.\(requestId)",
            title: action,
            body: L("A run needs your attention."),
            categoryIdentifier: Self.threadUpdateCategoryIdentifier,
            threadIdentifier: threadId,
            userInfo: userInfo,
            soundEnabled: true
        )
    }

    public static func groupedOutcomes(_ contents: [RemoteCodeNotificationContent]) -> RemoteCodeNotificationContent? {
        guard let first = contents.first else { return nil }
        guard contents.count > 1 else { return first }
        var userInfo = first.userInfo
        userInfo.removeValue(forKey: "threadId")
        userInfo.removeValue(forKey: "runId")
        userInfo.removeValue(forKey: "finalMessageId")
        userInfo["activityDestination"] = "true"
        userInfo["outcome"] = "completed"
        userInfo["runIds"] = contents.compactMap { $0.userInfo["runId"] }.joined(separator: ",")
        return RemoteCodeNotificationContent(
            identifier: "workspace.\(first.userInfo["workspaceId"] ?? "none").runs.\(UUID().uuidString)",
            title: L("%1$@ runs completed", contents.count),
            body: L("Runs are ready in Activity."),
            categoryIdentifier: first.categoryIdentifier,
            threadIdentifier: first.threadIdentifier,
            userInfo: userInfo,
            soundEnabled: first.soundEnabled
        )
    }

    public func withSound(_ enabled: Bool) -> RemoteCodeNotificationContent {
        RemoteCodeNotificationContent(
            identifier: identifier,
            title: title,
            body: body,
            categoryIdentifier: categoryIdentifier,
            threadIdentifier: threadIdentifier,
            userInfo: userInfo,
            soundEnabled: enabled
        )
    }

    public func makeRequest() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = soundEnabled ? .default : nil
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = threadIdentifier
        content.userInfo = userInfo
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}
