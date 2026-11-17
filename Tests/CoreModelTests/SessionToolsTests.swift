import Foundation
import XCTest
@testable import CoreModel

private actor SessionReplayCalls {
    var tools: [String] = []
    func append(_ tool: String) { tools.append(tool) }
}

final class SessionToolsTests: XCTestCase {
    private func object(_ result: ComputerUseToolResult) throws -> [String: Any] {
        let text = result.content.compactMap { $0.text }.joined()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func backend() -> SessionToolsBackend {
        SessionToolsBackend(capture: { _ in
            .success(ComputerUseNativeCapture(data: Data("fake PNG".utf8).base64EncodedString(), mimeType: "image/png"))
        })
    }
    func testLifecycleAndValidation() async throws {
        let backend = backend()
        let created = await backend.invoke(name: "start_session", arguments: ["session": "one", "capture_scope": "window"])
        XCTAssertFalse(created.isError)
        let duplicate = await backend.invoke(name: "start_session", arguments: ["session": "one"])
        XCTAssertTrue(duplicate.isError)
        let invalid = await backend.invoke(name: "set_agent_cursor_theme", arguments: ["session": "one", "theme": "unknown"])
        XCTAssertTrue(invalid.isError)
        let motion = await backend.invoke(name: "set_agent_cursor_motion", arguments: ["session": "one", "duration_ms": -1])
        XCTAssertTrue(motion.isError)
        let zeroSpeed = await backend.invoke(name: "set_agent_cursor_motion", arguments: ["session": "one", "speed": 0])
        XCTAssertTrue(zeroSpeed.isError)
        let enabled = await backend.invoke(name: "set_agent_cursor_enabled", arguments: ["session": "one", "enabled": false])
        XCTAssertEqual(try object(enabled)["enabled"] as? Bool, false)
        let end = await backend.invoke(name: "end_session", arguments: ["session": "one"])
        XCTAssertFalse(end.isError)
        let missing = await backend.invoke(name: "get_session_state", arguments: ["session": "one"])
        XCTAssertTrue(missing.isError)
    }
    func testRecordingRedactsTypedContentAndSecretInputsAndSessionOwnsStop() async throws {
        let backend = backend()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await backend.invoke(name: "start_session", arguments: ["session": "one"])
        let start = await backend.invoke(name: "start_recording", arguments: ["output_dir": root.path, "session": "one", "record_video": false])
        XCTAssertFalse(start.isError)
        let args: [String: Any] = ["session": "one", "text": "typed password", "value": "field password", "prompt_text": "private prompt", "javascript": "private script", "secret": "preserve secret", "secret_inputs": ["password"], "inputs": ["password": "hidden", "username": "public"], "nested": [["secret_inputs": ["password": "hidden"], "text": "nested password", "keep": 42]]]
        let action = await backend.aroundAction(tool: "type_text", arguments: args, targetPID: 123, windowID: 456, point: nil) { ComputerUseToolResult(text: "done") }
        XCTAssertFalse(action.isError)
        let turn = root.appendingPathComponent("turn-00001")
        for file in ["action.json", "before.png", "after.png", "evidence.json"] { XCTAssertTrue(FileManager.default.fileExists(atPath: turn.appendingPathComponent(file).path)) }
        let data = try Data(contentsOf: turn.appendingPathComponent("action.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try XCTUnwrap(json["arguments"] as? [String: Any])
        for key in ["text", "value", "prompt_text", "javascript", "secret_inputs"] {
            XCTAssertEqual(stored[key] as? String, "[REDACTED]", "Recordings on disk must not leak typed passwords or private content")
        }
        XCTAssertEqual(stored["secret"] as? String, "preserve secret")
        XCTAssertEqual(stored["session"] as? String, "one")
        let inputs = try XCTUnwrap(stored["inputs"] as? [String: Any])
        XCTAssertEqual(inputs["password"] as? String, "[REDACTED]")
        XCTAssertEqual(inputs["username"] as? String, "public")
        let nested = try XCTUnwrap((stored["nested"] as? [[String: Any]])?.first)
        XCTAssertEqual(nested["secret_inputs"] as? String, "[REDACTED]")
        XCTAssertEqual(nested["text"] as? String, "[REDACTED]")
        XCTAssertEqual(nested["keep"] as? Int, 42)
        let unknown = await backend.aroundAction(tool: "click", arguments: ["session": "one"], targetPID: nil, windowID: nil, point: nil) { ComputerUseToolResult(text: "done") }
        XCTAssertFalse(unknown.isError)
        let evidence = try String(contentsOf: root.appendingPathComponent("turn-00002/evidence.json"))
        XCTAssertTrue(evidence.contains("unknown"))
        let ended = await backend.invoke(name: "end_session", arguments: ["session": "one"])
        XCTAssertFalse(ended.isError)
        let state = await backend.invoke(name: "get_recording_state", arguments: [:])
        XCTAssertEqual(try object(state)["recording"] as? Bool, false)
        let collision = await backend.invoke(name: "start_recording", arguments: ["output_dir": root.path])
        XCTAssertTrue(collision.isError)
    }
    func testReplayLexicalOrderAndDryRun() async throws {
        let backend = backend()
        let calls = SessionReplayCalls()
        backend.replayDispatcher = { tool, _ in await calls.append(tool); return ComputerUseToolResult(text: "ok") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (folder, tool) in [("turn-00002", "second"), ("turn-00001", "first")] {
            let dir = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["tool": tool, "arguments": [:]]).write(to: dir.appendingPathComponent("action.json"))
        }
        let dry = await backend.invoke(name: "replay_trajectory", arguments: ["dir": root.path, "dry_run": true])
        XCTAssertFalse(dry.isError)
        let empty = await calls.tools
        XCTAssertTrue(empty.isEmpty)
        let actions = try XCTUnwrap(try object(dry)["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.compactMap { $0["tool"] as? String }, ["first", "second"])
        let replay = await backend.invoke(name: "replay_trajectory", arguments: ["dir": root.path, "dry_run": false])
        XCTAssertFalse(replay.isError)
        let recorded = await calls.tools
        XCTAssertEqual(recorded, ["first", "second"])
    }
    func testEveryToolHasDescriptionAndSchema() throws {
        for name in SessionToolsBackend.observationTools + SessionToolsBackend.mutationTools {
            XCTAssertFalse(try XCTUnwrap(SessionToolsBackend.description(for: name)).isEmpty)
            let schema = try XCTUnwrap(SessionToolsBackend.inputSchema(for: name))
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(schema["properties"])
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: schema))
        }
        XCTAssertNil(SessionToolsBackend.inputSchema(for: "not_a_tool"))
    }
}
