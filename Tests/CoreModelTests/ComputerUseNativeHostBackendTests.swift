import XCTest
import AppKit
import ScreenCaptureKit
@testable import CoreModel

final class ComputerUseNativeHostBackendTests: XCTestCase {
    func test_doctorNamesTheLaunchingAppAndRemediationWhenPermissionsAreMissing() async throws {
        // WHY: the helper's own permission checks resolve against the TCC
        // "responsible" app that launched the provider. A bare `false` sent the
        // owner hunting in the wrong place (2026-09-14: RemoteCode toggled on in
        // System Settings, helper still false — stale/duplicate entry).
        func backend(accessibility: Bool, screenCapture: Bool) -> ComputerUseNativeHostBackend {
            ComputerUseNativeHostBackend(hooks: .init(
                listWindows: { _ in [ComputerUseNativeWindow(
                    target: .init(pid: 17, windowID: 29),
                    title: "RemoteCode",
                    bundleIdentifier: "com.example.RemoteCode",
                    isOnScreen: true,
                    isMinimized: false,
                    bounds: .zero
                )] },
                userActivity: { _ in .none },
                activityMonitorAvailable: { true },
                accessibilityPermission: { accessibility },
                axTargetAvailable: { _ in accessibility },
                screenCapturePermission: { screenCapture },
                capture: { _ in .unavailable("test") },
                uiTree: { _ in nil },
                hostLauncherPath: { "/Applications/MacCode.app/Contents/MacOS/RemoteCode" }
            ))
        }
        let missing = await backend(accessibility: false, screenCapture: false).invoke(
            name: "doctor",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )
        let text = try XCTUnwrap(missing.content.first?.text)
        // JSONSerialization escapes "/" as "\/"; compare on unescaped content.
        let unescaped = text.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(unescaped.contains("\"launched_by\":\"/Applications/MacCode.app/Contents/MacOS/RemoteCode\""), unescaped)
        XCTAssertTrue(unescaped.contains("\"remediation\":"), unescaped)
        XCTAssertTrue(unescaped.contains("Screen Recording and Accessibility for /Applications/MacCode.app"), unescaped)
        XCTAssertTrue(unescaped.contains("remove the entry and add the app again"), unescaped)

        let granted = await backend(accessibility: true, screenCapture: true).invoke(
            name: "doctor",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )
        let grantedText = try XCTUnwrap(granted.content.first?.text)
        XCTAssertFalse(grantedText.contains("remediation"), "no remediation noise when both permissions hold")
        XCTAssertNil(ComputerUseNativeHostBackend.permissionRemediation(accessibility: true, screenCapture: true, launchedBy: nil))
        XCTAssertEqual(
            ComputerUseNativeHostBackend.permissionRemediation(accessibility: true, screenCapture: false, launchedBy: nil)?.hasPrefix("Missing Screen Recording for the app that launched this run."),
            true
        )
    }

    func test_hostLauncherWalkResolvesParentChainWithoutTouchingTCC() {
        // The test process always has a parent; the walk must terminate and
        // return either an .app executable or the top-most ancestor path.
        XCTAssertGreaterThan(ComputerUseNativeHostBackend.NativePlatform.parentPID(of: getpid()), 0)
        _ = ComputerUseNativeHostBackend.NativePlatform.hostLauncherExecutablePath()
    }

    func test_observationResolvesExactTargetWithoutActivation() async throws {
        let probe = Probe()
        let backend = makeBackend(probe: probe)

        let result = await backend.invoke(
            name: "screenshot",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )

        XCTAssertFalse(result.isError)
        let metadata = try XCTUnwrap(result.content.first?.text)
        XCTAssertTrue(metadata.contains("\"target_pid\":17"))
        XCTAssertTrue(metadata.contains("\"target_window_id\":29"))
        XCTAssertTrue(metadata.contains("\"state_token\":"))
        XCTAssertTrue(metadata.contains("\"capture_mode\":"))
        XCTAssertTrue(metadata.contains("\"capabilities\":"))
        XCTAssertTrue(metadata.contains("\"user_activity\":"))
        XCTAssertEqual(probe.activations, 0, "observing a target must not activate or raise its window")
    }

    func testObservationSelectsRequestedWindowWhenProcessOwnsMultipleWindows() async throws {
        // WHY: PID-only resolution can silently observe the first sibling
        // window while claiming the requested window ID in the tool call.
        let probe = Probe()
        probe.additionalWindows = [ComputerUseNativeWindow(
            target: .init(pid: 17, windowID: 30),
            title: "Second window",
            bundleIdentifier: "com.example.RemoteCode",
            isOnScreen: true,
            isMinimized: false,
            bounds: .zero
        )]
        let backend = makeBackend(probe: probe)

        let result = await backend.invoke(
            name: "screenshot",
            arguments: ["target_pid": 17, "target_window_id": 30]
        )

        XCTAssertFalse(result.isError)
        let metadata = try XCTUnwrap(result.content.first?.text)
        XCTAssertTrue(metadata.contains("\"target_window_id\":30"))
        XCTAssertFalse(metadata.contains("\"target_window_id\":29"))
    }

    func testTargetIDsRejectLossyJSONNumbersAndInvalidRanges() async throws {
        // WHY: NSNumber's intValue/int32Value silently truncates fractions and
        // wraps large values, which could observe or mutate the wrong window.
        let probe = Probe()
        let backend = makeBackend(probe: probe)
        let invalidArguments: [[String: Any]] = [
            ["target_pid": NSNumber(value: 17.5), "target_window_id": 29],
            ["target_pid": NSNumber(value: true), "target_window_id": 29],
            ["target_pid": NSNumber(value: Double.nan), "target_window_id": 29],
            ["target_pid": 0, "target_window_id": 29],
            ["target_pid": -1, "target_window_id": 29],
            ["target_pid": Int64(Int32.max) + 1, "target_window_id": 29],
            ["target_pid": 17, "target_window_id": NSNumber(value: 29.5)],
            ["target_pid": 17, "target_window_id": NSNumber(value: true)],
            ["target_pid": 17, "target_window_id": NSNumber(value: Double.infinity)],
            ["target_pid": 17, "target_window_id": 0],
            ["target_pid": 17, "target_window_id": -1],
            ["target_pid": 17, "target_window_id": UInt64(UInt32.max) + 1],
        ]

        for arguments in invalidArguments {
            let result = await backend.invoke(name: "doctor", arguments: arguments)
            XCTAssertTrue(result.isError, "invalid target must fail closed: \(arguments)")
            XCTAssertTrue(result.content.first?.text?.contains("invalid_target") == true)
        }
    }

    func testCaptureUsesInjectedAsyncExactWindowHook() async throws {
        let probe = Probe()
        let backend = makeBackend(probe: probe)

        let result = await backend.invoke(
            name: "screenshot",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.last?.type, "image")
        XCTAssertEqual(probe.captureCalls, 1)
    }

