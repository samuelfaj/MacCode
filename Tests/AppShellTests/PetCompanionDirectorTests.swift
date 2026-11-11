import XCTest
@testable import AppShell

final class PetCompanionDirectorTests: XCTestCase {
    func test_ambientCueRequiresTrulyIdleVisibleAnimationAndAvoidsImmediateRepeat() {
        var director = PetCompanionDirector()
        let eligible = PetCompanionEligibility(
            baseState: .idle,
            attentionCount: 0,
            activeRunCount: 0,
            isVisible: true,
            animationsEnabled: true,
            reducedMotion: false,
            screenLocked: false
        )

        let first = director.nextAmbientCue(
            eligibility: eligible,
            preferredIndex: 0,
            durationMilliseconds: 6_000
        )
        let second = director.nextAmbientCue(
            eligibility: eligible,
            preferredIndex: 0,
            durationMilliseconds: 12_000
        )

        XCTAssertEqual(first?.returnState, .idle)
        XCTAssertEqual(first?.durationMilliseconds, 6_000)
        XCTAssertEqual(second?.durationMilliseconds, 12_000)
        XCTAssertNotEqual(first?.state, second?.state,
            "a companion should not repeat the same ambient behavior back-to-back")
        XCTAssertNil(director.nextAmbientCue(
            eligibility: PetCompanionEligibility(
                baseState: .waiting,
                attentionCount: 1,
                activeRunCount: 0,
                isVisible: true,
                animationsEnabled: true,
                reducedMotion: false,
                screenLocked: false
            ),
            preferredIndex: 1,
            durationMilliseconds: 9_000
        ))
    }

    func test_ambientPoolKeepsYawAndStretchAsDistinctNonRepeatingReactions() {
        let eligible = PetCompanionEligibility(
            baseState: .idle,
            attentionCount: 0,
            activeRunCount: 0,
            isVisible: true,
            animationsEnabled: true,
            reducedMotion: false,
            screenLocked: false
        )
        var observed: Set<PetAnimationState> = []

        for preferredIndex in 0..<8 {
            var director = PetCompanionDirector()
            observed.insert(director.nextAmbientCue(
                eligibility: eligible,
                preferredIndex: preferredIndex
            )?.state ?? .idle)
        }

        XCTAssertEqual(observed, [
            .idleBall, .idleScratch, .idleGroom, .idleStretch,
            .idleBox, .idleButterfly, .eating, .idleYawn,
        ], "yawning and stretching must remain independently selectable feline behaviors")
    }

    func test_workCueRequiresActiveWorkAndCyclesMouseBugEngineerWithoutRepeat() {
        var director = PetCompanionDirector()
        let eligible = PetCompanionEligibility(
            baseState: .coding,
            attentionCount: 0,
            activeRunCount: 1,
            isVisible: true,
            animationsEnabled: true,
            reducedMotion: false,
            screenLocked: false
        )

        let first = director.nextWorkCue(
            eligibility: eligible,
            preferredIndex: 0,
            durationMilliseconds: 6_000
        )
        let second = director.nextWorkCue(
            eligibility: eligible,
            preferredIndex: 0,
            durationMilliseconds: 12_000
        )
        XCTAssertEqual(first?.state, .workingMouse)
        XCTAssertNotEqual(first?.state, second?.state)
        XCTAssertEqual(first?.returnState, .coding)
        XCTAssertEqual(first?.durationMilliseconds, 6_000)
    }

    func test_workCueAllowedWhileAttentionInboxIsNonZero() {
        // WHY: completed/failed Ready-for-you rows keep attentionCount > 0 for a
        // long time; blocking work cues on that left the pet stuck on laptop coding.
        var director = PetCompanionDirector()
        let eligible = PetCompanionEligibility(
            baseState: .coding,
            attentionCount: 8,
            activeRunCount: 2,
            isVisible: true,
            animationsEnabled: true,
            reducedMotion: false,
            screenLocked: false
        )
        XCTAssertTrue(eligible.allowsWorkCue)
        XCTAssertFalse(eligible.allowsAmbientCue,
                       "ambient idle clowning still requires a clear inbox")
        XCTAssertNotNil(director.nextWorkCue(
            eligibility: eligible,
            preferredIndex: 1,
            durationMilliseconds: 9_000
        ))
    }

    func test_notificationPounceOnlyOccursOnZeroToPositiveAndNeverOverridesBlockers() {
        var director = PetCompanionDirector()

        XCTAssertEqual(
            director.notificationCue(previousCount: 0, newCount: 3, baseState: .waiting),
            PetCompanionCue(state: .notificationPounce, returnState: .waiting)
        )
        XCTAssertNil(director.notificationCue(previousCount: 3, newCount: 4, baseState: .waiting))
        XCTAssertNil(director.notificationCue(previousCount: 0, newCount: 1, baseState: .approval))
        XCTAssertNil(director.notificationCue(previousCount: 0, newCount: 1, baseState: .question))
        XCTAssertNil(director.notificationCue(previousCount: 0, newCount: 1, baseState: .failed))
        XCTAssertNil(director.notificationCue(previousCount: 0, newCount: 1, baseState: .interrupted))
        XCTAssertNil(director.notificationCue(previousCount: 0, newCount: 1, baseState: .sleeping))
    }

    func test_everyThirdSuccessfulOutcomeUsesTreatCelebration() {
        var director = PetCompanionDirector()

        XCTAssertNil(director.successCue(returnState: .success))
        XCTAssertNil(director.successCue(returnState: .success))
        XCTAssertEqual(
            director.successCue(returnState: .success),
            PetCompanionCue(state: .celebrateTreat, returnState: .success)
        )
        XCTAssertNil(director.successCue(returnState: .success))
    }

    func test_careActionsMapToAuthoredReactionsAndReturnToExactBaseState() {
        let expected: [(PetCareAction, PetAnimationState)] = [
            (.feed, .eating),
            (.giveWater, .drinking),
            (.pet, .purring),
            (.play, .playing),
            (.cheerUp, .comfort),
        ]

        XCTAssertEqual(PetCareAction.allCases.map(\.title), [
            "Feed the cat", "Give water", "Pet the cat", "Play", "Cheer up"
        ])
        for (action, state) in expected {
            XCTAssertEqual(
                PetCompanionDirector.careCue(
                    action: action,
                    returnState: .reconnecting,
                    durationMilliseconds: 9_000
                ),
                PetCompanionCue(
                    state: state,
                    returnState: .reconnecting,
                    durationMilliseconds: 9_000
                )
            )
        }
    }

    func test_directorDelayContractsStayInsideProductBounds() {
        XCTAssertEqual(PetCompanionDirector.ambientDelayRange, 35...55)
        XCTAssertEqual(PetCompanionDirector.workDelayRange, 35...55)
        XCTAssertEqual(PetCompanionDirector.extendedReactionDurationRange, 6_000...12_000)
        XCTAssertEqual(
            PetCompanionDirector.ambientDelayRange.lowerBound
                + Int(PetCompanionDirector.extendedReactionDurationRange.lowerBound / 1_000),
            41,
            "the earliest start-to-start cadence must include the full six-second reaction"
        )
        XCTAssertEqual(
            PetCompanionDirector.ambientDelayRange.upperBound
                + Int(PetCompanionDirector.extendedReactionDurationRange.upperBound / 1_000),
            67,
            "random reactions should still occur about once per minute"
        )
    }
}
