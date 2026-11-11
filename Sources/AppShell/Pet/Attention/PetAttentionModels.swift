import Foundation
import CoreModel

public enum PetAttentionFilter: Sendable, Equatable {
    case all
    case completed
    case needsYou
}

public enum PetAttentionClassification: Sendable, Equatable {
    case completed
    case needsYou
}

public enum PetAttentionCallbackKind: String, Sendable, Equatable {
    case approval
    case question
}

public enum PetNotificationCategory: String, CaseIterable, Sendable, Equatable {
    case gitCompleted = "pet.git.completed"
    case gitFailed = "pet.git.failed"
    case projectScriptCompleted = "pet.project-script.completed"
    case projectScriptFailed = "pet.project-script.failed"
    case sshTransferCompleted = "pet.ssh-transfer.completed"
    case sshTransferFailed = "pet.ssh-transfer.failed"
    case sshUnexpectedDisconnect = "pet.ssh-session.unexpected-disconnect"
    case providerUpdateFailed = "pet.provider-update.failed"
    case fileConflict = "pet.file.conflict"
    case serverListenerFailed = "pet.server-listener.failed"
    case notificationsDenied = "pet.notifications.denied"
    case agentAttention = "agent_attention"

    var classification: PetAttentionClassification {
        switch self {
        case .sshUnexpectedDisconnect, .fileConflict, .serverListenerFailed, .agentAttention: return .needsYou
        default: return .completed
        }
    }

    var presentation: PetAttentionPresentation {
        switch self {
        case .gitCompleted:
            return .safe(kind: .gitDelivery(.succeeded))
        case .gitFailed:
            return .safe(kind: .gitDelivery(.failed))
        case .projectScriptCompleted:
            return .safe(kind: .projectScript(.succeeded))
        case .projectScriptFailed:
            return .safe(kind: .projectScript(.failed))
        case .sshTransferCompleted:
            return .safe(kind: .sshTransfer(.succeeded))
        case .sshTransferFailed:
            return .safe(kind: .sshTransfer(.failed))
        case .sshUnexpectedDisconnect:
            return PetAttentionPresentation(title: L("Reconnect SSH"), detail: L("The connection ended unexpectedly. Reconnect or dismiss this alert."))
        case .providerUpdateFailed:
            return .safe(kind: .providerUpdateFailed)
        case .fileConflict:
            return .safe(kind: .fileConflict)
        case .serverListenerFailed:
            return PetAttentionPresentation(title: L("Restore remote access"), detail: L("Open Settings to check the listener, or dismiss this alert."))
        case .notificationsDenied:
            return PetAttentionPresentation(
                title: L("Notifications are turned off"),
                detail: L("You can enable notifications in System Settings. Your runs can continue without them.")
            )
        case .agentAttention:
            return PetAttentionPresentation(title: L("Agent input requested"), detail: nil)
        }
    }
}

public enum PetSettingsRoute: Sendable, Equatable {
    case general
    case providers
    case accounts
}

public enum PetAttentionItemKind: Sendable, Equatable {
    case callback(PetAttentionCallbackKind, isStale: Bool)
    case agentOutcome(PetAttentionOutcome)
    case notification(PetNotificationCategory)

    public var needsUserAction: Bool {
        switch self {
        case .callback(_, let isStale):
            return !isStale
        case .agentOutcome:
            return false
        case .notification(let category):
            return category.classification == .needsYou
        }
    }

    /// Legacy bulk-viewability predicate; no Pet UI control exposes it.
    public var isBulkViewable: Bool {
        switch self {
        case .callback(_, let isStale): return isStale
        case .agentOutcome, .notification: return true
        }
    }
}

public enum PetAttentionRoute: Sendable, Equatable {
    case agentThread(threadID: AgentThreadID, workspaceID: WorkspaceID?)
    case surface(surfaceID: SurfaceID, workspaceID: WorkspaceID?)
    case workspace(workspaceID: WorkspaceID)
    case settings(PetSettingsRoute)
    case botsDesk(botID: BotID)
}

