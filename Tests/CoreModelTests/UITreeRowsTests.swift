import XCTest
@testable import CoreModel

final class UITreeRowsTests: XCTestCase {
    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func node(_ id: Int, _ role: String, title: String? = nil, value: String? = nil, description: String? = nil,
                      actions: [String] = [], _ children: [[String: Any]] = []) -> [String: Any] {
        var object: [String: Any] = ["id": "ax_\(id)", "role": role]
        if let title { object["title"] = title }
        if let value { object["value"] = value }
        if let description { object["description"] = description }
        if !actions.isEmpty { object["actions"] = actions }
        if !children.isEmpty { object["children"] = children }
        return object
    }

    private var window: [String: Any] {
        node(0, "AXWindow", title: "Apps", [
            node(1, "AXGroup", [
                node(2, "AXButton", title: "Create New App", actions: ["AXPress", "AXShowMenu"], [node(3, "AXStaticText", value: "Create New App")]),
                node(4, "AXTextField", value: "https://api.slack.com/apps", description: "Address and search bar"),
            ]),
            node(5, "AXGroup", title: "Your Apps", [node(6, "AXLink", title: "Bot", actions: ["AXPress"])]),
        ])
    }

    func testRowsKeepTheIdsAndDropWhatSaysNothing() throws {
        // The id must be the one click_element accepts, so collapsing layout wrappers and echoed
        // text may shorten the list but never renumber it.
        let rows = try XCTUnwrap(UITreeRows.render(tree: try json(window)))
        XCTAssertEqual(rows, """
        - [ax_0] AXWindow "Apps"
          - [ax_2] AXButton "Create New App" [Press]
          - [ax_4] AXTextField (Address and search bar) = "https://api.slack.com/apps"
          - [ax_5] AXGroup "Your Apps"
            - [ax_6] AXLink "Bot" [Press]
        """)
    }

    func testQueryReturnsOnlyMatchesWithTheirAncestors() throws {
        // A Chrome window has hundreds of rows; asking for the one control is what keeps a
        // session from losing its context to tree dumps.
        let rows = try XCTUnwrap(UITreeRows.render(tree: try json(window), query: "ADDRESS | bot"))
        XCTAssertEqual(rows, """
        - [ax_0] AXWindow "Apps"
          - [ax_4] AXTextField (Address and search bar) = "https://api.slack.com/apps"
          - [ax_5] AXGroup "Your Apps"
            - [ax_6] AXLink "Bot" [Press]
        """)
        XCTAssertTrue(try XCTUnwrap(UITreeRows.render(tree: try json(window), query: "nothing-here")).contains("no element matches"))
    }

    func testALongTreeIsCutWithACountAndAWayForward() throws {
        let many = node(0, "AXWindow", title: "List", (1...40).map { node($0, "AXButton", title: "Item \($0)") })
        let rows = try XCTUnwrap(UITreeRows.render(tree: try json(many), maxElements: 10)).components(separatedBy: "\n")
        XCTAssertEqual(rows.count, 11)
        XCTAssertTrue(rows[9].contains("[ax_9]"))
        XCTAssertTrue(rows[10].contains("31 more element(s) not shown") && rows[10].contains("query"), rows[10])
    }

    func testOnlyTheTreePartOfAResultIsRewritten() throws {
        // The observation line carries the state token and the ocr line carries evidence; both
        // are parsed by callers and must pass through untouched. Anything that is not the
        // serialized tree is left alone too.
        let text = "{\"state_token\":\"t\"}\nui_tree: \(try json(window))\nocr: [{\"text\":\"x\"}]"
        let rewritten = UITreeRows.rewrite(result: text, maxElements: 250, query: "bot")
        XCTAssertTrue(rewritten.hasPrefix("{\"state_token\":\"t\"}\nui_tree:\n- [ax_0] AXWindow"))
        XCTAssertTrue(rewritten.hasSuffix("\nocr: [{\"text\":\"x\"}]"))
        XCTAssertFalse(rewritten.contains("Create New App"))
        XCTAssertEqual(UITreeRows.rewrite(result: "{}\nui_tree: tree", maxElements: 250, query: nil), "{}\nui_tree: tree")
        XCTAssertEqual(UITreeRows.rewrite(result: "no tree here", maxElements: 250, query: nil), "no tree here")
    }
}
