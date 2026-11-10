import CoreModel
import Foundation
import AppKit
import SwiftUI
import DesignSystemKit

// Keybindings Settings pane (todo/macos-app.md :142, P1).
//
// Today users hand-edit ~/.remotecode/keybindings.json, restart, and get zero
// feedback. This pane gives feedback: it lists the parsed bindings + parse
// warnings, flags any user binding whose chord shadows a built-in menu shortcut
// (conflict detection against AppDelegate's static menu map), offers a
// record-a-shortcut control that prints the normalized chord string for copy
// into the JSON, and live-reloads on file change (plus a manual Reload).
//
// SCOPE (this version): read-only assist. The pane never writes the JSON file.
// The record control only displays the normalized chord; the user copies it in.

// MARK: - Reload notification

public extension Notification.Name {
    /// Posted on the main thread after KeybindingConfig.invalidateCache() and a
    /// fresh load complete (file-watcher change or manual Reload button). AppDelegate
    /// observes this to re-apply keybinding overrides to the live menu without
    /// requiring a relaunch.
    static let rc2KeybindingsReloaded = Notification.Name("rc2KeybindingsReloaded")
}

// MARK: - Pure conflict detector (nonisolated, testable)

/// A single detected conflict between a user binding and a built-in menu chord.
public struct KeybindingConflict: Equatable {
    /// The normalized chord (KeybindingConfig.normalize form, e.g. "mod+w").
    public let chord: String
    /// The user's command bound to that chord.
    public let userCommand: String
    /// The built-in menu item label the chord collides with (e.g. "Close Tab").
    public let builtInMenuLabel: String
}

public enum KeybindingConflictDetector {

    /// Built-in menu chords, normalized to KeybindingConfig.normalize form.
    ///
    /// SOURCE OF TRUTH: AppDelegate.installMainMenu() (AppDelegate.swift, the
    /// NSMenuItem construction at lines 494-641). NSMenuItem(keyEquivalent:) with
    /// no explicit keyEquivalentModifierMask defaults to `.command`, so a bare
    /// keyEquivalent "q" maps to chord "mod+q". Items that set an explicit mask
    /// (e.g. [.command, .shift]) are encoded accordingly. normalize() lowercases,
    /// maps cmd/command/meta -> mod, and sorts modifiers lexically
    /// (alt < ctrl < mod < opt < shift).
    ///
    /// This list MIRRORS AppDelegate and MUST stay in sync: if a menu shortcut is
    /// added/changed there, update it here (and KeybindingConflictTests guards the
    /// normalized form). Standard AppKit text-editing items (Cut/Copy/Paste/Select
    /// All) are intentionally included since a user binding could shadow them too.
    public static let builtInMenuChords: [(chord: String, label: String)] = [
        // App menu
        (KeybindingConfig.normalize("mod+,"), "Settings"),
        (KeybindingConfig.normalize("mod+h"), "Hide MacCode"),
        (KeybindingConfig.normalize("mod+q"), "Quit MacCode"),
        // File menu
        (KeybindingConfig.normalize("mod+n"), "New Workspace"),
        (KeybindingConfig.normalize("mod+w"), "Close Tab"),
        (KeybindingConfig.normalize("mod+shift+t"), "Reopen Closed Tab"),
        (KeybindingConfig.normalize("mod+shift+w"), "Close Window"),
        // Edit menu
        (KeybindingConfig.normalize("mod+z"), "Undo"),
        (KeybindingConfig.normalize("mod+shift+z"), "Redo"),
        (KeybindingConfig.normalize("mod+x"), "Cut"),
        (KeybindingConfig.normalize("mod+c"), "Copy"),
        (KeybindingConfig.normalize("mod+v"), "Paste"),
        (KeybindingConfig.normalize("mod+a"), "Select All"),
        // View menu
        (KeybindingConfig.normalize("mod+k"), "Show Command Palette"),
        // Surface menu
        (KeybindingConfig.normalize("mod+t"), "New Terminal Surface"),
        (KeybindingConfig.normalize("mod+b"), "New Browser Surface"),
        (KeybindingConfig.normalize("mod+g"), "New Agent App Surface"),
        (KeybindingConfig.normalize("mod+d"), "Split Right"),
        (KeybindingConfig.normalize("mod+shift+d"), "Split Down"),
        // Tab menu
        (KeybindingConfig.normalize("mod+shift+]"), "Next Tab"),
        (KeybindingConfig.normalize("mod+shift+["), "Previous Tab"),
        (KeybindingConfig.normalize("mod+1"), "Select Tab 1"),
        (KeybindingConfig.normalize("mod+2"), "Select Tab 2"),
        (KeybindingConfig.normalize("mod+3"), "Select Tab 3"),
        (KeybindingConfig.normalize("mod+4"), "Select Tab 4"),
        (KeybindingConfig.normalize("mod+5"), "Select Tab 5"),
        (KeybindingConfig.normalize("mod+6"), "Select Tab 6"),
        (KeybindingConfig.normalize("mod+7"), "Select Tab 7"),
        (KeybindingConfig.normalize("mod+8"), "Select Tab 8"),
        (KeybindingConfig.normalize("mod+9"), "Select Tab 9"),
        (KeybindingConfig.normalize("ctrl+tab"), "Focus Next Pane"),
        // Window menu
        (KeybindingConfig.normalize("mod+m"), "Minimize")
    ]

