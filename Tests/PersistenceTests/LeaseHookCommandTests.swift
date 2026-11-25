import XCTest
@testable import Persistence

final class LeaseHookCommandTests: XCTestCase {
    private func payload(_ tool: String, _ input: [String: Any], cwd: String = "/repo") -> Data {
        try! JSONSerialization.data(withJSONObject: ["tool_name": tool, "tool_input": input, "cwd": cwd])
    }

    func test_editToolsYieldTheirFilePathAndReadsYieldNothing() throws {
        for tool in ["write", "search_replace", "edit", "hashline_edit"] {
            let object = try JSONSerialization.jsonObject(with: payload(tool, ["file_path": "/repo/a.swift", "content": "x"])) as! [String: Any]
            XCTAssertEqual(LeaseHookCommand.request(fromHookInput: object)?.paths, ["/repo/a.swift"], tool)
        }
        let read = try JSONSerialization.jsonObject(with: payload("read_file", [:])) as! [String: Any]
        XCTAssertNil(LeaseHookCommand.request(fromHookInput: read), "a tool without a path has nothing to lease")
    }

    func test_applyPatchYieldsEveryFileTheCodexPatchTouches() throws {
        let patch = """
        *** Begin Patch
        *** Update File: src/a.swift
        @@
        -x
        +y
        *** Add File: src/new.swift
        +z
        *** Delete File: old.swift
        *** Update File: src/a.swift
        *** Move to: src/b.swift
        *** End Patch
        """
        let object = try JSONSerialization.jsonObject(with: payload("apply_patch", ["patch": patch])) as! [String: Any]
        XCTAssertEqual(LeaseHookCommand.request(fromHookInput: object)?.paths, ["src/a.swift", "src/new.swift", "old.swift", "src/b.swift"])
    }

    func test_denyBecomesAHookDecisionAndWarnOnlyAddsContext() throws {
        let deny = try XCTUnwrap(LeaseHookCommand.hookOutput(verdict: "deny", message: "held by Y"))
        let denyObject = try JSONSerialization.jsonObject(with: Data(deny.utf8)) as! [String: Any]
        let denySpecific = denyObject["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(denySpecific["permissionDecision"] as? String, "deny")
        XCTAssertEqual(denySpecific["permissionDecisionReason"] as? String, "held by Y")

        let warn = try XCTUnwrap(LeaseHookCommand.hookOutput(verdict: "warn", message: "held by Y"))
        let warnSpecific = (try JSONSerialization.jsonObject(with: Data(warn.utf8)) as! [String: Any])["hookSpecificOutput"] as! [String: Any]
        XCTAssertNil(warnSpecific["permissionDecision"], "a warning must not bypass or pre-empt the user's own permission prompt")
        XCTAssertEqual(warnSpecific["additionalContext"] as? String, "held by Y")

        XCTAssertNil(LeaseHookCommand.hookOutput(verdict: "allow", message: nil))
        XCTAssertNil(LeaseHookCommand.hookOutput(verdict: "deny", message: "  "), "no reason, no decision")
    }

    func test_theHookSendsOnlyTheEditedPathsAndFailsOpenWhenMacCodeIsUnreachable() {
        var sent: (String, [String: Any])?
        let output = LeaseHookCommand.run(stdin: payload("write", ["file_path": "/repo/a.swift"])) { method, arguments in
            sent = (method, arguments)
            return ["verdict": "deny", "message": "busy"]
        }
        XCTAssertEqual(sent?.0, "bot.peer.lease_check")
        XCTAssertEqual(sent?.1["paths"] as? [String], ["/repo/a.swift"])
        XCTAssertEqual(sent?.1["cwd"] as? String, "/repo")
        XCTAssertTrue(output?.contains("\"deny\"") == true)

        struct Down: Error {}
        XCTAssertNil(LeaseHookCommand.run(stdin: payload("write", ["file_path": "/repo/a.swift"])) { _, _ in throw Down() },
                     "an unreachable app must never block an edit")
        XCTAssertNil(LeaseHookCommand.run(stdin: Data("not json".utf8)) { _, _ in XCTFail("no call without a request"); return [:] })
        XCTAssertNil(LeaseHookCommand.run(stdin: payload("read_file", [:])) { _, _ in XCTFail("reads are never checked"); return [:] })
    }
}
