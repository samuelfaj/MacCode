import XCTest
import CoreModel

final class ProviderRuntimeLiveParityTests: XCTestCase {
    private func event(method: String, payload: String) -> ProviderRuntimeEvent {
        ProviderRuntimeEvent(provider: .distill, source: "acp", method: method, payloadJSON: payload, receivedAtMs: 0)
    }

    func test_toolCallArgumentChunkIsRecognizedAndOtherNotificationsAreNot() {
        // WHY: these chunks are dropped before persistence so they stop evicting
        // tool items from the replay window. Dropping a subagent or operation
        // update by mistake would blank the live strip instead.
        let chunk = #"{"sessionId":"s","update":{"arguments_delta":"ls","sessionUpdate":"tool_call_delta_chunk","tool_index":1}}"#
        XCTAssertTrue(event(method: "_x.ai/session_notification", payload: chunk).isToolCallArgumentChunk)
        XCTAssertTrue(event(method: "x.ai/session_notification", payload: chunk).isToolCallArgumentChunk)

        let subagent = #"{"sessionId":"s","update":{"sessionUpdate":"subagent_progress","subagent_id":"a"}}"#
        XCTAssertFalse(event(method: "_x.ai/session_notification", payload: subagent).isToolCallArgumentChunk)
        let quoted = #"{"sessionId":"s","update":{"sessionUpdate":"response_completed","text":"tool_call_delta_chunk"}}"#
        XCTAssertFalse(event(method: "_x.ai/session_notification", payload: quoted).isToolCallArgumentChunk,
                       "a body mentioning the name is not a chunk")
        XCTAssertFalse(event(method: "_remotecode/operation", payload: chunk).isToolCallArgumentChunk)
    }

    func test_liveStatusCarrierMatchesTheStripMethods() {
        XCTAssertTrue(ProviderRuntimeEvent.isLiveStatusCarrier(method: "_remotecode/operation"))
        XCTAssertTrue(ProviderRuntimeEvent.isLiveStatusCarrier(method: "remotecode/guest_stage"))
        XCTAssertTrue(ProviderRuntimeEvent.isLiveStatusCarrier(method: "_x.ai/session_notification"))
        XCTAssertTrue(ProviderRuntimeEvent.isLiveStatusCarrier(method: "subagent_spawned"))
        XCTAssertFalse(ProviderRuntimeEvent.isLiveStatusCarrier(method: "available_commands_update"))
        XCTAssertFalse(ProviderRuntimeEvent.isLiveStatusCarrier(method: "_x.ai/mcp/server_status"))
    }
}