    /// Named (non-character) key tokens that AppDelegate cannot write as a raw
    /// keyEquivalent. AppKit's keyEquivalent expects a single printable character;
    /// named keys like "f1" or "escape" are not single printable characters, so
    /// writing them verbatim silently fails (the shortcut never fires).
    ///
    /// The set covers: function keys f1-f12, named whitespace/control keys
    /// (space, tab, return, enter), navigation/delete keys (escape, esc, delete,
    /// backspace, home, end, pageup, pagedown), and arrow keys (up, down, left,
    /// right). All tokens are lowercase to match KeybindingConfig.normalize output.
    private static let nonCharacterKeyTokens: Set<String> = [
        "f1", "f2", "f3", "f4", "f5", "f6",
        "f7", "f8", "f9", "f10", "f11", "f12",
        "space", "tab", "return", "enter",
        "escape", "esc", "delete", "backspace",
        "home", "end", "pageup", "pagedown",
        "up", "down", "left", "right"
    ]

    /// Returns true when the chord's key token (the non-modifier component after
    /// KeybindingConfig.normalize) is a named key that AppDelegate cannot write
    /// as a raw NSMenuItem keyEquivalent — meaning the shortcut will silently not
    /// fire in the app's menu system.
    ///
    /// Key-token extraction: normalize() returns `(mods + rest).joined("+")`.
    /// We re-normalize the chord defensively, split on "+", filter out the five
    /// recognized modifier tokens, and take the remainder as the key token.
    private static let modifierTokens: Set<String> = ["mod", "ctrl", "alt", "opt", "shift"]

    public static func isNonCharacterKey(_ chord: String) -> Bool {
        let normalized = KeybindingConfig.normalize(chord)
        // PERF: single pass avoids the split + map + filter intermediates on
        // the per-row render path; key token identical.
        var token: String?
        for part in normalized.split(separator: "+") where !modifierTokens.contains(String(part)) {
            token = String(part)
            break
        }
        guard let token else { return false }
        return nonCharacterKeyTokens.contains(token)
    }

    /// Detect user bindings whose normalized chord shadows a built-in menu chord.
    ///
    /// Both sides are compared in KeybindingConfig.normalize form so that
    /// "Cmd+W" (user) and "mod+w" (built-in) collide. The caller passes the
    /// parsed [Keybinding] (already normalized by KeybindingConfig.parse, but we
    /// re-normalize defensively so this is correct for any caller). One conflict
    /// is emitted per (binding, matching built-in) pair, in binding order.
    public static func conflicts(
        userBindings: [Keybinding],
        builtIn: [(chord: String, label: String)] = builtInMenuChords
    ) -> [KeybindingConflict] {
        var out: [KeybindingConflict] = []
        for b in userBindings {
            let chord = KeybindingConfig.normalize(b.key)
            for entry in builtIn where entry.chord == chord {
                out.append(KeybindingConflict(
                    chord: chord,
                    userCommand: b.command,
                    builtInMenuLabel: entry.label
                ))
            }
        }
        return out
    }
}

// MARK: - Record-a-shortcut control

/// Captures the next key chord via an NSEvent local keyDown monitor and shows
/// the normalized chord string so the user can copy it into keybindings.json.
///
/// Read-only: this never writes the JSON. The monitor is installed only while
/// "recording" and is always removed on disappear to avoid a leak.
struct ShortcutRecorder: View {
    @State private var recording = false
    @State private var captured: String = ""
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Button(recording ? "Press a shortcut\u{2026}" : "Record Shortcut") {
                if recording { stop() } else { start() }
            }
            .buttonStyle(DSSecondaryButtonStyle())
            .accessibilityIdentifier("settings.keybindings.record.button")

