import XCTest
@testable import CoreModel

/// Roster subtitles, `titio_inbox.last_preview`, banners and the pet bubble
/// are one plain line. The owner saw raw `**` in the Titio roster row: any
/// Markdown that reaches a preview is a user-visible bug.
final class MarkdownPlainTextTests: XCTestCase {
    func test_contractVectorM10() {
        // WHY: the shared Mac↔iOS vector; both platforms must produce it.
        XCTAssertEqual(
            MarkdownPlainText.firstLine("Ó, a tarefa **X** — [PR](https://a.b) `code`\n2nd"),
            "Ó, a tarefa X — PR code"
        )
    }

    func test_theOwnersNoticeLosesItsMarkupAndKeepsTheLinkText() {
        // WHY: the exact message from the complaint: bold around a link must
        // read as the link's words, never as `**[Draft PR`.
        let text = "Implemented DEV-5277. **[Draft PR #3109](https://github.com/o/r/pull/3109)** is up."
        XCTAssertEqual(MarkdownPlainText.firstLine(text), "Implemented DEV-5277. Draft PR #3109 is up.")
    }

    func test_blockMarkersFencesRulesAndCardsAreSkipped() {
        // WHY: the first *visible* line is the preview; a heading mark, a
        // quote, a list bullet, a rule or Titio's own ```choices card is not.
        XCTAssertEqual(MarkdownPlainText.firstLine("\n\n# Title\nbody"), "Title")
        XCTAssertEqual(MarkdownPlainText.firstLine("> > quoted *text*"), "quoted text")
        XCTAssertEqual(MarkdownPlainText.firstLine("- [x] done item"), "done item")
        XCTAssertEqual(MarkdownPlainText.firstLine("3. third"), "third")
        XCTAssertEqual(MarkdownPlainText.firstLine("---\n***\nafter rules"), "after rules")
        XCTAssertEqual(MarkdownPlainText.firstLine("```choices\n{\"options\":[\"a\",\"b\"]}\n```\nreal text"), "real text")
        XCTAssertEqual(MarkdownPlainText.firstLine("```swift\nlet a = 1\n```"), "let a = 1")
        XCTAssertEqual(MarkdownPlainText.firstLine("| a | `x|y` |\n|---|---|"), "a · x|y")
        XCTAssertEqual(MarkdownPlainText.firstLine("Line<br>break and <b>bold</b>"), "Line break and bold")
        XCTAssertEqual(MarkdownPlainText.firstLine("see <https://ex.com/a> ~~old~~ __new__"), "see https://ex.com/a old new")
        XCTAssertEqual(MarkdownPlainText.firstLine("![shot](/tmp/a.png) caption"), "shot caption")
        XCTAssertEqual(MarkdownPlainText.firstLine("[doc](https://ex.com/(x)/y) ok"), "doc ok")
    }

    func test_identifiersAndEscapesSurvive() {
        // WHY: stripping emphasis must not eat snake_case names or arithmetic.
        XCTAssertEqual(MarkdownPlainText.firstLine("run my_test_name with 2 * 3 * 4"), "run my_test_name with 2 * 3 * 4")
        XCTAssertEqual(MarkdownPlainText.firstLine(#"price \*not italic\*"#), "price *not italic*")
        XCTAssertEqual(MarkdownPlainText.firstLine("`**literal**` stays"), "**literal** stays", "code text is verbatim")
    }

    func test_hostMarkerIsNeverThePreview() {
        // WHY: the owner got a push whose whole body was "[[RC_AWAITING]]";
        // the reader must see the agent's words, never the machine marker.
        XCTAssertEqual(MarkdownPlainText.firstLine("[[RC_AWAITING]]\nEsperando o build terminar."), "Esperando o build terminar.")
        XCTAssertEqual(MarkdownPlainText.firstLine("[[RC_AWAITING]] Build rodando"), "Build rodando")
        XCTAssertEqual(MarkdownPlainText.firstLine("[[RC_AWAITING]]"), "")
    }

    func test_clipAndEmpty() {
        XCTAssertEqual(MarkdownPlainText.firstLine(String(repeating: "a", count: 400), maxCharacters: 178).count, 178)
        XCTAssertEqual(MarkdownPlainText.firstLine("   \n\n  "), "")
    }
}
