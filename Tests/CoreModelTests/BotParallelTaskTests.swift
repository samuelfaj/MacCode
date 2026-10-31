import XCTest
@testable import CoreModel

final class BotParallelTaskTests: XCTestCase {
    func test_taskLinkRoundTripsExactIdentityAndArbitraryTitle() throws {
        let task = BotParallelTask(botID: BotID(), conversationID: BotConversationID(),
            threadID: AgentThreadID(), runID: AgentRunID(), title: "Inspect webhooks | replies ]] \n ação")
        XCTAssertEqual(BotParallelTask.parse(task.transcript), task,
            "The task must reopen its exact conversation even when its title contains marker delimiters")
    }

    func test_plainTextAndMalformedLinksAreNotInterpretedAsTasks() {
        for text in ["ordinary assistant text", "[[rc:bot-task:bad]]", "[[rc:bot-task:e30=]]", "[[rc:bot-task:"] {
            XCTAssertNil(BotParallelTask.parse(text), "Malformed content must never select a different conversation")
        }
    }
}