            if !captured.isEmpty {
                Text(captured)
                    .font(DS.Font.body.monospaced())
                    .foregroundColor(DS.Palette.accent)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.keybindings.record.chord")
                    .accessibilityLabel("Captured chord \(captured)")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        captured = ""
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            captured = Self.chord(from: event)
            stop()
            // Swallow the event so the captured chord does not also trigger a
            // menu action while recording.
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Build a normalized chord string from a keyDown event. Modifiers map to the
    /// same tokens normalize() understands (cmd -> mod), then we run normalize()
    /// so the output matches builtInMenuChords / parsed bindings exactly.
    static func chord(from event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags
        if flags.contains(.command) { parts.append("mod") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        parts.append(key.isEmpty ? "?" : key)
        return KeybindingConfig.normalize(parts.joined(separator: "+"))
    }
}

// MARK: - Live-reload file watcher

/// Watches ~/.remotecode/keybindings.json for changes and fires `onChange` on
/// the main actor. Guards against the file not existing (opens lazily; if absent
/// no source is created). Torn down on `stop()`.
@MainActor
final class KeybindingsFileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    func start(path: String, onChange: @escaping @MainActor () -> Void) {
        stop()
        guard FileManager.default.fileExists(atPath: path) else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        fd = descriptor
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        src.setEventHandler {
            MainActor.assumeIsolated { onChange() }
        }
        // Close the descriptor this source owns; `self.fd` may already belong to a newer watcher.
        src.setCancelHandler { [weak self] in
            close(descriptor)
            if let self, self.fd == descriptor { self.fd = -1 }
        }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        // Cancel handler closes the fd. If a source is still live, cancel it.
        source?.cancel()
    }
}

// MARK: - Pane View

struct KeybindingsSettingsPane: View {
    @State private var config = KeybindingConfig()
    @State private var conflicts: [KeybindingConflict] = []
    @State private var watcher = KeybindingsFileWatcher()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Keybindings")

            Text(L("Parsed from %1$@. Editing the JSON updates this list live; no restart needed. Conflicts shadow a built-in menu shortcut.", KeybindingConfig.defaultPath))
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)

            // Record-a-shortcut helper (read-only: copy the chord into the JSON).
            settingRow("Record a shortcut") {
                ShortcutRecorder()
            }

            if !config.warnings.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(Array(config.warnings.enumerated()), id: \.offset) { _, warn in
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(DS.Palette.warning)
                                .accessibilityHidden(true)
                            Text(warn)
                                .font(DS.Font.caption)
                                .foregroundColor(DS.Palette.warning)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Warning: \(warn)")
                    }
                }
                .accessibilityIdentifier("settings.keybindings.warnings")
            }

            if config.bindings.isEmpty {
                Text(L("No bindings defined. Add rules to keybindings.json to customize shortcuts."))
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("settings.keybindings.empty")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(config.bindings.enumerated()), id: \.offset) { _, b in
                        bindingRow(b)
                    }
                }
                .accessibilityIdentifier("settings.keybindings.list")
            }

            HStack {
                Spacer()
                Button(L("Reload")) { reload() }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("settings.keybindings.reload.button")
            }
        }
        .dsPanel(padding: DS.Space.lg)
        .onAppear {
            reload()
            watcher.start(path: KeybindingConfig.defaultPath) {
                reload()
            }
        }
        .onDisappear {
            watcher.stop()
        }
    }

    private func bindingRow(_ b: Keybinding) -> some View {
        let conflict = conflicts.first { $0.chord == b.key && $0.userCommand == b.command }
        let unsupportedKey = KeybindingConflictDetector.isNonCharacterKey(b.key)
        let hasWarning = conflict != nil || unsupportedKey
        return HStack(spacing: DS.Space.sm) {
            if hasWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(conflict != nil ? DS.Palette.danger : DS.Palette.warning)
                    .accessibilityHidden(true)
            }
            Text(b.key)
                .font(DS.Font.body.monospaced())
                .foregroundColor(DS.Palette.text)
                .frame(width: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.command)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.text)
                if let when = b.when, !when.isEmpty {
                    Text(L("when: %1$@", when))
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                }
                if let conflict {
                    Text(L("Shadows built-in: %1$@", conflict.builtInMenuLabel))
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.danger)
                }
                if unsupportedKey {
                    Text(L("Non-character key: won't work as a menu shortcut via AppDelegate"))
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.warning)
                }
            }
            Spacer()
        }
        .padding(.vertical, DS.Space.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel({
            var label = "\(b.key) bound to \(b.command)"
            if let conflict {
                label += ", conflict: shadows built-in \(conflict.builtInMenuLabel)"
            }
            if unsupportedKey {
                label += ", warning: non-character key won't work as a menu shortcut"
            }
            return label
        }())
    }

    /// settingRow mirror of SettingsView's helper (kept local so this pane is
    /// self-contained and does not depend on SettingsView internals).
    private func settingRow<Content: View>(_ label: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack {
            Text(label).font(DS.Font.body).foregroundColor(DS.Palette.text)
            Spacer()
            control()
                .accessibilityLabel(label)
        }
        .padding(.vertical, DS.Space.sm)
    }

    private func reload() {
        KeybindingConfig.invalidateCache()
        let loaded = KeybindingConfig.loadDefaultPath()
        config = loaded
        conflicts = KeybindingConflictDetector.conflicts(userBindings: loaded.bindings)
        // Notify AppDelegate so it re-applies keybinding overrides to the live menu.
        NotificationCenter.default.post(name: .rc2KeybindingsReloaded, object: nil)
    }
}
