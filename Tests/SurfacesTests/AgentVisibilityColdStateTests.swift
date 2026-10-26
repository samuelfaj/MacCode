import XCTest
@testable import Surfaces

/// S6: visibility cold-state generation safety + checkpoint retention.
final class AgentVisibilityColdStateTests: XCTestCase {
    func test_hideReveal_generationSafeAndPreservesCheckpoint() {
        var session = AgentVisibilitySession()
        let checkpoint = AgentPresentationCheckpoint(
            durableSequence: 10,
            lastAppliedDurableSequence: 9,
            selectedThreadId: "t1",
            composerText: "draft",
            attachmentIds: ["a1"],
            browserURL: "https://example.com",
            browserTitle: "Example",
            stopOwned: true
        )
        session = AgentVisibilityColdState.didBecomeHidden(session: session, checkpoint: checkpoint)
        XCTAssertEqual(session.state, .hidden)
        XCTAssertEqual(session.checkpoint.composerText, "draft")
        XCTAssertEqual(session.checkpoint.browserURL, "https://example.com")
        XCTAssertTrue(session.checkpoint.stopOwned)
        XCTAssertTrue(session.retainsCompactDirtyOnly)

        session = AgentVisibilityColdState.beginReveal(session: session)
        XCTAssertEqual(session.state, .restoring)
        let gen = session.generation
        let done = AgentVisibilityColdState.completeReveal(
            session: session,
            expectedGeneration: gen,
            appliedThroughSequence: 12
        )
        XCTAssertEqual(done?.state, .visible)
        XCTAssertEqual(done?.checkpoint.lastAppliedDurableSequence, 12)

        let stale = AgentVisibilityColdState.completeReveal(
            session: session,
            expectedGeneration: gen - 1,
            appliedThroughSequence: 99
        )
        XCTAssertNil(stale)
    }

    /// Checkpoints persisted before the plan sidebar was removed carry a
    /// `planSidebarIntent` key; they must still decode.
    func test_presentationCheckpoint_decodesLegacyPlanSidebarIntentKey() throws {
        let legacy = #"{"durableSequence":3,"lastAppliedDurableSequence":2,"composerText":"draft","attachmentIds":[],"planSidebarIntent":"forcedHidden","unreadOwned":false,"stopOwned":false}"#
        let decoded = try JSONDecoder().decode(AgentPresentationCheckpoint.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.durableSequence, 3)
        XCTAssertEqual(decoded.composerText, "draft")
    }

    func test_globalLRU_disabledUntilMeasuredBreach() {
        XCTAssertFalse(AgentVisibilityColdState.globalAgentLRUEnabled)
    }

    func test_promotionThreshold() {
        XCTAssertTrue(
            AgentVisibilityColdState.shouldPromoteReclamation(
                savedBytes: 200 * 1024 * 1024,
                appFootprintBytes: 1_000 * 1024 * 1024,
                revealP95Ms: 100,
                revealP99Ms: 200,
                mainActorStallMs: 50,
                duplicateOrMissingEvents: false
            )
        )
        XCTAssertFalse(
            AgentVisibilityColdState.shouldPromoteReclamation(
                savedBytes: 10 * 1024 * 1024,
                appFootprintBytes: 1_000 * 1024 * 1024,
                revealP95Ms: 100,
                revealP99Ms: 200,
                mainActorStallMs: 50,
                duplicateOrMissingEvents: false
            )
        )
        XCTAssertFalse(
            AgentVisibilityColdState.shouldPromoteReclamation(
                savedBytes: 200 * 1024 * 1024,
                appFootprintBytes: 1_000 * 1024 * 1024,
                revealP95Ms: 900,
                revealP99Ms: 200,
                mainActorStallMs: 50,
                duplicateOrMissingEvents: false
            ),
            "reveal p95 breach must block promotion"
        )
    }

