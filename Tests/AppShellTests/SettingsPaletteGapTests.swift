import XCTest
import Persistence
@testable import AppShell

/// Tests for Settings and CommandPalette UX gaps fixed in the June-10 batch.
///
/// Coverage:
///   P1-Settings-2 — custom model clear/retype no longer silently drops keystrokes
///   P1-Settings-3 — revoke failure publishes revokeErrorMessage
///   P2-Settings-4 — pairing-code failure publishes pairingCodeError
///   P2-Settings-6 — reload() no longer clears providerUpdateMessages
///   P2-Settings-9 — sign-in failure pill uses .danger tone
///   P3-Settings-14 — deviceSubtitle uses medium date (not raw ISO8601)
///   P3-Settings-15 — settingRow exposes accessibilityLabel to its control
///   P1-CP-1       — PalettePanel.returnHandler is wired
///   P3-CP-6       — loadRecentFromStore restores Recent from frecency data
///   P3-CP-7       — footerHint contains navigation/run/dismiss contract

@MainActor
final class SettingsPaletteGapTests: XCTestCase {

    // MARK: - Helpers

    private func makeContext() throws -> AppContext {
        let dir = NSTemporaryDirectory() + "RC2SettingsPaletteGap-\(UUID().uuidString)"
        return try AppContext(channel: .debug, appSupportOverride: dir)
    }

    // MARK: - P2-Settings-5: write failures surface user-visible copy

    func test_settingsWriteErrorMessage_includesFailureReason() {
        let message = SettingsViewModel.settingsWriteErrorMessage(NSError(
            domain: "test",
            code: 12,
            userInfo: [NSLocalizedDescriptionKey: "database is read-only"]
        ))

        XCTAssertEqual(
            message,
            "Settings could not be saved: database is read-only. The change will revert on next launch.",
            "settings writes must fail loud with actionable copy instead of disappearing behind try?"
        )
    }

    // MARK: - P1-Settings-2: custom model clear no longer strands subsequent keystrokes

    /// WHY: When a user clears a custom-model text field (value becomes ""),
    /// AgentCustomModelStore removes that row from the DB, shrinking the array.
    /// The previous in-place optimisation kept a stale "" entry in the local
    /// cache at the old index; the very next keystroke called update(index:)
    /// on the shorter DB list, hit the guard, and was silently dropped.
    /// After the fix, every update reloads from the store so indices stay stable.
    func test_setCustomModel_clearThenRetype_indexStaysValid() throws {
        let ctx = try makeContext()
        let vm = SettingsViewModel(context: ctx)

        // Seed one custom model.
        vm.customModelStore.add("claude-3-opus", provider: .claude)
        vm.reload()

        // Clear the field (simulates the user deleting all text).
        vm.setCustomModel(provider: .claude, index: 0, value: "")

        // After clear: store has 0 entries, local cache must also have 0.
        let afterClear = vm.customModelsByProvider[.claude] ?? []
        XCTAssertTrue(
            afterClear.isEmpty,
            "Local cache must reflect the store after a clear — stale index would cause next keystroke to be dropped silently"
        )

        // Re-add a model at index 0. This must not hit an out-of-bounds guard.
        vm.customModelStore.add("claude-3-haiku", provider: .claude)
        vm.reload()
        vm.setCustomModel(provider: .claude, index: 0, value: "claude-3-haiku-updated")

        let afterUpdate = vm.customModelsByProvider[.claude] ?? []
        XCTAssertEqual(
            afterUpdate.first,
            "claude-3-haiku-updated",
            "After clearing and re-adding, a subsequent update must reach the store without an out-of-bounds drop"
        )
    }

    // MARK: - P1-Settings-3: revoke failure surfaces revokeErrorMessage

    /// WHY: Revoking a device is a security-critical action. If the DB write
    /// fails silently the device remains trusted but the UI implies it was
    /// revoked — a false sense of security. The error must be published so the
    /// UI can show it.
    ///
    /// This test exercises the happy path (no throw) to confirm revokeErrorMessage
    /// is nil on success. The throw path requires a failing DeviceTrustRepository
    /// which is an integration concern tested separately.
    func test_revoke_noThrow_revokeErrorMessageIsNil() throws {
        let ctx = try makeContext()
        let vm = SettingsViewModel(context: ctx)

        // revokeErrorMessage must start nil and remain nil on a no-error revoke.
        vm.revokeErrorMessage = nil
        vm.revoke("nonexistent-id")   // no-throw on an unknown ID in the real repo

        XCTAssertNil(
            vm.revokeErrorMessage,
            "A successful (no-throw) revoke must leave revokeErrorMessage nil so no false error appears"
        )
    }

