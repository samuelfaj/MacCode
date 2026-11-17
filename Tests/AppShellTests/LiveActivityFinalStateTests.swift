import XCTest
import Foundation
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence

/// The Lock Screen card is the one channel that reaches a paused iPhone with no
/// silent-push budget, so its terminal push must say how the run really ended.
final class LiveActivityFinalStateTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LiveActivitySyncDelivery] = []
        private var endFailuresLeft: Int

        init(failFirstEnds: Int = 0) { endFailuresLeft = failFirstEnds }

        func deliver(_ delivery: LiveActivitySyncDelivery) throws {
            try lock.withLock {
                if delivery.event == .end, endFailuresLeft > 0 {
                    endFailuresLeft -= 1
                    throw URLError(.notConnectedToInternet)
                }
                values.append(delivery)
            }
        }

        var deliveries: [LiveActivitySyncDelivery] { lock.withLock { values } }
    }

    private let run = ActiveRunProjection(runs: [ActiveRunProjection.Run(
        threadId: AgentThreadID(UUID(uuidString: "10000000-0000-0000-0000-000000000001")!),
        runId: AgentRunID(UUID(uuidString: "20000000-0000-0000-0000-000000000001")!)
    )])

    private func coordinator(_ recorder: Recorder) -> LiveActivitySyncCoordinator {
        LiveActivitySyncCoordinator(
            serverId: "server-1",
            bootEpoch: 5,
            deliver: { try recorder.deliver($0) },
            heartbeatIntervalNanoseconds: 60_000_000_000_000,
            deliveryMaxAttempts: 1,
            deliveryRetryDelayNanoseconds: { _ in 0 }
        )
    }

    // WHY: the end of a completed run failed to reach the backend and the
    // heartbeat retried it. The retry has no finish cause of its own; the card
    // used to end as "Failed" for a run that completed.
    func testHeartbeatRetriedEndKeepsTheCompletedOutcome() async {
        let recorder = Recorder(failFirstEnds: 1)
        let sync = coordinator(recorder)
        sync.submit(run, cause: .started, now: Date(timeIntervalSince1970: 600))
        sync.submit(ActiveRunProjection(runs: []), cause: .finished(.completed), now: Date(timeIntervalSince1970: 601))
        await sync.flush()
        XCTAssertEqual(recorder.deliveries.map(\.event), [.start], "the first end did not get through")

        sync.submitHeartbeat(now: Date(timeIntervalSince1970: 630))
        await sync.flush()

        let end = recorder.deliveries.last
        XCTAssertEqual(end?.event, .end)
        XCTAssertEqual(end?.projection.phase, .completed)
        XCTAssertEqual(end?.projection.statusLine, "Finished")
    }

    // WHY: the same retry after a failed run must still say "Failed" — a
    // retry may never turn a terminal error into success either.
    func testHeartbeatRetriedEndKeepsTheFailedOutcome() async {
        let recorder = Recorder(failFirstEnds: 1)
        let sync = coordinator(recorder)
        sync.submit(run, cause: .started, now: Date(timeIntervalSince1970: 600))
        sync.submit(ActiveRunProjection(runs: []), cause: .finished(.failed), now: Date(timeIntervalSince1970: 601))
        sync.submitHeartbeat(now: Date(timeIntervalSince1970: 630))
        await sync.flush()

        XCTAssertEqual(recorder.deliveries.last?.event, .end)
        XCTAssertEqual(recorder.deliveries.last?.projection.phase, .failed)
        XCTAssertEqual(recorder.deliveries.last?.projection.statusLine, "Failed")
    }

    // WHY: with Titio on, the card used to end as completed/"success" whatever
    // the run did, so a failed Bot or agent run looked fine on the Lock Screen.
    // A user's own stop is not an error and still ends as completed.
    func testTitioCardEndsWithTheRunsFailure() async {
        for (status, phase, pet) in [
            (AgentRunStatus.failed, PrivateLiveActivityProjectionPhase.failed, "failed"),
            (.interrupted, .failed, "failed"),
            (.completed, .completed, "success"),
            (.cancelled, .completed, "success"),
        ] {
            let recorder = Recorder()
            let sync = coordinator(recorder)
            sync.submitTitio(TitioInboxSnapshot(botID: BotID(), conversationID: BotConversationID(), threadID: AgentThreadID(),
                unreadCount: 0, openDecisions: 0, lastPreview: nil, lastAt: nil))
            sync.submit(run, cause: .started)
            sync.submit(ActiveRunProjection(runs: []), cause: .finished(status))
            await sync.flush()

            let end = recorder.deliveries.last
            XCTAssertEqual(recorder.deliveries.map(\.event), [.start, .end], "\(status)")
            XCTAssertEqual(end?.projection.phase, phase, "\(status)")
            XCTAssertEqual(end?.projection.petState, pet, "\(status)")
        }
    }
}
