import AppKit
import XCTest
@testable import AppShell

final class FilesEditorBracketTests: XCTestCase {
    private func pair(_ text: String, caret: Int) -> (Int, Int)? {
        EditorBracketMatcher.pair(in: text as NSString, caret: caret).map { ($0.0.location, $0.1.location) }
    }

    func test_pairsNestedBracketsFromEitherSide() {
        let text = "f(a[1], {b})"
        XCTAssertEqual(pair(text, caret: 2)?.1, 11, "caret after '(' pairs with the final ')'")
        XCTAssertEqual(pair(text, caret: 12)?.1, 1, "caret after ')' pairs back to '('")
        XCTAssertEqual(pair(text, caret: 4)?.1, 5, "'[' pairs with ']' not with the outer ')'")
    }

    func test_ignoresBracketsInStringsAndComments() {
        let text = "call(\")\" /* ) */ // )\n)"
        XCTAssertEqual(pair(text, caret: 5)?.1, text.utf16.count - 1,
                       "quoted and commented ')' must not close the call")
    }

    func test_unmatchedBracketHasNoPair() {
        XCTAssertNil(pair("(abc", caret: 1))
        XCTAssertNil(pair("abc", caret: 1))
    }

    func test_scanIsBoundedOnHugeDocuments() {
        let text = "(" + String(repeating: "x", count: EditorBracketMatcher.scanLimit + 10) + ")"
        XCTAssertNil(pair(text, caret: 1), "partner beyond the scan cap is treated as unmatched")
    }
}