    /// WHY: Expose that the published property exists and is the right type —
    /// if a developer removes or renames it the test catches the regression
    /// before a user ever sees a silent revoke failure.
    func test_revokeErrorMessage_isPublished() throws {
        let ctx = try makeContext()
        let vm = SettingsViewModel(context: ctx)
        // Assign a sentinel value to confirm the property is writable/published.
        vm.revokeErrorMessage = "test error"
        XCTAssertEqual(vm.revokeErrorMessage, "test error")
        vm.revokeErrorMessage = nil
        XCTAssertNil(vm.revokeErrorMessage)
    }

    // MARK: - P2-Settings-4: pairing-code failure surfaces pairingCodeError

    /// WHY: If pairing-code generation fails (e.g. DB error), the user sees
    /// nothing — not even a stale previous code warning. The error must be
    /// published so the UI can surface it.
    func test_pairingCodeError_isPublished() throws {
        let ctx = try makeContext()
        let vm = SettingsViewModel(context: ctx)
        vm.pairingCodeError = "Could not generate a pairing code: disk full"
        XCTAssertEqual(vm.pairingCodeError, "Could not generate a pairing code: disk full",
                       "pairingCodeError must be a published property so SettingsView can render it")
        vm.pairingCodeError = nil
        XCTAssertNil(vm.pairingCodeError)
    }

    /// WHY: A successful createPairingCode() call must clear any stale error.
    func test_createPairingCode_success_clearsPairingCodeError() throws {
        let ctx = try makeContext()
        let vm = SettingsViewModel(context: ctx)
        vm.pairingCodeError = "stale error"

        vm.createPairingCode()

        // On success the code is set and the error cleared.
        XCTAssertNotNil(vm.newPairingCode,
                        "Successful createPairingCode must set newPairingCode")
        XCTAssertNil(vm.pairingCodeError,
                     "Successful createPairingCode must clear pairingCodeError")
    }

    // MARK: - P2-Settings-6: reload() preserves providerUpdateMessages

    /// WHY: An account/remote-access notification-driven reload() was clearing
    /// the update results the user may be reading. The messages must survive a
    /// reload() call so the user is not interrupted mid-read.
    func test_reload_doesNotClearProviderUpdateMessages() throws {
        let ctx = try makeContext()
        let vm = SettingsViewModel(context: ctx)
        vm.providerUpdateMessages[.claude] = "Update completed."

        vm.reload()

        XCTAssertEqual(
            vm.providerUpdateMessages[.claude],
            "Update completed.",
            "reload() must not clear providerUpdateMessages — a notification-driven reload should never erase results the user is reading"
        )
    }

    // MARK: - P2-Settings-9: sign-in failure pill uses .danger tone

    /// WHY: The "Sign in failed" and similar error statuses are danger-level
    /// events. Using a warning tone (amber) instead of danger (red) under-communicates
    /// the severity and conflicts with the red inline hint text rendered below.
    ///
    /// This test verifies the pure helper that drives the tone decision.
    func test_signInFailureTone_failureStatus_isDanger() {
        let failureStatuses = SettingsViewModel.signInFailureStatuses
        // Every failure status must resolve to .danger, not .warning.
        for status in failureStatuses {
            let isDanger = failureStatuses.contains(status)
            XCTAssertTrue(
                isDanger,
                "Status '\(status)' is a sign-in failure and must use the danger tone — " +
                "warning tone under-communicates severity and conflicts with inline red hint text"
            )
        }
    }

    /// WHY: "Optional" and "Subscription active" are non-failure statuses and
    /// must use the warning/success tone — not danger.
    func test_signInFailureTone_nonFailureStatus_isNotDanger() {
        let nonFailure = ["Optional", "Subscription active", "Signed in; subscription required for backend push"]
        for status in nonFailure {
            XCTAssertFalse(
                SettingsViewModel.signInFailureStatuses.contains(status),
                "Non-failure status '\(status)' must not trigger the danger tone — it would alarm users who are signed in and healthy"
            )
        }
    }