    func test_completeReveal_rejectsDuplicateAndIncompleteCatchUp() {
        var session = AgentVisibilitySession()
        session = AgentVisibilityColdState.didBecomeHidden(
            session: session,
            checkpoint: AgentPresentationCheckpoint(durableSequence: 10, lastAppliedDurableSequence: 9)
        )
        session = AgentVisibilityColdState.beginReveal(session: session)
        let gen = session.generation
        let first = AgentVisibilityColdState.completeReveal(
            session: session,
            expectedGeneration: gen,
            appliedThroughSequence: 10
        )
        XCTAssertEqual(first?.state, .visible)
        // Duplicate completion after visible must fail.
        XCTAssertNil(
            AgentVisibilityColdState.completeReveal(
                session: first!,
                expectedGeneration: gen,
                appliedThroughSequence: 11
            )
        )
        // Incomplete catch-up while restoring must fail.
        session = AgentVisibilityColdState.beginReveal(session: first!)
        XCTAssertNil(
            AgentVisibilityColdState.completeReveal(
                session: session,
                expectedGeneration: session.generation,
                appliedThroughSequence: 5
            )
        )
    }

    func test_promotion_allSafetyGates() {
        // 10%-of-footprint branch (footprint large → threshold = 10%).
        XCTAssertFalse(
            AgentVisibilityColdState.shouldPromoteReclamation(
                savedBytes: 50 * 1024 * 1024,
                appFootprintBytes: 2_000 * 1024 * 1024, // 10% = 200 MiB
                revealP95Ms: 10,
                revealP99Ms: 10,
                mainActorStallMs: 10,
                duplicateOrMissingEvents: false
            )
        )
        XCTAssertTrue(
            AgentVisibilityColdState.shouldPromoteReclamation(
                savedBytes: 200 * 1024 * 1024,
                appFootprintBytes: 2_000 * 1024 * 1024,
                revealP95Ms: 10,
                revealP99Ms: 10,
                mainActorStallMs: 10,
                duplicateOrMissingEvents: false
            )
        )
        // p99 boundary
        XCTAssertFalse(
            AgentVisibilityColdState.shouldPromoteReclamation(
                savedBytes: 200 * 1024 * 1024,
                appFootprintBytes: 1_000 * 1024 * 1024,
                revealP95Ms: 10,
                revealP99Ms: 1_001,
                mainActorStallMs: 10,
                duplicateOrMissingEvents: false
            )
        )
        // MainActor stall exact boundary (≥2s fails)
        XCTAssertFalse(
            AgentVisibilityColdState.shouldPromoteReclamation(
                savedBytes: 200 * 1024 * 1024,
                appFootprintBytes: 1_000 * 1024 * 1024,
                revealP95Ms: 10,
                revealP99Ms: 10,
                mainActorStallMs: 2_000,
                duplicateOrMissingEvents: false
            )
        )
        // Duplicate/missing events
        XCTAssertFalse(
            AgentVisibilityColdState.shouldPromoteReclamation(
                savedBytes: 200 * 1024 * 1024,
                appFootprintBytes: 1_000 * 1024 * 1024,
                revealP95Ms: 10,
                revealP99Ms: 10,
                mainActorStallMs: 10,
                duplicateOrMissingEvents: true
            )
        )
    }

    func test_completeReveal_lastAppliedWatermarkFloor() {
        var session = AgentVisibilitySession()
        session = AgentVisibilityColdState.didBecomeHidden(
            session: session,
            checkpoint: AgentPresentationCheckpoint(durableSequence: 5, lastAppliedDurableSequence: 20)
        )
        session = AgentVisibilityColdState.beginReveal(session: session)
        // Floor is max(durable=5, lastApplied=20) = 20.
        XCTAssertNil(
            AgentVisibilityColdState.completeReveal(
                session: session,
                expectedGeneration: session.generation,
                appliedThroughSequence: 19
            )
        )
        let ok = AgentVisibilityColdState.completeReveal(
            session: session,
            expectedGeneration: session.generation,
            appliedThroughSequence: 20
        )
        XCTAssertEqual(ok?.checkpoint.lastAppliedDurableSequence, 20)
    }
}
