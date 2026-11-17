import Foundation
import XCTest
@testable import CoreModel

private actor ExtensionsJev: JevTransport {
    private var requests: [[String: Any]] = []
    let probabilities: [Double]
    let confidence: Double
    let consequential: Double
    let authorized: Double

    init(probabilities: [Double] = [0.85, 0.15, 0.5], confidence: Double = 0.99,
         consequential: Double = 0, authorized: Double = 0.99) {
        self.probabilities = probabilities
        self.confidence = confidence
        self.consequential = consequential
        self.authorized = authorized
    }

    func evaluate(_ request: [String: Any]) async throws -> [String: Any] {
        requests.append(request)
        let questions = request["questions"] as! [String: [String: Any]]
        if let next = questions["next"] {
            let criteria = next["criteria"] as! [String: String]
            var distribution = Dictionary(uniqueKeysWithValues: criteria.keys.map { ($0, 0.0) })
            distribution["e0"] = 0.99
            distribution["WAIT"] = 0.01
            return ["answers": [
                "next": ["choice": "e0", "probabilities": distribution, "confidence": confidence],
                "complete": ["noul": 0.0], "consequential": ["noul": consequential],
                "authorized": ["noul": authorized],
            ]]
        }
        return ["answers": Dictionary(uniqueKeysWithValues: questions.keys.map { key in
            (key, ["noul": probabilities[Int(key.dropFirst())!]])
        })]
    }

    func captured() -> [[String: Any]] { requests }
}

private struct ExtensionsBrowser: ComputerUseToolBackend, @unchecked Sendable {
    let snapshot: [String: Any]
    func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        guard name == "browser_snapshot", arguments.isEmpty else {
            return ComputerUseToolResult(text: "Unexpected browser call", isError: true)
        }
        return ComputerUseToolResult(text: String(decoding: try! JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self))
    }
}

final class JevExtensionsTests: XCTestCase {
    private let criteria = ["Saved indicator is visible", "Error is visible", "Task is complete"]
    private var snapshot: [String: Any] {
        ["ok": true, "state_token": "owned-state", "url": "https://private.example", "title": "private title",
         "text": "private page content", "elements": [
            ["ref": "owned.0", "role": "button", "name": "Continue", "value": "private value"],
            ["ref": "owned.1", "role": "button", "name": "Send", "value": "private message"],
            ["ref": "owned.2", "role": "input", "name": "Login", "type": "password", "value": "hunter2"],
            ["ref": "owned.3", "role": "button", "name": "Email person@example.com"],
            ["ref": "owned.4", "role": "button", "name": "Duplicate"],
            ["ref": "owned.5", "role": "button", "name": "Duplicate"],
            ["ref": "owned.6", "role": "input", "name": "Unspecified field"],
         ] as [[String: Any]]]
    }

