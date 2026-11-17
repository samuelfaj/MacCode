import Foundation

public enum SubtaskStatus: String, Sendable {
    case SUBTASK_COMPLETE, BLOCKED, NEEDS_AGENT, NEEDS_INPUT, DRY_RUN
}

public enum SubtaskError: Error, CustomStringConvertible, Equatable {
    case invalid(field: String, reason: String)

    public var description: String {
        switch self {
        case .invalid(let field, let reason): "Invalid subtask field '\(field)': \(reason)"
        }
    }
}

/// Controls whose label names an irreversible or externally visible effect.
/// They are only offered to a model when the subtask explicitly allows the category.
public enum RiskCategory: String, CaseIterable, Sendable {
    case delete, send, purchase, close

    private static let phrases: [RiskCategory: [String]] = [
        .delete: ["delete", "remove", "erase", "trash", "discard", "clear all", "empty trash", "permanently"],
        .send: ["send", "post", "publish", "share", "reply all", "forward", "tweet"],
        .purchase: ["buy", "purchase", "pay", "checkout", "check out", "place order", "order now", "subscribe",
                    "donate", "confirm payment"],
        .close: ["close", "quit", "exit", "sign out", "log out", "logout", "shut down", "restart", "uninstall"],
    ]

    /// Every category whose whole-word phrase appears in the label.
    public static func categories(_ label: String) -> Set<RiskCategory> {
        let lowered = label.lowercased()
        return Set(allCases.filter { category in
            (phrases[category] ?? []).contains { phrase in
                let words = phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
                return lowered.range(of: pattern, options: .regularExpression) != nil
            }
        })
    }

    public static func classify(_ label: String) -> RiskCategory? {
        let found = categories(label)
        return allCases.first { found.contains($0) }
    }
}

public struct SecretRedactor: Sendable {
    public static let placeholder = "[secret]"
    private let secrets: [String]

    public init(subtask: Subtask) {
        self.init(secrets: subtask.secretInputs.compactMap { subtask.inputs[$0] })
    }

    /// Best effort over unvalidated tool arguments, so errors raised before parsing never echo a secret.
    public init(rawArguments: [String: Any]) {
        let inputs = rawArguments["inputs"] as? [String: Any] ?? [:]
        let names = rawArguments["secret_inputs"] as? [Any] ?? []
        self.init(secrets: names.compactMap { ($0 as? String).flatMap { inputs[$0] } }.compactMap { value in
            if let string = value as? String { return string }
            return (value as? NSNumber)?.stringValue
        })
    }

    public init(secrets: [String]) {
        self.secrets = Array(Set(secrets.filter { !$0.isEmpty })).sorted { $0.count > $1.count || ($0.count == $1.count && $0 < $1) }
    }

    public var isEmpty: Bool { secrets.isEmpty }

    public func redact(_ text: String) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: Self.placeholder) }
    }

    public func redact(json value: Any) -> Any {
        if let string = value as? String { return redact(string) }
        if let dictionary = value as? [String: Any] {
            return Dictionary(dictionary.map { (redact($0.key), redact(json: $0.value)) }, uniquingKeysWith: { first, _ in first })
        }
        if let array = value as? [Any] { return array.map { redact(json: $0) } }
        return value
    }
}

public struct Subtask: Sendable, Equatable {
    public let goal: String
    public let verification: [String]
    public let constraints: [String]
    /// Literal text the model may type; numbers and booleans are stored in their typed text form.
    public let inputs: [String: String]
    public let maxActions: Int
    public let shortcuts: [String: String]
    public let allowedRisks: Set<RiskCategory>
    public let secretInputs: [String]
    public let dryRun: Bool
    public let minConfidence: Double
    public let minMargin: Double

    private static let modifiers: Set<String> = ["MOD", "CTRL", "ALT", "SHIFT"]
    private static let namedKeys: Set<String> = [
        "ENTER", "TAB", "ESCAPE", "SPACE", "DELETE", "UP", "DOWN", "LEFT", "RIGHT", "HOME", "END", "PAGEUP", "PAGEDOWN",
    ]

    /// Pass when each supplied value meets its threshold; a nil value is not gated.
    public static func gate(confidence: Double?, margin: Double?, minConfidence: Double, minMargin: Double) -> Bool {
        (confidence.map { $0 >= minConfidence } ?? true) && (margin.map { $0 >= minMargin } ?? true)
    }

    public static func parse(_ obj: [String: Any]) throws -> Subtask {
        guard let goal = obj["goal"] as? String, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw fail("goal", "must be a non-empty string")
        }
        let verification = try strings(obj["verification"], "verification", required: true)
        let constraints = try strings(obj["constraints"], "constraints", required: false)

