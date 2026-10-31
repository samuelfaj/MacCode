import Foundation

/// A durable link from a Bot's conversation to one exact parallel run.
public struct BotParallelTask: Codable, Equatable, Sendable {
    public let botID: BotID
    public let conversationID: BotConversationID
    public let threadID: AgentThreadID
    public let runID: AgentRunID
    public let title: String

    public init(botID: BotID, conversationID: BotConversationID, threadID: AgentThreadID,
                runID: AgentRunID, title: String) {
        self.botID = botID
        self.conversationID = conversationID
        self.threadID = threadID
        self.runID = runID
        self.title = title
    }

    private static let prefix = "[[rc:bot-task:"

    public var transcript: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.prefix + data.base64EncodedString() + "]]"
    }

    public static func parse(_ content: String) -> Self? {
        guard content.hasPrefix(prefix), content.hasSuffix("]]"),
              let data = Data(base64Encoded: String(content.dropFirst(prefix.count).dropLast(2))),
              let task = try? JSONDecoder().decode(Self.self, from: data),
              !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return task
    }
}