    private func object(_ result: ComputerUseToolResult) throws -> [String: Any] {
        XCTAssertFalse(result.isError, result.content.first?.text ?? "")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result.content.first?.text).utf8)) as? [String: Any])
    }

    private func backend(
        _ transport: any JevTransport, available: Bool,
        capture: @escaping @Sendable (ComputerUseNativeHostTarget) async -> (url: String?, skipReason: String?) = { _ in (nil, "no capture in tests") }
    ) -> InputToolsBackend {
        var effects = InputToolsBackend.Effects()
        effects.windows = { [] }
        effects.snapshot = { _ in InputSnapshot(windowExists: true,
            title: "Editor hunter2 https://private.example person@example.com /Users/private/file token=hidden",
            nodes: [InputNode(role: "AXStaticText", label: "Saved", value: "secret field value"),
                    InputNode(role: "AXTextField", label: "Password: hunter2", value: "hunter2"),
                    InputNode(role: "AXButton", label: "Send"),
                    InputNode(role: "AXButton", label: "https://private.example")], focused: nil) }
        effects.capture = capture
        return InputToolsBackend(effects: effects, transport: transport, jevAvailable: { available })
    }

    func testCriteriaBatchThresholdsAndDeterministicChecks() async throws {
        let transport = ExtensionsJev()
        let result = try object(await backend(transport, available: true).invoke(name: "verify_state", arguments: [
            "target_pid": 42, "target_window_id": 7,
            "expect": ["window_exists": true, "criteria": criteria],
        ]))
        let checks = try XCTUnwrap(result["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.compactMap { $0["result"] as? String }, ["pass", "pass", "fail", "unknown"])
        XCTAssertEqual(checks.dropFirst().compactMap { $0["probability"] as? Double }, [0.85, 0.15, 0.5])
        XCTAssertEqual(checks.dropFirst().compactMap { $0["criterion"] as? String }, criteria)
        XCTAssertEqual(result["result"] as? String, "fail")
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        let questions = try XCTUnwrap(request["questions"] as? [String: [String: Any]])
        XCTAssertEqual(questions.count, 3)
        XCTAssertTrue(questions.values.allSatisfy { $0["type"] as? String == "noul" })
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        for secret in ["secret field value", "hunter2", "private.example", "person@example.com", "/Users/private", "hidden", "Send"] {
            XCTAssertFalse(payload.contains(secret), secret)
        }
        XCTAssertTrue(payload.contains("Saved"))
        XCTAssertFalse(payload.contains("\"value\""))
    }

    func testCriteriaAreCheckedOnceWithTheWindowImage() async throws {
        let transport = ExtensionsJev()
        let result = try object(await backend(transport, available: true, capture: { target in
            XCTAssertEqual(target, ComputerUseNativeHostTarget(pid: 42, windowID: 7))
            return ("data:image/png;base64,QUJD", nil)
        }).invoke(name: "verify_state", arguments: ["target_pid": 42, "target_window_id": 7, "expect": ["criteria": criteria]]))
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual((request["questions"] as? [String: Any])?.count, 3)
        let parts = try XCTUnwrap(request["state"] as? [Any])
        XCTAssertEqual(((parts[0] as? [String: Any])?["image_url"] as? [String: String])?["url"], "data:image/png;base64,QUJD")
        // The labels still travel filtered beside the image.
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        XCTAssertTrue(payload.contains("Saved"))
        XCTAssertFalse(payload.contains("hunter2"))
        let checks = try XCTUnwrap(result["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.map { $0["image_attached"] as? Bool }, [true, true, true])
        XCTAssertEqual(checks.compactMap { $0["result"] as? String }, ["pass", "fail", "unknown"])
    }

    func testSecureFieldKeepsVerificationTextOnly() async throws {
        var effects = InputToolsBackend.Effects()
        effects.windows = { [] }
        effects.snapshot = { _ in InputSnapshot(windowExists: true, title: "Sign in",
            nodes: [InputNode(role: "AXSecureTextField", label: "Password", value: "hunter2")], focused: nil) }
        effects.capture = { _ in XCTFail("A window with a secure field must not be captured"); return (nil, nil) }
        let transport = ExtensionsJev(probabilities: [0.5])
        let result = try object(await InputToolsBackend(effects: effects, transport: transport, jevAvailable: { true })
            .invoke(name: "verify_state", arguments: ["target_pid": 42, "target_window_id": 7, "expect": ["criteria": ["Signed in"]]]))
        let checks = try XCTUnwrap(result["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.first?["image_skip_reason"] as? String, "secure_field")
        XCTAssertEqual(checks.first?["image_attached"] as? Bool, false)
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests.first?["state"] is [String: Any])
    }

    func testCriteriaWithoutKeyReturnsEvidenceAndNeverCallsJev() async throws {
        let transport = ExtensionsJev()
        let result = try object(await backend(transport, available: false).invoke(name: "verify_state", arguments: [
            "target_pid": 42, "target_window_id": 7, "expect": ["criteria": criteria],
        ]))
        XCTAssertEqual(result["result"] as? String, "unknown")
        let checks = try XCTUnwrap(result["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.count, 3)
        for check in checks {
            XCTAssertEqual(check["result"] as? String, "unknown")
            XCTAssertNil(check["probability"])
            XCTAssertEqual(check["evidence"] as? [[String: String]], [["role": "AXStaticText", "label": "Saved"]])
        }
        let requests = await transport.captured()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCriteriaValidationBoundaries() throws {
        func validate(_ criteria: Any) throws {
            try InputToolsBackend.validate(name: "verify_state", arguments: [
                "target_pid": 42, "target_window_id": 7, "expect": ["criteria": criteria],
            ])
        }
        XCTAssertNoThrow(try validate([String(repeating: "x", count: 200)]))
        XCTAssertNoThrow(try validate(Array(repeating: "Visible", count: 8)))
        for invalid in [[], [""], ["  "], [String(repeating: "x", count: 201)], Array(repeating: "Visible", count: 9), [1], "Visible"] as [Any] {
            XCTAssertThrowsError(try validate(invalid))
        }
    }

    func testBrowserProposalAndFilteringShareDecisionGates() async throws {
        let transport = ExtensionsJev()
        let decision = JevDecision(transport: transport)
        let proposal = try await decision.adviseBrowser(goal: "Continue", snapshot: snapshot)
        let json = proposal.jsonObject()
        XCTAssertEqual(json["operation"] as? String, "browser_act")
        XCTAssertEqual(json["action"] as? String, "click")
        XCTAssertEqual(json["ref"] as? String, "owned.0")
        XCTAssertEqual(json["role"] as? String, "button")
        XCTAssertEqual(json["label"] as? String, "Continue")
        XCTAssertEqual(json["probability"] as? Double, 0.99)
        XCTAssertEqual(json["confidence"] as? Double, 0.99)
        XCTAssertNotNil(json["signals"])
        XCTAssertNotNil(json["margin"])
        let requests = await transport.captured()
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: requests), as: UTF8.self)
        for secret in ["private value", "private message", "hunter2", "private.example", "private page content", "private title", "owned-state", "Send", "Duplicate", "Login"] {
            XCTAssertFalse(payload.contains(secret), secret)
        }
        let gated = try await decision.adviseBrowser(goal: "Continue", snapshot: snapshot, minConfidence: 1)
        XCTAssertEqual(gated.operation, "NEEDS_AGENT")
        let unauthorized = try await JevDecision(transport: ExtensionsJev(consequential: 1, authorized: 0)).adviseBrowser(goal: "Continue", snapshot: snapshot)
        XCTAssertEqual(unauthorized.operation, "BLOCKED")
    }

    func testBrowserFallbackWithholdsRiskAndKeepsRefs() throws {
        let decision = JevDecision(transport: ExtensionsJev())
        let fallback = try decision.localBrowserFallback(snapshot: snapshot)
        let candidates = try XCTUnwrap(fallback["candidates"] as? [[String: String]])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?["ref"], "owned.0")
        XCTAssertEqual(candidates.first?["action"], "click")
        let allowed = try decision.localBrowserFallback(snapshot: snapshot, allowedRisks: [.send])
        XCTAssertEqual((allowed["candidates"] as? [[String: String]])?.count, 2)
        XCTAssertThrowsError(try decision.localBrowserFallback(snapshot: ["elements": []]))
    }

    func testMCPBrowserModeUsesOwnedSnapshotWithoutNativeTarget() async throws {
        for available in [true, false] {
            let transport = ExtensionsJev()
            let server = ManagedComputerUseMCP(jev: JevDecision(transport: transport),
                browser: ExtensionsBrowser(snapshot: snapshot), jevAvailable: { available })
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "jev_decide", "arguments": ["browser": true, "goal": "Continue"]]]
            let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            let handled = await server.handle(line)
            let response = try XCTUnwrap(handled)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            let result = try XCTUnwrap(envelope["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, false)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            let text = try XCTUnwrap(content.first?["text"] as? String)
            let proposal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(proposal["operation"] as? String, available ? "browser_act" : "DEFER_TO_LLM")
            XCTAssertEqual(proposal["state_token"] as? String, "owned-state")
            let requests = await transport.captured()
            XCTAssertEqual(requests.count, available ? 1 : 0)
        }
    }
}
