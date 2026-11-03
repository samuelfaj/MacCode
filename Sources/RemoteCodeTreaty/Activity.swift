import Foundation

public enum AgentActivityKind: String, Codable, Sendable {
    case agent, request, notification, operation
}

public enum AgentActivityState: String, Codable, Sendable {
    case running, queued, waitingApproval = "waiting_approval", waitingAnswer = "waiting_answer"
    case completed, failed, interrupted, stopped, expired, needsYou = "needs_you"
}

public struct AgentActivityItem: Codable, Equatable, Sendable {
    public let id: String
    public let kind: AgentActivityKind
    public let runID: UUID?
    public let requestID: String?
    public let notificationID: String?
    public let workspaceID: UUID?
    public let threadID: UUID?
    public let surfaceID: UUID?
    public let state: AgentActivityState
    public let title: String
    public let workspaceName: String?
    /// `TabColor` raw value of the workspace color (e.g. "blue"); nil when the workspace has none.
    public let workspaceColor: String?
    public let provider: String?
    public let summary: String?
    public let occurredAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let viewedAt: Date?
    public let attentionAcknowledgedAt: Date?
    public let needsAction: Bool
    public let blocking: Bool
    public let finalMessageID: UUID?
    public let checkpointID: UUID?
    public let checkpointTurnCount: Int?
    public let changedFiles: [String]
    /// Files the checkpoint touched; larger than `changedFiles.count` when the host capped the list.
    public let changedFilesTotal: Int?
    public let error: String?
    public let botID: UUID?
    public let conversationID: UUID?
    public let originLabel: String?

    public init(id: String, kind: AgentActivityKind, runID: UUID? = nil, requestID: String? = nil, notificationID: String? = nil, workspaceID: UUID? = nil, threadID: UUID? = nil, surfaceID: UUID? = nil, state: AgentActivityState, title: String, workspaceName: String? = nil, workspaceColor: String? = nil, provider: String? = nil, summary: String? = nil, occurredAt: Date, startedAt: Date? = nil, finishedAt: Date? = nil, viewedAt: Date? = nil, attentionAcknowledgedAt: Date? = nil, needsAction: Bool = false, blocking: Bool = false, finalMessageID: UUID? = nil, checkpointID: UUID? = nil, checkpointTurnCount: Int? = nil, changedFiles: [String] = [], changedFilesTotal: Int? = nil, error: String? = nil, botID: UUID? = nil, conversationID: UUID? = nil, originLabel: String? = nil) {
        self.id = id; self.kind = kind; self.runID = runID; self.requestID = requestID
        self.notificationID = notificationID; self.workspaceID = workspaceID; self.threadID = threadID
        self.surfaceID = surfaceID; self.state = state; self.title = title; self.workspaceName = workspaceName
        self.workspaceColor = workspaceColor
        self.provider = provider; self.summary = summary; self.occurredAt = occurredAt; self.startedAt = startedAt
        self.finishedAt = finishedAt; self.viewedAt = viewedAt; self.attentionAcknowledgedAt = attentionAcknowledgedAt
        self.needsAction = needsAction; self.blocking = blocking; self.finalMessageID = finalMessageID
        self.checkpointID = checkpointID; self.checkpointTurnCount = checkpointTurnCount; self.changedFiles = changedFiles; self.changedFilesTotal = changedFilesTotal; self.error = error
        self.botID = botID; self.conversationID = conversationID; self.originLabel = originLabel
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, state, title, provider, summary, error, blocking
        case runID = "run_id", requestID = "request_id", notificationID = "notification_id"
        case workspaceID = "workspace_id", threadID = "thread_id", surfaceID = "surface_id"
        case workspaceName = "workspace_name", workspaceColor = "workspace_color", occurredAt = "occurred_at", startedAt = "started_at"
        case finishedAt = "finished_at", viewedAt = "viewed_at"
        case attentionAcknowledgedAt = "attention_acknowledged_at", needsAction = "needs_action"
        case finalMessageID = "final_message_id", checkpointID = "checkpoint_id", checkpointTurnCount = "checkpoint_turn_count", changedFiles = "changed_files", changedFilesTotal = "changed_files_total"
        case botID = "bot_id", conversationID = "conversation_id", originLabel = "origin_label"
    }
}

public struct AgentActivityCounts: Codable, Equatable, Sendable {
    public let running: Int
    public let queued: Int
    public let needsYou: Int
    public let finished: Int
    public let newResults: Int
    public init(running: Int, queued: Int, needsYou: Int, finished: Int, newResults: Int) {
        self.running = running; self.queued = queued; self.needsYou = needsYou
        self.finished = finished; self.newResults = newResults
    }
    private enum CodingKeys: String, CodingKey {
        case running, queued, finished
        case needsYou = "needs_you", newResults = "new_results"
    }
}

public struct AgentActivityPage: Codable, Equatable, Sendable {
    public let items: [AgentActivityItem]
    public let nextCursor: String?
    public let counts: AgentActivityCounts
    public let generatedAt: Date
    public let workspaceCounts: [String: AgentActivityCounts]?

    public init(items: [AgentActivityItem], nextCursor: String? = nil, counts: AgentActivityCounts, generatedAt: Date, workspaceCounts: [String: AgentActivityCounts]? = nil) {
        self.items = items; self.nextCursor = nextCursor; self.counts = counts; self.generatedAt = generatedAt; self.workspaceCounts = workspaceCounts
    }
    public static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { input in
            let container = try input.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = fractional.date(from: text) ?? plain.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Activity timestamp")
            }
            return date
        }
        return decoder
    }

    private enum CodingKeys: String, CodingKey {
        case items, counts
        case nextCursor = "next_cursor", generatedAt = "generated_at"
        case workspaceCounts = "workspace_counts"
    }
}
