import Foundation
import CoreModel
import Persistence

public final class PetAttentionStore {
    private let threadRepository: AgentThreadRepository
    private let callbackRepository: ProviderPendingCallbackRepository
    private let notificationRepository: NotificationRepository
    private let markAgentThreadReadMutation: (AgentThreadID) throws -> Void
    private let markNotificationReadMutation: (String) throws -> Void
    private let workspaceNameProvider: (WorkspaceID) -> String?
    private let destLookup: (() throws -> PetDestAttentionSnapshot)?
    private let markBotConversationViewed: ((BotConversationID) throws -> Void)?
    private let acknowledgeBotAttention: ((BotAttentionItemID) throws -> Void)?
    // PERF: approvalActionLabel allocated JSONDecoder per approval callback
    // during refresh. Store usage is sequential; one instance decoder avoids
    // per-item codec construction (kind-only decode unchanged).
    private let pendingRequestDecoder = JSONDecoder()

    public init(
        threadRepository: AgentThreadRepository,
        callbackRepository: ProviderPendingCallbackRepository,
        notificationRepository: NotificationRepository,
        markAgentThreadRead: ((AgentThreadID) throws -> Void)? = nil,
        markNotificationRead: ((String) throws -> Void)? = nil,
        workspaceNameProvider: ((WorkspaceID) -> String?)? = nil,
        destLookup: (() throws -> PetDestAttentionSnapshot)? = nil,
        markBotConversationViewed: ((BotConversationID) throws -> Void)? = nil,
        acknowledgeBotAttention: ((BotAttentionItemID) throws -> Void)? = nil
    ) {
        self.threadRepository = threadRepository
        self.callbackRepository = callbackRepository
        self.notificationRepository = notificationRepository
        self.markAgentThreadReadMutation = markAgentThreadRead ?? { threadID in
            guard var thread = try threadRepository.get(id: threadID) else { return }
            thread.hasUnread = false
            try threadRepository.upsert(thread)
        }
        self.markNotificationReadMutation = markNotificationRead ?? { id in
            try notificationRepository.markRead(id: id)
        }
        self.workspaceNameProvider = workspaceNameProvider ?? { _ in nil }
        self.destLookup = destLookup
        self.markBotConversationViewed = markBotConversationViewed
        self.acknowledgeBotAttention = acknowledgeBotAttention
    }

    public func refresh(filter: PetAttentionFilter = .all) throws -> PetAttentionSnapshot {
        let threads = try threadRepository.list()
        let threadsByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let callbacks = try callbackRepository.list(states: [.pending, .stale])
        let blockedThreadIDs = Set(callbacks.map(\.threadId))

        let dest = try destLookup?()
        let destLinkedThreadIDs = dest?.linkedThreadIDs ?? []
        let callbackItems = callbacks.compactMap { callback -> PetAttentionItem? in
            if destLinkedThreadIDs.contains(callback.threadId) { return nil }
            return callbackItem(callback, thread: threadsByID[callback.threadId])
        }
        let threadItems = threads
            .filter {
                $0.hasUnread
                    && !blockedThreadIDs.contains($0.id)
                    && !destLinkedThreadIDs.contains($0.id)
            }
            .compactMap(threadItem)
        let notificationItems = try notificationRepository.list(unreadOnly: true)
            .compactMap(notificationItem)
        let destItems = dest.map(Self.projectDest) ?? []

        let allItems = (callbackItems + threadItems + notificationItems + destItems)
            .sorted(by: Self.attentionOrder)
        let filtered: [PetAttentionItem]
        switch filter {
        case .all:
            filtered = allItems
        case .completed:
            filtered = allItems.filter { $0.classification == .completed }
        case .needsYou:
            filtered = allItems.filter { $0.classification == .needsYou }
        }
        return PetAttentionSnapshot(items: filtered)
    }