    func testQuartzFallbackCaptureIsReturnedAsSingleExactImageRead() async throws {
        let probe = Probe()
        probe.captureFallback = true
        let backend = makeBackend(probe: probe)

        let result = await backend.invoke(
            name: "screenshot",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.last?.type, "image")
        XCTAssertEqual(probe.captureCalls, 1, "a fallback capture must not be retried for token generation")
        let metadata = try XCTUnwrap(result.content.first?.text)
        XCTAssertTrue(metadata.contains("\"target_pid\":17"))
        XCTAssertTrue(metadata.contains("\"target_window_id\":29"))
        XCTAssertFalse(metadata.contains(probe.captureData), "observation metadata must not expose captured pixels")
    }

    func testQuartzFallbackValidationFailsClosedForDriftMissingSymbolAndFailedImage() {
        let target = ComputerUseNativeHostTarget(pid: 17, windowID: 29)
        let before = ComputerUseNativeHostBackend.NativePlatform.QuartzWindowSnapshot(
            pid: target.pid,
            windowID: target.windowID,
            isOnScreen: true,
            bounds: .init(x: 10, y: 20, width: 640, height: 480)
        )
        let drifted = ComputerUseNativeHostBackend.NativePlatform.QuartzWindowSnapshot(
            pid: target.pid,
            windowID: target.windowID,
            isOnScreen: true,
            bounds: .init(x: 11, y: 20, width: 640, height: 480)
        )

        XCTAssertEqual(
            ComputerUseNativeHostBackend.NativePlatform.quartzFallbackValidationFailure(
                target: target,
                before: before,
                symbolAvailable: true,
                imageSize: .init(width: 640, height: 480),
                after: drifted
            ),
            "window_identity_or_bounds_drifted_after"
        )
        XCTAssertEqual(
            ComputerUseNativeHostBackend.NativePlatform.quartzFallbackValidationFailure(
                target: target,
                before: before,
                symbolAvailable: false,
                imageSize: nil,
                after: nil
            ),
            "quartz_fallback_symbol_unavailable"
        )
        XCTAssertEqual(
            ComputerUseNativeHostBackend.NativePlatform.quartzFallbackValidationFailure(
                target: target,
                before: before,
                symbolAvailable: true,
                imageSize: nil,
                after: nil
            ),
            "quartz_fallback_image_unavailable"
        )
    }

    func testQuartzFallbackOnlyHandlesScreenCaptureInternalError() {
        XCTAssertTrue(
            ComputerUseNativeHostBackend.NativePlatform.allowsQuartzFallback(
                domain: SCStreamErrorDomain,
                code: -3811
            )
        )
        XCTAssertFalse(
            ComputerUseNativeHostBackend.NativePlatform.allowsQuartzFallback(
                domain: SCStreamErrorDomain,
                code: -3801
            )
        )
        XCTAssertFalse(
            ComputerUseNativeHostBackend.NativePlatform.allowsQuartzFallback(
                domain: "other.domain",
                code: -3811
            )
        )
    }

    func testAXWindowArrayRejectsWrongCoreFoundationElementTypes() {
        let malformedWindows = NSArray(object: "not-an-AXUIElement") as CFArray
        XCTAssertNil(
            ComputerUseNativeHostBackend.NativePlatform.axElements(from: malformedWindows),
            "AX window resolution must fail closed when the AXWindows CFArray contains a wrong type"
        )
    }

    func testAXTitleFallbackRequiresUniqueQuartzTargetTitle() {
        let target = ComputerUseNativeHostTarget(pid: 17, windowID: 29)
        func window(_ id: UInt32, title: String) -> ComputerUseNativeWindow {
            ComputerUseNativeWindow(
                target: .init(pid: 17, windowID: id),
                title: title,
                bundleIdentifier: "com.example.fixture",
                isOnScreen: true,
                isMinimized: false,
                bounds: CGRect(x: 20, y: 30, width: 640, height: 480)
            )
        }

        XCTAssertFalse(
            ComputerUseNativeHostBackend.NativePlatform.quartzTitleUniquelyIdentifiesTarget(
                "Fixture",
                target: target,
                windows: [window(29, title: "Fixture"), window(30, title: "Fixture")]
            ),
            "a title-only AX match must fail closed when Quartz has another same-PID window with that title"
        )
        XCTAssertTrue(
            ComputerUseNativeHostBackend.NativePlatform.quartzTitleUniquelyIdentifiesTarget(
                "Fixture",
                target: target,
                windows: [window(29, title: "Fixture"), window(30, title: "Other")]
            )
        )
    }

    func testCaptureFailureReturnsDiagnosticWithoutPixels() async throws {
        let probe = Probe()
        probe.captureFailure = "screenshot_manager_test_failure"
        let backend = makeBackend(probe: probe)

        let result = await backend.invoke(
            name: "screenshot",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )

        XCTAssertTrue(result.isError)
        let text = try XCTUnwrap(result.content.first?.text)
        XCTAssertTrue(text.contains("capture_unavailable"))
        XCTAssertTrue(text.contains("capture_failure: screenshot_manager_test_failure"))
        XCTAssertEqual(result.content.count, 1, "capture failures must not emit an image content part")
        XCTAssertEqual(probe.captureCalls, 1, "a failed capture must not be retried for token generation")
        XCTAssertFalse(text.contains(probe.captureData), "diagnostics must not expose captured pixels")
    }

