import Foundation
import XCTest
@testable import CoreModel

private final class FakeBackend: ComputerUseToolBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var trees: [String]
    private var observed = 0
    private(set) var calls: [(name: String, arguments: [String: Any])] = []
    var mutationText = #"{"settle_ms":42,"settled":true}"#
    var mutationError = false

    init(trees: [String]) { self.trees = trees }

    var mutations: [(name: String, arguments: [String: Any])] { calls.filter { $0.name != "get_ui_tree" } }

    func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        let tree: String? = lock.withLock {
            calls.append((name, arguments))
            guard name == "get_ui_tree" else { return nil }
            defer { observed += 1 }
            return trees[min(observed, trees.count - 1)]
        }
        if let tree { return ComputerUseToolResult(text: tree) }
        return ComputerUseToolResult(text: mutationText, isError: mutationError)
    }
}

private final class FakeTransport: JevTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let script: @Sendable ([String: Any], Int) -> [String: Any]
    private(set) var requests: [[String: Any]] = []

    init(_ script: @escaping @Sendable ([String: Any], Int) -> [String: Any]) { self.script = script }

    func evaluate(_ request: [String: Any]) async throws -> [String: Any] {
        let index = lock.withLock { () -> Int in
            requests.append(request)
            return requests.count - 1
        }
        return script(request, index)
    }

    var requestText: String {
        requests.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .compactMap { String(data: $0, encoding: .utf8) }.joined()
    }
}

private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64] = []
    func add(_ value: UInt64) { lock.lock(); values.append(value); lock.unlock() }
    var all: [UInt64] { lock.lock(); defer { lock.unlock() }; return values }
}

private func answer(
    _ request: [String: Any], _ operation: String, target: String? = nil, input: String? = nil,
    submit: String = "NONE", hotkey: String? = nil, verify: Double = 0.97, constraint: Double = 0.97
) -> [String: Any] {
    let questions = request["questions"] as? [String: [String: Any]] ?? [:]
    func choice(_ name: String, _ selected: String?) -> [String: Any]? {
        guard let selected, let criteria = questions[name]?["criteria"] as? [String: Any] else { return nil }
        let others = criteria.keys.filter { $0 != selected }
        var probabilities = Dictionary(uniqueKeysWithValues: others.map { ($0, 0.05 / Double(max(others.count, 1))) })
        probabilities[selected] = others.isEmpty ? 1 : 0.95
        return ["choice": selected, "confidence": 0.95, "probabilities": probabilities]
    }
    var answers: [String: Any] = ["constraint_ok": ["noul": constraint]]
    answers["operation"] = choice("operation", operation)
    answers["target"] = choice("target", target)
    answers["input"] = choice("input", input)
    answers["submit"] = choice("submit", input == nil ? nil : submit)
    answers["hotkey"] = choice("hotkey", hotkey)
    for name in questions.keys where name.hasPrefix("verify_") { answers[name] = ["noul": verify] }
    return ["answers": answers]
}

final class SubtaskRunnerTests: XCTestCase {
    private let target = ComputerUseNativeHostTarget(pid: 42, windowID: 7)