    /// Opens the stored route first and mutates persistence only after the caller
    /// confirms that the exact destination is visible. Provider callbacks remain
    /// blockers until their normal approval/question response resolves them.
    public func openAndMarkRead(
        itemID: String,
        verifyRoute: (PetAttentionItem) throws -> Bool
    ) throws -> PetAttentionMarkResult {
        guard let item = try refresh().items.first(where: { $0.id == itemID }) else {
            return .notFound
        }
        guard try verifyRoute(item) else { return .routeRejected }

        switch item.source {
        case .callback:
            return .retainedBlocker
        case .agentThread(let threadID):
            guard !item.kind.needsUserAction else { return .retainedBlocker }
            guard let thread = try threadRepository.get(id: threadID) else { return .notFound }
            guard thread.status != .failed && thread.status != .interrupted else { return .retainedBlocker }
            try markAgentThreadReadMutation(threadID)
            return .marked
        case .notification(let id):
            guard !item.kind.needsUserAction else { return .retainedBlocker }
            try markNotificationReadMutation(id)
            return .marked
        case .bot(_, let conversationID, let attentionItemID):
            guard item.classification != .needsYou else { return .retainedBlocker }
            if let conversationID {
                try markBotConversationViewed?(conversationID)
            }
            if let attentionItemID {
                try acknowledgeBotAttention?(attentionItemID)
            }
            return .marked
        }
    }

    /// Clears every projected row. Stale provider callbacks are acknowledged; a live
    /// (pending) provider callback is never resolved here.
    @discardableResult
    public func markAllRead() throws -> Int {
        var marked = 0
        for thread in try threadRepository.list()
            where thread.hasUnread && Self.outcome(for: thread.status) != nil {
            try markAgentThreadReadMutation(thread.id)
            marked += 1
        }
        for notification in try notificationRepository.list(unreadOnly: true)
            where notificationItem(notification)?.kind.isBulkViewable == true {
            try markNotificationReadMutation(notification.id)
            marked += 1
        }
        if let dest = try destLookup?() {
            for item in Self.projectDest(dest) {
                if case .bot(_, let conversationID, let attentionItemID) = item.source {
                    if let conversationID {
                        try markBotConversationViewed?(conversationID)
                    }
                    if let attentionItemID {
                        try acknowledgeBotAttention?(attentionItemID)
                    }
                    marked += 1
                }
            }
        }
        for callback in try callbackRepository.list(states: [.stale]) {
            try callbackRepository.resolve(
                threadId: callback.threadId,
                requestId: callback.requestId,
                kind: callback.kind,
                state: .acknowledged
            )
            marked += 1
        }
        return marked
    }

    private func workspaceName(for workspaceID: WorkspaceID?) -> String? {
        workspaceID.flatMap(workspaceNameProvider)
    }

    private func attentionContext(
        for thread: AgentThread?,
        actionLabel: String? = nil
    ) -> PetAttentionContext {
        guard let thread else {
            return PetAttentionContext(actionLabel: actionLabel)
        }
        return PetAttentionContext(
            workspaceName: workspaceName(for: thread.workspaceId),
            providerName: Self.providerLabel(thread.provider),
            threadTitle: thread.title,
            actionLabel: actionLabel
        )
    }

    private func callbackItem(
        _ callback: ProviderPendingCallback,
        thread: AgentThread?
    ) -> PetAttentionItem {
        let kind: PetAttentionCallbackKind = callback.kind == .approval ? .approval : .question
        let isStale = callback.state == .stale
        let actionLabel = kind == .approval ? approvalActionLabel(from: callback) : nil
        let context = attentionContext(for: thread, actionLabel: actionLabel)
        let presentation = PetAttentionPresentation.safe(
            kind: kind == .approval ? .approval : .question(isSecret: false),
            context: context
        )
        let title: String
        if isStale {
            if kind == .approval, let action = actionLabel {
                title = L("Approval expired: %1$@", action)
            } else {
                title = kind == .approval ? L("Approval expired") : L("Input request expired")
            }
        } else {
            title = presentation.title
        }
        return PetAttentionItem(
            id: "callback:\(callback.threadId.value.uuidString):\(kind.rawValue):\(callback.requestId)",
            kind: .callback(kind, isStale: isStale),
            title: title,
            detail: presentation.detail,
            workspaceName: context.workspaceName,
            createdAt: callback.createdAt,
            route: .agentThread(threadID: callback.threadId, workspaceID: thread?.workspaceId),
            source: .callback(
                threadID: callback.threadId,
                requestID: callback.requestId,
                kind: kind
            )
        )
    }