public enum PetAttentionSource: Sendable, Equatable {
    case callback(threadID: AgentThreadID, requestID: String, kind: PetAttentionCallbackKind)
    case agentThread(threadID: AgentThreadID)
    case notification(id: String)
    case bot(botID: BotID, conversationID: BotConversationID?, attentionItemID: BotAttentionItemID?)
}

public struct PetAttentionItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: PetAttentionItemKind
    public let title: String
    public let detail: String?
    public let workspaceName: String?
    public let createdAt: Date
    public let route: PetAttentionRoute
    public let source: PetAttentionSource

    public init(
        id: String,
        kind: PetAttentionItemKind,
        title: String,
        detail: String?,
        workspaceName: String? = nil,
        createdAt: Date,
        route: PetAttentionRoute,
        source: PetAttentionSource
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.workspaceName = workspaceName
        self.createdAt = createdAt
        self.route = route
        self.source = source
    }

    public var classification: PetAttentionClassification {
        if case .bot = source {
            switch kind {
            case .agentOutcome(.failed), .agentOutcome(.interrupted):
                return .needsYou
            default:
                break
            }
        }
        return kind.needsUserAction ? .needsYou : .completed
    }
}

public struct PetDestAttentionSnapshot: Sendable, Equatable {
    public let bots: [BotDefinition]
    public let conversations: [BotConversation]
    public let attention: [BotAttentionItem]
    public let linkedThreadIDs: Set<AgentThreadID>
    /// Conversations the pet never counts: Titio's Notifications inbox. Its
    /// notices already reach the pet (speech bubble) and the counts would
    /// otherwise show every notice twice (hub spec §8 "Read state").
    public let excludedConversationIDs: Set<BotConversationID>

    public init(
        bots: [BotDefinition],
        conversations: [BotConversation],
        attention: [BotAttentionItem],
        linkedThreadIDs: Set<AgentThreadID> = [],
        excludedConversationIDs: Set<BotConversationID> = []
    ) {
        self.bots = bots
        self.conversations = conversations
        self.attention = attention
        self.linkedThreadIDs = linkedThreadIDs
        self.excludedConversationIDs = excludedConversationIDs
    }
}

public struct PetAttentionSnapshot: Sendable, Equatable {
    public let items: [PetAttentionItem]

    public init(items: [PetAttentionItem]) {
        self.items = items
    }

    public var count: Int { items.count }
}

/// In-flight agent thread row for the pet popover. Primary title is fixed
/// privacy-safe copy; secondary detail shows workspace, provider, thread
/// title (redacted), and optional elapsed. Membership comes from the live
/// active-run projection. `lastUpdatePreview` is Live Activity-only (single
/// active description) and is not shown on the pet popover row.
public struct PetActiveThreadItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let threadID: AgentThreadID
    public let title: String
    public let detail: String?
    /// Latest material agent progress for Live Activity single-active preview.
    public let lastUpdatePreview: String?
    public let workspaceName: String?
    public let route: PetAttentionRoute

    public init(
        threadID: AgentThreadID,
        workspaceID: WorkspaceID?,
        workspaceName: String? = nil,
        providerName: String? = nil,
        threadTitle: String? = nil,
        startedAt: Date? = nil,
        lastUpdatePreview: String? = nil,
        now: Date = Date(),
        route: PetAttentionRoute? = nil
    ) {
        self.id = "active:\(threadID.value.uuidString)"
        self.threadID = threadID
        self.workspaceName = workspaceName
        let elapsed = startedAt.flatMap { PetElapsedFormatter.label(from: $0, now: now) }
        let presentation = PetAttentionPresentation.safe(
            kind: .agentRunning,
            context: PetAttentionContext(
                workspaceName: workspaceName,
                providerName: providerName,
                threadTitle: threadTitle,
                elapsedLabel: elapsed
            )
        )
        self.title = presentation.title
        self.detail = presentation.detail
        self.lastUpdatePreview = PetAttentionRedactor.safeContextLabel(lastUpdatePreview)
        self.route = route ?? .agentThread(threadID: threadID, workspaceID: workspaceID)
    }
}

