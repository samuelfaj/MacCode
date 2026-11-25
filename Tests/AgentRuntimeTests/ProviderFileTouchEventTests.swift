import XCTest
@testable import AgentRuntime
import CoreModel

/// The Claude and Distill parsers must hand the host the files each tool call edits, as a
/// host-only envelope that the coordinator consumes before anything is persisted.
final class ProviderFileTouchEventTests: XCTestCase {
    private func touches(_ events: [AssistantEvent]) -> [ProviderFileTouch] {
        events.flatMap { event -> [ProviderFileTouch] in
            if case .providerRuntime(let runtime) = event { return ProviderFileTouchParser.touches(in: runtime) ?? [] }
            return []
        }
    }

    func test_claudeStreamedEditReportsItsFileOnceTheInputIsComplete() {
        let parser = ClaudeParser()
        _ = parser.parseLine(#"{"type":"message_start","message":{"id":"m1"}}"#)
        let start = parser.parseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu1","name":"Edit","input":{}}}"#)
        XCTAssertEqual(touches(start), [], "the input is not known until its JSON finished streaming")
        _ = parser.parseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"file_path\":\"/r/a.swift\","}}"#)
        _ = parser.parseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"old_string\":\"x\",\"new_string\":\"y\"}"}}"#)
        let stop = parser.parseLine(#"{"type":"content_block_stop","index":0}"#)
        XCTAssertEqual(touches(stop), [ProviderFileTouch(path: "/r/a.swift", kind: .edit)])
    }

    func test_claudeWholeMessageWriteReportsItsFileAndReadReportsNone() {
        let parser = ClaudeParser()
        let events = parser.parseLine(#"{"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"tu2","name":"Write","input":{"file_path":"/r/new.swift","content":"x"}},{"type":"tool_use","id":"tu3","name":"Read","input":{"file_path":"/r/read.swift"}}]}}"#)
        XCTAssertEqual(touches(events), [ProviderFileTouch(path: "/r/new.swift", kind: .write)])
    }

    func test_distillToolCallReportsEditKindsFromLocationsAndIgnoresReads() {
        let mapper = DistillACPEventMapper(sessionId: "s")
        _ = mapper.beginTurn()
        let edit = mapper.consumeSessionUpdate([
            "sessionUpdate": "tool_call", "toolCallId": "e1", "title": "Edit a.swift", "kind": "edit",
            "locations": [["path": "/r/a.swift"]], "rawInput": ["file_path": "/r/a.swift"]
        ])
        XCTAssertEqual(touches(edit), [ProviderFileTouch(path: "/r/a.swift", kind: .edit)])
        let read = mapper.consumeSessionUpdate([
            "sessionUpdate": "tool_call", "toolCallId": "r1", "title": "Read b.swift", "kind": "read",
            "locations": [["path": "/r/b.swift"]]
        ])
        XCTAssertEqual(touches(read), [])
        let late = mapper.consumeSessionUpdate([
            "sessionUpdate": "tool_call_update", "toolCallId": "e2", "kind": "delete", "status": "completed",
            "locations": [["path": "/r/gone.swift"]]
        ])
        XCTAssertEqual(touches(late), [ProviderFileTouch(path: "/r/gone.swift", kind: .delete)],
                       "an update that first carries the locations still reports them")
    }

    func test_transcriptOnlyMapperEmitsNoTouchEnvelopes() {
        let mapper = DistillACPEventMapper(sessionId: "s")
        mapper.emitsFileTouches = false
        _ = mapper.beginTurn()
        let edit = mapper.consumeSessionUpdate([
            "sessionUpdate": "tool_call", "toolCallId": "e1", "kind": "edit", "locations": [["path": "/r/a.swift"]]
        ])
        XCTAssertEqual(touches(edit), [], "a read-only subagent transcript must not feed its ring of runtime events")
    }
}
