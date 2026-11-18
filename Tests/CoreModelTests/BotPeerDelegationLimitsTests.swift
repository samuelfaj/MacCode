import XCTest
@testable import CoreModel

final class BotPeerDelegationLimitsTests: XCTestCase {
    /// The owner chose these on 2026-11-18 after a 15-minute wall clock killed a
    /// Bot that was still creating Trello cards: guard against loops, not volume.
    func test_standardLimitsGuardLoopsWithoutCappingLiveWork() {
        let limits = BotPeerDelegation.Limits.standard
        XCTAssertEqual(limits.maxAdmissionsPerTask, 50, "12 blocked ordinary batches such as 11 cards plus a read")
        XCTAssertEqual(limits.maxConsecutiveFailures, 3)
        XCTAssertEqual(limits.maxIdenticalAsks, 3)
        XCTAssertEqual(limits.idleTimeout, BotPeerDelegation.peerConsultationTimeout,
                       "the host watchdog and the socket keepalive must agree on what silence means")
        XCTAssertEqual(limits.runCeiling, 2 * 60 * 60)
        XCTAssertGreaterThan(limits.runCeiling, 15 * 60, "a live Bot must outlast the old 15-minute task clock")
    }

    /// Retry loops rarely resend byte-identical text; whitespace and case must
    /// not let the same request slip past the repetition guard.
    func test_promptNormalizationIgnoresWhitespaceAndCaseOnly() {
        XCTAssertEqual(
            BotPeerDelegation.normalizedPrompt("  Crie os 11  cartões\nno Backlog "),
            BotPeerDelegation.normalizedPrompt("crie os 11 cartões no backlog")
        )
        XCTAssertNotEqual(
            BotPeerDelegation.normalizedPrompt("Crie o cartão 1"),
            BotPeerDelegation.normalizedPrompt("Crie o cartão 2"),
            "different work must never count as a repetition"
        )
    }
}