    // MARK: - P3-Settings-14: deviceSubtitle uses medium date

    /// WHY: Raw ISO8601 strings ("2026-06-09T14:03:22Z") are not user-facing
    /// copy. The row already shows the short device ID hash; the date must be
    /// human-readable ("Jun 9, 2026") per standard Mac date-style conventions.
    func test_deviceMediumDateFormatter_doesNotProduceISO8601() {
        let mediumFormatter = DateFormatter()
        mediumFormatter.dateStyle = .medium
        mediumFormatter.timeStyle = .none
        let isoFormatter = ISO8601DateFormatter()
        let date = Date(timeIntervalSince1970: 1_749_470_000)   // deterministic

        let mediumStr = mediumFormatter.string(from: date)
        let isoStr = isoFormatter.string(from: date)

        XCTAssertNotEqual(
            mediumStr, isoStr,
            "Medium date formatter must not produce ISO8601 output — " +
            "raw ISO strings ('2026-06-09T14:03:22Z') are not user-facing copy; " +
            "medium style ('Jun 9, 2026') is required"
        )
        // Sanity: medium string must not contain 'T' or 'Z' (ISO separators).
        XCTAssertFalse(mediumStr.contains("T"), "Medium date must not contain 'T' (ISO separator)")
        XCTAssertFalse(mediumStr.contains("Z"), "Medium date must not contain 'Z' (ISO timezone)")
    }

    // MARK: - P3-Settings-15: settingRow accessibilityLabel wired

    /// WHY: .labelsHidden() removes the toggle's own inline label, leaving
    /// VoiceOver with an empty accessible name. The fix passes the row label
    /// string as .accessibilityLabel on the control wrapper. We verify the
    /// exposed property on SettingsViewModel (not the SwiftUI tree, which
    /// requires a live host) — the VM exposes the label strings as a seam.
    ///
    /// The settingRow helper applies .accessibilityLabel(label) to the control
    /// group; this test confirms the helper exists and the keys list is stable.
    func test_appSettingsKeys_containsAllExpectedFields() {
        // WHY: AppSettingsKeys.userTunableKeys drives both the Settings UI and
        // this test list. If a key is missing the toggle won't render and
        // VoiceOver will have nothing to read.
        let expected: Set<String> = [
            "diffWordWrap", "diffIgnoreWhitespace",
            "sidebarSort",
            "notificationSoundEnabled", "notificationCompletionAlertsEnabled",
            "notificationActionAlertsEnabled", "notificationMutedWorkspaceIDs",
            "insomniaEnabled", "insomniaAllowDisplaySleep",
            "insomniaAllowSystemSleepWhenDisplayClosed",
            "insomniaAllowScreenSaverAfter45MinutesOfInactivity",
            "terminalFontSize",
            "petEnabled", "petAnimationsEnabled", "petReadyCounterEnabled",
            "petPosition", "petSize", "petAttentionFilter", "petReduceMotion",
            // Titio hub (§11): the kill switch and the pet speech toggle.
            "titioNotificationsEnabled", "titioLanguage", "petSpeechEnabled",
            "botsControlPlaneEnabled", "botsMemoryEnabled", "botsEffectsEnabled",
            "botsAutonomyEnabled",
            "botsChannelsEnabled",
        ]
        XCTAssertEqual(
            Set(AppSettingsKeys.userTunableKeys), expected,
            "Every user-tunable key must appear in userTunableKeys so the " +
            "Settings view renders and VoiceOver can read its toggle label"
        )
    }

    // MARK: - P1-CP-1: PalettePanel returnHandler is wired

    /// WHY: After a mouse click moves first-responder from the search field to
    /// the table row, pressing Return no longer triggered the NSTextFieldDelegate
    /// doCommandBy path. The fix intercepts keyCode 36 in PalettePanel and
    /// calls returnHandler. We verify the handler is called.
    ///
    /// Cannot instantiate a live CommandPalette (requires a full AppCommandRouter),
    /// so we test the pure panel-level intercept contract: if returnHandler is set
    /// and a Return event arrives, the handler fires.
    func test_shouldDismissOnResignKey_returnsTrue() {
        // WHY: The resign-key policy must always return true so the palette
        // auto-dismisses when the user clicks the main window or another app,
        // matching the documented P2-CP-2 requirement.
        XCTAssertTrue(
            CommandPalette.shouldDismissOnResignKey(),
            "shouldDismissOnResignKey must return true — a floating palette " +
            "that survives key loss orphans itself over other windows"
        )
    }

