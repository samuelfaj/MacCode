import CoreGraphics
import Foundation
import XCTest
@testable import CoreModel

final class InputToolsTests: XCTestCase {
    private let target = ComputerUseNativeHostTarget(pid: 42, windowID: 7)
    private var base: [String: Any] { ["target_pid": 42, "target_window_id": 7] }
    func testElementWithoutPressUsesItsExactBoundsForTargetedPointerDelivery() async {
        var effects = fakeEffects()
        effects.axAction = { _, _, _ in false }
        effects.elementPoint = { target, id in
            XCTAssertEqual(target.windowID, 7); XCTAssertEqual(id, "ax_1")
            return CGPoint(x: 150, y: 250)
        }
        var events: [CGEvent] = []
        effects.post = { event, _, foreground in XCTAssertFalse(foreground); events.append(event) }
        let result = await InputToolsBackend(effects: effects).invoke(name: "click", arguments: arguments(["element_id": "ax_1", "action": "pointer"]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
        XCTAssertTrue(events.allSatisfy { $0.location == CGPoint(x: 150, y: 250) })
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(CGEventField(rawValue: 51)!) == 7 })
    }

    func testExplicitPointerActionDoesNotPressAXBeforeSendingClick() async {
        var effects = fakeEffects()
        effects.axAction = { _, _, _ in XCTFail("explicit pointer must not also AXPress"); return true }
        effects.elementPoint = { _, _ in CGPoint(x: 150, y: 250) }
        var events: [CGEvent] = []
        effects.post = { event, _, _ in events.append(event) }
        let result = await InputToolsBackend(effects: effects).invoke(name: "click", arguments: arguments(["element_id": "ax_1", "action": "pointer"]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    func testBackgroundTransportChoosesExactlyOnePidRoute() throws {
        let event = try XCTUnwrap(CGEvent(source: nil))
        var native = 0
        var fallback = 0
        BackgroundEventDelivery.deliver(event, pid: 42, native: { pid, value in
            XCTAssertEqual(pid, 42); XCTAssertTrue(value === event); native += 1
        }, fallback: { _, _ in fallback += 1 })
        XCTAssertEqual(native, 1); XCTAssertEqual(fallback, 0)
        BackgroundEventDelivery.deliver(event, pid: 42, native: nil, fallback: { value, pid in
            XCTAssertEqual(pid, 42); XCTAssertTrue(value === event); fallback += 1
        })
        XCTAssertEqual(native, 1); XCTAssertEqual(fallback, 1)
    }

    func testInsertionVerifiesValueAndUsesValueOnlyForEmptyComposer() throws {
        var text = "\n"
        var writes = 0
        XCTAssertTrue(try AXTextInsertion.insert("hello", read: { text }, selected: { false }, value: { text = "hello"; writes += 1; return true }))
        XCTAssertEqual(writes, 1)
        text = "existing draft"
        XCTAssertFalse(try AXTextInsertion.insert("hello", read: { text }, selected: { false }, value: { XCTFail("must preserve draft"); return true }))
        XCTAssertTrue(try AXTextInsertion.insert("hello", read: { text }, selected: { text += "hello"; return true }, value: { XCTFail("do not write twice"); return false }))
    }

    func testAcceptedButUnverifiedInsertionNeverRetriesAndAllowsDelayedReadback() throws {
        XCTAssertThrowsError(try AXTextInsertion.insert("hello", read: { nil }, selected: { true }, value: { XCTFail("do not retry"); return true }, wait: {}))
        var polls = 0
        XCTAssertTrue(try AXTextInsertion.insert("hello", read: { polls >= 2 ? "hello" : "" }, selected: { true }, value: { XCTFail("do not retry"); return true }, wait: { polls += 1 }))
    }

    func testAcceptedValueWriteWaitsForDelayedReadbackWithoutWritingAgain() throws {
        var polls = 0
        var writes = 0
        XCTAssertTrue(try AXTextInsertion.insert("hello", read: { polls >= 2 ? "hello" : "" }, selected: { false }, value: { writes += 1; return true }, wait: { polls += 1 }))
        XCTAssertEqual(writes, 1)
    }

    func testUnverifiedAcceptedValueWriteNeverFallsBackToUnicode() async {
        var effects = fakeEffects()
        var writes = 0
        effects.insert = { _, _, text in
            try AXTextInsertion.insert(text, read: { "" }, selected: { false }, value: { writes += 1; return true }, wait: {})
        }
        effects.post = { _, _, _ in XCTFail("accepted value write must never be duplicated through Unicode") }
        let result = await InputToolsBackend(effects: effects).invoke(name: "type_text", arguments: arguments(["element_id": "ax_1", "text": "hello"]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("AX value insertion accepted but unverified") == true)
        XCTAssertEqual(writes, 1)
    }

    func testFailedExplicitAXPressNeverFallsBackToPointer() async {
        var effects = fakeEffects()
        effects.axAction = { _, _, _ in false }
        effects.post = { _, _, _ in XCTFail("ambiguous AX failure must not send another action") }
        let result = await InputToolsBackend(effects: effects).invoke(name: "click", arguments: arguments(["element_id": "ax_1", "action": "press"]))
        XCTAssertTrue(result.isError)
    }

    private func arguments(_ extra: [String: Any]) -> [String: Any] { base.merging(extra) { _, new in new } }

    func testKeyTableCoversLettersDigitsNavigationFunctionAndPunctuation() throws {
        for key in Array("abcdefghijklmnopqrstuvwxyz0123456789-=[];'\\,./`").map(String.init)
            + ["return", "tab", "escape", "space", "delete", "forwarddelete", "left", "right", "up", "down", "home", "end", "pageup", "pagedown"]
            + (1...12).map({ "f\($0)" }) {
            XCTAssertNoThrow(try InputKey.parse(key), key)
        }
        XCTAssertEqual(try InputKey.parse("A"), InputKey(code: 0, flags: .maskShift))
        XCTAssertEqual(try InputKey.parse("?"), InputKey(code: 44, flags: .maskShift))
        XCTAssertEqual(try InputKey.parse("enter").code, 36)
        XCTAssertEqual(try InputKey.parse("forwarddelete").code, 117)
        XCTAssertThrowsError(try InputKey.parse("unknown"))
        XCTAssertThrowsError(try InputKey.modifiers(["hyper"]))
    }

    func testHotkeyRequiresOneOrdinaryKeyAndCollectsModifiers() throws {
        XCTAssertEqual(try InputKey.hotkey(["cmd", "shift", "c"]), InputKey(code: 8, flags: [.maskCommand, .maskShift]))
        XCTAssertEqual(try InputKey.hotkey(["control", "alt", "delete"]), InputKey(code: 51, flags: [.maskControl, .maskAlternate]))
        XCTAssertThrowsError(try InputKey.hotkey([]))
        XCTAssertThrowsError(try InputKey.hotkey(["cmd"]))
        XCTAssertThrowsError(try InputKey.hotkey(["cmd", "a", "b"]))
        XCTAssertThrowsError(try InputKey.hotkey(["cmd", "unknown"]))
    }

    func testValidationRejectsMalformedTargetsAndAddressing() throws {
        XCTAssertNoThrow(try InputToolsBackend.validate(name: "click", arguments: arguments(["x": 0, "y": 0])))
        XCTAssertNoThrow(try InputToolsBackend.validate(name: "click", arguments: ["scope": "desktop", "x": -20, "y": 10]))
        XCTAssertNoThrow(try InputToolsBackend.validate(name: "type_text", arguments: arguments(["text": ""])))
        let bad: [[String: Any]] = [
            ["x": 0, "y": 0], arguments(["x": 0]), arguments(["x": true, "y": 0]),
            arguments(["x": Double.nan, "y": 0]), arguments(["x": 0, "y": 0, "count": 0]),
            arguments(["x": 0, "y": 0, "count": 1.5]), arguments(["x": 0, "y": 0, "button": "other"]),
            arguments(["element_id": "ax_1", "x": 0, "y": 0]), arguments(["element_id": "ax_1000"]),
            arguments(["element_id": "ax_1", "action": "delete"]), arguments(["x": 0, "y": 0, "action": "open"]),
            ["scope": "desktop", "element_id": "ax_1"], arguments(["x": 0, "y": 0, "delivery_mode": "automatic"]),
            ["target_pid": 0, "target_window_id": 7, "x": 0, "y": 0],
            ["target_pid": 42.5, "target_window_id": 7, "x": 0, "y": 0],
            ["target_pid": true, "target_window_id": 7, "x": 0, "y": 0]
        ]
        for item in bad { XCTAssertThrowsError(try InputToolsBackend.validate(name: "click", arguments: item), "\(item)") }
        XCTAssertThrowsError(try InputToolsBackend.validate(name: "type_text", arguments: arguments(["text": 5])))
        XCTAssertThrowsError(try InputToolsBackend.validate(name: "drag", arguments: arguments(["from_x": 0, "from_y": 0, "to_x": 1, "to_y": 1, "duration_ms": -1])))
        XCTAssertThrowsError(try InputToolsBackend.validate(name: "hotkey", arguments: arguments(["keys": ["cmd"]])))
        XCTAssertThrowsError(try InputToolsBackend.validate(name: "invoke_menu", arguments: arguments(["path": []])))
        XCTAssertThrowsError(try InputToolsBackend.validate(name: "double_click", arguments: ["scope": "desktop", "x": 0, "y": 0]))
    }

    func testMenuMatchingRefusesMissingAmbiguousDisabledAndUnknownEnabled() throws {
        let nodes = [InputNode(label: "File", enabled: true), InputNode(label: "Edit", enabled: false)]
        XCTAssertEqual(try InputNode.menuIndex(title: "File", nodes: nodes), 0)
        XCTAssertThrowsError(try InputNode.menuIndex(title: "file", nodes: nodes))
        XCTAssertThrowsError(try InputNode.menuIndex(title: "Edit", nodes: nodes))
        XCTAssertThrowsError(try InputNode.menuIndex(title: "File", nodes: nodes + [nodes[0]]))
        XCTAssertThrowsError(try InputNode.menuIndex(title: "File", nodes: [InputNode(label: "File")]))
        let tree = InputNode(children: [InputNode(label: "File", enabled: true, children: [InputNode(label: "Save", enabled: true)])])
        let first = tree.children[try InputNode.menuIndex(title: "File", nodes: tree.children)]
        XCTAssertEqual(try InputNode.menuIndex(title: "Save", nodes: first.children), 0)
        XCTAssertThrowsError(try InputNode.menuIndex(title: "Save", nodes: tree.children))
    }

    func testVerificationReturnsPassFailUnknownAndDoesNotGuessAmbiguousValue() {
        let field = InputNode(id: "ax_1", role: "AXTextField", label: "Name", value: "Ada")
        let selector: [String: Any] = ["role": "AXTextField", "label": "Name"]
        let state = InputSnapshot(windowExists: true, title: "Editor — Saved", nodes: [field], focused: field)
        let expectation: [String: Any] = ["title_contains": "Saved", "window_exists": true, "element_exists": selector,
                                        "element_value": ["element_id": "ax_1", "equals": "Ada"], "focused_element": selector]
        XCTAssertEqual(state.evaluate(expectation)["result"] as? String, "pass")
        XCTAssertEqual((state.evaluate(expectation)["checks"] as? [[String: Any]])?.count, 5)
        XCTAssertEqual(state.evaluate(["title_contains": "Unsaved"])["result"] as? String, "fail")
        XCTAssertEqual(state.evaluate(["element_value": ["element_id": "ax_1", "equals": "Grace"]])["result"] as? String, "fail")
        let unavailable = InputSnapshot(windowExists: true, title: nil, nodes: nil, focused: nil)
        XCTAssertEqual(unavailable.evaluate(expectation)["result"] as? String, "unknown")
        let ambiguous = InputSnapshot(windowExists: true, title: "", nodes: [field, field], focused: nil)
        XCTAssertEqual(ambiguous.evaluate(["element_value": selector.merging(["equals": "Ada"]) { _, new in new }])["result"] as? String, "unknown")
        let truncated = InputSnapshot(windowExists: true, title: "", nodes: [], focused: nil, complete: false)
        XCTAssertEqual(truncated.evaluate(["element_exists": selector])["result"] as? String, "unknown")
        let absent = InputSnapshot(windowExists: false, title: nil, nodes: nil, focused: nil)
        XCTAssertEqual(absent.evaluate(["window_exists": false])["result"] as? String, "pass")
        XCTAssertEqual(absent.evaluate(["window_exists": true, "title_contains": "x"])["result"] as? String, "fail")
    }

    func testVerificationValidationRejectsEmptyAndAmbiguousExpectations() {
        for expect: [String: Any] in [[:], ["unknown": true], ["window_exists": 1], ["title_contains": 2],
                                     ["element_exists": ["role": "AXButton"]],
                                     ["element_value": ["element_id": "ax_1", "role": "AXButton", "label": "Save", "equals": "1"]],
                                     ["element_value": ["element_id": "ax_1"]]] {
            XCTAssertThrowsError(try InputToolsBackend.validate(name: "verify_state", arguments: arguments(["expect": expect])))
        }
    }

    func testEveryToolHasSerializableSchemaAndDescription() throws {
        let tools = InputToolsBackend.observationTools + InputToolsBackend.mutationTools
        XCTAssertEqual(Set(tools).count, 10)
        for name in tools {
            XCTAssertFalse(try XCTUnwrap(InputToolsBackend.description(for: name)).isEmpty)
            let schema = try XCTUnwrap(InputToolsBackend.inputSchema(for: name))
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: schema))
        }
        XCTAssertNil(InputToolsBackend.inputSchema(for: "right_click"))
        XCTAssertNil(InputToolsBackend.description(for: "unknown"))
    }

    private func fakeEffects() -> InputToolsBackend.Effects {
        var effects = InputToolsBackend.Effects()
        effects.windows = { [ComputerUseNativeWindow(target: self.target, bounds: CGRect(x: 100, y: 200, width: 300, height: 200))] }
        effects.activity = { _ in .none }
        effects.frontmost = { 99 }
        effects.scale = { _ in 2 }
        effects.sleep = { _ in }
        effects.axAction = { _, _, _ in false }
        effects.axPressAt = { _, _ in false }
        effects.focusedWindow = { _ in true }
        effects.menuShortcut = { _, _ in false }
        effects.insert = { _, _, _ in false }
        effects.settleWatcher = { _ in .immediate }
        effects.hiddenChromium = { _, _ in false }
        return effects
    }

    func testTypedReturnAndTabAreKeyPressesNotText() async {
        // A newline sent as text on key code 0 is not a key press: Chrome's address bar and
        // single-line fields ignored it, so "type the URL and press Return" never submitted.
        var effects = fakeEffects()
        var codes: [Int64] = []
        effects.post = { event, _, _ in if event.type == .keyDown { codes.append(event.getIntegerValueField(.keyboardEventKeycode)) } }
        let result = await InputToolsBackend(effects: effects).invoke(name: "type_text", arguments: arguments(["text": "a\nb\t"]))
        XCTAssertFalse(result.isError, result.content.first?.text ?? "")
        XCTAssertEqual(codes, [0, 36, 0, 48])
    }

    func testAGestureThatStartedIsFinishedEvenIfTheUserArrives() async {
        // The activity check used to run before every event. Tripping between a key down and
        // its up left the key held in the target app, which is worse than either outcome.
        var effects = fakeEffects()
        var posted: [CGEventType] = []
        var userArrived = false
        effects.activity = { _ in userArrived ? .human : .none }
        effects.post = { event, _, _ in posted.append(event.type); userArrived = true }
        let backend = InputToolsBackend(effects: effects)
        let first = await backend.invoke(name: "press_key", arguments: arguments(["key": "return"]))
        XCTAssertFalse(first.isError, first.content.first?.text ?? "")
        XCTAssertEqual(posted, [.keyDown, .keyUp])
        // A new gesture still yields to the user.
        let second = await backend.invoke(name: "press_key", arguments: arguments(["key": "return"]))
        XCTAssertTrue(second.isError)
        XCTAssertEqual(posted.count, 2)
    }

    func testResultSaysWhetherTheAppReacted() async throws {
        // A click that did nothing used to come back as plain "ok", and the agent built on it.
        // Silence is reported as unverified, never as "nothing happened": a real page toggled
        // while its app sent no notification, and a false no-op would invite toggling it back.
        for (reacted, expected) in [(true, "ui_changed"), (false, "unverified"), (nil, "unverified")] as [(Bool?, String)] {
            var effects = fakeEffects()
            effects.axAction = { _, _, _ in true }
            effects.settleWatcher = { _ in NativeSettleWatcher(wait: { .init(settled: true, elapsedMilliseconds: 7, reacted: reacted) }) }
            let result = await InputToolsBackend(effects: effects).invoke(name: "click", arguments: arguments(["element_id": "ax_1"]))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result.content.first?.text).utf8)) as? [String: Any])
            XCTAssertEqual(object["effect"] as? String, expected)
            XCTAssertEqual(object["delivery"] as? String, "accessibility")
        }
        // The watcher only reports a reaction it actually saw.
        var answers = [true, false]
        XCTAssertEqual(NativeSettle.wait(now: { 0 }, waitForNotification: { _ in answers.removeFirst() }).reacted, true)
        XCTAssertEqual(NativeSettle.wait(now: { 0 }, waitForNotification: { _ in false }).reacted, false)
    }

    func testATargetThatBringsItselfForwardGivesTheFrontBack() async throws {
        // Background delivery promises the user's app stays in front. Pressing a control made a
        // browser activate itself over what the user was doing; the front is handed back, unless
        // the user is the one who went there.
        func run(userWentThere: Bool) async throws -> (result: [String: Any], activated: [Int32]) {
            var effects = fakeEffects()
            var front: Int32 = 99
            var activated: [Int32] = []
            var acted = false
            effects.frontmost = { front }
            effects.axAction = { target, _, _ in front = target.pid; acted = true; return true }
            effects.activity = { _ in acted && userWentThere ? .human : .none }
            effects.activate = { activated.append($0); front = $0; return true }
            let result = await InputToolsBackend(effects: effects).invoke(name: "click", arguments: arguments(["element_id": "ax_1"]))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result.content.first?.text).utf8)) as? [String: Any])
            return (object, activated)
        }
        let stolen = try await run(userWentThere: false)
        XCTAssertEqual(stolen.result["took_focus"] as? Bool, true)
        XCTAssertEqual(stolen.result["focus_returned"] as? Bool, true)
        XCTAssertEqual(stolen.activated, [99])
        let chosen = try await run(userWentThere: true)
        XCTAssertNil(chosen.result["took_focus"])
        XCTAssertEqual(chosen.activated, [], "an app the user switched to must not be taken away from them")
    }

    func testKeysGoToTheNamedElementNotToWhateverHoldsFocus() async {
        // Return pressed after an address bar was only given a value went to the page instead:
        // setting a value through Accessibility does not move keyboard focus.
        var effects = fakeEffects()
        var order: [String] = []
        effects.focusElement = { _, id in order.append("focus:\(id)"); return id == "ax_10" }
        effects.post = { event, _, _ in if event.type == .keyDown { order.append("key:\(event.getIntegerValueField(.keyboardEventKeycode))") } }
        let backend = InputToolsBackend(effects: effects)
        let pressed = await backend.invoke(name: "press_key", arguments: arguments(["key": "return", "element_id": "ax_10"]))
        XCTAssertFalse(pressed.isError, pressed.content.first?.text ?? "")
        XCTAssertEqual(order, ["focus:ax_10", "key:36"])
        // An element that cannot take focus is reported; the key is not sent somewhere else instead.
        let refused = await backend.invoke(name: "hotkey", arguments: arguments(["keys": ["cmd", "a"], "element_id": "ax_11"]))
        XCTAssertTrue(refused.isError)
        XCTAssertEqual(order, ["focus:ax_10", "key:36", "focus:ax_11"])
    }

    func testTextThatEndsInReturnIsTypedSoTheReturnSubmits() async {
        // Inserted through Accessibility, "url\n" became a field holding a newline and nothing was submitted.
        var effects = fakeEffects()
        var codes: [Int64] = []
        effects.insert = { _, _, _ in XCTFail("a text with Return must not be inserted as a value"); return true }
        effects.focusElement = { _, _ in true }
        effects.post = { event, _, _ in if event.type == .keyDown { codes.append(event.getIntegerValueField(.keyboardEventKeycode)) } }
        let result = await InputToolsBackend(effects: effects).invoke(name: "type_text", arguments: arguments(["text": "go\r\n", "element_id": "ax_10"]))
        XCTAssertFalse(result.isError, result.content.first?.text ?? "")
        XCTAssertEqual(codes, [0, 0, 36])
    }

    func testACoveredChromiumWindowIsCalledOutInsteadOfReportedAsDelivered() async throws {
        // Measured on a real window: the same background click toggled a page while the window
        // was visible and did nothing once another window covered it, with the same "ok".
        var effects = fakeEffects()
        effects.hiddenChromium = { _, _ in true }
        let covered = await InputToolsBackend(effects: effects).invoke(name: "click", arguments: arguments(["x": 10, "y": 10]))
        let warned = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(covered.content.first?.text).utf8)) as? [String: Any])
        XCTAssertTrue((warned["warning"] as? String)?.contains("browser tools") == true)
        // Accessibility actions do not depend on the page being shown.
        effects.axAction = { _, _, _ in true }
        let pressed = await InputToolsBackend(effects: effects).invoke(name: "click", arguments: arguments(["element_id": "ax_1"]))
        let quiet = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(pressed.content.first?.text).utf8)) as? [String: Any])
        XCTAssertNil(quiet["warning"])

        typealias Platform = ComputerUseNativeHostBackend.NativePlatform
        let frame = CGRect(x: 40, y: 60, width: 900, height: 700)
        XCTAssertTrue(Platform.covered(target: 5, bounds: frame, frontToBack: [(1, CGRect(x: 0, y: 30, width: 1668, height: 1265)), (5, frame)]))
        XCTAssertFalse(Platform.covered(target: 5, bounds: frame, frontToBack: [(1, CGRect(x: 100, y: 100, width: 400, height: 400)), (5, frame)]))
        XCTAssertFalse(Platform.covered(target: 5, bounds: frame, frontToBack: [(5, frame), (1, CGRect(x: 0, y: 0, width: 3000, height: 3000))]), "a window behind it hides nothing")
    }

    func testClickPixelsFollowTheScreenshotTheCallerWasGiven() async {
        // click takes pixels of the screenshot. That image is scaled down from the frame, so
        // dividing by the display scale sent clicks to the wrong point; with no screenshot on
        // record the pixels are still read as frame pixels, as before.
        var effects = fakeEffects()
        var pressed: [CGPoint] = []
        effects.axPressAt = { _, point in pressed.append(point); return true }
        effects.screenshotScale = { _, bounds in bounds.width == 300 ? 0.5 : nil }
        _ = await InputToolsBackend(effects: effects).invoke(name: "click", arguments: arguments(["x": 75, "y": 50]))
        XCTAssertEqual(pressed.last, CGPoint(x: 100 + 150, y: 200 + 100))
        let outside = await InputToolsBackend(effects: effects).invoke(name: "click", arguments: arguments(["x": 151, "y": 50]))
        XCTAssertTrue(outside.isError, "151 is past the 150-pixel image of a 300-point window")
        effects.screenshotScale = { _, _ in nil }
        _ = await InputToolsBackend(effects: effects).invoke(name: "click", arguments: arguments(["x": 75, "y": 50]))
        XCTAssertEqual(pressed.last, CGPoint(x: 100 + 37.5, y: 200 + 25))
    }

    func testUnknownArgumentNamesTheOnesThatAreAccepted() async {
        // "unknown argument: width" left the caller guessing; a screenshot width was the real case.
        let result = await InputToolsBackend(effects: fakeEffects()).invoke(name: "click", arguments: arguments(["x": 1, "y": 1, "width": 900]))
        XCTAssertTrue(result.isError)
        let text = result.content.first?.text ?? ""
        XCTAssertTrue(text.contains("unknown argument: width"), text)
        XCTAssertTrue(text.contains("accepted:") && text.contains("delivery_mode") && text.contains("expected_state_token"), text)
    }

    func testBackgroundPixelClickUsesAXPressWhenAvailable() async {
        var effects = fakeEffects()
        var pressedAt: CGPoint?
        var events: [CGEvent] = []
        effects.axPressAt = { _, point in pressedAt = point; return true }
        effects.post = { event, _, _ in events.append(event) }
        let backend = InputToolsBackend(effects: effects)
        let result = await backend.invoke(name: "click", arguments: arguments(["x": 40, "y": 60]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(pressedAt, CGPoint(x: 120, y: 230))
        XCTAssertTrue(events.isEmpty)
    }

    func testBackgroundDoubleClickRepeatsAXPressSoAppsIgnoringPidEventsStillSeeTwoPresses() async {
        var effects = fakeEffects()
        var presses = 0
        effects.axPressAt = { _, _ in presses += 1; return true }
        effects.post = { _, _, _ in XCTFail("AX-pressable control must not receive ignored pid events") }
        let result = await InputToolsBackend(effects: effects).invoke(name: "double_click", arguments: arguments(["x": 40, "y": 60]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(presses, 2)
    }

    func testBackgroundCommandHotkeyPressesMenuItemBecausePidKeyEventsSkipTheMenuBar() async {
        var effects = fakeEffects()
        var chord: ComputerUseNativeMenuChord?
        effects.menuShortcut = { _, c in chord = c; return true }
        effects.post = { _, _, _ in XCTFail("menu-backed chord must not fall back to key events") }
        let result = await InputToolsBackend(effects: effects).invoke(name: "hotkey", arguments: arguments(["keys": ["cmd", "c"]]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(chord?.key, "C")
        XCTAssertEqual(chord?.command, true)
    }

    func testBackgroundPixelDeliveryConvertsScaleTagsEventsAndNeverActivates() async {
        var effects = fakeEffects()
        var events: [CGEvent] = []
        var activations = 0
        effects.activate = { _ in activations += 1; return true }
        effects.post = { event, pid, foreground in
            XCTAssertEqual(pid, 42)
            XCTAssertFalse(foreground)
            events.append(event)
        }
        effects.windowLocation = { _, point in XCTAssertEqual(point, CGPoint(x: 20, y: 30)) }
        let backend = InputToolsBackend(effects: effects)
        let result = await backend.invoke(name: "click", arguments: arguments(["x": 40, "y": 60, "modifier": ["cmd"]]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(events.count, 3)
        for event in events {
            XCTAssertEqual(event.location, CGPoint(x: 120, y: 230))
            XCTAssertEqual(event.getIntegerValueField(CGEventField(rawValue: 40)!), 42)
            for field: UInt32 in [51, 91, 92] {
                XCTAssertEqual(event.getIntegerValueField(CGEventField(rawValue: field)!), 7)
            }
            XCTAssertTrue(event.flags.contains(.maskCommand))
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), ComputerUseNativeActivityMonitor.syntheticEventUserData)
        }
        let outside = await backend.invoke(name: "click", arguments: arguments(["x": 600, "y": 0]))
        XCTAssertTrue(outside.isError)
        XCTAssertEqual(events.count, 3)
    }

    func testHumanActivityRefusesEveryMutationBeforeEffects() async {
        var effects = fakeEffects()
        effects.activity = { _ in .human }
        effects.post = { _, _, _ in XCTFail("must not post") }
        effects.activate = { _ in XCTFail("must not activate"); return false }
        effects.axAction = { _, _, _ in XCTFail("must not perform AX action"); return false }
        effects.insert = { _, _, _ in XCTFail("must not insert"); return false }
        effects.warp = { _ in XCTFail("must not warp"); return false }
        effects.menu = { _, _, _ in XCTFail("must not invoke menu") }
        let backend = InputToolsBackend(effects: effects)
        let cases: [(String, [String: Any])] = [
            ("click", ["x": 0, "y": 0]), ("double_click", ["element_id": "ax_1"]),
            ("drag", ["from_x": 0, "from_y": 0, "to_x": 1, "to_y": 1]),
            ("type_text", ["text": "hello"]), ("press_key", ["key": "return"]),
            ("hotkey", ["keys": ["cmd", "c"]]), ("move_cursor", ["x": 0, "y": 0]),
            ("invoke_menu", ["path": ["File", "Save"]])
        ]
        for (name, extra) in cases {
            let result = await backend.invoke(name: name, arguments: arguments(extra))
            XCTAssertTrue(result.isError, name)
            guard let text = result.content.first?.text else { XCTFail("missing error"); continue }
            XCTAssertTrue(text.hasPrefix("human_activity"), text)
        }
    }

    func testEscalationActsWhileTheUserIsOnTheTargetAndTheRefusalSaysHow() async throws {
        // Stealth is the default, but a refusal must not be a dead end: when no quiet route
        // exists the caller retries the same call with allow_while_user_active.
        var effects = fakeEffects()
        effects.activity = { _ in .human }
        var pressed = 0
        effects.axAction = { _, _, _ in pressed += 1; return true }
        let backend = InputToolsBackend(effects: effects)
        let refused = await backend.invoke(name: "click", arguments: arguments(["element_id": "ax_1"]))
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(try XCTUnwrap(refused.content.first?.text).contains("allow_while_user_active"))
        XCTAssertEqual(pressed, 0)
        let allowed = await backend.invoke(name: "click", arguments: arguments(["element_id": "ax_1", "allow_while_user_active": true]))
        XCTAssertFalse(allowed.isError, allowed.content.first?.text ?? "")
        XCTAssertEqual(pressed, 1)
        let invalid = await backend.invoke(name: "click", arguments: arguments(["element_id": "ax_1", "allow_while_user_active": "yes"]))
        XCTAssertTrue(invalid.isError)
        XCTAssertEqual(pressed, 1)
    }

    func testForegroundSucceedsWhenRaiseFailsIfActivationMakesTargetFrontmost() async {
        var effects = fakeEffects()
        var frontmost: Int32 = 99
        var events: [CGEvent] = []
        effects.frontmost = { frontmost }
        effects.activate = { pid in frontmost = pid; return true }
        effects.raise = { _ in false }
        effects.post = { event, _, foreground in
            XCTAssertTrue(foreground)
            events.append(event)
        }
        let backend = InputToolsBackend(effects: effects)
        let result = await backend.invoke(name: "click", arguments: arguments(["x": 10, "y": 10, "delivery_mode": "foreground"]))
        XCTAssertFalse(result.isError)
        // A pointer move comes first: a press with none before it misses controls that arm on hover.
        XCTAssertEqual(events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])

        effects.focusedWindow = { _ in false }
        let otherWindowBackend = InputToolsBackend(effects: effects)
        let otherWindow = await otherWindowBackend.invoke(name: "click", arguments: arguments(["x": 10, "y": 10, "delivery_mode": "foreground"]))
        XCTAssertTrue(otherWindow.isError, "keys must never reach a sibling window of the same app")
        XCTAssertEqual(events.count, 3)

        effects.activate = { _ in false }
        let failingBackend = InputToolsBackend(effects: effects)
        let failed = await failingBackend.invoke(name: "click", arguments: arguments(["x": 10, "y": 10, "delivery_mode": "foreground"]))
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(events.count, 3)
    }

    func testForegroundRestoresPriorAppAndWindowMoveDoesNotWarp() async {
        var effects = fakeEffects()
        var frontmost: Int32 = 99
        var activations: [Int32] = []
        effects.frontmost = { frontmost }
        effects.activate = { pid in activations.append(pid); frontmost = pid; return true }
        effects.raise = { target in XCTAssertEqual(target, self.target); return true }
        effects.post = { event, _, foreground in
            XCTAssertTrue(foreground)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), ComputerUseNativeActivityMonitor.syntheticEventUserData)
        }
        effects.warp = { _ in XCTFail("window scope must not warp"); return false }
        let backend = InputToolsBackend(effects: effects)
        let result = await backend.invoke(name: "press_key", arguments: arguments(["key": "tab", "delivery_mode": "foreground"]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(activations, [42, 99])
        let move = await backend.invoke(name: "move_cursor", arguments: arguments(["x": 0, "y": 0]))
        XCTAssertFalse(move.isError)
        XCTAssertEqual(activations, [42, 99])
    }
    func testDoubleClickUsesAXOpenBeforePixelFallback() async {
        var effects = fakeEffects()
        var actions: [String] = []
        var events: [CGEvent] = []
        var canOpen = true
        effects.axAction = { _, _, action in actions.append(action); return canOpen }
        effects.elementPoint = { _, _ in CGPoint(x: 150, y: 250) }
        effects.post = { event, _, _ in events.append(event) }
        let backend = InputToolsBackend(effects: effects)
        let opened = await backend.invoke(name: "double_click", arguments: arguments(["element_id": "ax_1"]))
        XCTAssertFalse(opened.isError)
        XCTAssertEqual(actions, ["AXOpen"])
        XCTAssertTrue(events.isEmpty)
        canOpen = false
        let clicked = await backend.invoke(name: "double_click", arguments: arguments(["element_id": "ax_1"]))
        XCTAssertFalse(clicked.isError)
        XCTAssertEqual(events.map { $0.getIntegerValueField(.mouseEventClickState) }, [0, 1, 1, 2, 2])
    }

    func testUnicodeDragAndHotkeyFallbackEventsStayTagged() async {
        var effects = fakeEffects()
        var events: [CGEvent] = []
        effects.post = { event, _, foreground in XCTAssertFalse(foreground); events.append(event) }
        let backend = InputToolsBackend(effects: effects)
        let typed = await backend.invoke(name: "type_text", arguments: arguments(["text": "A😀"]))
        XCTAssertFalse(typed.isError)
        XCTAssertEqual(events.count, 4)
        let chord = await backend.invoke(name: "hotkey", arguments: arguments(["keys": ["cmd", "c"]]))
        XCTAssertFalse(chord.isError)
        XCTAssertTrue(events.last!.flags.contains(.maskCommand))
        let dragged = await backend.invoke(name: "drag", arguments: arguments(["from_x": 0, "from_y": 0, "to_x": 20, "to_y": 40, "duration_ms": 0]))
        XCTAssertFalse(dragged.isError)
        XCTAssertEqual(Array(events.suffix(3)).map(\.type), [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        XCTAssertEqual(events.last?.location, CGPoint(x: 110, y: 220))
        for event in events.suffix(3) {
            for field: UInt32 in [51, 91, 92] { XCTAssertEqual(event.getIntegerValueField(CGEventField(rawValue: field)!), 7) }
        }
        for event in events {
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), ComputerUseNativeActivityMonitor.syntheticEventUserData)
        }
    }

    func testExplicitTextElementCannotSilentlyFallBackToDifferentFocus() async {
        var effects = fakeEffects()
        effects.focusElement = { _, _ in false }
        effects.post = { _, _, _ in XCTFail("unresolved element must not receive keyboard fallback") }
        let result = await InputToolsBackend(effects: effects).invoke(name: "type_text", arguments: arguments(["element_id": "ax_1", "text": "private"]))
        XCTAssertTrue(result.isError)
    }

    func testDesktopWarpAndCursorObservationUseScreenPoints() async throws {
        var effects = fakeEffects()
        var warped: CGPoint?
        effects.warp = { warped = $0; return true }
        effects.cursor = { CGPoint(x: -20, y: 50) }
        let backend = InputToolsBackend(effects: effects)
        let move = await backend.invoke(name: "move_cursor", arguments: ["scope": "desktop", "x": -20, "y": 50])
        XCTAssertFalse(move.isError)
        XCTAssertEqual(warped, CGPoint(x: -20, y: 50))
        let observation = await backend.invoke(name: "get_cursor_position", arguments: [:])
        let text = try XCTUnwrap(observation.content.first?.text)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["x"] as? Double, -20)
        XCTAssertEqual(object["coordinate_space"] as? String, "screen_points")
    }
}