    private func threadItem(_ thread: AgentThread) -> PetAttentionItem? {
        guard let outcome = Self.outcome(for: thread.status) else { return nil }
        let context = attentionContext(for: thread)
        let presentation = PetAttentionPresentation.safe(
            kind: .agentOutcome(outcome),
            context: context
        )
        return PetAttentionItem(
            id: "thread:\(thread.id.value.uuidString)",
            kind: .agentOutcome(outcome),
            title: presentation.title,
            detail: presentation.detail,
            workspaceName: context.workspaceName,
            createdAt: thread.updatedAt,
            route: .agentThread(threadID: thread.id, workspaceID: thread.workspaceId),
            source: .agentThread(threadID: thread.id)
        )
    }

    private func notificationItem(_ notification: AppNotification) -> PetAttentionItem? {
        guard let rawCategory = notification.category,
              let category = PetNotificationCategory(rawValue: rawCategory),
              let route = Self.notificationRoute(notification) else { return nil }
        let presentation = category.presentation
        return PetAttentionItem(
            id: "notification:\(notification.id)",
            kind: .notification(category),
            title: presentation.title,
            detail: presentation.detail,
            workspaceName: workspaceName(for: notification.workspaceId),
            createdAt: notification.createdAt,
            route: route,
            source: .notification(id: notification.id)
        )
    }

    internal static func notificationRoute(_ notification: AppNotification) -> PetAttentionRoute? {
        guard let rawCategory = notification.category,
              let category = PetNotificationCategory(rawValue: rawCategory) else { return nil }
        let route: PetAttentionRoute
        switch category {
        case .providerUpdateFailed:
            route = .settings(.providers)
        case .serverListenerFailed, .notificationsDenied:
            route = .settings(.general)
        case .agentAttention:
            if let surfaceID = notification.surfaceId {
                route = .surface(surfaceID: surfaceID, workspaceID: notification.workspaceId)
            } else if let workspaceID = notification.workspaceId {
                route = .workspace(workspaceID: workspaceID)
            } else {
                return nil
            }
        case .gitCompleted, .gitFailed:
            if let surfaceID = notification.surfaceId {
                route = .surface(surfaceID: surfaceID, workspaceID: notification.workspaceId)
            } else if let workspaceID = notification.workspaceId {
                route = .workspace(workspaceID: workspaceID)
            } else {
                return nil
            }
        case .projectScriptCompleted, .projectScriptFailed,
             .sshTransferCompleted, .sshTransferFailed, .sshUnexpectedDisconnect,
             .fileConflict:
            guard let surfaceID = notification.surfaceId else { return nil }
            route = .surface(surfaceID: surfaceID, workspaceID: notification.workspaceId)
        }
        return route
    }

    /// Decodes structured pending-request kind only; never surfaces title/detail payloads.
    private func approvalActionLabel(from callback: ProviderPendingCallback) -> String? {
        guard callback.kind == .approval,
              let data = callback.payloadJSON.data(using: .utf8),
              let request = try? pendingRequestDecoder.decode(
                  AssistantPendingRequest.self,
                  from: data
              )
        else { return nil }
        return PetApprovalActionLabel.label(for: request.kind)
    }

    private static func outcome(for status: AgentRunStatus) -> PetAttentionOutcome? {
        switch status {
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled, .interrupted:
            return .interrupted
        case .pending, .running:
            return nil
        }
    }

    private static func attentionOrder(_ lhs: PetAttentionItem, _ rhs: PetAttentionItem) -> Bool {
        if lhs.classification != rhs.classification {
            return lhs.classification == .needsYou
        }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }

