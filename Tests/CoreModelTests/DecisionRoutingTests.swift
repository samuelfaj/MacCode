import Foundation
import XCTest
@testable import CoreModel

/// Answers each request by the model in its body, so a test scripts d1.2-ultra and Jev separately.
private final class ScriptedDecisionHTTP: URLProtocol {
    struct Reply { var status = 200; var body: [String: Any] = [:]; var error: URLError? = nil }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requested: [(model: String, body: [String: Any], timeout: TimeInterval)] = []

    static func script(_ replies: [String: Reply]) { lock.withLock { self.replies = replies; requested = [] } }
    static var calls: [(model: String, body: [String: Any], timeout: TimeInterval)] { lock.withLock { requested } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let model = body["model"] as? String ?? ""
        let reply = Self.lock.withLock { () -> Reply in
            Self.requested.append((model, body, request.timeoutInterval))
            return Self.replies[model] ?? Reply(status: 500)
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply.body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Answers `next` from text with one distribution and, when the state carries an image, with another.
private actor EscalationJev: JevTransport {
    private(set) var requests: [[String: Any]] = []
    let text: (choice: String, probability: Double, confidence: Double)
    let withImage: (choice: String, probability: Double, confidence: Double)
    let authorized: Double
    let consequential: Double

    init(text: (String, Double, Double), withImage: (String, Double, Double) = ("e0", 0.97, 0.95),
         consequential: Double = 0, authorized: Double = 0.99) {
        self.text = text
        self.withImage = withImage
        self.consequential = consequential
        self.authorized = authorized
    }

    func evaluate(_ request: [String: Any]) async throws -> [String: Any] {
        requests.append(request)
        let pick = request["state"] is [Any] ? withImage : text
        let questions = request["questions"] as! [String: [String: Any]]
        let keys = (questions["next"]!["criteria"] as! [String: String]).keys.sorted()
        var distribution = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0.0) })
        distribution[pick.choice] = pick.probability
        if let other = keys.first(where: { $0 != pick.choice }) { distribution[other] = 1 - pick.probability }
        return ["engine": "liquid/d1.2-ultra-20261116", "answers": [
            "next": ["choice": pick.choice, "probabilities": distribution, "confidence": pick.confidence],
            "complete": ["noul": 0.0], "consequential": ["noul": consequential], "authorized": ["noul": authorized],
        ]]
    }
}

private final class CaptureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func hit() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

