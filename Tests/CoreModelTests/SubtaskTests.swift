import Foundation
import XCTest
@testable import CoreModel

final class SubtaskTests: XCTestCase {
    private func base(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["goal": "Save the note", "verification": ["Note title shows Saved"]].merging(extra) { $1 }
    }

    private func assertRejects(_ object: [String: Any], field: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Subtask.parse(object), file: file, line: line) { error in
            XCTAssertTrue("\(error)".contains("'\(field)"), "\(error) should name \(field)", file: file, line: line)
        }
    }

    func testParseAppliesDefaults() throws {
        let task = try Subtask.parse(base())
        XCTAssertEqual(task.maxActions, 30)
        XCTAssertEqual(task.minConfidence, 0)
        XCTAssertEqual(task.minMargin, 0)
        XCTAssertFalse(task.dryRun)
        XCTAssertTrue(task.allowedRisks.isEmpty)
    }

    func testBareStringVerificationRejected() {
        assertRejects(base(["verification": "Saved"]), field: "verification")
        assertRejects(base(["verification": []]), field: "verification")
        assertRejects(["goal": "x"], field: "verification")
        assertRejects(base(["goal": "  "]), field: "goal")
    }

    func testInputsDistinguishBooleansFromNumbers() throws {
        let json = #"{"goal":"g","verification":["v"],"inputs":{"n":1,"b":true,"s":"x","f":2.5}}"#
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let task = try Subtask.parse(parsed)
        XCTAssertEqual(task.inputs, ["n": "1", "b": "true", "s": "x", "f": "2.5"])
        assertRejects(base(["inputs": ["a": [1]]]), field: "inputs.a")
        assertRejects(base(["inputs": ["a": Double.nan]]), field: "inputs.a")
        // A boolean is not a valid integer, so max_actions: true must fail.
        let flag = try JSONSerialization.jsonObject(with: Data(#"{"goal":"g","verification":["v"],"max_actions":true}"#.utf8)) as! [String: Any]
        assertRejects(flag, field: "max_actions")
        assertRejects(base(["max_actions": 0]), field: "max_actions")
        assertRejects(base(["max_actions": 1.5]), field: "max_actions")
        XCTAssertEqual(try Subtask.parse(base(["max_actions": 5])).maxActions, 5)
    }

    func testShortcutChordsValidated() throws {
        XCTAssertEqual(try Subtask.parse(base(["shortcuts": ["MOD+S": "save", "MOD+SHIFT+F12": "x", "ALT+ENTER": "y"]])).shortcuts.count, 3)
        for bad in ["S", "mod+s", "MOD+", "MOD+F21", "MOD+F0", "MOD+AB", "S+MOD", "MOD+MOD2+S", "MOD+PAGE"] {
            assertRejects(base(["shortcuts": [bad: "x"]]), field: "shortcuts.\(bad)")
        }
    }

    func testRisksSecretsAndThresholds() throws {
        assertRejects(base(["allowed_risks": ["explode"]]), field: "allowed_risks")
        XCTAssertEqual(try Subtask.parse(base(["allowed_risks": ["send", "close"]])).allowedRisks, [.send, .close])
        assertRejects(base(["secret_inputs": ["token"], "inputs": ["name": "a"]]), field: "secret_inputs")
        assertRejects(base(["min_confidence": 1.5]), field: "min_confidence")
        assertRejects(base(["min_margin": -0.1]), field: "min_margin")
        assertRejects(base(["dry_run": "yes"]), field: "dry_run")
    }

    func testRiskClassifyMatchesWholeWordsOnly() {
        XCTAssertEqual(RiskCategory.classify("Empty Trash"), .delete)
        XCTAssertNil(RiskCategory.classify("Closet"))
        XCTAssertNil(RiskCategory.classify("Postal code"))
        XCTAssertEqual(RiskCategory.classify("Sign out"), .close)
        XCTAssertEqual(RiskCategory.classify("Place   Order"), .purchase)
        XCTAssertEqual(RiskCategory.classify("Reply All"), .send)
        XCTAssertNil(RiskCategory.classify("Save"))
    }

    func testRedactorReplacesLongestSecretFirstAndRecurses() throws {
        let task = try Subtask.parse(base(["inputs": ["a": "hunter", "b": "hunter2", "c": "public"], "secret_inputs": ["a", "b"]]))
        let redactor = SecretRedactor(subtask: task)
        XCTAssertEqual(redactor.redact("pw hunter2 and hunter, public"), "pw [secret] and [secret], public")
        let json = redactor.redact(json: ["k": ["hunter2", 3, ["x": "a hunter"]]]) as! [String: Any]
        XCTAssertEqual(json["k"] as! NSArray, ["[secret]", 3, ["x": "a [secret]"]] as NSArray)
        XCTAssertEqual(SecretRedactor(secrets: [""]).redact("abc"), "abc")
    }

    func testGate() {
        XCTAssertTrue(Subtask.gate(confidence: nil, margin: nil, minConfidence: 0.9, minMargin: 0.9))
        XCTAssertTrue(Subtask.gate(confidence: 0.8, margin: 0.2, minConfidence: 0.8, minMargin: 0.2))
        XCTAssertFalse(Subtask.gate(confidence: 0.7, margin: 0.5, minConfidence: 0.8, minMargin: 0))
        XCTAssertFalse(Subtask.gate(confidence: 0.9, margin: 0.1, minConfidence: 0, minMargin: 0.2))
    }

    func testRedactJSONAlsoRedactsDictionaryKeys() throws {
        let redactor = SecretRedactor(secrets: ["hunter2"])
        let out = redactor.redact(json: ["hunter2": ["nested hunter2": ["hunter2"]]])
        let text = String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8)!
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertTrue(text.contains("[secret]"))
    }

    func testParseErrorsNeverEchoInvalidInputDerivedValues() {
        for object in [
            base(["allowed_risks": ["hunter2"]]),
            base(["secret_inputs": ["hunter2"]]),
        ] {
            XCTAssertThrowsError(try Subtask.parse(object)) { error in
                XCTAssertFalse("\(error)".contains("hunter2"), "\(error)")
            }
        }
        assertRejects(base(["allowed_risks": ["hunter2"]]), field: "allowed_risks")
        assertRejects(base(["secret_inputs": ["nope"]]), field: "secret_inputs")
    }

    func testRawArgumentRedactorHandlesUnvalidatedShapes() {
        let redactor = SecretRedactor(rawArguments: [
            "inputs": ["a": "hunter2", "n": 42, "bad": [1]], "secret_inputs": ["a", "n", "bad", 7, "missing"],
        ])
        XCTAssertEqual(redactor.redact("hunter2 42 x"), "[secret] [secret] x")
        XCTAssertTrue(SecretRedactor(rawArguments: ["inputs": "oops", "secret_inputs": "oops"]).isEmpty)
    }
}