        var inputs: [String: String] = [:]
        if let raw = obj["inputs"] {
            guard let dictionary = raw as? [String: Any] else { throw fail("inputs", "must be an object") }
            for (name, value) in dictionary {
                if let string = value as? String {
                    inputs[name] = string
                } else if let flag = bool(value) {
                    inputs[name] = flag ? "true" : "false"
                } else if let number = number(value), number.isFinite {
                    inputs[name] = text(number)
                } else {
                    throw fail("inputs.\(name)", "must be a string, finite number or boolean")
                }
            }
        }

        var maxActions = 30
        if let raw = obj["max_actions"] {
            guard bool(raw) == nil, let value = number(raw), value.isFinite, value == value.rounded(),
                  let count = Int(exactly: value), count >= 1 else {
                throw fail("max_actions", "must be an integer >= 1")
            }
            maxActions = count
        }

        var shortcuts: [String: String] = [:]
        if let raw = obj["shortcuts"] {
            guard let dictionary = raw as? [String: Any] else { throw fail("shortcuts", "must be an object") }
            for (chord, description) in dictionary {
                guard validChord(chord) else {
                    throw fail("shortcuts.\(chord)", "chord must be uppercase modifiers (MOD, CTRL, ALT, SHIFT) plus a key, such as MOD+S")
                }
                guard let text = description as? String else { throw fail("shortcuts.\(chord)", "description must be a string") }
                shortcuts[chord] = text
            }
        }

        var allowedRisks = Set<RiskCategory>()
        for name in try strings(obj["allowed_risks"], "allowed_risks", required: false) {
            guard let category = RiskCategory(rawValue: name) else {
                throw fail("allowed_risks", "every entry must be one of delete, send, purchase, close")
            }
            allowedRisks.insert(category)
        }

        let secretInputs = try strings(obj["secret_inputs"], "secret_inputs", required: false)
        if secretInputs.contains(where: { inputs[$0] == nil }) {
            throw fail("secret_inputs", "every entry must be a key of inputs")
        }

        var dryRun = false
        if let raw = obj["dry_run"] {
            guard let flag = bool(raw) else { throw fail("dry_run", "must be a boolean") }
            dryRun = flag
        }

        return Subtask(
            goal: goal, verification: verification, constraints: constraints, inputs: inputs, maxActions: maxActions,
            shortcuts: shortcuts, allowedRisks: allowedRisks, secretInputs: secretInputs, dryRun: dryRun,
            minConfidence: try unit(obj["min_confidence"], "min_confidence"),
            minMargin: try unit(obj["min_margin"], "min_margin"))
    }

    private static func fail(_ field: String, _ reason: String) -> SubtaskError {
        .invalid(field: field, reason: reason)
    }

    private static func strings(_ raw: Any?, _ field: String, required: Bool) throws -> [String] {
        guard let raw else {
            if required { throw fail(field, "is required") }
            return []
        }
        guard let array = raw as? [Any] else { throw fail(field, "must be an array of strings") }
        let values = try array.map { element -> String in
            guard let string = element as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw fail(field, "must contain only non-empty strings")
            }
            return string
        }
        if required && values.isEmpty { throw fail(field, "must not be empty") }
        return values
    }

    private static func unit(_ raw: Any?, _ field: String) throws -> Double {
        guard let raw else { return 0 }
        guard bool(raw) == nil, let value = number(raw), value.isFinite, (0...1).contains(value) else {
            throw fail(field, "must be a number between 0 and 1")
        }
        return value
    }

    private static func validChord(_ chord: String) -> Bool {
        let parts = chord.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let key = parts.last else { return false }
        guard parts.dropLast().allSatisfy({ modifiers.contains($0) }) else { return false }
        if namedKeys.contains(key) { return true }
        if key.count == 1, let scalar = key.unicodeScalars.first,
           ("A"..."Z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)) { return true }
        if key.hasPrefix("F"), let index = Int(key.dropFirst()), (1...20).contains(index),
           key.dropFirst().allSatisfy(\.isASCII), !key.dropFirst().hasPrefix("0") { return true }
        return false
    }

    private static func bool(_ value: Any) -> Bool? {
        guard let object = value as? NSNumber else { return nil }
        #if canImport(Darwin)
        return CFGetTypeID(object) == CFBooleanGetTypeID() ? object.boolValue : nil
        #else
        return type(of: value) == Bool.self ? object.boolValue : nil
        #endif
    }

    private static func number(_ value: Any) -> Double? {
        guard bool(value) == nil, let object = value as? NSNumber else { return nil }
        return object.doubleValue
    }

    private static func text(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(Int(number)) }
        return String(number)
    }
}
