import XCTest
@testable import CoreModel

/// Concurrent-work awareness needs the exact files each run edits. Reads must never count,
/// or every run that merely reads a file would block its neighbours.
final class ProviderFileTouchParserTests: XCTestCase {
    func test_claudeEditingToolsTouchTheirFileAndReadingToolsTouchNothing() {
        XCTAssertEqual(ProviderFileTouchParser.claude(toolName: "Edit", input: ["file_path": "/r/a.swift"]),
                       [ProviderFileTouch(path: "/r/a.swift", kind: .edit)])
        XCTAssertEqual(ProviderFileTouchParser.claude(toolName: "MultiEdit", input: ["file_path": "/r/b.swift", "edits": []]),
                       [ProviderFileTouch(path: "/r/b.swift", kind: .edit)])
        XCTAssertEqual(ProviderFileTouchParser.claude(toolName: "Write", input: ["file_path": "/r/c.swift"]),
                       [ProviderFileTouch(path: "/r/c.swift", kind: .write)])
        XCTAssertEqual(ProviderFileTouchParser.claude(toolName: "NotebookEdit", input: ["notebook_path": "/r/n.ipynb"]),
                       [ProviderFileTouch(path: "/r/n.ipynb", kind: .edit)])
        for tool in ["Read", "Grep", "Glob", "Bash", "WebFetch", "mcp__x__edit_thing"] {
            XCTAssertEqual(ProviderFileTouchParser.claude(toolName: tool, input: ["file_path": "/r/a.swift"]), [], tool)
        }
        XCTAssertEqual(ProviderFileTouchParser.claude(toolName: "Edit", input: ["file_path": "  "]), [])
        XCTAssertEqual(ProviderFileTouchParser.claude(toolName: "Edit", input: nil), [])
    }

    func test_distillACPCountsOnlyEditKindsAndPrefersLocations() {
        func call(_ kind: String, locations: [String]? = nil, rawInput: [String: Any]? = nil, status: String? = nil) -> [String: Any] {
            var update: [String: Any] = ["sessionUpdate": "tool_call", "toolCallId": "t", "kind": kind]
            if let locations { update["locations"] = locations.map { ["path": $0] } }
            if let rawInput { update["rawInput"] = rawInput }
            if let status { update["status"] = status }
            return update
        }
        XCTAssertEqual(ProviderFileTouchParser.distillACP(call("edit", locations: ["/r/a", "/r/b", "/r/a"])),
                       [ProviderFileTouch(path: "/r/a", kind: .edit), ProviderFileTouch(path: "/r/b", kind: .edit)])
        XCTAssertEqual(ProviderFileTouchParser.distillACP(call("delete", locations: ["/r/gone"])),
                       [ProviderFileTouch(path: "/r/gone", kind: .delete)])
        XCTAssertEqual(ProviderFileTouchParser.distillACP(call("move", locations: ["/r/new"])),
                       [ProviderFileTouch(path: "/r/new", kind: .move)])
        XCTAssertEqual(ProviderFileTouchParser.distillACP(call("write", rawInput: ["file_path": "/r/w"])),
                       [ProviderFileTouch(path: "/r/w", kind: .write)], "falls back to the raw input path without locations")
        for kind in ["read", "search", "execute", "fetch", "think", "other"] {
            XCTAssertEqual(ProviderFileTouchParser.distillACP(call(kind, locations: ["/r/a"])), [], kind)
        }
        XCTAssertEqual(ProviderFileTouchParser.distillACP(call("edit", locations: ["/r/a"], status: "failed")), [],
                       "a failed edit changed nothing")
        XCTAssertEqual(ProviderFileTouchParser.distillACP(["sessionUpdate": "tool_call", "toolCallId": "t"]), [])
    }

    func test_codexFileChangeMapsAddUpdateDeleteAndMove() {
        let item: [String: Any] = [
            "type": "fileChange", "status": "completed",
            "changes": [
                ["path": "/r/new.txt", "kind": ["type": "add"]],
                ["path": "/r/old.txt", "kind": ["type": "update", "move_path": NSNull()]],
                ["path": "/r/del.txt", "kind": ["type": "delete"]],
                ["path": "/r/from.txt", "kind": ["type": "update", "move_path": "/r/to.txt"]],
            ],
        ]
        XCTAssertEqual(ProviderFileTouchParser.codex(item: item), [
            ProviderFileTouch(path: "/r/new.txt", kind: .write),
            ProviderFileTouch(path: "/r/old.txt", kind: .edit),
            ProviderFileTouch(path: "/r/del.txt", kind: .delete),
            ProviderFileTouch(path: "/r/from.txt", kind: .move),
            ProviderFileTouch(path: "/r/to.txt", kind: .move),
        ])
        XCTAssertEqual(ProviderFileTouchParser.codex(item: ["type": "file_change", "changes": [["path": "/r/a", "kind": "add"]]]),
                       [ProviderFileTouch(path: "/r/a", kind: .write)], "snake_case type and a plain string kind")
        XCTAssertEqual(ProviderFileTouchParser.codex(item: ["type": "commandExecution", "command": "rm x"]), [])
        XCTAssertEqual(ProviderFileTouchParser.codex(item: ["type": "fileChange", "status": "declined", "changes": [["path": "/r/a"]]]), [],
                       "a declined patch changed nothing")
    }

