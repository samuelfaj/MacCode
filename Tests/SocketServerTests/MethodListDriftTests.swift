import XCTest
@testable import SocketServer
import CoreModel

/// T028 -- every method advertised in `system.capabilities` resolves to a
/// real Dispatcher case (no methodNotFound -32601).
///
/// Why this matters: the capabilities list and the dispatch switch are
/// maintained separately and can silently diverge. A client that builds UI
/// from capabilities will show a button that triggers -32601 at runtime.
@MainActor
final class MethodListDriftTests: XCTestCase {

    // All methods advertised inside the `files.methods` array of
    // system.capabilities (Dispatcher.swift:361-376).
    private static let advertisedFileMethods: [String] = [
        "fs.workspace.list",
        "fs.workspace.read",
        "fs.workspace.preview_url",
        "fs.workspace.create_file",
        "fs.workspace.rename",
        "fs.workspace.delete",
        "files.tab.open",
        "files.tab.split",
        "files.state.get",
        "files.state.update",
        "files.edit.session",
        "files.ai.complete",
        "files.edit.open",
        "files.edit.apply_patch",
        "files.edit.save",
        "files.edit.discard",
        "files.edit.close"
    ]

    // All methods advertised inside the `ssh.methods` array of
    // system.capabilities (Dispatcher.swift:338-348).
    private static let advertisedSSHMethods: [String] = [
        "ssh.host.list",
        "ssh.host.upsert",
        "ssh.host.delete",
        "ssh.connect",
        "ssh.disconnect",
        "ssh.transfer.upload",
        "ssh.transfer.download",
        "ssh.files.local.list",
        "ssh.files.remote.list"
    ]

    // MARK: - Helpers

    /// Returns the response error code (or nil) for a bare method call.
    private func errorCode(for method: String, dispatcher: JSONRPCDispatcher) async -> Int? {
        let req = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: method, params: [:])
        let resp = await dispatcher.dispatch(req)
        return resp.error?.code
    }

    // MARK: - Files methods

    /// Every method in the files capabilities block must not return -32601
    /// (methodNotFound). Some will return -32602 (invalidParams) because we
    /// send no params -- that is intentional and proves the switch arm exists.
    func test_capabilitiesFileMethods_allResolveToDispatcherCase() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        for method in Self.advertisedFileMethods {
            let code = await errorCode(for: method, dispatcher: d)
            XCTAssertNotEqual(code, -32601,
                              "'\(method)' is advertised in system.capabilities files.methods but returns -32601 (methodNotFound) -- the capabilities list and dispatch switch have drifted")
        }
    }

    // MARK: - SSH methods

    func test_capabilitiesSSHMethods_allResolveToDispatcherCase() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        for method in Self.advertisedSSHMethods {
            let code = await errorCode(for: method, dispatcher: d)
            XCTAssertNotEqual(code, -32601,
                              "'\(method)' is advertised in system.capabilities ssh.methods but returns -32601 (methodNotFound) -- the capabilities list and dispatch switch have drifted")
        }
    }

    // MARK: - Round-trip: capabilities endpoint itself matches the static lists

    /// The system.capabilities response must contain exactly the methods
    /// declared in our static lists above. If the Dispatcher adds a new method
    /// to the switch but forgets to add it to the capabilities payload (or
    /// vice versa), this test fails -- the authoritative set is the static list
    /// in this file, which the integration-team owns.
    func test_capabilitiesResponse_filesMethodsMatchStaticList() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil))

        guard case .object(let body) = resp.result,
              case .object(let filesObj) = body["files"],
              case .array(let methods) = filesObj["methods"] else {
            return XCTFail("system.capabilities must include files.methods array for iOS to build the files feature menu")
        }
        let advertised = Set(methods.compactMap(\.stringValue))
        let expected = Set(Self.advertisedFileMethods)

        let missing = expected.subtracting(advertised)
        let extra = advertised.subtracting(expected)

        XCTAssertTrue(missing.isEmpty,
                      "methods in our contract list are missing from capabilities response: \(missing.sorted())")
        XCTAssertTrue(extra.isEmpty,
                      "capabilities response advertises extra methods not in our contract list: \(extra.sorted()) -- add them to the static list in this test so iOS can rely on them")
    }

    func test_filesEditSessionIsLegacyDiscoveryWithoutV1Claim() async {
        // WHY: session readback closes legacy response-loss recovery, but it must
        // not opt clients into the stricter bounded edit_v1 protocol by accident.
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "system.capabilities",
            params: nil
        ))
        let authenticatedFiles = response.result?.objectValue?["files"]?.objectValue
        let publicFiles = DirectHTTPServer.capabilitiesPayload(loopbackOnly: true)["files"] as? [String: Any]

        XCTAssertEqual(
            authenticatedFiles?["methods"]?.arrayValue?.contains(.string("files.edit.session")),
            true
        )
        XCTAssertNil(authenticatedFiles?["edit_v1"], "legacy session discovery must not claim edit_v1")
        XCTAssertTrue(
            (publicFiles?["methods"] as? [String])?.contains("files.edit.session") == true
        )
        XCTAssertNil(publicFiles?["edit_v1"], "public discovery must not claim edit_v1")
    }

    func test_capabilitiesResponse_sshMethodsMatchStaticList() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil))

        guard case .object(let body) = resp.result,
              case .object(let sshObj) = body["ssh"],
              case .array(let methods) = sshObj["methods"] else {
            return XCTFail("system.capabilities must include ssh.methods array for iOS SSH tab")
        }
        let advertised = Set(methods.compactMap(\.stringValue))
        let expected = Set(Self.advertisedSSHMethods)

        XCTAssertEqual(advertised, expected,
                       "ssh.methods in capabilities response diverged from the static contract -- missing: \(expected.subtracting(advertised).sorted()), extra: \(advertised.subtracting(expected).sorted())")
    }
}