    private func observation(token: String, children: [[String: Any]], ocr: String? = nil) -> String {
        let header: [String: Any] = [
            "state_token": token, "user_activity": "none", "is_minimized": false, "is_on_screen": true,
            "permissions": ["accessibility": true],
        ]
        let tree: [String: Any] = ["id": "ax_0", "role": "AXWindow", "title": "Form", "children": children]
        func json(_ object: Any) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
        }
        return json(header) + "\nui_tree: " + json(tree) + (ocr.map { "\nocr: " + json([$0]) } ?? "")
    }

    private func field(_ id: String, _ title: String, value: String = "") -> [String: Any] {
        ["id": id, "role": "AXTextField", "title": title, "value": value, "enabled": true]
    }

    private func button(_ id: String, _ title: String) -> [String: Any] {
        ["id": id, "role": "AXButton", "title": title, "enabled": true]
    }

    private func runner(
        _ backend: any ComputerUseToolBackend, _ transport: FakeTransport, sleeps: SleepLog = SleepLog()
    ) -> SubtaskRunner {
        let lock = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-cu-tests-\(UUID().uuidString)/computer-use.lock")
        return SubtaskRunner(
            backend: backend, transport: transport, queue: ComputerUseHostQueue(lockURL: lock),
            sleep: { sleeps.add($0) })
    }

    private func subtask(_ extra: [String: Any] = [:]) throws -> Subtask {
        var object: [String: Any] = ["goal": "Fill in the form", "verification": ["Name field shows the name"]]
        object.merge(extra) { _, new in new }
        return try Subtask.parse(object)
    }

    func testCompletesInTwoStepsAndNeverLeaksSecret() async throws {
        let backend = FakeBackend(trees: [
            observation(token: "t0", children: [field("ax_1", "Password"), button("ax_2", "Save")], ocr: "Enter password"),
            observation(token: "t1", children: [field("ax_1", "Password", value: "hunter2"), button("ax_2", "Save")]),
        ])
        let transport = FakeTransport { request, index in
            index == 0 ? answer(request, "SET_VALUE", target: "ax_1", input: "input_0", submit: "ENTER")
                : answer(request, "DONE")
        }
        let task = try subtask(["inputs": ["password": "hunter2"], "secret_inputs": ["password"]])
        let result = await runner(backend, transport).run(target: target, subtask: task, dryRun: false)
        XCTAssertEqual(result["status"] as? String, "SUBTASK_COMPLETE")
        XCTAssertEqual(result["actions_taken"] as? Int, 1)
        let mutation = try XCTUnwrap(backend.mutations.first)
        XCTAssertEqual(mutation.name, "set_value")
        XCTAssertEqual(mutation.arguments["value"] as? String, "hunter2")
        XCTAssertEqual(mutation.arguments["element_id"] as? String, "ax_1")
        XCTAssertEqual(mutation.arguments["submit_key"] as? String, "ENTER")
        XCTAssertEqual(mutation.arguments["expected_state_token"] as? String, "t0")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertFalse(transport.requestText.contains("hunter2"), "secret reached the model")
        let output = String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!
        XCTAssertFalse(output.contains("hunter2"), "secret reached the result")
        let history = try XCTUnwrap(result["history"] as? [[String: Any]])
        XCTAssertEqual(history.first?["settle_ms"] as? Int, 42)
        XCTAssertEqual(history.first?["input_key"] as? String, "password")
        XCTAssertEqual(mutation.arguments["allowed_risks"] as? [String], [])
        XCTAssertEqual(history.first?["state_changed"] as? Bool, true)
    }

    func testRiskyControlIsWithheldAndForgedChoiceIsNotExecuted() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save"), button("ax_2", "Delete")])])
        let transport = FakeTransport { request, _ in answer(request, "CLICK", target: "ax_2") }
        let result = await runner(backend, transport).run(target: target, subtask: try subtask(), dryRun: false)
        let request = try XCTUnwrap(transport.requests.first)
        let elements = try XCTUnwrap((request["state"] as? [String: Any])?["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.compactMap { $0["id"] as? String }, ["ax_1"])
        XCTAssertFalse(transport.requestText.contains("Delete"))
        XCTAssertEqual(result["status"] as? String, "NEEDS_AGENT")
        XCTAssertEqual(result["reason"] as? String, "invalid decision")
        XCTAssertTrue(backend.mutations.isEmpty)
    }

    func testRiskyControlIsOfferedOnlyWhenTheCategoryIsAllowed() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Delete draft")])])
        let transport = FakeTransport { request, index in
            index == 0 ? answer(request, "CLICK", target: "ax_1") : answer(request, "DONE")
        }
        let task = try subtask(["allowed_risks": ["delete"]])
        let result = await runner(backend, transport).run(target: target, subtask: task, dryRun: false)
        XCTAssertEqual(result["status"] as? String, "SUBTASK_COMPLETE")
        XCTAssertEqual(backend.mutations.first?.name, "click_element")
    }

    func testNeedsInputReturnsFieldDetailsAndOptions() async throws {
        let popup: [String: Any] = [
            "id": "ax_3", "role": "AXPopUpButton", "title": "Country", "value": "", "enabled": true,
            "children": [["role": "AXMenuItem", "title": "Brazil"], ["role": "AXMenuItem", "title": "Chile"]],
        ]
        let backend = FakeBackend(trees: [observation(token: "t0", children: [popup])])
        let transport = FakeTransport { request, _ in answer(request, "NEEDS_INPUT", target: "ax_3") }
        let result = await runner(backend, transport).run(target: target, subtask: try subtask(), dryRun: false)
        XCTAssertEqual(result["status"] as? String, "NEEDS_INPUT")
        let info = try XCTUnwrap(result["needs_input"] as? [String: Any])
        XCTAssertEqual(info["element_id"] as? String, "ax_3")
        XCTAssertEqual(info["role"] as? String, "AXPopUpButton")
        XCTAssertEqual(info["name"] as? String, "Country")
        XCTAssertEqual(info["options"] as? [String], ["Brazil", "Chile"])
        XCTAssertTrue(backend.mutations.isEmpty)
    }

    func testNeedsInputIsNotOfferedWithoutTextLikeElements() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        let transport = FakeTransport { request, _ in answer(request, "BLOCKED") }
        _ = await runner(backend, transport).run(target: target, subtask: try subtask(["inputs": ["name": "Ann"]]), dryRun: false)
        let questions = try XCTUnwrap(transport.requests.first?["questions"] as? [String: [String: Any]])
        let operations = try XCTUnwrap(questions["operation"]?["criteria"] as? [String: Any])
        XCTAssertNil(operations["SET_VALUE"])
        XCTAssertNil(operations["NEEDS_INPUT"])
        XCTAssertNil(questions["input"])
        XCTAssertNotNil(operations["HOTKEY"])
    }

    func testDryRunPlansWithoutMutating() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        let transport = FakeTransport { request, _ in answer(request, "CLICK", target: "ax_1") }
        let result = await runner(backend, transport).run(target: target, subtask: try subtask(), dryRun: true)
        XCTAssertEqual(result["status"] as? String, "DRY_RUN")
        let planned = try XCTUnwrap(result["planned_action"] as? [String: Any])
        XCTAssertEqual(planned["action"] as? String, "CLICK")
        XCTAssertEqual(planned["target"] as? String, "ax_1")
        XCTAssertTrue(backend.mutations.isEmpty)
        XCTAssertEqual(result["actions_taken"] as? Int, 0)
    }

    func testBudgetStopsTheLoop() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Next")])])
        let transport = FakeTransport { request, _ in answer(request, "CLICK", target: "ax_1") }
        let result = await runner(backend, transport).run(
            target: target, subtask: try subtask(["max_actions": 2]), dryRun: false)
        XCTAssertEqual(result["status"] as? String, "NEEDS_AGENT")
        XCTAssertEqual(result["reason"] as? String, "action budget reached")
        XCTAssertEqual(backend.mutations.count, 2)
    }

    func testBlockedAfterActionIsRecheckedWhenTheScreenChanged() async throws {
        let first = observation(token: "t0", children: [button("ax_1", "Next")])
        let second = observation(token: "t1", children: [button("ax_1", "Next"), field("ax_2", "Status", value: "loading")])
        let third = observation(token: "t2", children: [button("ax_1", "Next"), field("ax_2", "Status", value: "loaded")])
        let backend = FakeBackend(trees: [first, second, third])
        let transport = FakeTransport { request, index in
            switch index {
            case 0: return answer(request, "CLICK", target: "ax_1")
            case 1: return answer(request, "BLOCKED")
            default: return answer(request, "DONE")
            }
        }
        let sleeps = SleepLog()
        let result = await runner(backend, transport, sleeps: sleeps).run(target: target, subtask: try subtask(), dryRun: false)
        XCTAssertEqual(result["status"] as? String, "SUBTASK_COMPLETE")
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(sleeps.all, [1_000_000_000])
    }

    func testBlockedAfterActionStaysBlockedWhenTheScreenIsUnchanged() async throws {
        let tree = observation(token: "t0", children: [button("ax_1", "Next")])
        let backend = FakeBackend(trees: [tree])
        let transport = FakeTransport { request, index in
            index == 0 ? answer(request, "CLICK", target: "ax_1") : answer(request, "BLOCKED")
        }
        let result = await runner(backend, transport).run(target: target, subtask: try subtask(), dryRun: false)
        XCTAssertEqual(result["status"] as? String, "BLOCKED")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testInvalidAnswerIsRetriedOnceThenGivesUp() async throws {
        let tree = observation(token: "t0", children: [button("ax_1", "Save")])
        let retried = FakeTransport { request, index in
            index == 0 ? ["answers": [String: Any]()] : answer(request, "DONE")
        }
        let ok = await runner(FakeBackend(trees: [tree]), retried).run(target: target, subtask: try subtask(), dryRun: false)
        XCTAssertEqual(ok["status"] as? String, "SUBTASK_COMPLETE")
        XCTAssertEqual(retried.requests.count, 2)

        let broken = FakeTransport { _, _ in ["answers": [String: Any]()] }
        let failed = await runner(FakeBackend(trees: [tree]), broken).run(target: target, subtask: try subtask(), dryRun: false)
        XCTAssertEqual(failed["status"] as? String, "NEEDS_AGENT")
        XCTAssertEqual(failed["reason"] as? String, "invalid decision")
        XCTAssertEqual(broken.requests.count, 2)
    }

    func testDoneNeedsEveryVerificationCriterion() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        let transport = FakeTransport { request, _ in answer(request, "DONE", verify: 0.5) }
        let result = await runner(backend, transport).run(target: target, subtask: try subtask(), dryRun: false)
        XCTAssertEqual(result["status"] as? String, "NEEDS_AGENT")
        XCTAssertTrue((result["reason"] as? String)?.contains("Name field shows the name") == true)
    }

    func testViolatedConstraintStopsBeforeActing() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        let transport = FakeTransport { request, _ in answer(request, "CLICK", target: "ax_1", constraint: 0.2) }
        let result = await runner(backend, transport).run(
            target: target, subtask: try subtask(["constraints": ["Do not touch Save"]]), dryRun: false)
        XCTAssertEqual(result["status"] as? String, "NEEDS_AGENT")
        XCTAssertTrue(backend.mutations.isEmpty)
    }

    func testMarginGateAndHotkeyExecution() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        let hotkey = FakeTransport { request, index in
            index == 0 ? answer(request, "HOTKEY", hotkey: "MOD+S") : answer(request, "DONE")
        }
        let done = await runner(backend, hotkey).run(target: target, subtask: try subtask(), dryRun: false)
        XCTAssertEqual(done["status"] as? String, "SUBTASK_COMPLETE")
        XCTAssertEqual(backend.mutations.first?.name, "menu_shortcut")
        XCTAssertEqual(backend.mutations.first?.arguments["chord"] as? String, "MOD+S")

        let gated = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        let strict = FakeTransport { request, _ in answer(request, "CLICK", target: "ax_1") }
        let blocked = await runner(gated, strict).run(
            target: target, subtask: try subtask(["min_margin": 0.99]), dryRun: false)
        XCTAssertEqual(blocked["status"] as? String, "NEEDS_AGENT")
        XCTAssertTrue(gated.mutations.isEmpty)
    }

    func testBackendErrorAndHumanActivityStopTheLoop() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        backend.mutationError = true
        backend.mutationText = "native computer-use error: human_activity"
        let transport = FakeTransport { request, _ in answer(request, "CLICK", target: "ax_1") }
        let result = await runner(backend, transport).run(target: target, subtask: try subtask(), dryRun: false)
        XCTAssertEqual(result["status"] as? String, "NEEDS_AGENT")
        XCTAssertEqual(result["reason"] as? String, "user took control")

        let busy = observation(token: "t0", children: [button("ax_1", "Save")])
            .replacingOccurrences(of: #""user_activity":"none""#, with: #""user_activity":"human""#)
        let stopped = await runner(FakeBackend(trees: [busy]), transport).run(target: target, subtask: try subtask(), dryRun: false)
        XCTAssertEqual(stopped["reason"] as? String, "user took control")
        XCTAssertTrue(transport.requests.count == 1)
    }

    func testLogLineIsRedactedJSONL() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [field("ax_1", "Password")])])
        let transport = FakeTransport { request, index in
            index == 0 ? answer(request, "SET_VALUE", target: "ax_1", input: "input_0") : answer(request, "DONE")
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("subtask-\(UUID().uuidString).jsonl").path
        let task = try subtask(["inputs": ["password": "hunter2"], "secret_inputs": ["password"]])
        _ = await runner(backend, transport).run(target: target, subtask: task, dryRun: false, logPath: path)
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["choice"] as? String, "SET_VALUE")
        XCTAssertEqual(first["input_key"] as? String, "password")
        XCTAssertEqual(first["outcome"] as? String, "executed")
        XCTAssertFalse(lines.joined().contains("hunter2"))
    }

    func testInputKeyNamesNeverReachJevOrResult() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [field("ax_1", "Password")])])
        let transport = FakeTransport { request, index in
            index == 0 ? answer(request, "SET_VALUE", target: "ax_1", input: "input_0") : answer(request, "DONE")
        }
        let task = try subtask(["inputs": ["hunter2": "hunter2"], "secret_inputs": ["hunter2"]])
        let result = await runner(backend, transport).run(target: target, subtask: task, dryRun: false)
        XCTAssertEqual(result["status"] as? String, "SUBTASK_COMPLETE")
        XCTAssertEqual(backend.mutations.first?.arguments["value"] as? String, "hunter2")
        XCTAssertFalse(transport.requestText.contains("hunter2"), "secret key name reached the model")
        let output = String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!
        XCTAssertFalse(output.contains("hunter2"), "secret key name reached the result")
    }

    func testSecretLongerThanClipLimitIsRedactedBeforeTruncation() async throws {
        let secret = String(repeating: "s", count: 100) + String(repeating: "k", count: 101)
        let backend = FakeBackend(trees: [
            observation(token: "t0", children: [field("ax_1", "Password", value: secret), button("ax_2", secret)], ocr: secret),
        ])
        let transport = FakeTransport { request, _ in answer(request, "DONE") }
        let task = try subtask(["inputs": ["pw": secret], "secret_inputs": ["pw"]])
        _ = await runner(backend, transport).run(target: target, subtask: task, dryRun: false)
        XCTAssertFalse(transport.requests.isEmpty)
        XCTAssertFalse(transport.requestText.contains(String(repeating: "s", count: 20)), "clipped secret prefix leaked")
        XCTAssertFalse(transport.requestText.contains(String(repeating: "k", count: 20)), "clipped secret suffix leaked")
        XCTAssertTrue(transport.requestText.contains("[secret]"))
    }

    func testRunnerObservationArgumentsAreAcceptedByRealBackendValidation() async throws {
        let seen = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        _ = await runner(seen, FakeTransport { request, _ in answer(request, "DONE") })
            .run(target: target, subtask: try subtask(), dryRun: false)
        let arguments = try XCTUnwrap(seen.calls.first { $0.name == "get_ui_tree" }?.arguments)
        XCTAssertEqual(arguments["ocr"] as? String, "auto")

        let window = ComputerUseNativeWindow(target: target, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let tree = #"{"id":"ax_0","role":"AXWindow","title":"Form","children":[{"id":"ax_1","role":"AXButton","title":"Save"}]}"#
        let real = ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in [window] }, userActivity: { _ in .none }, activityMonitorAvailable: { true },
            accessibilityPermission: { true }, axTargetAvailable: { _ in true }, screenCapturePermission: { true },
            capture: { _ in .unavailable("offline") }, uiTree: { _ in tree }, settleWatcher: { _ in .immediate }))
        let result = await runner(real, FakeTransport { request, _ in answer(request, "DONE") })
            .run(target: target, subtask: try subtask(), dryRun: false)
        XCTAssertEqual(result["status"] as? String, "SUBTASK_COMPLETE", "\(result["reason"] ?? "")")
    }

    func testRiskyMenuRefusalFromBackendBecomesNeedsAgentAndRisksAreAlwaysSent() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        backend.mutationText = "native computer-use error: semantic_action_failed\nrisky menu item 'Close' requires allowed_risks close"
        backend.mutationError = true
        let transport = FakeTransport { request, _ in answer(request, "HOTKEY", hotkey: "MOD+S") }
        let result = await runner(backend, transport).run(target: target, subtask: try subtask(), dryRun: false)
        XCTAssertEqual(result["status"] as? String, "NEEDS_AGENT")
        XCTAssertTrue((result["reason"] as? String)?.contains("risk category") == true)
        XCTAssertEqual(backend.mutations.first?.arguments["allowed_risks"] as? [String], [])

        let allowed = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        _ = await runner(allowed, FakeTransport { request, index in
            index == 0 ? answer(request, "HOTKEY", hotkey: "MOD+S") : answer(request, "DONE")
        }).run(target: target, subtask: try subtask(["allowed_risks": ["send", "close"]]), dryRun: false)
        XCTAssertEqual(allowed.mutations.first?.arguments["allowed_risks"] as? [String], ["close", "send"])
    }

    func testMCPValidationErrorNeverEchoesSecret() async throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("rc-cu-tests-\(UUID().uuidString)/computer-use.lock")
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        let handler = ManagedComputerUseMCP(
            queue: ComputerUseHostQueue(lockURL: lock), backend: backend,
            jevAvailable: { true }, jevTransport: FakeTransport { request, _ in answer(request, "DONE") })
        let (isError, message) = try await call(handler, [
            "target_pid": 42, "target_window_id": 7, "goal": "x", "verification": ["v"],
            "inputs": ["token": "hunter2"], "secret_inputs": ["token"], "allowed_risks": ["hunter2"],
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(message.contains("allowed_risks"), message)
        XCTAssertFalse(message.contains("hunter2"), message)
        let (_, other) = try await call(handler, [
            "target_pid": 42, "target_window_id": 7, "goal": "hunter2", "verification": "hunter2",
            "inputs": ["token": "hunter2"], "secret_inputs": ["token"],
        ])
        XCTAssertFalse(other.contains("hunter2"), other)
    }

    private func call(_ handler: ManagedComputerUseMCP, _ arguments: [String: Any]) async throws -> (Bool, String) {
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "run_subtask", "arguments": arguments],
        ]
        let line = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
        let raw = await handler.handle(line)
        let reply = try XCTUnwrap(raw)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let parts = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (result["isError"] as? Bool ?? false, parts.first?["text"] as? String ?? "")
    }

    func testMCPRunSubtaskReportsFieldErrorsAndMissingKey() async throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("rc-cu-tests-\(UUID().uuidString)/computer-use.lock")
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        let keyed = ManagedComputerUseMCP(
            queue: ComputerUseHostQueue(lockURL: lock), backend: backend,
            jevAvailable: { true }, jevTransport: FakeTransport { request, _ in answer(request, "DONE") })
        let (invalid, message) = try await call(keyed, ["target_pid": 42, "target_window_id": 7, "goal": "x"])
        XCTAssertTrue(invalid)
        XCTAssertTrue(message.contains("verification"), message)
        XCTAssertTrue(backend.calls.isEmpty)

        let (done, text) = try await call(keyed, [
            "target_pid": 42, "target_window_id": 7, "goal": "x", "verification": ["v"],
        ])
        XCTAssertFalse(done)
        XCTAssertTrue(text.contains("SUBTASK_COMPLETE"), text)

        let unkeyed = ManagedComputerUseMCP(
            queue: ComputerUseHostQueue(lockURL: lock), backend: backend, jevAvailable: { false })
        let (missing, note) = try await call(unkeyed, [
            "target_pid": 42, "target_window_id": 7, "goal": "x", "verification": ["v"],
        ])
        XCTAssertTrue(missing)
        XCTAssertTrue(note.contains("run_subtask needs OPENROUTER_API_KEY or a Jev key"), note)
    }

    func testSingleCandidateGetsANoneOptionAndChoosingItStopsWithoutActing() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [button("ax_1", "Save")])])
        let transport = FakeTransport { request, _ in answer(request, "CLICK", target: "NONE") }
        let result = await runner(backend, transport).run(target: target, subtask: try subtask(), dryRun: false)
        // d1.2-ultra rejects a one-option choice with HTTP 422, and NONE lets the model refuse the only control.
        let questions = try XCTUnwrap(transport.requests.first?["questions"] as? [String: [String: Any]])
        XCTAssertEqual((questions["target"]?["criteria"] as? [String: String])?.keys.sorted(), ["NONE", "ax_1"])
        XCTAssertEqual(result["status"] as? String, "NEEDS_AGENT")
        XCTAssertEqual(result["reason"] as? String, "model chose none of the offered elements")
        XCTAssertTrue(backend.mutations.isEmpty)
    }

    func testSingleInputGetsANoneOptionAndChoosingItStopsWithoutTyping() async throws {
        let backend = FakeBackend(trees: [observation(token: "t0", children: [field("ax_1", "Name"), button("ax_2", "Save")])])
        let transport = FakeTransport { request, _ in answer(request, "SET_VALUE", target: "ax_1", input: "NONE") }
        let result = await runner(backend, transport).run(
            target: target, subtask: try subtask(["inputs": ["name": "Ana"]]), dryRun: false)
        let questions = try XCTUnwrap(transport.requests.first?["questions"] as? [String: [String: Any]])
        XCTAssertEqual((questions["input"]?["criteria"] as? [String: String])?.keys.sorted(), ["NONE", "input_0"])
        XCTAssertEqual(result["status"] as? String, "NEEDS_AGENT")
        XCTAssertEqual(result["reason"] as? String, "model chose none of the offered inputs")
        XCTAssertTrue(backend.mutations.isEmpty)
    }

    func testHistoryNamesTheModelThatDecidedEachStep() async throws {
        let backend = FakeBackend(trees: [
            observation(token: "t0", children: [button("ax_1", "Save"), button("ax_2", "Cancel")]),
            observation(token: "t1", children: [button("ax_1", "Save"), button("ax_2", "Cancel")]),
        ])
        let transport = FakeTransport { request, index in
            var reply = index == 0 ? answer(request, "CLICK", target: "ax_1") : answer(request, "DONE")
            reply["engine"] = "typesafe/jev-1.14"
            reply["fallback_reason"] = "liquid/d1.2-ultra HTTP 503"
            return reply
        }
        let result = await runner(backend, transport).run(target: target, subtask: try subtask(), dryRun: false)
        XCTAssertEqual(result["status"] as? String, "SUBTASK_COMPLETE")
        let history = try XCTUnwrap(result["history"] as? [[String: Any]])
        XCTAssertEqual(history.first?["engine"] as? String, "typesafe/jev-1.14")
        XCTAssertEqual(history.first?["fallback_reason"] as? String, "liquid/d1.2-ultra HTTP 503")
    }
}
