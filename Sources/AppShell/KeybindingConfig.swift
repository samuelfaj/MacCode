import Foundation
import os
import CoreModel

private let keybindingLog = Logger(subsystem: "io.remotecode.appshell", category: "keybindings")

public struct Keybinding: Codable, Equatable, Sendable {
    public let key: String
    public let command: String
    public let when: String?
}

/// Loads/parses `~/.remotecode/keybindings.json` and resolves a key
/// chord + UI context to a command. T3 Code semantics: `when` is a
/// space-separated AND of identifiers, `!` negates; invalid rules are
/// dropped with a warning; the last matching rule wins.
public struct KeybindingConfig: Equatable {
    public let bindings: [Keybinding]
    public let warnings: [String]

    public init(bindings: [Keybinding] = [], warnings: [String] = []) {
        self.bindings = bindings
        self.warnings = warnings
    }

    // MARK: - Warning observer seam (:19 / T037)

    /// Called synchronously from `parse()` whenever warnings are produced.
    /// Production: nil (warnings go to os_log only).
    /// Tests: set to a closure that captures warnings so the test can assert them.
    ///
    /// WHY this seam exists: parse warnings silently disappeared into nothing
    /// before :19. os_log entries are invisible to XCTest; this closure lets a
    /// test prove the fail-loud contract (if warnings exist, something observes
    /// them) without depending on any AppKit surface.
    public static var onWarningsEmitted: (([String]) -> Void)? = nil

    public static func parse(_ data: Data) -> KeybindingConfig {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            let warns = ["keybindings.json is not a JSON array — using defaults"]
            for w in warns { keybindingLog.warning("\(w, privacy: .public)") }
            onWarningsEmitted?(warns)
            return KeybindingConfig(warnings: warns)
        }
        var out: [Keybinding] = []
        var warns: [String] = []
        for (i, raw) in arr.enumerated() {
            guard let key = raw["key"] as? String, !key.isEmpty,
                  let cmd = raw["command"] as? String, !cmd.isEmpty else {
                warns.append(L("rule %1$@ missing key/command — dropped", i))
                continue
            }
            out.append(Keybinding(key: normalize(key), command: cmd, when: raw["when"] as? String))
        }
        if !warns.isEmpty {
            for w in warns { keybindingLog.warning("\(w, privacy: .public)") }
            onWarningsEmitted?(warns)
        }
        return KeybindingConfig(bindings: out, warnings: warns)
    }

    /// Lowercase, sort modifiers, canonicalize `cmd`→`mod`, strip spaces:
    /// `Cmd+Shift+K` and `mod+shift+k` resolve identically.
    public static func normalize(_ key: String) -> String {
        let parts = key.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+").map(String.init)
            .map { $0 == "cmd" || $0 == "command" || $0 == "meta" ? "mod" : $0 }
        let mods = parts.filter { ["mod", "ctrl", "alt", "opt", "shift"].contains($0) }.sorted()
        let rest = parts.filter { !["mod", "ctrl", "alt", "opt", "shift"].contains($0) }
        return (mods + rest).joined(separator: "+")
    }

    public static func evalWhen(_ expr: String?, context: Set<String>) -> Bool {
        guard let expr = expr?.trimmingCharacters(in: .whitespaces), !expr.isEmpty else { return true }
        for token in expr.split(separator: " ").map(String.init) where !token.isEmpty {
            let negated = token.hasPrefix("!")
            let id = negated ? String(token.dropFirst()) : token
            let present = context.contains(id)
            if negated ? present : !present { return false }
        }
        return true
    }

    /// Last matching rule wins (T3 Code precedence).
    public func command(forKey key: String, context: Set<String> = []) -> String? {
        let k = Self.normalize(key)
        var hit: String?
        for b in bindings where b.key == k && Self.evalWhen(b.when, context: context) {
            hit = b.command
        }
        return hit
    }

    /// QA-005: testable seam — load + parse from an explicit path so tests can
    /// point at a fixture URL without mutating the process HOME.
    public static func load(path: String) -> KeybindingConfig {
        guard let data = FileManager.default.contents(atPath: path) else {
            return KeybindingConfig()
        }
        return parse(data)
    }

    public static var defaultPath: String {
        NSHomeDirectory() + "/.remotecode/keybindings.json"
    }

    /// PERF-008: the keybindings file is unchanging within a session, so parse
    /// it once and serve the cached config. `loadDefaultPath()` previously
    /// re-read + re-parsed the file on every menu-item override. Call
    /// `invalidateCache()` from a file-watch event if live reload is wired.
    ///
    /// `@MainActor` enforces the documented invariant that the cache is only
    /// accessed from the main thread, preventing a data race if a background
    /// consumer is ever added (PERF note: currently only AppDelegate on MainActor
    /// calls these).
    @MainActor private static var cached: KeybindingConfig?

    @MainActor public static func loadDefaultPath() -> KeybindingConfig {
        if let cached { return cached }
        let config = load(path: defaultPath)
        cached = config
        return config
    }

    @MainActor public static func invalidateCache() {
        cached = nil
    }
}
