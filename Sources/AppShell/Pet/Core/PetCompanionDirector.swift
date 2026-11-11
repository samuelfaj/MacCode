import Foundation
import CoreModel

public enum PetCareAction: String, CaseIterable, Sendable, Equatable {
    case feed
    case giveWater
    case pet
    case play
    case cheerUp

    public var title: String {
        switch self {
        case .feed: return L("Feed the cat")
        case .giveWater: return L("Give water")
        case .pet: return L("Pet the cat")
        case .play: return L("Play")
        case .cheerUp: return L("Cheer up")
        }
    }

    var animationState: PetAnimationState {
        switch self {
        case .feed: return .eating
        case .giveWater: return .drinking
        case .pet: return .purring
        case .play: return .playing
        case .cheerUp: return .comfort
        }
    }
}

public struct PetCompanionCue: Sendable, Equatable {
    public let state: PetAnimationState
    public let returnState: PetAnimationState
    public let durationMilliseconds: Int64

    public init(
        state: PetAnimationState,
        returnState: PetAnimationState,
        durationMilliseconds: Int64 = 1_200
    ) {
        self.state = state
        self.returnState = returnState
        self.durationMilliseconds = max(0, durationMilliseconds)
    }
}

public struct PetCompanionEligibility: Sendable, Equatable {
    public let baseState: PetAnimationState
    public let attentionCount: Int
    public let activeRunCount: Int
    public let isVisible: Bool
    public let animationsEnabled: Bool
    public let reducedMotion: Bool
    public let screenLocked: Bool

    public init(
        baseState: PetAnimationState,
        attentionCount: Int,
        activeRunCount: Int,
        isVisible: Bool,
        animationsEnabled: Bool,
        reducedMotion: Bool,
        screenLocked: Bool
    ) {
        self.baseState = baseState
        self.attentionCount = max(0, attentionCount)
        self.activeRunCount = max(0, activeRunCount)
        self.isVisible = isVisible
        self.animationsEnabled = animationsEnabled
        self.reducedMotion = reducedMotion
        self.screenLocked = screenLocked
    }

    private var allowsCompanionMotion: Bool {
        isVisible && animationsEnabled && !reducedMotion && !screenLocked
    }

    /// Idle ambient (ball, groom, yawn…) only when nothing needs attention and
    /// no agent is running — completed/failed inbox should keep the pet calm
    /// without ambient clowning over a "Ready for you" badge.
    var allowsAmbientCue: Bool {
        allowsCompanionMotion
            && attentionCount == 0
            && activeRunCount == 0
            && baseState == .idle
    }

    /// Work variants (mouse / bug / engineer) while an agent run is active.
    ///
    /// WHY ignore `attentionCount` (primary root of forever-laptop): Ready-for-you
    /// completed/failed rows keep the count non-zero for hours. That is the E5
    /// freeze. `baseState` must be the **semantic** work base (companionBaseState),
    /// not the display pose — calling with workingMouse as base would false-cancel
    /// the next work countdown.
    var allowsWorkCue: Bool {
        guard allowsCompanionMotion, activeRunCount > 0 else { return false }
        switch baseState {
        case .coding, .editing, .terminal, .search, .gitReview, .thinking, .listening:
            return true
        default:
            return false
        }
    }
}

public struct PetCompanionDirector: Sendable {
    public static let ambientDelayRange = 35...55
    public static let workDelayRange = 35...55
    public static let extendedReactionDurationRange: ClosedRange<Int64> = 6_000...12_000

    private static let ambientStates: [PetAnimationState] = [
        .idleBall, .idleScratch, .idleGroom, .idleStretch,
        .idleBox, .idleButterfly, .eating, .idleYawn,
    ]
    private static let workStates: [PetAnimationState] = [
        .workingMouse, .workingBug, .workingEngineer,
    ]

    private var lastAmbientState: PetAnimationState?
    private var lastWorkState: PetAnimationState?
    private var successfulOutcomeCount = 0

    public init() {}

    public mutating func nextAmbientCue(
        eligibility: PetCompanionEligibility,
        preferredIndex: Int,
        durationMilliseconds: Int64 = 9_000
    ) -> PetCompanionCue? {
        guard eligibility.allowsAmbientCue else { return nil }
        let state = Self.nonRepeatingState(
            from: Self.ambientStates,
            preferredIndex: preferredIndex,
            previous: lastAmbientState
        )
        lastAmbientState = state
        return PetCompanionCue(
            state: state,
            returnState: eligibility.baseState,
            durationMilliseconds: durationMilliseconds
        )
    }

    public mutating func nextWorkCue(
        eligibility: PetCompanionEligibility,
        preferredIndex: Int,
        durationMilliseconds: Int64 = 9_000
    ) -> PetCompanionCue? {
        guard eligibility.allowsWorkCue else { return nil }
        let state = Self.nonRepeatingState(
            from: Self.workStates,
            preferredIndex: preferredIndex,
            previous: lastWorkState
        )
        lastWorkState = state
        return PetCompanionCue(
            state: state,
            returnState: eligibility.baseState,
            durationMilliseconds: durationMilliseconds
        )
    }

    public mutating func notificationCue(
        previousCount: Int,
        newCount: Int,
        baseState: PetAnimationState
    ) -> PetCompanionCue? {
        guard previousCount == 0, newCount > 0 else { return nil }
        return Self.speechCue(baseState: baseState)
    }

    /// Titio speaks from the pet (hub spec §9): the pounce pairs with the
    /// bubble, except over a pose that already asks for the user or sleeps.
    public static func speechCue(baseState: PetAnimationState) -> PetCompanionCue? {
        guard ![.approval, .question, .sleeping, .failed, .interrupted].contains(baseState) else {
            return nil
        }
        return PetCompanionCue(state: .notificationPounce, returnState: baseState)
    }

    public mutating func successCue(returnState: PetAnimationState) -> PetCompanionCue? {
        successfulOutcomeCount += 1
        guard successfulOutcomeCount.isMultiple(of: 3) else { return nil }
        return PetCompanionCue(state: .celebrateTreat, returnState: returnState)
    }

    public static func careCue(
        action: PetCareAction,
        returnState: PetAnimationState,
        durationMilliseconds: Int64 = 9_000
    ) -> PetCompanionCue {
        PetCompanionCue(
            state: action.animationState,
            returnState: returnState,
            durationMilliseconds: durationMilliseconds
        )
    }

    private static func nonRepeatingState(
        from states: [PetAnimationState],
        preferredIndex: Int,
        previous: PetAnimationState?
    ) -> PetAnimationState {
        let normalizedIndex = ((preferredIndex % states.count) + states.count) % states.count
        let candidate = states[normalizedIndex]
        guard candidate == previous else { return candidate }
        return states[(normalizedIndex + 1) % states.count]
    }
}
