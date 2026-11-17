import XCTest
@testable import SocketServer

/// `client.perf.report`: the phone's resume timings must reach the Mac so a
/// return from the background can be measured end to end, but the RPC is a
/// diagnostics sink only — bounded, paired clients only, never user state.
@MainActor
final class ClientPerfReportTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("ios-perf.jsonl") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-perf-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func dispatcher() -> JSONRPCDispatcher {
        JSONRPCDispatcher(router: FakeRouter(), perfReportLog: ClientPerfReportLog(fileURL: fileURL))
    }

    private func request(_ lines: [JSONValue]) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "client.perf.report", params: ["lines": .array(lines)])
    }

    private let paired = MutationRequestContext(ownerFingerprint: "owner-a", hostId: "host-a", bootEpoch: 7)

    private func fileText() -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    // WHY: the whole point of the RPC — a paired phone's lines land, in order,
    // one record per line, in the host log.
    func test_pairedReportAppendsEveryLineAsJSONL() async {
        let d = dispatcher()
        let first = await d.dispatch(request([.string(#"{"m":"resume.begin","t":1}"#), .string(#"{"m":"resume.end","t":2}"#)]), mutationContext: paired)
        XCTAssertNil(first.error)
        XCTAssertEqual(first.result?.objectValue?["accepted"]?.intValue, 2)
        let second = await d.dispatch(request([.string(#"{"m":"cold.launch","t":3}"#)]), mutationContext: paired)
        XCTAssertNil(second.error)
        XCTAssertEqual(fileText(), "{\"m\":\"resume.begin\",\"t\":1}\n{\"m\":\"resume.end\",\"t\":2}\n{\"m\":\"cold.launch\",\"t\":3}\n")
    }

    // WHY: authenticated paired clients only. Local IPC and the Unix socket
    // carry no paired identity, so they must not write the log.
    func test_callWithoutPairedIdentityIsRefusedAndWritesNothing() async {
        let response = await dispatcher().dispatch(request([.string(#"{"m":"x"}"#)]))
        XCTAssertEqual(response.error?.code, -32098)
        XCTAssertNil(fileText())
    }

    private func server() -> DirectHTTPServer {
        DirectHTTPServer(port: UInt16.random(in: 33000...44000), loopbackOnly: true, dispatcher: dispatcher(), bootEpoch: 1)
    }

    private let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"client.perf.report","params":{"lines":["{\"m\":\"x\"}"]}}"#.utf8)

    // WHY: a loopback-only host trusts tokenless Mac-local HTTP callers for the
    // rest of the API, and they reach the dispatcher with an identity. Seen in
    // the sandbox app: a curl with no bearer wrote the log. Perf reports must
    // come from a paired phone's verified bearer.
    func test_tokenlessLoopbackHTTPCallIsRefused() async throws {
        let data = await server().dispatchRPC(bodyData: body)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32098)
        XCTAssertNil(fileText())
    }

    func test_bearerVerifiedHTTPCallIsAppended() async throws {
        let paired = DirectRPCPrincipal(ownerFingerprint: "phone-owner", grantedCapabilities: "read")
        let data = await server().dispatchRPC(bodyData: body, principal: paired)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["result"] as? [String: Any])?["accepted"] as? Int, 1)
        XCTAssertEqual(fileText(), "{\"m\":\"x\"}\n")
    }

    // WHY: 64 KB per call. An oversize call is refused whole, so the file never
    // holds a partial report.
    func test_callOverSixtyFourKilobytesIsRefusedWhole() async {
        let padding = String(repeating: "a", count: 1000)
        let lines = (0..<70).map { JSONValue.string("{\"i\":\($0),\"p\":\"\(padding)\"}") }
        let response = await dispatcher().dispatch(request(lines), mutationContext: paired)
        XCTAssertEqual(response.error?.code, -32602)
        XCTAssertNil(fileText())
    }

    // WHY: the file must stay valid JSONL — a non-object line or an embedded
    // newline (a forged second record) rejects the call with no write.
    func test_invalidLineRejectsTheWholeCall() async {
        let d = dispatcher()
        for bad: JSONValue in [.string("not json"), .string("{\"a\":1}\n{\"forged\":true}"), .string("[1]"), .number(3)] {
            let response = await d.dispatch(request([.string(#"{"ok":1}"#), bad]), mutationContext: paired)
            XCTAssertEqual(response.error?.code, -32602, "\(bad)")
        }
        let missing = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "client.perf.report", params: [:]), mutationContext: paired)
        XCTAssertEqual(missing.error?.code, -32602)
        XCTAssertNil(fileText())
    }

    // WHY: 1 MB file with rotation. The active file never passes 1 MB and the
    // previous megabyte is kept once, so the log cannot grow without bound.
    func test_activeFileRotatesBeforePassingOneMegabyte() async throws {
        let log = ClientPerfReportLog(fileURL: fileURL)
        let old = Data(repeating: 0x41, count: ClientPerfReport.maxFileBytes - 10)
        try await log.append(old)
        let next = Data("{\"m\":\"after\"}\n".utf8)
        try await log.append(next)
        XCTAssertEqual(try Data(contentsOf: fileURL), next)
        XCTAssertEqual(try Data(contentsOf: log.rotatedFileURL), old)
        // A second rotation replaces the old predecessor rather than piling up.
        try await log.append(Data(repeating: 0x42, count: ClientPerfReport.maxFileBytes - next.count))
        try await log.append(next)
        XCTAssertEqual(try Data(contentsOf: fileURL), next)
        let rotated = try Data(contentsOf: log.rotatedFileURL)
        XCTAssertLessThanOrEqual(rotated.count, ClientPerfReport.maxFileBytes)
        XCTAssertFalse(rotated.contains(0x41))
    }

    // WHY: the phone sends only when the welcome lists the capability; a scoped
    // read device may report, and the RPC never enters the mutation gate or the
    // read-only batch (it writes a log, not user state).
    func test_capabilityIsAdvertisedAndScopedAsReadDiagnostics() {
        XCTAssertTrue(DirectHTTPServer.welcomeCapabilities().contains("client.perf.report.v1"))
        XCTAssertTrue(JSONRPCDispatcher.isAuthorized(method: "client.perf.report", grantedCapabilities: "read"))
        XCTAssertFalse(JSONRPCDispatcher.isAuthorized(method: "client.perf.report", grantedCapabilities: "file"))
        XCTAssertFalse(JSONRPCDispatcher.hostMutationMethods.contains("client.perf.report"))
        XCTAssertFalse(JSONRPCDispatcher.isReadOnlyBatchMethod("client.perf.report"))
    }

    // WHY: the isolated sandbox app runs with its own HOME and must not write
    // into the user's real ~/Library/Logs.
    func test_defaultPathFollowsHome() {
        XCTAssertEqual(
            ClientPerfReport.defaultFileURL(environment: ["HOME": "/tmp/sandbox-home"]).path,
            "/tmp/sandbox-home/Library/Logs/RemoteCode/ios-perf.jsonl"
        )
    }
}