    func test_envelopeRoundTripsAndOnlyMatchesItself() throws {
        let touches = [ProviderFileTouch(path: "/r/a", kind: .edit)]
        let event = try XCTUnwrap(ProviderFileTouchParser.runtimeEvent(provider: .claude, touches: touches, itemId: "i", receivedAtMs: 1))
        guard case .providerRuntime(let runtime) = event else { return XCTFail("expected a runtime event") }
        XCTAssertEqual(ProviderFileTouchParser.touches(in: runtime), touches)
        XCTAssertNil(ProviderFileTouchParser.runtimeEvent(provider: .claude, touches: [], receivedAtMs: 1))
        let other = ProviderRuntimeEvent(provider: .claude, source: "claude.agent-sdk", method: "runtime.handshake", payloadJSON: "{}", receivedAtMs: 1)
        XCTAssertNil(ProviderFileTouchParser.touches(in: other))
    }
}

final class RunFileTouchPathsTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "rc2-touchpaths-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func test_relativizeResolvesSymlinksNewFilesAndRejectsOutsidePaths() throws {
        let real = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        XCTAssertEqual(RunFileTouchPaths.relativize(path: root + "/sub/a.swift", repoRoot: real, cwd: real), "sub/a.swift",
                       "a /var spelling must match git's /private/var toplevel")
        XCTAssertEqual(RunFileTouchPaths.relativize(path: root + "/sub/not-yet/created.swift", repoRoot: real, cwd: real), "sub/not-yet/created.swift")
        XCTAssertEqual(RunFileTouchPaths.relativize(path: "sub/rel.swift", repoRoot: real, cwd: real), "sub/rel.swift")
        XCTAssertEqual(RunFileTouchPaths.relativize(path: "rel.swift", repoRoot: real, cwd: real + "/sub"), "sub/rel.swift")
        XCTAssertNil(RunFileTouchPaths.relativize(path: "/etc/hosts", repoRoot: real, cwd: real))
        XCTAssertNil(RunFileTouchPaths.relativize(path: real + "-sibling/a", repoRoot: real, cwd: real), "a sibling directory with the same prefix is outside")
        XCTAssertNil(RunFileTouchPaths.relativize(path: real, repoRoot: real, cwd: real), "the root itself is not a file")
    }

    func test_narrowKeepsWholeTreeWhenNothingWasTouchedAndMatchesCwdRelativeUntracked() {
        let changes = ["a.swift", "b.swift", "pkg/c.swift"]
        XCTAssertEqual(RunFileTouchPaths.narrow(changes, path: { $0 }, touched: nil, cwdPrefix: ""), changes)
        XCTAssertEqual(RunFileTouchPaths.narrow(changes, path: { $0 }, touched: [], cwdPrefix: ""), changes)
        XCTAssertEqual(RunFileTouchPaths.narrow(changes, path: { $0 }, touched: ["b.swift"], cwdPrefix: ""), ["b.swift"])
        XCTAssertEqual(RunFileTouchPaths.narrow(changes, path: { $0 }, touched: ["other.swift"], cwdPrefix: ""), [],
                       "touched files that left no diff must not drag the whole tree back in")
        XCTAssertEqual(RunFileTouchPaths.narrow(["c.swift"], path: { $0 }, touched: ["pkg/c.swift"], cwdPrefix: "pkg/"), ["c.swift"],
                       "untracked files are listed relative to the run's cwd")
    }

    func test_cwdPrefix() {
        let real = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        XCTAssertEqual(RunFileTouchPaths.cwdPrefix(cwd: real, repoRoot: real), "")
        XCTAssertEqual(RunFileTouchPaths.cwdPrefix(cwd: real + "/sub", repoRoot: real), "sub/")
    }

    func test_objectiveFallsBackToFirstRequestForPlaceholderTitlesAndCaps160() {
        XCTAssertEqual(RunObjective.make(title: "Fix login", firstUserMessage: "ignored"), "Fix login")
        XCTAssertEqual(RunObjective.make(title: "New thread", firstUserMessage: "Please fix\nthe   login"), "Please fix the login")
        XCTAssertEqual(RunObjective.make(title: "", firstUserMessage: nil), "")
        XCTAssertEqual(RunObjective.make(title: "New thread", firstUserMessage: String(repeating: "x", count: 500)).count, 160)
    }
}
