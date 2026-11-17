import Foundation
import XCTest
@testable import CoreModel

private final class StubHTTPProtocol: URLProtocol {
    static var inspect: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.inspect?(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"answers":{}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor TestJev: JevTransport {
    var captured: [String: Any]?
    let selected: String
    let probability: Double
    let confidence: Double
    let completion: Double
    let consequential: Double
    let authorization: Double

    init(selected: String = "e0", probability: Double = 0.99, confidence: Double = 0.99,
         completion: Double = 0, consequential: Double = 0, authorization: Double = 0.99) {
        self.selected = selected
        self.probability = probability
        self.confidence = confidence
        self.completion = completion
        self.consequential = consequential
        self.authorization = authorization
    }

    func evaluate(_ request: [String: Any]) async throws -> [String: Any] {
        captured = request
        let questions = request["questions"] as! [String: [String: Any]]
        let next = questions["next"]!["criteria"] as! [String: String]
        var distribution = Dictionary(uniqueKeysWithValues: next.keys.map { ($0, 0.0) })
        distribution[selected] = probability
        let others = next.keys.filter { $0 != selected }.sorted()
        if let first = others.first { distribution[first] = 1 - probability }
        return ["answers": [
            "next": ["choice": selected, "confidence": confidence, "probabilities": distribution],
            "complete": ["noul": completion],
            "consequential": ["noul": consequential],
            "authorized": ["noul": authorization],
        ]]
    }

    func request() -> [String: Any]? { captured }
}

private struct FailingJev: JevTransport {
    func evaluate(_ request: [String: Any]) async throws -> [String: Any] {
        throw JevDecisionError.unavailable("Jev provider unavailable")
    }
}

private struct ObservationBackend: ComputerUseToolBackend {
    let observation: String
    func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        guard name == "get_ui_tree" else { return ComputerUseToolResult(text: "unexpected native mutation", isError: true) }
        return ComputerUseToolResult(text: observation)
    }
}

final class JevDecisionTests: XCTestCase {
    private let observation = """
    {"user_activity":"none","is_on_screen":true,"is_minimized":false,"permissions":{"accessibility":true},"state_token":"private-token","target_pid":123}
    ui_tree: {"role":"AXWindow","value":"private message","children":[{"role":"AXButton","title":"Send"},{"role":"AXTextField","value":"secret text"}]}
    """

    private var safeObservation: String { observation.replacingOccurrences(of: "\"Send\"", with: "\"Save\"") }