    func test_staleStateTokenExecutesNoMutation() async throws {
        // WHY: a positional element id only means something in the observation it was read
        // from. Once the window changed, pressing "ax_1" could press a different control.
        let probe = Probe()
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend)
        probe.windowTitle = "changed by the user"

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "element_id": "ax_1"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("stale_state_token") == true)
        XCTAssertEqual(probe.semanticMutations, 0, "stale state must fail before any AX mutation")
    }

    func test_semanticContentChangeWithStableGeometryStillResolvesRoleAndLabel() async throws {
        // WHY (mac-use v1.7.0 contract): in a live window the whole-tree token is stale before
        // any action arrives, which made every Slack and Chrome action fail. A role+label
        // selector is found again on the current tree, where it must still be the only match.
        let probe = Probe()
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "doctor")
        probe.uiTree = "{\"role\":\"AXWindow\",\"children\":[{\"role\":\"AXButton\",\"title\":\"Cancel\"}]}"

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertFalse(result.isError, result.content.first?.text ?? "")
        XCTAssertEqual(probe.semanticMutations, 1)
    }

    func test_pixelContentChangeWithStableGeometryStillClicks() async throws {
        // WHY (mac-use v1.7.0 contract): coordinates depend on the frame they were read from,
        // not on what was drawn in it; a caret blink must not refuse every click. A moved or
        // resized window still does (testScopedPixelTokenRejectsTargetGeometryDrift).
        let probe = Probe()
        probe.windowBounds = CGRect(x: 100, y: 200, width: 640, height: 480)
        probe.captureData = try makePNGBase64(width: 640, height: 480)
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "screenshot")
        probe.captureData = try makePNGBase64(width: 640, height: 480, red: 240)

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging([
                "coordinate": [12, 34]
            ]) { _, value in value }
        )

        XCTAssertFalse(result.isError, result.content.first?.text ?? "")
        XCTAssertEqual(probe.leftClickMutations, 1)
    }

    func testUnavailableOrUndecodableCaptureCannotMintActionablePixelToken() async throws {
        for mode in ["unavailable", "undecodable"] {
            let probe = Probe()
            probe.windowBounds = CGRect(x: 100, y: 200, width: 100, height: 100)
            if mode == "unavailable" {
                probe.captureFailure = "capture_unavailable_test"
            } else {
                probe.captureData = "not-a-png"
            }
            let backend = makeBackend(probe: probe)
            let screenshot = await backend.invoke(
                name: "screenshot",
                arguments: ["target_pid": 17, "target_window_id": 29]
            )
            if mode == "undecodable" {
                XCTAssertTrue(screenshot.isError)
            }
            let token = try XCTUnwrap(stateToken(from: screenshot))
            if mode == "undecodable" {
                XCTAssertTrue(token.isEmpty, "undecodable capture must not return an actionable token")
            }
            let click = await backend.invoke(
                name: "left_click",
                arguments: baseArguments(token: token).merging(["coordinate": [1, 1]]) { _, value in value }
            )
            XCTAssertTrue(click.isError, "\(mode) capture must not mint an actionable token")
            XCTAssertEqual(probe.leftClickMutations, 0)
        }
    }

    func testScopedPixelTokenCannotResumeAfterCaptureBecomesUnavailable() async throws {
        // WHY: once a scoped observation can no longer be re-captured, the
        // backend must not mint a placeholder pixel token that a retry could
        // accept or use to mutate the target.
        let probe = Probe()
        probe.windowBounds = CGRect(x: 100, y: 200, width: 100, height: 100)
        probe.captureData = try makePNGBase64(width: 200, height: 200)
        let backend = makeBackend(probe: probe)
        let zoom = await backend.invoke(
            name: "zoom",
            arguments: [
                "target_pid": 17,
                "target_window_id": 29,
                "region": [40, 30, 80, 60],
            ]
        )
        let token = try XCTUnwrap(stateToken(from: zoom))
        XCTAssertTrue(token.hasPrefix("native-pixel-v1:"))
        probe.captureFailure = "capture_unavailable_after_issue"

        for _ in 0..<3 {
            let result = await backend.invoke(
                name: "left_click",
                arguments: baseArguments(token: token).merging(["coordinate": [10, 20]]) { _, value in value }
            )
            let text = try XCTUnwrap(result.content.first?.text)
            XCTAssertTrue(result.isError)
            XCTAssertTrue(text.contains("stale_state_token"))
            XCTAssertFalse(text.contains("native-pixel-v1:"), "unavailable recapture must not return a placeholder pixel token")
        }
        XCTAssertEqual(probe.leftClickMutations, 0)
    }

    func testExtremePixelRegionEnvelopeFailsClosedWithoutOverflow() async throws {
        let probe = Probe()
        probe.windowBounds = CGRect(x: 100, y: 200, width: 100, height: 100)
        probe.captureData = try makePNGBase64(width: 200, height: 200)
        let backend = makeBackend(probe: probe)
        let zoom = await backend.invoke(
            name: "zoom",
            arguments: [
                "target_pid": 17,
                "target_window_id": 29,
                "region": [40, 30, 80, 60],
            ]
        )
        let token = try XCTUnwrap(stateToken(from: zoom))
        let prefix = "native-pixel-v1:"
        let encoded = String(token.dropFirst(prefix.count))
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(base64Encoded: encoded)!) as? [String: Any]
        )
        envelope["region"] = [Int.max, Int.max, 2, 2]
        let extremeJSON = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let extremeToken = prefix + extremeJSON.base64EncodedString()

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: extremeToken).merging(["coordinate": [1, 1]]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertEqual(probe.leftClickMutations, 0)
    }

    func testFreshZoomCaptureThatCannotReproduceScopeRejectsWithoutMutation() async throws {
        let probe = Probe()
        probe.windowBounds = CGRect(x: 100, y: 200, width: 100, height: 100)
        probe.captureData = try makePNGBase64(width: 200, height: 200)
        let backend = makeBackend(probe: probe)
        let zoom = await backend.invoke(
            name: "zoom",
            arguments: [
                "target_pid": 17,
                "target_window_id": 29,
                "region": [40, 30, 80, 60],
            ]
        )
        let token = try XCTUnwrap(stateToken(from: zoom))
        probe.captureData = try makePNGBase64(width: 20, height: 20)

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging(["coordinate": [10, 20]]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("stale_state_token") == true)
        XCTAssertEqual(probe.leftClickMutations, 0)
    }

    func testHumanActivityWinsAndExecutesNoMutation() async throws {
        let probe = Probe()
        probe.activity = .human
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "doctor")
        probe.uiTreeCalls = 0

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("human_activity") == true)
        XCTAssertEqual(probe.semanticMutations, 0, "physical user activity has priority over semantic automation")
        XCTAssertEqual(probe.uiTreeCalls, 0, "busy targets must yield without traversing their UI")
        XCTAssertEqual(probe.captureCalls, 0)
    }

    func testActivityTapObservesOngoingDragsAndModifierKeys() {
        let mask = ComputerUseNativeHostBackend.NativePlatform.activityEventMask
        for type in [CGEventType.leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .flagsChanged] {
            XCTAssertNotEqual(mask & CGEventMask(1 << type.rawValue), 0,
                              "ongoing human interaction must keep automation paused")
        }
    }

    func testUnavailableActivityMonitorFailsClosedBeforeMutation() async throws {
        let probe = Probe()
        probe.activityMonitorAvailable = false
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "doctor")

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("activity_monitor_unavailable") == true)
        XCTAssertEqual(probe.semanticMutations, 0)
    }

    func testHumanActivityRecheckWinsImmediatelyBeforeMutationHook() async throws {
        let probe = Probe()
        probe.activitySequence = [.none, .none, .none, .none, .human]
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "doctor")

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("human_activity") == true)
        XCTAssertEqual(probe.semanticMutations, 0, "a physical event during token validation must stop the mutation hook")
    }

    func testUnrelatedAndTaggedSyntheticActivityDoNotBlockTarget() {
        var now: UInt64 = 10_000
        let monitor = ComputerUseNativeActivityMonitor(
            quietWindowNanoseconds: 2_000,
            now: { now }
        )
        let target = ComputerUseNativeHostTarget(pid: 17, windowID: 29)

        monitor.record(.init(
            kind: .keyboard,
            pid: 99,
            timestampNanoseconds: now
        ))
        monitor.record(.init(
            kind: .mouse,
            pid: 99,
            windowID: 88,
            timestampNanoseconds: now
        ))
        XCTAssertEqual(monitor.activity(for: target), .none)

        monitor.record(.init(
            kind: .keyboard,
            pid: target.pid,
            timestampNanoseconds: now,
            isSynthetic: true
        ))
        monitor.record(.init(
            kind: .mouse,
            pid: target.pid,
            windowID: target.windowID,
            timestampNanoseconds: now,
            isSynthetic: true
        ))
        XCTAssertEqual(monitor.activity(for: target), .none)

        monitor.record(.init(
            kind: .keyboard,
            pid: target.pid,
            timestampNanoseconds: now
        ))
        XCTAssertEqual(monitor.activity(for: target), .human)
        now += 2_001
        XCTAssertEqual(monitor.activity(for: target), .none, "the native quiet window is exactly two seconds")
    }

    func testActivityMonitorBoundsRecentTargetsConservatively() {
        var now: UInt64 = 10_000
        let monitor = ComputerUseNativeActivityMonitor(
            quietWindowNanoseconds: 2_000,
            now: { now }
        )

        for index in 0...ComputerUseNativeActivityMonitor.maximumTrackedActivityEntries {
            monitor.record(.init(
                kind: .keyboard,
                pid: Int32(1_000 + index),
                timestampNanoseconds: now
            ))
        }

        XCTAssertEqual(
            monitor.activity(for: .init(pid: 17, windowID: 29)),
            .human,
            "activity overflow must fail closed instead of retaining an unbounded target map"
        )
        now += 2_001
        XCTAssertEqual(monitor.activity(for: .init(pid: 17, windowID: 29)), .none)
    }

    func testOversizedCaptureFailsClosedWithoutEmittingImage() async throws {
        let probe = Probe()
        probe.captureData = String(
            repeating: "A",
            count: ComputerUseNativeHostBackend.maximumCaptureBase64Characters + 1
        )
        let backend = makeBackend(probe: probe)

        let result = await backend.invoke(
            name: "screenshot",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.content.count, 1)
        XCTAssertTrue(result.content.first?.text?.contains("capture_too_large") == true)
        XCTAssertFalse(result.content.contains { $0.type == "image" })
    }

    func testCompressedCaptureWithExcessiveDimensionsFailsClosed() async throws {
        // WHY: PNG compression can keep a huge pixel surface below the byte
        // limit; dimensions must be bounded before image decoding/cropping.
        let probe = Probe()
        probe.captureData = try makePNGBase64(
            width: ComputerUseNativeHostBackend.maximumCapturePixelDimension + 1,
            height: 1,
            rgba: Array(repeating: 255, count: (ComputerUseNativeHostBackend.maximumCapturePixelDimension + 1) * 4)
        )
        let backend = makeBackend(probe: probe)

        let result = await backend.invoke(
            name: "screenshot",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("capture_too_large") == true)
        XCTAssertFalse(result.content.contains { $0.type == "image" })
    }

    func testZoomRejectsCompressedCaptureWithExcessiveDimensionsWithoutInflate() async throws {
        // WHY: zoom must honor the same pixel cap as screenshot and must not
        // inflate a too-large PNG just to reject the region.
        let probe = Probe()
        probe.captureData = try makePNGBase64(
            width: ComputerUseNativeHostBackend.maximumCapturePixelDimension + 1,
            height: 1,
            rgba: Array(repeating: 255, count: (ComputerUseNativeHostBackend.maximumCapturePixelDimension + 1) * 4)
        )
        let backend = makeBackend(probe: probe)
        ComputerUseNativeHostBackend.resetPNGPixelInflateMetrics()

        let result = await backend.invoke(
            name: "zoom",
            arguments: [
                "target_pid": 17,
                "target_window_id": 29,
                "region": [0, 0, 1, 1],
            ]
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("capture_too_large") == true)
        XCTAssertFalse(result.content.contains { $0.type == "image" })
        XCTAssertEqual(ComputerUseNativeHostBackend.pngPixelInflateCount, 0)
    }

    func testScreenshotReadsImageSizeWithoutPNGPixelInflate() async throws {
        // WHY: screenshot only needs width/height for the pixel token. Inflating
        // the full PNG just to read IHDR re-allocates the captured frame.
        let probe = Probe()
        probe.captureData = try makePNGBase64(width: 32, height: 24)
        let backend = makeBackend(probe: probe)
        ComputerUseNativeHostBackend.resetPNGPixelInflateMetrics()

        let result = await backend.invoke(
            name: "screenshot",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.last?.type, "image")
        XCTAssertEqual(
            ComputerUseNativeHostBackend.pngPixelInflateCount,
            0,
            "screenshot must measure PNG IHDR without expanding pixels"
        )
        XCTAssertEqual(ComputerUseNativeHostBackend.lastPNGInflatePixelCount, 0)
    }

    func testZoomInflatesEncodedPNGOnceNotTwice() async throws {
        // WHY: imageSize used to NSBitmapImageRep-decode the full PNG, then
        // crop decoded it again. Zoom must inflate the encoded frame once.
        let probe = Probe()
        probe.captureData = try makePNGBase64(width: 32, height: 24)
        let backend = makeBackend(probe: probe)
        ComputerUseNativeHostBackend.resetPNGPixelInflateMetrics()

        let zoom = await backend.invoke(
            name: "zoom",
            arguments: [
                "target_pid": 17,
                "target_window_id": 29,
                "region": [4, 6, 8, 4],
            ]
        )

        XCTAssertFalse(zoom.isError)
        XCTAssertEqual(
            ComputerUseNativeHostBackend.pngPixelInflateCount,
            1,
            "encoded zoom must inflate the full PNG once, then crop the live CGImage"
        )
        XCTAssertEqual(
            ComputerUseNativeHostBackend.lastPNGInflatePixelCount,
            32 * 24,
            "the single inflate must be the captured frame, not a second full-frame decode"
        )
        let croppedData = try XCTUnwrap(zoom.content.last?.data).flatMap { Data(base64Encoded: $0) }
        let cropped = try XCTUnwrap(croppedData.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(cropped.pixelsWide, 8)
        XCTAssertEqual(cropped.pixelsHigh, 4)
        XCTAssertLessThanOrEqual(
            croppedData?.count ?? Int.max,
            ComputerUseNativeHostBackend.maximumCaptureEncodedBytes
        )
        XCTAssertLessThan(
            cropped.pixelsWide * cropped.pixelsHigh,
            32 * 24,
            "retained crop pixels must be the region, not the full captured frame"
        )
    }

    func testNativeZoomCropsCGImageBeforePNGWithoutInflate() throws {
        // WHY: production capture already holds a CGImage. Encoding the full
        // frame to PNG just so zoom can decode it again doubles peak pixels.
        let image = try XCTUnwrap(makeCGImage(width: 64, height: 48))
        ComputerUseNativeHostBackend.resetPNGPixelInflateMetrics()

        let full = try XCTUnwrap(
            ComputerUseNativeHostBackend.encodePreparedCapture(image: image, region: nil).successCapture()
        )
        let cropped = try XCTUnwrap(
            ComputerUseNativeHostBackend.encodePreparedCapture(
                image: image,
                region: CGRect(x: 8, y: 12, width: 16, height: 10)
            ).successCapture()
        )

        XCTAssertEqual(ComputerUseNativeHostBackend.pngPixelInflateCount, 0)
        XCTAssertEqual(full.sourcePixelSize, [64, 48])
        XCTAssertEqual(cropped.sourcePixelSize, [64, 48])
        let fullPNG = try XCTUnwrap(Data(base64Encoded: full.data))
        let croppedPNG = try XCTUnwrap(Data(base64Encoded: cropped.data))
        XCTAssertLessThan(croppedPNG.count, fullPNG.count)
        XCTAssertLessThanOrEqual(croppedPNG.count, ComputerUseNativeHostBackend.maximumCaptureEncodedBytes)
        let croppedRep = try XCTUnwrap(NSBitmapImageRep(data: croppedPNG))
        XCTAssertEqual(croppedRep.pixelsWide, 16)
        XCTAssertEqual(croppedRep.pixelsHigh, 10)
        XCTAssertEqual(
            croppedRep.pixelsWide * croppedRep.pixelsHigh * 4,
            16 * 10 * 4,
            "peak retained crop bytes are the region pixels, not 64×48"
        )
    }

    func testNativeZoomRejectsOutOfBoundsRegionWithoutEncoding() throws {
        let image = try XCTUnwrap(makeCGImage(width: 8, height: 8))
        ComputerUseNativeHostBackend.resetPNGPixelInflateMetrics()

        switch ComputerUseNativeHostBackend.encodePreparedCapture(
            image: image,
            region: CGRect(x: 6, y: 0, width: 4, height: 1)
        ) {
        case .unavailable(let reason):
            XCTAssertEqual(reason, "invalid_region")
        case .success, .quartzFallback:
            XCTFail("out-of-bounds zoom must fail closed before PNG encode")
        }
        XCTAssertEqual(ComputerUseNativeHostBackend.pngPixelInflateCount, 0)
    }

    func testEncodePreparedCaptureKeepsPixelAndByteBudgets() throws {
        let oversize = try XCTUnwrap(makeCGImage(
            width: ComputerUseNativeHostBackend.maximumCapturePixelDimension + 1,
            height: 1
        ))
        switch ComputerUseNativeHostBackend.encodePreparedCapture(image: oversize, region: nil) {
        case .unavailable(let reason):
            XCTAssertEqual(reason, "capture_too_large")
        case .success, .quartzFallback:
            XCTFail("pixel-dimension cap must reject before PNG encode")
        }

        let image = try XCTUnwrap(makeCGImage(width: 4, height: 3))
        let encoded = try XCTUnwrap(
            ComputerUseNativeHostBackend.encodePreparedCapture(image: image, region: nil).successCapture()
        )
        let png = try XCTUnwrap(Data(base64Encoded: encoded.data))
        XCTAssertLessThanOrEqual(png.count, ComputerUseNativeHostBackend.maximumCaptureEncodedBytes)
        XCTAssertLessThanOrEqual(
            encoded.data.utf8.count,
            ComputerUseNativeHostBackend.maximumCaptureBase64Characters
        )
    }

    func testZoomSkipsPNGInflateWhenNativeAlreadyCropped() async throws {
        // WHY: once NativePlatform cropped the live CGImage, invoke must not
        // base64-decode that PNG back into a full-frame bitmap.
        let image = try XCTUnwrap(makeCGImage(width: 12, height: 8))
        let cropped = try XCTUnwrap(
            ComputerUseNativeHostBackend.encodePreparedCapture(
                image: image,
                region: CGRect(x: 2, y: 1, width: 4, height: 2)
            ).successCapture()
        )
        let probe = Probe()
        probe.captureData = cropped.data
        probe.captureSourcePixelSize = cropped.sourcePixelSize
        let backend = makeBackend(probe: probe)
        ComputerUseNativeHostBackend.resetPNGPixelInflateMetrics()

        let zoom = await backend.invoke(
            name: "zoom",
            arguments: [
                "target_pid": 17,
                "target_window_id": 29,
                "region": [2, 1, 4, 2],
            ]
        )

        XCTAssertFalse(zoom.isError)
        XCTAssertEqual(ComputerUseNativeHostBackend.pngPixelInflateCount, 0)
        XCTAssertEqual(zoom.content.last?.data, cropped.data)
        let croppedData = try XCTUnwrap(zoom.content.last?.data).flatMap { Data(base64Encoded: $0) }
        let rep = try XCTUnwrap(croppedData.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(rep.pixelsWide, 4)
        XCTAssertEqual(rep.pixelsHigh, 2)
        let envelope = try XCTUnwrap(pixelTokenEnvelope(from: zoom))
        XCTAssertEqual(intArray(envelope["fullImageSize"]), [12, 8])
        XCTAssertEqual(intArray(envelope["region"]), [2, 1, 4, 2])
    }

    func testZoomCropBeforeEncodeDropsRetainedEncodedBytesVersusFullFrame() throws {
        // WHY: the old zoom path PNG+base64 encoded the full CGImage, then
        // inflated it to crop. Peak retained encoded bytes were the full-frame
        // payload. Crop-before-encode must retain only the region PNG/base64
        // while pixelScope still names the source frame.
        let image = try XCTUnwrap(makeCGImage(width: 80, height: 80))
        let region = CGRect(x: 0, y: 0, width: 40, height: 40)
        ComputerUseNativeHostBackend.resetPNGPixelInflateMetrics()

        let full = try XCTUnwrap(
            ComputerUseNativeHostBackend.encodePreparedCapture(image: image, region: nil).successCapture()
        )
        let cropped = try XCTUnwrap(
            ComputerUseNativeHostBackend.encodePreparedCapture(image: image, region: region).successCapture()
        )

        XCTAssertEqual(ComputerUseNativeHostBackend.pngPixelInflateCount, 0)
        XCTAssertEqual(cropped.sourcePixelSize, [80, 80])
        let fullPNG = try XCTUnwrap(Data(base64Encoded: full.data))
        let croppedPNG = try XCTUnwrap(Data(base64Encoded: cropped.data))
        let fullEncoded = full.data.utf8.count
        let croppedEncoded = cropped.data.utf8.count
        let encodedDrop = 1.0 - (Double(croppedEncoded) / Double(fullEncoded))
        XCTAssertLessThan(croppedPNG.count, fullPNG.count)
        XCTAssertLessThan(croppedEncoded, fullEncoded)
        XCTAssertGreaterThan(
            encodedDrop,
            0.30,
            "25% region must drop retained encoded capture bytes (was \(encodedDrop); full=\(fullEncoded) crop=\(croppedEncoded))"
        )
        XCTAssertEqual(Double(40 * 40) / Double(80 * 80), 0.25)
        let croppedRep = try XCTUnwrap(NSBitmapImageRep(data: croppedPNG))
        XCTAssertEqual(croppedRep.pixelsWide * croppedRep.pixelsHigh, 40 * 40)
    }

    func testMissingPermissionExecutesNoMutation() async throws {
        let probe = Probe()
        probe.accessibilityPermission = false
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "doctor")

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("permission_required") == true)
        XCTAssertEqual(probe.semanticMutations, 0, "missing accessibility permission must fail closed")
    }

    func testMinimizedPixelTargetExecutesNoMutation() async throws {
        let probe = Probe()
        probe.isMinimized = true
        probe.captureData = try makePNGBase64(width: 640, height: 480)
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "screenshot")

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging([
                "coordinate": [12, 34]
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        // Input events need a visible window; the refusal names the way out.
        XCTAssertTrue(result.content.first?.text?.contains("pixel_target_not_renderable") == true)
        XCTAssertTrue(result.content.first?.text?.contains("restore_window first") == true)
        XCTAssertEqual(probe.pixelMutations, 0, "minimized pixels cannot be targeted without restoring the window")
        XCTAssertEqual(probe.leftClickMutations, 0)
    }

    func testFocusOnlyActionsExecuteNoMutation() async throws {
        let probe = Probe()
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "doctor")

        let result = await backend.invoke(
            name: "type",
            arguments: baseArguments(token: token).merging([
                "text": "secret"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("focus_required") == true)
        XCTAssertEqual(probe.pixelMutations, 0, "typing must not activate or focus a background target")
    }

    func testBackgroundSemanticTypingUsesTargetFocusedElement() async throws {
        let probe = Probe()
        probe.typeTextResult = true
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "doctor")

        let result = await backend.invoke(
            name: "type",
            arguments: baseArguments(token: token).merging([
                "text": "background text"
            ]) { _, value in value }
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(probe.typeTextMutations, 1)
        XCTAssertEqual(probe.activations, 0)
    }

    func testLeftClickUsesExactTargetAXHookWithoutActivation() async throws {
        let probe = Probe()
        probe.windowBounds = CGRect(x: 100, y: 200, width: 640, height: 480)
        probe.captureData = try makePNGBase64(width: 640, height: 480)
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "screenshot")

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging([
                "coordinate": [12, 34]
            ]) { _, value in value }
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(probe.leftClickMutations, 1)
        XCTAssertEqual(probe.activations, 0)
    }

    func testLeftClickConvertsWindowLocalCoordinatesUsingCurrentOrigin() async throws {
        // WHY: callers target the screenshot's window-local pixels; passing
        // them as global coordinates can click an unrelated window.
        let probe = Probe()
        probe.windowBounds = CGRect(x: 100, y: 200, width: 640, height: 480)
        probe.captureData = try makePNGBase64(width: 640, height: 480)
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "screenshot")

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging(["coordinate": [12, 34]]) { _, value in value }
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(probe.lastLeftClickCoordinate, [112, 234])
    }

    func testRetinaScreenshotCoordinatesMapPixelsToGlobalPoints() async throws {
        // WHY: screenshot coordinates are pixels in the returned image. A
        // Retina image can therefore be twice the window's point dimensions.
        let probe = Probe()
        probe.windowBounds = CGRect(x: 100, y: 200, width: 100, height: 100)
        probe.captureData = try makePNGBase64(width: 200, height: 200)
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "screenshot")

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging(["coordinate": [150, 50]]) { _, value in value }
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(probe.lastLeftClickCoordinate, [175, 225])
    }

    func testZoomPixelTokenUsesCropLocalPixelsAndTopLeftOrigin() async throws {
        // WHY: zoom returns a top-left-origin crop, so a click must add the
        // crop origin before converting Retina pixels into target points.
        let probe = Probe()
        probe.windowBounds = CGRect(x: 100, y: 200, width: 100, height: 100)
        probe.captureData = try makePNGBase64(width: 200, height: 200)
        let backend = makeBackend(probe: probe)
        let zoom = await backend.invoke(
            name: "zoom",
            arguments: [
                "target_pid": 17,
                "target_window_id": 29,
                "region": [40, 30, 80, 60],
            ]
        )
        let token = try XCTUnwrap(stateToken(from: zoom))

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging(["coordinate": [10, 20]]) { _, value in value }
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(probe.lastLeftClickCoordinate, [125, 225])
    }

    func testScopedPixelTokenRejectsTargetGeometryDrift() async throws {
        let probe = Probe()
        let initial = CGRect(x: 100, y: 200, width: 100, height: 100)
        probe.windowBounds = initial
        probe.captureData = try makePNGBase64(width: 200, height: 200)
        let backend = makeBackend(probe: probe)
        let zoom = await backend.invoke(
            name: "zoom",
            arguments: [
                "target_pid": 17,
                "target_window_id": 29,
                "region": [40, 30, 80, 60],
            ]
        )
        let token = try XCTUnwrap(stateToken(from: zoom))
        probe.windowBounds = CGRect(x: 101, y: 200, width: 100, height: 100)

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging(["coordinate": [10, 20]]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("stale_state_token") == true)
        XCTAssertEqual(probe.leftClickMutations, 0)
    }

    func testMalformedPixelTokenScopeFailsClosedWithoutMutation() async throws {
        let probe = Probe()
        probe.windowBounds = CGRect(x: 100, y: 200, width: 100, height: 100)
        probe.captureData = try makePNGBase64(width: 200, height: 200)
        let backend = makeBackend(probe: probe)

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: "native-pixel-v1:not-a-valid-scope")
                .merging(["coordinate": [10, 20]]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("stale_state_token") == true)
        XCTAssertEqual(probe.leftClickMutations, 0)
    }

    func testPixelCoordinateOutsideReturnedZoomImageFailsClosed() async throws {
        let probe = Probe()
        probe.windowBounds = CGRect(x: 100, y: 200, width: 100, height: 100)
        probe.captureData = try makePNGBase64(width: 200, height: 200)
        let backend = makeBackend(probe: probe)
        let zoom = await backend.invoke(
            name: "zoom",
            arguments: [
                "target_pid": 17,
                "target_window_id": 29,
                "region": [40, 30, 80, 60],
            ]
        )
        let token = try XCTUnwrap(stateToken(from: zoom))

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging(["coordinate": [80, 0]]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("semantic_action_failed") == true)
        XCTAssertEqual(probe.leftClickMutations, 0)
    }

    func testLeftClickRejectsOutOfBoundsWindowLocalCoordinateWithoutMutation() async throws {
        let probe = Probe()
        probe.windowBounds = CGRect(x: 100, y: 200, width: 640, height: 480)
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "screenshot")

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging(["coordinate": [640, 0]]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("semantic_action_failed") == true)
        XCTAssertEqual(probe.leftClickMutations, 0)
    }

    func testBooleanCoordinateAndRegionValuesFailClosed() async throws {
        let probe = Probe()
        probe.windowBounds = CGRect(x: 100, y: 200, width: 640, height: 480)
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "screenshot")

        let click = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging([
                "coordinate": [NSNumber(value: true), 0]
            ]) { _, value in value }
        )
        XCTAssertTrue(click.isError)
        XCTAssertTrue(click.content.first?.text?.contains("semantic_action_failed") == true)
        XCTAssertEqual(probe.leftClickMutations, 0)

        let zoom = await backend.invoke(
            name: "zoom",
            arguments: [
                "target_pid": 17,
                "target_window_id": 29,
                "region": [NSNumber(value: true), 0, 1, 1],
            ]
        )
        XCTAssertTrue(zoom.isError)
        XCTAssertTrue(zoom.content.first?.text?.contains("invalid_region") == true)
    }

    func testLeftClickRevalidatesWindowOriginImmediatelyBeforeAction() async throws {
        let probe = Probe()
        let initial = CGRect(x: 100, y: 200, width: 640, height: 480)
        probe.windowBoundsSequence = [initial, initial, CGRect(x: 101, y: 200, width: 640, height: 480)]
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "screenshot")

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging(["coordinate": [12, 34]]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("stale_state_token") == true)
        XCTAssertEqual(probe.leftClickMutations, 0)
    }

    func testZoomCropsExactCapturedPixelsAndBindsTokenToCrop() async throws {
        // WHY: zoom must narrow observation to the requested pixel region;
        // returning the full screenshot leaks unrelated pixels and permits a
        // token to validate content outside the requested region.
        let probe = Probe()
        probe.captureData = try makePNGBase64(width: 4, height: 3)
        let backend = makeBackend(probe: probe)

        let screenshot = await backend.invoke(
            name: "screenshot",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )
        let screenshotToken = try XCTUnwrap(stateToken(from: screenshot))
        let zoom = await backend.invoke(
            name: "zoom",
            arguments: [
                "target_pid": 17,
                "target_window_id": 29,
                "region": [1, 1, 2, 1],
            ]
        )

        XCTAssertFalse(zoom.isError)
        let zoomMetadata = try XCTUnwrap(zoom.content.first?.text)
        let zoomToken = try XCTUnwrap(stateToken(from: zoom))
        XCTAssertNotEqual(zoomToken, screenshotToken, "zoom token must bind to cropped pixels")
        let croppedData = try XCTUnwrap(zoom.content.last?.data).flatMap { Data(base64Encoded: $0) }
        let cropped = try XCTUnwrap(croppedData.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(cropped.pixelsWide, 2)
        XCTAssertEqual(cropped.pixelsHigh, 1)
        XCTAssertTrue(zoomMetadata.contains("\"target_window_id\":29"))
        XCTAssertNotEqual(croppedData, Data(base64Encoded: probe.captureData))
    }

    func testZoomCropUsesTopLeftRowsWithoutYFlip() async throws {
        // WHY: screenshot regions are top-left-origin pixels. CGImage.cropping
        // receives that same origin, so y=0 must select the red top row and
        // y=1 must select the blue bottom row in this asymmetric image.
        let probe = Probe()
        probe.captureData = try makePNGBase64(width: 2, height: 2, rgba: [
            255, 0, 0, 255, 0, 0, 0, 255,
            0, 0, 255, 255, 0, 0, 0, 255,
        ])
        let backend = makeBackend(probe: probe)

        for (y, expected) in [(0, [UInt8](arrayLiteral: 255, 0, 0, 255)), (1, [UInt8](arrayLiteral: 0, 0, 255, 255))] {
            let zoom = await backend.invoke(
                name: "zoom",
                arguments: [
                    "target_pid": 17,
                    "target_window_id": 29,
                    "region": [0, y, 1, 1],
                ]
            )
            XCTAssertFalse(zoom.isError)
            let encoded = try XCTUnwrap(zoom.content.last?.data)
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            let image = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)
            let providerData = try XCTUnwrap(image.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(providerData))
            XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: 4)), expected)
        }
    }

    func testZoomRejectsFractionalNegativeAndOutOfBoundsRegions() async throws {
        let probe = Probe()
        probe.captureData = try makePNGBase64(width: 4, height: 3)
        let backend = makeBackend(probe: probe)
        let regions: [[Any]] = [
            [1.5, 0, 1, 1],
            [NSNumber(value: true), 0, 1, 1],
            [-1, 0, 1, 1],
            [0, 0, 0, 1],
            [3, 2, 2, 1],
        ]

        for region in regions {
            let result = await backend.invoke(
                name: "zoom",
                arguments: ["target_pid": 17, "target_window_id": 29, "region": region]
            )
            XCTAssertTrue(result.isError, "invalid region must fail closed: \(region)")
            XCTAssertTrue(result.content.first?.text?.contains("invalid_region") == true)
            XCTAssertNil(result.content.last?.data)
        }
    }

    func testGetUITreeSerializesBoundedInjectedTargetTree() async throws {
        let probe = Probe()
        probe.uiTree = "{\"role\":\"AXWindow\",\"children\":[{\"role\":\"AXButton\",\"title\":\"Save\"}]}"
        let backend = makeBackend(probe: probe)
        let result = await backend.invoke(
            name: "get_ui_tree",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("AXButton") == true)
        XCTAssertFalse(result.content.first?.text?.contains("unavailable") == true)
        XCTAssertEqual(probe.uiTreeCalls, 1, "get_ui_tree must hash and return the same single AX traversal")
    }

    func testSemanticCapabilityRequiresExactTargetAXResolution() async throws {
        let probe = Probe()
        probe.axTargetAvailable = false
        let backend = makeBackend(probe: probe)

        let result = await backend.invoke(
            name: "doctor",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )

        let text = try XCTUnwrap(result.content.first?.text)
        XCTAssertTrue(probe.accessibilityPermission, "the regression requires global Accessibility permission")
        XCTAssertFalse(text.contains("semantic_ax"), "global permission must not advertise AX when this target cannot resolve")
    }

    func testSemanticAXActionCanMutateBackgroundTarget() async throws {
        let probe = Probe()
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend)
        probe.uiTreeCalls = 0

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(probe.semanticMutations, 1)
        XCTAssertEqual(probe.activations, 0)
        // One traversal validates the action (no duplicate preflight); one after it reports the
        // settled window so the caller can see whether the app reacted.
        XCTAssertEqual(probe.uiTreeCalls, 2)
    }

    private func stateToken(from backend: ComputerUseNativeHostBackend, name: String = "doctor") async throws -> String {
        let result = await backend.invoke(
            name: name,
            arguments: ["target_pid": 17, "target_window_id": 29]
        )
        let text = try XCTUnwrap(result.content.first?.text)
        for line in text.split(separator: "\n").reversed() {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["state_token"] as? String else { continue }
            return token
        }
        throw XCTSkip("native response did not contain an observation token")
    }

    private func baseArguments(token: String) -> [String: Any] {
        [
            "target_pid": 17,
            "target_window_id": 29,
            "expected_state_token": token,
        ]
    }

    private func stateToken(from result: ComputerUseToolResult) -> String? {
        for line in result.content.compactMap(\.text).joined(separator: "\n").split(separator: "\n").reversed() {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["state_token"] as? String else { continue }
            return token
        }
        return nil
    }

    private func intArray(_ value: Any?) -> [Int]? {
        guard let values = value as? [Any] else { return nil }
        let ints = values.compactMap { ($0 as? NSNumber)?.intValue }
        return ints.count == values.count ? ints : nil
    }

    private func pixelTokenEnvelope(from result: ComputerUseToolResult) -> [String: Any]? {
        guard let token = stateToken(from: result),
              token.hasPrefix("native-pixel-v1:") else {
            return nil
        }
        let encoded = String(token.dropFirst("native-pixel-v1:".count))
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func makeCGImage(width: Int, height: Int, rgba: [UInt8]? = nil) -> CGImage? {
        let pixels: [UInt8]
        if let rgba {
            pixels = rgba
        } else {
            var generated = [UInt8](repeating: 0, count: width * height * 4)
            for index in 0..<(width * height) {
                generated[index * 4] = UInt8(index & 0xff)
                generated[index * 4 + 1] = UInt8((index * 3) & 0xff)
                generated[index * 4 + 2] = UInt8((index * 7) & 0xff)
                generated[index * 4 + 3] = 255
            }
            pixels = generated
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return pixels.withUnsafeBytes { bytes in
            CGContext(
                data: UnsafeMutableRawPointer(mutating: bytes.baseAddress),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }

    private func makePNGBase64(width: Int, height: Int, red: UInt8 = 0) throws -> String {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = red == 0 ? UInt8(index & 0xff) : red
            pixels[index * 4 + 1] = UInt8((index * 3) & 0xff)
            pixels[index * 4 + 2] = UInt8((index * 7) & 0xff)
            pixels[index * 4 + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let image = pixels.withUnsafeMutableBytes { bytes in
            CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        let representation = try XCTUnwrap(image.map(NSBitmapImageRep.init(cgImage:)))
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        return data.base64EncodedString()
    }

    private func makePNGBase64(width: Int, height: Int, rgba: [UInt8]) throws -> String {
        XCTAssertEqual(rgba.count, width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let image = rgba.withUnsafeBytes { bytes in
            CGContext(
                data: UnsafeMutableRawPointer(mutating: bytes.baseAddress),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        let representation = try XCTUnwrap(image.map(NSBitmapImageRep.init(cgImage:)))
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        return data.base64EncodedString()
    }

    private func makeBackend(probe: Probe) -> ComputerUseNativeHostBackend {
        ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in [probe.nextWindow()] + probe.additionalWindows },
            userActivity: { _ in probe.nextActivity() },
            activityMonitorAvailable: { probe.activityMonitorAvailable },
            accessibilityPermission: { probe.accessibilityPermission },
            axTargetAvailable: { _ in probe.axTargetAvailable },
            screenCapturePermission: { probe.screenCapturePermission },
            capture: { _ in
                probe.captureCalls += 1
                if probe.isMinimized {
                    return .unavailable("minimized")
                }
                if let failure = probe.captureFailure {
                    return .unavailable(failure)
                }
                let capture = ComputerUseNativeCapture(
                    data: probe.captureData,
                    mimeType: "image/png",
                    sourcePixelSize: probe.captureSourcePixelSize
                )
                if probe.captureFallback {
                    return .quartzFallback(capture)
                }
                return .success(capture)
            },
            uiTree: { _ in
                probe.uiTreeCalls += 1
                return probe.uiTree
            },
            semanticAction: { _, _, _ in
                probe.semanticMutations += 1
                return true
            },
            leftClick: { _, coordinate in
                probe.leftClickMutations += 1
                probe.lastLeftClickCoordinate = coordinate
                return .applied
            },
            typeText: { _, _ in
                probe.typeTextMutations += 1
                return probe.typeTextResult
            },
            pixelAction: { _, _, _ in
                probe.pixelMutations += 1
                return true
            },
            activate: { _ in probe.activations += 1; return true }
        ))
    }
}

private extension ComputerUseNativeCaptureResult {
    func successCapture() -> ComputerUseNativeCapture? {
        switch self {
        case .success(let capture), .quartzFallback(let capture):
            return capture
        case .unavailable:
            return nil
        }
    }
}

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    var windowTitle = "RemoteCode"
    var windowBounds = CGRect.zero
    var windowBoundsSequence: [CGRect] = []
    private var windowBoundsIndex = 0
    var activity: ComputerUseNativeUserActivity = .none
    var activitySequence: [ComputerUseNativeUserActivity] = []
    private var activityIndex = 0
    var activityMonitorAvailable = true
    var accessibilityPermission = true
    var axTargetAvailable = true
    var screenCapturePermission = true
    var isMinimized = false
    var semanticMutations = 0
    var leftClickMutations = 0
    var typeTextMutations = 0
    var typeTextResult = false
    var pixelMutations = 0
    var lastLeftClickCoordinate: [Double] = []
    var activations = 0
    var captureCalls = 0
    var uiTree: String? = "{\"role\":\"AXWindow\",\"title\":\"RemoteCode\"}"
    var uiTreeCalls = 0
    var captureData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1s="
    var captureSourcePixelSize: [Int]?
    var captureFailure: String?
    var captureFallback = false

    func nextWindow() -> ComputerUseNativeWindow {
        lock.lock()
        let bounds: CGRect
        if windowBoundsSequence.indices.contains(windowBoundsIndex) {
            bounds = windowBoundsSequence[windowBoundsIndex]
            windowBoundsIndex += 1
        } else {
            bounds = windowBounds
        }
        lock.unlock()
        return ComputerUseNativeWindow(
            target: .init(pid: 17, windowID: 29),
            title: windowTitle,
            bundleIdentifier: "com.example.RemoteCode",
            isOnScreen: !isMinimized,
            isMinimized: isMinimized,
            bounds: bounds
        )
    }
    var additionalWindows: [ComputerUseNativeWindow] = []

    var window: ComputerUseNativeWindow {
        lock.lock(); defer { lock.unlock() }
        return ComputerUseNativeWindow(
            target: .init(pid: 17, windowID: 29),
            title: windowTitle,
            bundleIdentifier: "com.example.RemoteCode",
            isOnScreen: !isMinimized,
            isMinimized: isMinimized,
            bounds: windowBounds
        )
    }

    func nextActivity() -> ComputerUseNativeUserActivity {
        lock.lock()
        defer { lock.unlock() }
        defer { activityIndex += 1 }
        return activitySequence.indices.contains(activityIndex) ? activitySequence[activityIndex] : activity
    }
}
