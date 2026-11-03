import XCTest
@testable import AppShell

/// WHY: the owner (2026-10-20) wants every submenu row (conversation, Bot,
/// terminal tab) to show the green dot when its work just finished, like the
/// workspace row, until the user opens it.
final class SidebarFinishedDotTests: XCTestCase {
    func test_rowThatStoppedRunningGetsTheDotUntilItRunsAgain() {
        let finished = SidebarViewModel.finishedAfterTransition(previous: ["a", "b"], now: ["b"], current: [], except: nil)
        XCTAssertEqual(finished, ["a"])
        XCTAssertEqual(SidebarViewModel.finishedAfterTransition(previous: ["b"], now: ["a", "b"], current: finished, except: nil), [],
                       "running again replaces the dot with the spinner")
    }

    func test_rowOnScreenNeverGetsTheDot() {
        XCTAssertEqual(SidebarViewModel.finishedAfterTransition(previous: ["a"], now: [], current: [], except: "a"), [])
    }

    func test_everyChildRowRendersTheDot() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "{ finishedDot }").count - 1, 4, "conversation, workspace Bot, general Bot and open tab rows")
    }
}

/// WHY: rows must keep their stored order so a running row never jumps while the user is reading the list.
final class SidebarPinnedFirstTests: XCTestCase {
    func test_pinnedMovesUpAndRunningNeverReorders() {
        let order = SidebarViewModel.pinnedFirst(["a", "pin", "b", "c"], isPinned: { $0 == "pin" })
        XCTAssertEqual(order, ["pin", "a", "b", "c"], "running rows keep the stored order; only pinned moves up")
    }
}