    func testOpenRouterKeyAlwaysRoutesToD12UltraWithJevFallback() throws {
        XCTAssertNil(TypeSafeJevTransport.route(environment: [:]))
        let openRouter = try XCTUnwrap(TypeSafeJevTransport.route(environment: ["OPENROUTER_API_KEY": "or-key"]))
        XCTAssertEqual(openRouter.url.absoluteString, "https://openrouter.ai/api/alpha/decisions")
        XCTAssertEqual(openRouter.model, "liquid/d1.2-ultra")
        XCTAssertEqual(openRouter.fallbackModel, "typesafe/jev-1.14")
        XCTAssertEqual(openRouter.key, "or-key")
        // The owner chose OpenRouter for every decision, so a Jev key beside it must not win.
        let both = try XCTUnwrap(TypeSafeJevTransport.route(environment: ["OPENROUTER_API_KEY": "or-key", "TYPESAFE_API_KEY": "ts-key"]))
        XCTAssertEqual(both.model, "liquid/d1.2-ultra")
        XCTAssertEqual(both.key, "or-key")
        // Without OpenRouter, a Jev key keeps the direct TypeSafe route and has nothing to fall back to.
        let direct = try XCTUnwrap(TypeSafeJevTransport.route(environment: ["TYPESAFE_API_KEY": "ts-key"]))
        XCTAssertEqual(direct.url.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(direct.model, "jev-latest")
        XCTAssertNil(direct.fallbackModel)
        XCTAssertEqual(TypeSafeJevTransport.route(environment: ["JEV_API_KEY": "jev-key", "TYPESAFE_API_KEY": "ts-key"])?.key, "jev-key")
    }

    func testOpenRouterTransportPostsTypedDecisionEnvelopeWithoutLeakingOtherKey() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); StubHTTPProtocol.inspect = nil }
        let requested = expectation(description: "OpenRouter typed Jev request")
        StubHTTPProtocol.inspect = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/alpha/decisions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer or-test")
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "liquid/d1.2-ultra")
            XCTAssertEqual((body?["state"] as? [String: String])?["goal"], "Click Save")
            requested.fulfill()
        }
        _ = try await TypeSafeJevTransport(environment: ["OPENROUTER_API_KEY": "or-test"], session: session)
            .evaluate(["model": "jev-latest", "state": ["goal": "Click Save"], "questions": [:]])
        await fulfillment(of: [requested], timeout: 2)
    }

    func testJevOnlyReceivesAllowlistedLabelsNeverWindowTokenOrFieldValues() async throws {
        let transport = TestJev()
        let proposal = try await JevDecision(transport: transport).advise(goal: "Click Send", observation: observation, allowedRisks: [.send])
        XCTAssertEqual(proposal.operation, "click_element")
        XCTAssertEqual(proposal.role, "AXButton")
        let captured = await transport.request()
        let request = try XCTUnwrap(captured)
        let payload = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        XCTAssertTrue(payload.contains("Send"))
        XCTAssertFalse(payload.contains("private-token"))
        XCTAssertFalse(payload.contains("private message"))
        XCTAssertFalse(payload.contains("secret text"))
        XCTAssertFalse(payload.contains("target_pid"))
    }

    func testCredentialBearingGoalNeverLeavesMac() async {
        let transport = TestJev()
        do {
            _ = try await JevDecision(transport: transport).advise(
                goal: "my password is hunter2; click Send", observation: observation)
            XCTFail("A credential-bearing goal must not be sent to Jev")
        } catch {
            let captured = await transport.request()
            XCTAssertNil(captured)
        }
    }

    func testHumanActivityStopsBeforeJevRequest() async {
        let transport = TestJev()
        do {
            _ = try await JevDecision(transport: transport).advise(
                goal: "Click Send", observation: observation.replacingOccurrences(of: "\"none\"", with: "\"human\""))
            XCTFail("Human activity must prevent remote evaluation")
        } catch {
            let captured = await transport.request()
            XCTAssertNil(captured)
        }
    }

    func testConsequentialClickRequiresExplicitAuthorization() async throws {
        let blocked = TestJev(consequential: 0.95, authorization: 0.2)
        let result = try await JevDecision(transport: blocked).advise(goal: "Find Send", observation: observation, allowedRisks: [.send])
        XCTAssertEqual(result.operation, "BLOCKED")
        let permitted = TestJev(consequential: 0.95, authorization: 0.99)
        let allowed = try await JevDecision(transport: permitted).advise(goal: "Send", observation: observation, allowedRisks: [.send])
        XCTAssertEqual(allowed.operation, "click_element")
    }

    func testMaterialButtonRequiresStrongGatesEvenIfModelMisclassifiesIt() async throws {
        let transport = TestJev(probability: 0.70, confidence: 0.8, consequential: 0, authorization: 0.99)
        let result = try await JevDecision(transport: transport).advise(goal: "Send", observation: observation, allowedRisks: [.send])
        XCTAssertEqual(result.operation, "BLOCKED")
    }

    func testJevAdviceCarriesAlternativesSignalsAndBlockReasonForSessionLLM() async throws {
        // "Send" is material by label, so 0.70 is below the material threshold.
        let transport = TestJev(probability: 0.70, confidence: 0.8, consequential: 0, authorization: 0.99)
        let json = try await JevDecision(transport: transport).advise(goal: "Send", observation: observation, allowedRisks: [.send]).jsonObject()
        XCTAssertEqual(json["mode"] as? String, "jev")
        XCTAssertEqual(json["operation"] as? String, "BLOCKED")
        // A blocked choice must explain why, so the session LLM asks the user instead of guessing.
        XCTAssertEqual(json["reason"] as? String, "Choice below material confidence threshold")
        XCTAssertEqual((json["signals"] as? [String: Double])?["authorized"], 0.99)
        // The runner-up (TestJev puts the remainder on the first other option) is surfaced as evidence.
        let alternatives = try XCTUnwrap(json["alternatives"] as? [[String: Any]])
        XCTAssertEqual(alternatives.count, 1)
        XCTAssertEqual(alternatives[0]["operation"] as? String, "BLOCKED")
        XCTAssertEqual(alternatives[0]["probability"] as? Double ?? 0, 0.30, accuracy: 1e-9)
    }

    func testDoneNeedsIndependentCompletionEvidence() async throws {
        let transport = TestJev(selected: "DONE", completion: 0.5)
        let result = try await JevDecision(transport: transport).advise(goal: "Send", observation: observation, allowedRisks: [.send])
        XCTAssertEqual(result.operation, "BLOCKED")
    }

    func testMCPJevToolReturnsProposalAndTokenWithoutExecutingInput() async throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("rc-cu-tests-\(UUID().uuidString)/computer-use.lock")
        let handler = ManagedComputerUseMCP(
            queue: ComputerUseHostQueue(lockURL: lock),
            backend: ObservationBackend(observation: safeObservation),
            jev: JevDecision(transport: TestJev()),
            jevAvailable: { true }
        )
        let call = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"jev_decide","arguments":{"goal":"Click Save","target_pid":123,"target_window_id":9}}}"#
        let reply = await handler.handle(call)
        let response = try XCTUnwrap(reply)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let parts = try XCTUnwrap(result["content"] as? [[String: Any]])
        let proposal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((parts[0]["text"] as! String).utf8)) as? [String: Any])
        XCTAssertEqual(proposal["operation"] as? String, "click_element")
        XCTAssertEqual(proposal["expected_state_token"] as? String, "private-token")
    }

    func testMissingJevKeyDefersToDistillLLMWithoutCallingJevOrExecutingInput() async throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("rc-cu-tests-\(UUID().uuidString)/computer-use.lock")
        let transport = TestJev()
        let handler = ManagedComputerUseMCP(
            queue: ComputerUseHostQueue(lockURL: lock),
            backend: ObservationBackend(observation: safeObservation),
            jev: JevDecision(transport: transport),
            jevAvailable: { false }
        )
        let call = #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"jev_decide","arguments":{"goal":"Click Save","target_pid":123,"target_window_id":9}}}"#
        let reply = await handler.handle(call)
        let response = try XCTUnwrap(reply)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let parts = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(parts.first?["text"] as? String)
        let fallback = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(fallback["mode"] as? String, "llm")
        XCTAssertEqual(fallback["operation"] as? String, "DEFER_TO_LLM")
        XCTAssertEqual(fallback["expected_state_token"] as? String, "private-token")
        XCTAssertEqual((fallback["candidates"] as? [[String: String]])?.first?["label"], "Save")
        XCTAssertFalse(text.contains("private message"))
        XCTAssertFalse(text.contains("secret text"))
        let captured = await transport.request()
        XCTAssertNil(captured)
    }

    func testConfiguredJevFailureDoesNotSilentlySwitchToLLM() async throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("rc-cu-tests-\(UUID().uuidString)/computer-use.lock")
        let handler = ManagedComputerUseMCP(
            queue: ComputerUseHostQueue(lockURL: lock),
            backend: ObservationBackend(observation: safeObservation),
            jev: JevDecision(transport: FailingJev()),
            jevAvailable: { true }
        )
        let call = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"jev_decide","arguments":{"goal":"Click Save","target_pid":123,"target_window_id":9}}}"#
        let reply = await handler.handle(call)
        let response = try XCTUnwrap(reply)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let parts = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertFalse((parts.first?["text"] as? String ?? "").contains("DEFER_TO_LLM"))
    }

    func testMissingKeyWithHumanActivityDoesNotOfferLLMCandidates() async throws {
        let unsafe = observation.replacingOccurrences(of: "\"none\"", with: "\"human\"")
        XCTAssertThrowsError(try JevDecision(transport: TestJev()).localFallback(observation: unsafe))
    }

    func testTitleCannotResolveToAnotherButtonsDescription() async throws {
        let ambiguous = observation.replacingOccurrences(
            of: #"{"role":"AXButton","title":"Send"}"#,
            with: #"{"role":"AXButton","title":"Delete","description":"Send"},{"role":"AXButton","title":"Send"}"#
        )
        let transport = TestJev(selected: "BLOCKED")
        _ = try await JevDecision(transport: transport).advise(goal: "Send", observation: ambiguous, allowedRisks: [.send, .delete])
        let captured = await transport.request()
        let request = try XCTUnwrap(captured)
        let state = request["state"] as! [String: Any]
        let visible = state["visibleElements"] as! [[String: String]]
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0]["label"], "Delete")
    }

    func testDuplicateSemanticTargetsNeverProposed() async throws {
        let duplicated = observation.replacingOccurrences(
            of: "{\"role\":\"AXTextField\",\"value\":\"secret text\"}",
            with: "{\"role\":\"AXButton\",\"title\":\"Send\"}")
        let transport = TestJev(selected: "BLOCKED")
        _ = try await JevDecision(transport: transport).advise(goal: "Send", observation: duplicated, allowedRisks: [.send])
        let captured = await transport.request()
        let request = try XCTUnwrap(captured)
        let state = request["state"] as! [String: Any]
        XCTAssertTrue((state["visibleElements"] as! [[String: String]]).isEmpty)
    }

    func testRiskyTargetWithheldFromJevUnlessCategoryAllowed() async throws {
        let withheld = TestJev(selected: "BLOCKED")
        _ = try await JevDecision(transport: withheld).advise(goal: "Send", observation: observation)
        let firstCaptured = await withheld.request()
        let first = try XCTUnwrap(firstCaptured)
        XCTAssertTrue(((first["state"] as! [String: Any])["visibleElements"] as! [[String: String]]).isEmpty)

        let wrongCategory = TestJev(selected: "BLOCKED")
        _ = try await JevDecision(transport: wrongCategory).advise(goal: "Send", observation: observation, allowedRisks: [.delete])
        let secondCaptured = await wrongCategory.request()
        let second = try XCTUnwrap(secondCaptured)
        XCTAssertTrue(((second["state"] as! [String: Any])["visibleElements"] as! [[String: String]]).isEmpty)

        let allowed = TestJev(selected: "BLOCKED")
        _ = try await JevDecision(transport: allowed).advise(goal: "Send", observation: observation, allowedRisks: [.send])
        let thirdCaptured = await allowed.request()
        let third = try XCTUnwrap(thirdCaptured)
        XCTAssertEqual(((third["state"] as! [String: Any])["visibleElements"] as! [[String: String]]).count, 1)
    }

    func testLocalFallbackWithholdsRiskyCandidatesUnlessAllowed() throws {
        let jev = JevDecision(transport: TestJev())
        XCTAssertTrue((try jev.localFallback(observation: observation)["candidates"] as! [[String: String]]).isEmpty)
        let allowed = try jev.localFallback(observation: observation, allowedRisks: [.send])
        XCTAssertEqual((allowed["candidates"] as! [[String: String]]).first?["label"], "Send")
    }

    func testSecretsAllowGoalButAreRedactedBeforeTransport() async throws {
        let transport = TestJev()
        let proposal = try await JevDecision(transport: transport).advise(
            goal: "Type password hunter2 then click Save", observation: safeObservation, secrets: ["hunter2"])
        XCTAssertEqual(proposal.operation, "click_element")
        let requestCaptured = await transport.request()
        let request = try XCTUnwrap(requestCaptured)
        let payload = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        XCTAssertFalse(payload.contains("hunter2"))
        XCTAssertTrue(payload.contains("[secret]"))
    }

    func testMarginBelowMinimumReturnsNeedsAgentWithReason() async throws {
        // Runner-up gets 0.30 so margin is 0.40.
        let transport = TestJev(probability: 0.70, confidence: 0.9, consequential: 0, authorization: 0.99)
        let blocked = try await JevDecision(transport: transport).advise(
            goal: "Save", observation: safeObservation, minMargin: 0.5)
        XCTAssertEqual(blocked.operation, "NEEDS_AGENT")
        XCTAssertTrue(try XCTUnwrap(blocked.reason).contains("min_margin"))
        XCTAssertEqual(try XCTUnwrap(blocked.margin), 0.4, accuracy: 1e-9)
        XCTAssertEqual(blocked.jsonObject()["margin"] as? Double ?? 0, 0.4, accuracy: 1e-9)

        let passes = try await JevDecision(transport: transport).advise(
            goal: "Save", observation: safeObservation, minMargin: 0.39)
        XCTAssertEqual(passes.operation, "click_element")

        let lowConfidence = try await JevDecision(transport: transport).advise(
            goal: "Save", observation: safeObservation, minConfidence: 0.95)
        XCTAssertEqual(lowConfidence.operation, "NEEDS_AGENT")
        XCTAssertTrue(try XCTUnwrap(lowConfidence.reason).contains("min_confidence"))
    }
}
