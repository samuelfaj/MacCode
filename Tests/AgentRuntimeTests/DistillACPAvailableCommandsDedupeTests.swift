import XCTest
@testable import AgentRuntime
import CoreModel

/// Live incident 2026-11-13..16: Distill re-sends the same
/// `available_commands_update` (about 200 KB: 309 commands, 168 tools) up to
/// 27 times in seven minutes of one run. Every copy became a stream event row
/// and a provider log row, so these repeats were about 90% of MacCode's
/// SQLite writes and macOS filed four "disk writes" resource reports
/// (2.1 GB to 34 GB). Only a changed list carries information.
final class DistillACPAvailableCommandsDedupeTests: XCTestCase {
    private func update(_ names: [String]) -> [String: Any] {
        [
            "sessionUpdate": "available_commands_update",
            "availableCommands": names.map { ["name": $0, "description": "Run \($0)"] },
            "_meta": ["tools": ["Read", "Bash"]]
        ]
    }

    private func commandEvents(_ events: [AssistantEvent]) -> [ProviderRuntimeEvent] {
        events.compactMap {
            guard case .providerRuntime(let runtime) = $0,
                  runtime.method == "available_commands_update" else { return nil }
            return runtime
        }
    }

    func test_repeatedIdenticalListIsEmittedOnce() {
        let mapper = DistillACPEventMapper(sessionId: "s")
        XCTAssertEqual(commandEvents(mapper.consumeSessionUpdate(update(["goal", "review"]))).count, 1)
        _ = mapper.beginTurn()
        for _ in 0..<5 {
            XCTAssertTrue(commandEvents(mapper.consumeSessionUpdate(update(["goal", "review"]))).isEmpty,
                          "an unchanged list must not become another persisted row")
        }
        XCTAssertEqual(mapper.availableCommands.map(\.name), ["goal", "review"])
    }

    func test_changedListIsStillEmitted() {
        let mapper = DistillACPEventMapper(sessionId: "s")
        _ = mapper.consumeSessionUpdate(update(["goal"]))
        let changed = commandEvents(mapper.consumeSessionUpdate(update(["goal", "review"])))
        XCTAssertEqual(changed.count, 1, "a new command must still reach the composer")
        XCTAssertTrue(changed[0].payloadJSON.contains("review"))
        XCTAssertEqual(mapper.availableCommands.map(\.name), ["goal", "review"])

        XCTAssertEqual(commandEvents(mapper.consumeSessionUpdate(update(["goal"]))).count, 1,
                       "going back to an earlier list is a change too")
    }

    /// Each session gets its own mapper, so a new session still announces
    /// its commands once even when the list matches another session's.
    func test_newSessionAnnouncesItsListAgain() {
        _ = DistillACPEventMapper(sessionId: "a").consumeSessionUpdate(update(["goal"]))
        let other = DistillACPEventMapper(sessionId: "b")
        XCTAssertEqual(commandEvents(other.consumeSessionUpdate(update(["goal"]))).count, 1)
    }
}