    static func projectDest(_ dest: PetDestAttentionSnapshot) -> [PetAttentionItem] {
        var enabled = Set<BotID>()
        enabled.reserveCapacity(dest.bots.count)
        var botsByID: [BotID: BotDefinition] = [:]
        botsByID.reserveCapacity(dest.bots.count)
        for bot in dest.bots {
            botsByID[bot.id] = bot
            if bot.notificationsEnabled { enabled.insert(bot.id) }
        }
        var items: [PetAttentionItem] = []
        var coveredConversations = Set<BotConversationID>()
        var botsWithUnscopedAttention = Set<BotID>()

        for row in dest.attention where row.acknowledgedAt == nil && enabled.contains(row.botID) {
            // Dest `.unread` only duplicates conversation unreadActivity.
            guard row.kind != .unread else { continue }
            let kinds = destPetKinds(for: row.kind)
            let bot = botsByID[row.botID]
            let presentation = PetAttentionPresentation.safe(
                kind: kinds.presentation,
                context: PetAttentionContext(
                    workspaceName: L("Bots"),
                    threadTitle: bot?.name
                )
            )
            items.append(
                PetAttentionItem(
                    id: "bot.attention:\(row.id.value.uuidString)",
                    kind: kinds.item,
                    title: row.kind.activityTitle,
                    detail: presentation.detail,
                    workspaceName: L("Bots"),
                    createdAt: row.createdAt,
                    route: .botsDesk(botID: row.botID),
                    source: .bot(
                        botID: row.botID,
                        conversationID: row.conversationID,
                        attentionItemID: row.id
                    )
                )
            )
            if let conversationID = row.conversationID {
                coveredConversations.insert(conversationID)
            } else {
                // P1 dest keeps one conversation per bot. An unscoped inbox
                // row is that dest event — do not also project conversation state.
                botsWithUnscopedAttention.insert(row.botID)
            }
        }

        for conversation in dest.conversations {
            guard enabled.contains(conversation.botID) else { continue }
            if dest.excludedConversationIDs.contains(conversation.id) { continue }
            if coveredConversations.contains(conversation.id) { continue }
            if botsWithUnscopedAttention.contains(conversation.botID) { continue }
            let bot = botsByID[conversation.botID]
            switch conversation.attentionState {
            case .unreadActivity:
                let presentation = PetAttentionPresentation.safe(
                    kind: .agentOutcome(.completed),
                    context: PetAttentionContext(
                        workspaceName: L("Bots"),
                        threadTitle: bot?.name
                    )
                )
                items.append(
                    PetAttentionItem(
                        id: "bot.conversation:\(conversation.id.value.uuidString)",
                        kind: .agentOutcome(.completed),
                        title: presentation.title,
                        detail: presentation.detail,
                        workspaceName: L("Bots"),
                        createdAt: conversation.updatedAt,
                        route: .botsDesk(botID: conversation.botID),
                        source: .bot(
                            botID: conversation.botID,
                            conversationID: conversation.id,
                            attentionItemID: nil
                        )
                    )
                )
            case .needsAttention:
                let presentation = PetAttentionPresentation.safe(
                    kind: .question(isSecret: false),
                    context: PetAttentionContext(
                        workspaceName: L("Bots"),
                        threadTitle: bot?.name
                    )
                )
                items.append(
                    PetAttentionItem(
                        id: "bot.conversation:\(conversation.id.value.uuidString)",
                        kind: .callback(.question, isStale: false),
                        title: presentation.title,
                        detail: presentation.detail,
                        workspaceName: L("Bots"),
                        createdAt: conversation.updatedAt,
                        route: .botsDesk(botID: conversation.botID),
                        source: .bot(
                            botID: conversation.botID,
                            conversationID: conversation.id,
                            attentionItemID: nil
                        )
                    )
                )
            case .none, .working:
                continue
            }
        }
        return items
    }

    /// Dest inbox kinds that still need a decision stay pet blockers.
    /// Failed dest turns are outcomes (same as Agent App failed runs) so
    /// Mark all viewed can dismiss them without answering a question.
    static func destPetKinds(for destKind: BotAttentionItemKind) -> (
        item: PetAttentionItemKind,
        presentation: PetAttentionKind
    ) {
        switch destKind {
        case .approval:
            return (.callback(.approval, isStale: false), .approval)
        case .question, .handoff:
            return (.callback(.question, isStale: false), .question(isSecret: false))
        case .blocked, .unknownEffect:
            return (.agentOutcome(.failed), .agentOutcome(.failed))
        case .unread:
            return (.agentOutcome(.completed), .agentOutcome(.completed))
        }
    }

    private static func providerLabel(_ provider: AgentProvider) -> String {
        switch provider {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .distill: return "Distill"
        }
    }
}
