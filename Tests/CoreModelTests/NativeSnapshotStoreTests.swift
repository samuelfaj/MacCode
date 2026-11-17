import ApplicationServices
import XCTest
@testable import CoreModel

final class NativeSnapshotStoreTests: XCTestCase {
    private let target = ComputerUseNativeHostTarget(pid: 42, windowID: 7)
    private func element(_ n: Int32) -> AXUIElement { AXUIElementCreateApplication(n) }
    private func identity(_ title: String) -> NativeSnapshotStore.Identity { .init(role: "AXButton", title: title) }

    /// Identities as the live elements would report them now, keyed by the fake pid behind each element.
    private func live(_ now: [Int32: String]) -> (AXUIElement) -> NativeSnapshotStore.Identity? {
        { element in
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            return now[pid].map { .init(role: "AXButton", title: $0) }
        }
    }

    func testAnIdKeepsPointingAtTheControlTheCallerReadAfterTheTreeChanges() {
        // Slack inserted a row above the button between the read and the click. Position 1 of
        // the new tree is a different control; the caller meant the one it was shown.
        let store = NativeSnapshotStore()
        store.publish(target: target, tree: "before", elements: [element(1), element(2)], identities: [identity("Window"), identity("Send")])
        store.bind(token: "token-before", tree: "before", target: target)
        store.publish(target: target, tree: "after", elements: [element(1), element(3), element(2)],
                      identities: [identity("Window"), identity("New message"), identity("Send")])
        store.bind(token: "token-after", tree: "after", target: target)

        guard case .found(let old) = store.resolve(target: target, index: 1, token: "token-before", identity: live([2: "Send", 3: "New message"])) else {
            return XCTFail("the earlier observation must still resolve")
        }
        XCTAssertTrue(CFEqual(old, element(2)))
        guard case .found(let new) = store.resolve(target: target, index: 1, token: "token-after", identity: live([2: "Send", 3: "New message"])) else {
            return XCTFail("the later observation must resolve too")
        }
        XCTAssertTrue(CFEqual(new, element(3)))
    }

    func testAControlThatBecameSomethingElseOrDisappearedIsRefused() {
        // The same AX element can be reused for another row; acting on it would hit the wrong thing.
        let store = NativeSnapshotStore()
        store.publish(target: target, tree: "tree", elements: [element(1), element(2)], identities: [identity("Window"), identity("Delete draft")])
        store.bind(token: "token", tree: "tree", target: target)
        for now in [[2: "Delete account"], [:]] as [[Int32: String]] {
            guard case .changed = store.resolve(target: target, index: 1, token: "token", identity: live(now)) else {
                return XCTFail("a renamed or dead element must not resolve")
            }
        }
        guard case .changed = store.resolve(target: target, index: 9, token: "token", identity: live([:])) else {
            return XCTFail("an id the observation never contained must not resolve")
        }
    }

    func testAnObservationThisServerDoesNotHoldIsReportedAsUnknown() {
        // The caller then falls back to the strict whole-observation check instead of guessing.
        let store = NativeSnapshotStore()
        guard case .unknown = store.resolve(target: target, index: 0, token: "never-seen", identity: live([:])) else { return XCTFail() }
        store.publish(target: target, tree: "tree-0", elements: [element(1)], identities: [identity("A")])
        store.bind(token: "token-0", tree: "tree-0", target: target)
        for n in 1...NativeSnapshotStore.snapshotsPerWindow {
            store.publish(target: target, tree: "tree-\(n)", elements: [element(1)], identities: [identity("A")])
        }
        guard case .unknown = store.resolve(target: target, index: 0, token: "token-0", identity: live([1: "A"])) else {
            return XCTFail("an evicted observation must not resolve")
        }
    }

    func testAnIdWithoutATokenMeansTheTreeTheCallerLastReceived() {
        // Every action re-reads the tree internally. Those reads were never shown to the caller,
        // so its ids must not be counted against them.
        let store = NativeSnapshotStore()
        store.publish(target: target, tree: "shown", elements: [element(1), element(2)], identities: [identity("Window"), identity("Send")])
        store.bind(token: "shown-token", tree: "shown", target: target)
        store.deliver(token: "shown-token", target: target)
        store.publish(target: target, tree: "internal", elements: [element(1), element(3), element(2)],
                      identities: [identity("Window"), identity("Banner"), identity("Send")])
        guard case .found(let found) = store.resolve(target: target, index: 1, token: nil, identity: live([2: "Send", 3: "Banner"])) else { return XCTFail() }
        XCTAssertTrue(CFEqual(found, element(2)))
    }

    func testScreenshotScaleHoldsOnlyWhileTheWindowKeepsItsSize() {
        // Click pixels are read from the image the caller was given. Once the window is resized
        // that image no longer maps onto it, and guessing would click the wrong place.
        let store = NativeSnapshotStore()
        XCTAssertNil(store.screenshotPixelsPerPoint(target: target, windowSize: CGSize(width: 1668, height: 1264)))
        store.recordScreenshot(target: target, imageSize: [1366, 1035], windowSize: CGSize(width: 1668, height: 1264))
        XCTAssertEqual(try XCTUnwrap(store.screenshotPixelsPerPoint(target: target, windowSize: CGSize(width: 1668, height: 1264))), 1366.0 / 1668.0, accuracy: 0.0001)
        XCTAssertNil(store.screenshotPixelsPerPoint(target: target, windowSize: CGSize(width: 1200, height: 900)))
    }
}
