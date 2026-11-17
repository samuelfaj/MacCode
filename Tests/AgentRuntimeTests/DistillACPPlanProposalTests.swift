import XCTest
@testable import AgentRuntime
import CoreModel

/// Live incident 2026-11-17: on a Full access turn, GPT-6.2-Astra switched its
/// Distill session into plan mode by itself (`enter_plan_mode`) and kept a
/// to-do list. Each to-do update became a proposed plan, and Full access queued
/// "Implement this proposed plan now" twice, though nobody asked for a plan.
final class DistillACPPlanProposalTests: XCTestCase {
    private static let agentEntersPlanMode: [String: Any] = [
        "sessionUpdate": "current_mode_update", "currentModeId": "plan"
    ]

    private func plan(_ entries: [(String, String)]) -> [String: Any] {
        ["sessionUpdate": "plan", "entries": entries.map { ["content": $0.0, "status": $0.1] }]
    }

    private func mapper(mode: String, planRequested: Bool) -> DistillACPEventMapper {
        let mapper = DistillACPEventMapper(sessionId: "plan-session")
        mapper.setPlanReviewModeId("plan")
        mapper.setCurrentModeId(mode)
        mapper.setPlanReviewRequested(planRequested)
        return mapper
    }

    private func turn(_ mapper: DistillACPEventMapper, _ updates: [[String: Any]],
                      stopReason: String = "end_turn") -> [AssistantEvent] {
        var events = mapper.beginTurn()
        for update in updates { events += mapper.consumeSessionUpdate(update) }
        events += mapper.finishTurn(stopReason: stopReason, usage: nil)
        return events
    }

    private func proposals(_ events: [AssistantEvent]) -> [AssistantProposedPlan] {
        events.compactMap { if case .proposedPlan(let plan) = $0 { return plan }; return nil }
    }

    func test_agentEnteringPlanModeByItselfProposesNothing_becauseTheUserDidNotAskForAPlan() {
        let mapper = mapper(mode: "bypassPermissions", planRequested: false)
        let events = turn(mapper, [
            Self.agentEntersPlanMode,
            plan([("Check the rules", "in_progress"), ("Trace the flows", "pending")]),
            plan([("Check the rules", "completed"), ("Trace the flows", "in_progress")])
        ])
        XCTAssertEqual(proposals(events).count, 0,
                       "a proposal makes Full access queue an implementation the user never asked for")
        XCTAssertTrue(events.contains { if case .activePlanUpdated = $0 { return true }; return false },
                      "the to-do list still shows as the turn's progress")
    }

    func test_planTurnProposesOnceWithTheFinishedPlan_soFullAccessQueuesOneImplementation() {
        let mapper = mapper(mode: "plan", planRequested: true)
        var events = mapper.beginTurn()
        events += mapper.consumeSessionUpdate(plan([("Inspect", "in_progress")]))
        events += mapper.consumeSessionUpdate(plan([("Inspect", "completed"), ("Patch", "pending")]))
        XCTAssertEqual(proposals(events).count, 0, "an unfinished plan must not be implemented")
        events += mapper.finishTurn(stopReason: "end_turn", usage: nil)

        let proposed = proposals(events)
        XCTAssertEqual(proposed.count, 1)
        XCTAssertEqual(proposed.first?.markdown, "1. [completed] Inspect\n2. [pending] Patch")
        let proposalIndex = events.firstIndex { if case .proposedPlan = $0 { return true }; return false }
        let completedIndex = events.firstIndex { if case .turnCompleted = $0 { return true }; return false }
        XCTAssertLessThan(try XCTUnwrap(proposalIndex), try XCTUnwrap(completedIndex),
                          "the plan lands before the turn ends, where the run's finish looks for it")
    }

    func test_cancelledPlanTurnProposesNothing_becauseFullAccessWouldImplementWhatTheUserStopped() {
        let mapper = mapper(mode: "plan", planRequested: true)
        let events = turn(mapper, [plan([("Inspect", "in_progress")])], stopReason: "cancelled")
        XCTAssertEqual(proposals(events).count, 0)
    }

    func test_planRequestLastsOneTurn_soAWakeTurnAfterItDoesNotPropose() {
        // Wake turns (loop iterations) start without a prompt, so nothing sets the flag for them.
        let mapper = mapper(mode: "plan", planRequested: true)
        XCTAssertEqual(proposals(turn(mapper, [plan([("Inspect", "pending")])])).count, 1)
        XCTAssertEqual(proposals(turn(mapper, [plan([("Inspect", "completed")])])).count, 0)
    }
}
