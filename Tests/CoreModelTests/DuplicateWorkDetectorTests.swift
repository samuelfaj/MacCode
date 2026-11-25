import XCTest
@testable import CoreModel

/// A warning that fires on every shared noun trains users to ignore it, and one that never fires
/// lets two agents redo the same job. These pin the threshold on both sides.
final class DuplicateWorkDetectorTests: XCTestCase {
    func test_sameRequestWorded_differently_inEnglishMatches() {
        XCTAssertTrue(DuplicateWorkDetector.isSimilar(
            "Please fix the login redirect bug in the auth service",
            "Fix login redirect bug in auth service"
        ))
    }

    func test_portugueseAndSpanishStopwordsAreIgnored() {
        XCTAssertTrue(DuplicateWorkDetector.isSimilar(
            "Preciso que você corrija o bug do redirecionamento de login no serviço de autenticação",
            "corrija bug redirecionamento login serviço autenticação por favor"
        ))
        XCTAssertTrue(DuplicateWorkDetector.isSimilar(
            "Necesito que arregles el error de redirección del login en el servicio de autenticación",
            "arregles error redirección login servicio autenticación"
        ))
    }

    func test_accentsCaseAndPluralsDoNotSplitAWord() {
        XCTAssertEqual(DuplicateWorkDetector.words("Autenticação TESTES"), DuplicateWorkDetector.words("autenticacao teste"))
    }

    func test_differentJobsInTheSameAreaDoNotMatch() {
        XCTAssertFalse(DuplicateWorkDetector.isSimilar(
            "Fix the login redirect bug in the auth service",
            "Add rate limiting to the auth service token endpoint"
        ))
    }

    func test_oneSharedNounIsNotEnough() {
        XCTAssertNil(DuplicateWorkDetector.score("fix bug", "fix payment bug"), "two of three words overlap, but the shared-word floor keeps short requests from matching")
    }

    func test_identicalShortRequestsStillMatch() {
        XCTAssertEqual(DuplicateWorkDetector.score("fix login", "Fix login!"), 1)
    }

    func test_thresholdIsInclusiveAtSixTenths() {
        let base = "alpha beta gamma delta epsilon zeta"
        XCTAssertEqual(DuplicateWorkDetector.score(base + " eta", base + " theta"), 0.75, "6 shared of 8")
        XCTAssertEqual(DuplicateWorkDetector.score("alpha beta gamma delta", "alpha beta gamma epsilon"), 0.6, "3 shared of 5 is exactly the threshold")
        XCTAssertNil(DuplicateWorkDetector.score("alpha beta gamma delta epsilon", "alpha beta gamma zeta eta"), "3 shared of 7")
        XCTAssertNil(DuplicateWorkDetector.score("alpha beta gamma one two three", "alpha beta gamma four five six"), "3 shared of 9")
    }

    func test_candidateTitleAloneCanMatchALongRequest() {
        let score = DuplicateWorkDetector.score(
            request: "Fix login redirect bug",
            candidateTitle: "Fix login redirect bug",
            candidateRequest: "Users land on a blank page after signing in through the SSO provider, please investigate the whole flow and write regression tests"
        )
        XCTAssertEqual(score, 1, "a generated title is short; the long first request must not drown it")
    }

    func test_emptyAndStopwordOnlyTextNeverMatches() {
        XCTAssertNil(DuplicateWorkDetector.score("", ""))
        XCTAssertNil(DuplicateWorkDetector.score("please do the", "the please do"))
    }
}
