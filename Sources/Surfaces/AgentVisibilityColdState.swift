import CoreModel
import Foundation

/// Agent visibility cold-state protocol (S6 / T-003).
///
/// Local hide/reveal reclamation precedes any host-wide LRU. Global LRU is not
/// implemented until a measured residual breach is recorded.

public enum AgentVisibilityState: String, Sendable, Equatable {
    case visible
    case hidden
    case restoring
}

public struct AgentPresentationCheckpoint: Sendable, Equatable, Codable {
    public var durableSequence: Int64
    public var lastAppliedDurableSequence: Int64
    public var selectedThreadId: String?
    public var selectedTabId: String?
    public var composerText: String
    public var attachmentIds: [String]
    public var scrollPinIntent: String?
    public var disclosureIntent: String?
    public var browserURL: String?
    public var browserTitle: String?
    public var surfaceMetadataJSON: String?
    public var unreadOwned: Bool
    public var stopOwned: Bool

    public init(
        durableSequence: Int64 = 0,
        lastAppliedDurableSequence: Int64 = 0,
        selectedThreadId: String? = nil,
        selectedTabId: String? = nil,
        composerText: String = "",
        attachmentIds: [String] = [],
        scrollPinIntent: String? = nil,
        disclosureIntent: String? = nil,
        browserURL: String? = nil,
        browserTitle: String? = nil,
        surfaceMetadataJSON: String? = nil,
        unreadOwned: Bool = false,
        stopOwned: Bool = false
    ) {
        self.durableSequence = durableSequence
        self.lastAppliedDurableSequence = lastAppliedDurableSequence
        self.selectedThreadId = selectedThreadId
        self.selectedTabId = selectedTabId
        self.composerText = composerText
        self.attachmentIds = attachmentIds
        self.scrollPinIntent = scrollPinIntent
        self.disclosureIntent = disclosureIntent
        self.browserURL = browserURL
        self.browserTitle = browserTitle
        self.surfaceMetadataJSON = surfaceMetadataJSON
        self.unreadOwned = unreadOwned
        self.stopOwned = stopOwned
    }
}

public struct AgentVisibilitySession: Sendable, Equatable {
    public var state: AgentVisibilityState
    public var generation: UInt64
    public var checkpoint: AgentPresentationCheckpoint
    public var retainsCompactDirtyOnly: Bool

    public init(
        state: AgentVisibilityState = .visible,
        generation: UInt64 = 0,
        checkpoint: AgentPresentationCheckpoint = AgentPresentationCheckpoint(),
        retainsCompactDirtyOnly: Bool = false
    ) {
        self.state = state
        self.generation = generation
        self.checkpoint = checkpoint
        self.retainsCompactDirtyOnly = retainsCompactDirtyOnly
    }
}

public enum AgentVisibilityColdState {
    /// Memory save threshold to promote reclamation (plan S6).
    public static let minSaveBytes = 128 * 1024 * 1024
    public static let minSaveFractionOfAppFootprint = 0.10
    public static let revealP95BudgetMs: Double = 500
    public static let revealP99BudgetMs: Double = 1_000
    public static let mainActorStallBudgetMs: Double = 2_000

    public static func shouldPromoteReclamation(
        savedBytes: Int64,
        appFootprintBytes: Int64,
        revealP95Ms: Double,
        revealP99Ms: Double,
        mainActorStallMs: Double,
        duplicateOrMissingEvents: Bool
    ) -> Bool {
        let fractionFloor = Int64(Double(appFootprintBytes) * minSaveFractionOfAppFootprint)
        let threshold = max(Int64(minSaveBytes), fractionFloor)
        guard savedBytes >= threshold else { return false }
        guard revealP95Ms <= revealP95BudgetMs else { return false }
        guard revealP99Ms <= revealP99BudgetMs else { return false }
        guard mainActorStallMs < mainActorStallBudgetMs else { return false }
        guard !duplicateOrMissingEvents else { return false }
        return true
    }

    public static func didBecomeHidden(
        session: AgentVisibilitySession,
        checkpoint: AgentPresentationCheckpoint
    ) -> AgentVisibilitySession {
        var next = session
        next.state = .hidden
        next.generation &+= 1
        next.checkpoint = checkpoint
        next.retainsCompactDirtyOnly = true
        return next
    }

    public static func beginReveal(session: AgentVisibilitySession) -> AgentVisibilitySession {
        var next = session
        next.state = .restoring
        next.generation &+= 1
        return next
    }

    public static func completeReveal(
        session: AgentVisibilitySession,
        expectedGeneration: UInt64,
        appliedThroughSequence: Int64
    ) -> AgentVisibilitySession? {
        guard session.generation == expectedGeneration else { return nil }
        // Must still be restoring; duplicate completion after visible is rejected.
        guard session.state == .restoring else { return nil }
        // Monotonic catch-up through durable checkpoint and prior applied watermark.
        let floor = max(
            session.checkpoint.durableSequence,
            session.checkpoint.lastAppliedDurableSequence
        )
        guard appliedThroughSequence >= floor else { return nil }
        var next = session
        next.state = .visible
        next.retainsCompactDirtyOnly = false
        next.checkpoint.lastAppliedDurableSequence = appliedThroughSequence
        return next
    }

    /// Explicit product decision: no host-wide Agent LRU until residual breach.
    public static let globalAgentLRUEnabled = false
}

/// S-F4c: the cold form of a hidden Agent App tab's timeline. A hidden tab
/// whose thread has no live run gives up the in-memory tree for this
/// LZFSE-compressed Codable snapshot. `AssistantTimelineState` round-trips
/// exactly through Codable (location maps are rebuilt on decode and excluded
/// from equality), so reveal restores the same timeline, not a re-derived one.
public enum AgentColdTimelineArchive {
    public static func archive(_ timeline: AssistantTimelineState) throws -> Data {
        let encoded = try JSONEncoder().encode(timeline)
        return try (encoded as NSData).compressed(using: .lzfse) as Data
    }

    public static func restore(_ archive: Data) throws -> AssistantTimelineState {
        let encoded = try (archive as NSData).decompressed(using: .lzfse) as Data
        return try JSONDecoder().decode(AssistantTimelineState.self, from: encoded)
    }
}