public enum PetActiveThreadProjector {
    public typealias ThreadMeta = (
        workspaceID: WorkspaceID?,
        workspaceName: String?,
        providerName: String?,
        threadTitle: String?,
        startedAt: Date?,
        lastUpdatePreview: String?
    )

    public static func items(
        threadIDs: [AgentThreadID],
        now: Date = Date(),
        lookup: (AgentThreadID) -> ThreadMeta?
    ) -> [PetActiveThreadItem] {
        // Oldest run first; rows without a start stamp last. Ties keep first-seen order, so new rows append.
        var seen = Set<AgentThreadID>()
        let unique = threadIDs.filter { seen.insert($0).inserted }
        let metas = unique.map { lookup($0) }
        let order = unique.indices.sorted { lhs, rhs in
            let l = metas[lhs]?.startedAt ?? .distantFuture
            let r = metas[rhs]?.startedAt ?? .distantFuture
            return l == r ? lhs < rhs : l < r
        }
        return order.map { index in
            let threadID = unique[index]
            let meta = metas[index]
            return PetActiveThreadItem(
                threadID: threadID,
                workspaceID: meta?.workspaceID,
                workspaceName: meta?.workspaceName,
                providerName: meta?.providerName,
                threadTitle: meta?.threadTitle,
                startedAt: meta?.startedAt,
                lastUpdatePreview: meta?.lastUpdatePreview,
                now: now
            )
        }
    }

    public static func providerLabel(_ provider: AgentProvider) -> String {
        switch provider {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .distill: return "Distill"
        }
    }
}

/// Groups popover rows under workspace headers while preserving relative order.
public enum PetPopoverGrouping {
    public static let unknownWorkspaceName = L("Other")

    public struct Group<Item: Identifiable>: Identifiable {
        public let id: String
        public let name: String
        public let items: [Item]

        public init(name: String, items: [Item]) {
            self.id = name
            self.name = name
            self.items = items
        }
    }

    public static func active(_ items: [PetActiveThreadItem]) -> [Group<PetActiveThreadItem>] {
        group(items) { $0.workspaceName }
    }

    public static func attention(_ items: [PetAttentionItem]) -> [Group<PetAttentionItem>] {
        group(items) { $0.workspaceName }
    }

    private static func group<Item: Identifiable>(
        _ items: [Item],
        name: (Item) -> String?
    ) -> [Group<Item>] {
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in items {
            let key = PetAttentionRedactor.safeContextLabel(name(item)) ?? unknownWorkspaceName
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key, default: []].append(item)
        }
        // Stable: named workspaces alphabetically, "Other" last, items keep input order.
        var named: [String] = []
        named.reserveCapacity(order.count)
        var hasUnknown = false
        for key in order {
            if key == unknownWorkspaceName { hasUnknown = true } else { named.append(key) }
        }
        named.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if hasUnknown { named.append(unknownWorkspaceName) }
        return named.compactMap { key in
            guard let groupItems = buckets[key], !groupItems.isEmpty else { return nil }
            return Group(name: key, items: groupItems)
        }
    }
}

public enum PetAttentionMarkResult: Sendable, Equatable {
    case marked
    case retainedBlocker
    case routeRejected
    case notFound
}

public enum PetTerminalNotificationKind: Sendable, Equatable {
    case gitDelivery(PetAttentionOperationOutcome)
    case projectScript(PetAttentionOperationOutcome)
    case sshTransfer(PetAttentionOperationOutcome)
    case sshUnexpectedDisconnect
    case providerUpdateFailed
    case fileConflict
}

public struct PetTerminalEvent: Sendable, Equatable {
    public let sequence: Int64
    public let kind: PetTerminalNotificationKind
    public let workspaceID: WorkspaceID?
    public let surfaceID: SurfaceID?
    public let createdAt: Date

    public init(
        sequence: Int64,
        kind: PetTerminalNotificationKind,
        workspaceID: WorkspaceID?,
        surfaceID: SurfaceID?,
        createdAt: Date
    ) {
        self.sequence = sequence
        self.kind = kind
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.createdAt = createdAt
    }
}
