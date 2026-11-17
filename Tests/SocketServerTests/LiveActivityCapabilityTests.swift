import XCTest
@testable import SocketServer

final class LiveActivityCapabilityTests: XCTestCase {
    // WHY: the phone sends its push-to-start and activity-update tokens only to a
    // Mac that advertises live_activity.protocol_version 2. Without it the Mac
    // has no token to open or update the Lock Screen card remotely, and every
    // delivery falls back to the legacy route the backend no longer serves.

    func test_publicAndAuthenticatedCapabilitiesAdvertiseProtocolVersion2() {
        let projection = DirectHTTPServer.capabilitiesProjection(loopbackOnly: false)
        let publicLiveActivity = projection.publicPayload()["live_activity"] as? [String: Any]
        XCTAssertEqual(publicLiveActivity?["protocol_version"] as? Int, 2)

        let authenticated = projection.authenticatedPayload(serverID: "host-1", bootEpoch: 42)["capabilities"] as? [String: Any]
        let authenticatedLiveActivity = authenticated?["live_activity"] as? [String: Any]
        XCTAssertEqual(authenticatedLiveActivity?["protocol_version"] as? Int, 2)
    }

    @MainActor
    func test_systemCapabilitiesAdvertisesTheSameProtocolVersion() async {
        let response = await JSONRPCDispatcher(router: FakeRouter()).dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: [:]
        ))
        XCTAssertNil(response.error)
        let liveActivity = response.result?.objectValue?["live_activity"]?.objectValue
        XCTAssertEqual(liveActivity?["protocol_version"]?.intValue, 2)
    }
}