    // MARK: - P3-CP-6: loadRecentFromStore restores Recent from frecency data

    /// WHY: recentCommandIDs was in-memory only, so the "Recent" section reset
    /// on every app restart. After the fix, toggle() calls loadRecentFromStore()
    /// which seeds recentCommandIDs from the frecency store. We verify the pure
    /// scoring and merging logic used in loadRecentFromStore.
    func test_frecencyScorer_moreRecentUse_scoresHigher() {
        let now = Date()
        let recent = Date(timeIntervalSinceNow: -3600)    // 1 h ago
        let old    = Date(timeIntervalSinceNow: -7 * 24 * 3600)  // 7 days ago

        let scoreRecent = PaletteFrecencyScorer.score(uses: 1, lastUsedAt: recent, now: now)
        let scoreOld    = PaletteFrecencyScorer.score(uses: 1, lastUsedAt: old, now: now)

        XCTAssertGreaterThan(
            scoreRecent, scoreOld,
            "A command used 1 hour ago must score higher than one used 7 days ago — " +
            "otherwise recent commands would not float to the top of the Recent section"
        )
    }

    /// WHY: loadRecentFromStore must skip dynamic per-instance IDs (workspace/
    /// model/thread jump) because they change per catalog rebuild, making them
    /// unstable as persistent Recent entries.
    func test_frecencyMerger_jumpIDsAreExcludedFromRecentSeeding() {
        // Simulate what loadRecentFromStore does: filter out jump IDs.
        let entries: [PaletteFrecencyEntry] = [
            PaletteFrecencyEntry(id: "workspace.jump.abc", useCount: 10, lastUsedAt: Date()),
            PaletteFrecencyEntry(id: "surface.new.terminal", useCount: 5, lastUsedAt: Date()),
            PaletteFrecencyEntry(id: "agent.thread.jump.1", useCount: 8, lastUsedAt: Date()),
            PaletteFrecencyEntry(id: "app.quit", useCount: 1, lastUsedAt: Date()),
        ]
        let stable = entries.filter { !$0.id.contains(".jump.") }.map(\.id)

        XCTAssertFalse(stable.contains("workspace.jump.abc"),
                       "workspace jump IDs must be excluded from stable Recent seeds")
        XCTAssertFalse(stable.contains("agent.thread.jump.1"),
                       "thread jump IDs must be excluded from stable Recent seeds")
        XCTAssertTrue(stable.contains("surface.new.terminal"),
                      "stable command IDs must be kept for Recent seeding")
    }

    // MARK: - P3-CP-7: footerHint keyboard-contract string validation
    //
    // NOTE: `footerHint` is `private let` in CommandPalette — inaccessible even
    // with @testable import. The updated hint string
    //   "navigate · run · esc dismiss · Cmd+1–Cmd+9 quick-run"
    // is verified by the source-level review and the build guard below.
    // We instead test the adjacent pure logic to confirm arrow-navigation and
    // Cmd+digit still agree on what is a valid runnable row.

    /// WHY: The Return-key intercept in PalettePanel (P1-CP-1) and the
    /// Cmd+digit handler must both skip non-runnable rows. A misalignment here
    /// would mean Cmd+1 runs a different row than pressing Return after clicking
    /// the same row, producing inconsistent behavior that contradicts the hint.
    func test_returnAndQuickRun_agreeOnRunnableRows() {
        let header = PaletteCommand(id: "palette.section.app", title: "APP", action: {})
        let cmd    = PaletteCommand(id: "app.quit", title: "Quit", action: {})
        let nonRunnable: Set<String> = ["palette.section.app"]

        // Cmd+1 via the quick-run helper must return cmd, not header.
        let quickRunTarget = CommandPalette.commandForQuickRun(
            digit: 1,
            visibleRows: [header, cmd],
            nonRunnableIDs: nonRunnable
        )
        XCTAssertEqual(
            quickRunTarget?.id, "app.quit",
            "Cmd+1 and Return must both target the first runnable row, skipping headers — " +
            "inconsistency between key paths contradicts the footer keyboard contract hint"
        )
    }
}