final class DecisionRoutingTests: XCTestCase {
    private func transport(_ environment: [String: String]) -> (TypeSafeJevTransport, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedDecisionHTTP.self]
        let session = URLSession(configuration: configuration)
        return (TypeSafeJevTransport(environment: environment, session: session), session)
    }

    private let request: [String: Any] = ["state": ["goal": "Click Save"], "questions": ["q": ["type": "noul", "instructions": "?"]]]
    private let answered: [String: Any] = ["answers": ["q": ["type": "noul", "noul": 0.9]]]

    override func tearDown() { ScriptedDecisionHTTP.script([:]) }

    func testD12UltraAnswersAndNamesTheModelThatServedIt() async throws {
        ScriptedDecisionHTTP.script(["liquid/d1.2-ultra": .init(body: answered.merging(["model": "liquid/d1.2-ultra-20261116"]) { $1 })])
        let (client, session) = transport(["OPENROUTER_API_KEY": "or-key"])
        defer { session.invalidateAndCancel() }
        let response = try await client.evaluate(request)
        XCTAssertEqual(response["engine"] as? String, "liquid/d1.2-ultra-20261116")
        XCTAssertNil(response["fallback_reason"])
        XCTAssertEqual(ScriptedDecisionHTTP.calls.map(\.model), ["liquid/d1.2-ultra"])
        // A text decision gets a short primary timeout so a stuck d1.2-ultra still leaves time for Jev.
        XCTAssertEqual(ScriptedDecisionHTTP.calls.first?.timeout, 5)
    }

    func testUnreachableD12UltraFallsBackToJevAndSaysWhy() async throws {
        for failure in [ScriptedDecisionHTTP.Reply(status: 503), .init(status: 429), .init(status: 404),
                        .init(error: URLError(.timedOut)), .init(error: URLError(.cannotConnectToHost))] {
            ScriptedDecisionHTTP.script(["liquid/d1.2-ultra": failure, "typesafe/jev-1.14": .init(body: answered)])
            let (client, session) = transport(["OPENROUTER_API_KEY": "or-key"])
            let response = try await client.evaluate(request)
            session.invalidateAndCancel()
            XCTAssertEqual(ScriptedDecisionHTTP.calls.map(\.model), ["liquid/d1.2-ultra", "typesafe/jev-1.14"])
            XCTAssertEqual(response["engine"] as? String, "typesafe/jev-1.14")
            let reason = try XCTUnwrap(response["fallback_reason"] as? String)
            XCTAssertTrue(reason.hasPrefix("liquid/d1.2-ultra "), reason)
            XCTAssertEqual((response["answers"] as? [String: [String: Any]])?["q"]?["noul"] as? Double, 0.9)
        }
    }

    func testRejectedRequestFailsLoudInsteadOfHidingTheBugBehindJev() async throws {
        for status in [400, 401, 402, 422] {
            ScriptedDecisionHTTP.script(["liquid/d1.2-ultra": .init(status: status), "typesafe/jev-1.14": .init(body: answered)])
            let (client, session) = transport(["OPENROUTER_API_KEY": "or-key"])
            do {
                _ = try await client.evaluate(request)
                XCTFail("HTTP \(status) must not be answered by the fallback")
            } catch {
                XCTAssertTrue(String(describing: error).contains("HTTP \(status)"), String(describing: error))
            }
            session.invalidateAndCancel()
            XCTAssertEqual(ScriptedDecisionHTTP.calls.map(\.model), ["liquid/d1.2-ultra"])
        }
    }

    func testBothModelsDownIsAnErrorNamingBoth() async throws {
        ScriptedDecisionHTTP.script(["liquid/d1.2-ultra": .init(status: 503), "typesafe/jev-1.14": .init(status: 502)])
        let (client, session) = transport(["OPENROUTER_API_KEY": "or-key"])
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.evaluate(request)
            XCTFail("Two unreachable models must not produce a decision")
        } catch {
            let text = String(describing: error)
            XCTAssertTrue(text.contains("liquid/d1.2-ultra HTTP 503") && text.contains("typesafe/jev-1.14 HTTP 502"), text)
        }
    }

    func testDirectJevRouteHasNoFallback() async throws {
        ScriptedDecisionHTTP.script(["jev-latest": .init(status: 503)])
        let (client, session) = transport(["JEV_API_KEY": "jev-key"])
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.evaluate(request)
            XCTFail("The direct route has no second model")
        } catch {}
        XCTAssertEqual(ScriptedDecisionHTTP.calls.map(\.model), ["jev-latest"])
        XCTAssertEqual(ScriptedDecisionHTTP.calls.first?.timeout, 12)
    }

    func testImageRequestKeepsItsImageOnFallbackAndGetsALongerTimeout() async throws {
        ScriptedDecisionHTTP.script(["liquid/d1.2-ultra": .init(status: 503), "typesafe/jev-1.14": .init(body: answered)])
        let (client, session) = transport(["OPENROUTER_API_KEY": "or-key"])
        defer { session.invalidateAndCancel() }
        let state = JevDecision.stateWithImage(["goal": "Click Save"], image: "data:image/png;base64,AAAA")
        _ = try await client.evaluate(["state": state, "questions": request["questions"]!])
        let calls = ScriptedDecisionHTTP.calls
        XCTAssertEqual(calls.first?.timeout, 10)
        // Jev on OpenRouter reads images up to 1024 px, so the fallback decides from the same evidence.
        for call in calls {
            let parts = try XCTUnwrap(call.body["state"] as? [Any])
            XCTAssertEqual(((parts.first as? [String: Any])?["image_url"] as? [String: String])?["url"], "data:image/png;base64,AAAA")
            XCTAssertTrue((parts.last as? String)?.contains("Click Save") == true)
        }
    }

    // MARK: Escalation

    private func observation(_ children: String) -> String {
        """
        {"user_activity":"none","is_on_screen":true,"is_minimized":false,"permissions":{"accessibility":true},"state_token":"t1"}
        ui_tree: {"role":"AXWindow","children":[\(children)]}
        """
    }
    private var buttons: String { #"{"role":"AXButton","title":"Save"},{"role":"AXButton","title":"Cancel"}"# }

    func testDecisionReadsTheWindowImageWithTheLabels() async throws {
        // From labels alone the model would press Cancel; the screenshot shows Save is the step.
        let model = EscalationJev(text: ("e1", 0.97, 0.95), withImage: ("e0", 0.97, 0.95))
        let shots = CaptureCounter()
        let proposal = try await JevDecision(transport: model).advise(
            goal: "Save the file", observation: observation(buttons),
            image: { shots.hit(); return ("data:image/png;base64,AAAA", nil) })
        XCTAssertEqual(proposal.operation, "click_element")
        XCTAssertEqual(proposal.label, "Save")
        XCTAssertEqual(proposal.imageAttached, true)
        XCTAssertEqual(proposal.jsonObject()["image_attached"] as? Bool, true)
        XCTAssertEqual(proposal.engine, "liquid/d1.2-ultra-20261116")
        XCTAssertEqual(shots.count, 1)
        // One request carries both: the image first, then the same labels a text decision would get.
        let requests = await model.requests
        XCTAssertEqual(requests.count, 1)
        let parts = try XCTUnwrap(requests[0]["state"] as? [Any])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(((parts[0] as? [String: Any])?["image_url"] as? [String: String])?["url"], "data:image/png;base64,AAAA")
        XCTAssertTrue((parts[1] as? String)?.contains("visibleElements") == true)
    }

    func testImageNeverOverridesTheAuthorizationGate() async throws {
        let model = EscalationJev(text: ("e0", 0.97, 0.95), withImage: ("e0", 0.97, 0.95), consequential: 0.95, authorized: 0.2)
        let proposal = try await JevDecision(transport: model).advise(
            goal: "Look at the draft", observation: observation(#"{"role":"AXButton","title":"Send"}"#), allowedRisks: [.send],
            image: { ("data:image/png;base64,AAAA", nil) })
        XCTAssertEqual(proposal.operation, "BLOCKED")
        XCTAssertEqual(proposal.reason, "Material action not explicitly authorized by the goal")
    }

    func testWindowWithSecureFieldIsNeverCaptured() async throws {
        let model = EscalationJev(text: ("e1", 0.97, 0.95))
        let shots = CaptureCounter()
        let proposal = try await JevDecision(transport: model).advise(
            goal: "Sign in", observation: observation(buttons + #",{"role":"AXSecureTextField","title":"Password"}"#),
            image: { shots.hit(); return ("data:image/png;base64,AAAA", nil) })
        XCTAssertEqual(proposal.label, "Cancel")
        XCTAssertEqual(proposal.imageAttached, false)
        XCTAssertEqual(proposal.imageSkipReason, "secure_field")
        XCTAssertEqual(shots.count, 0)
        let requests = await model.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0]["state"] is [String: Any])
    }

    func testCallWithSecretsIsNeverCaptured() async throws {
        let model = EscalationJev(text: ("e1", 0.97, 0.95))
        let shots = CaptureCounter()
        let proposal = try await JevDecision(transport: model).advise(
            goal: "Type hunter2 then save", observation: observation(buttons), secrets: ["hunter2"],
            image: { shots.hit(); return ("data:image/png;base64,AAAA", nil) })
        XCTAssertEqual(proposal.imageSkipReason, "secrets")
        XCTAssertEqual(shots.count, 0)
    }

    func testFailedCaptureDecidesFromLabelsAndSaysWhy() async throws {
        let model = EscalationJev(text: ("e1", 0.97, 0.95))
        let proposal = try await JevDecision(transport: model).advise(
            goal: "Save the file", observation: observation(buttons), image: { (nil, "capture_unavailable") })
        XCTAssertEqual(proposal.label, "Cancel")
        XCTAssertEqual(proposal.imageAttached, false)
        XCTAssertEqual(proposal.imageSkipReason, "capture_unavailable")
        let requests = await model.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0]["state"] is [String: Any])
    }

    func testWithoutAnImageSourceTheRequestStaysTextOnly() async throws {
        let model = EscalationJev(text: ("e1", 0.97, 0.95))
        let proposal = try await JevDecision(transport: model).advise(goal: "Save the file", observation: observation(buttons))
        XCTAssertNil(proposal.imageAttached)
        XCTAssertNil(proposal.jsonObject()["image_attached"])
        let requests = await model.requests
        XCTAssertTrue(requests[0]["state"] is [String: Any])
    }

    func testJevDecideToolCapturesTheExactWindowAt1024Pixels() async throws {
        final class Backend: ComputerUseToolBackend, @unchecked Sendable {
            let tree: String
            var screenshotArguments: [String: Any]?
            init(tree: String) { self.tree = tree }
            func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
                if name == "get_ui_tree" { return ComputerUseToolResult(text: tree) }
                guard name == "screenshot" else { return ComputerUseToolResult(text: "unexpected \(name)", isError: true) }
                screenshotArguments = arguments
                return ComputerUseToolResult(content: [.text("{}"), .image(data: "QUJD", mimeType: "image/png")])
            }
        }
        let backend = Backend(tree: observation(buttons))
        let model = EscalationJev(text: ("e1", 0.5, 0.3))
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("rc-cu-tests-\(UUID().uuidString)/computer-use.lock")
        let handler = ManagedComputerUseMCP(queue: ComputerUseHostQueue(lockURL: lock), backend: backend,
                                            jev: JevDecision(transport: model), jevAvailable: { true })
        let call = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"jev_decide","arguments":{"goal":"Save the file","target_pid":123,"target_window_id":9}}}"#
        let handled = await handler.handle(call)
        let reply = try XCTUnwrap(handled)
        let result = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let proposal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(proposal["image_attached"] as? Bool, true)
        XCTAssertEqual(proposal["engine"] as? String, "liquid/d1.2-ultra-20261116")
        XCTAssertEqual(backend.screenshotArguments?["target_pid"] as? Int, 123)
        XCTAssertEqual(backend.screenshotArguments?["target_window_id"] as? Int, 9)
        XCTAssertEqual(backend.screenshotArguments?["max_image_dimension"] as? Int, 1024)
        let requests = await model.requests
        let parts = try XCTUnwrap(requests.last?["state"] as? [Any])
        XCTAssertEqual(((parts[0] as? [String: Any])?["image_url"] as? [String: String])?["url"], "data:image/png;base64,QUJD")
    }
}
