import XCTest
@testable import CoreModel

final class LayoutReducerTests: XCTestCase {
    func test_createWorkspace_addsAndSelects() throws {
        let r = LayoutReducer()
        let s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        XCTAssertEqual(s.window.workspaces.count, 1)
        XCTAssertNotNil(s.window.selectedWorkspaceID)
    }

    func test_setWorkspaceColor_setsAndClears() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .setWorkspaceColor(wid, "purple"))
        XCTAssertEqual(s.workspaces[wid]?.metadata["color"], "purple")
        s = try r.reduce(s, .setWorkspaceColor(wid, ""))
        XCTAssertNil(s.workspaces[wid]?.metadata["color"], "empty clears the color key")
    }

    func test_workspacePinningAndReorder_keepPinnedWorkspacesFirst() throws {
        let r = LayoutReducer()
        var s = LayoutState()
        s = try r.reduce(s, .createWorkspace(name: "one", cwd: "/tmp", initial: nil))
        let one = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "two", cwd: "/tmp", initial: nil))
        let two = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "three", cwd: "/tmp", initial: nil))
        let three = s.window.selectedWorkspaceID!

        s = try r.reduce(s, .setWorkspacePinned(two, true))
        XCTAssertEqual(s.window.workspaces, [two, one, three],
                       "pinning a workspace must move it above unpinned workspaces without losing relative order")

        s = try r.reduce(s, .reorderWorkspace(three, position: 0))
        XCTAssertEqual(s.window.workspaces, [two, three, one],
                       "drag reorder must respect the pinned-first sort boundary")
    }

    func test_promoteWorkspace_movesOnlyInsidePinnedGroup() throws {
        let r = LayoutReducer()
        var s = LayoutState()
        s = try r.reduce(s, .createWorkspace(name: "one", cwd: "/tmp", initial: nil))
        let one = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "two", cwd: "/tmp", initial: nil))
        let two = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "three", cwd: "/tmp", initial: nil))
        let three = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "four", cwd: "/tmp", initial: nil))
        let four = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .setWorkspacePinned(two, true))
        s = try r.reduce(s, .setWorkspacePinned(four, true))

        s = try r.reduce(s, .promoteWorkspace(three))
        XCTAssertEqual(s.window.workspaces, [two, four, three, one],
                       "a completed unpinned workspace must jump to the top of unpinned workspaces without crossing pinned workspaces")

        s = try r.reduce(s, .promoteWorkspace(four))
        XCTAssertEqual(s.window.workspaces, [four, two, three, one],
                       "a completed pinned workspace must jump to the top of pinned workspaces")
    }

    func test_setSurfaceColor_writesToDescriptorMetadata() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let surf = SurfaceDescriptor(type: .terminal, title: "term")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: surf))
        s = try r.reduce(s, .setSurfaceColor(wid, surf.id, "green"))
        let found = s.workspaces[wid]?.layout.paneIDs().compactMap {
            s.workspaces[wid]?.layout.find(paneID: $0)?.surfaces.first { $0.id == surf.id }
        }.first
        XCTAssertEqual(found?.metadata["color"], "green")
    }

    func test_addSurface_setsSelected() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let surface = SurfaceDescriptor(type: .terminal, title: "t1")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: surface))
        let ws = s.workspaces[wid]!
        guard case .pane(let pane) = ws.layout else { return XCTFail("not pane") }
        XCTAssertEqual(pane.surfaces.count, 1)
        XCTAssertEqual(pane.selectedSurfaceID, surface.id)
    }

    func test_split_createsSplitNode_andFocusesNewPane() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let initial = SurfaceDescriptor(type: .terminal, title: "left")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: initial))
        let ws0 = s.workspaces[wid]!
        guard case .pane(let pane0) = ws0.layout else { return XCTFail() }
        let newSurface = SurfaceDescriptor(type: .agentApp, title: "right")
        s = try r.reduce(s, .splitPane(wid, paneID: pane0.id, direction: .right, newSurface: newSurface))
        let ws = s.workspaces[wid]!
        guard case .split(let split) = ws.layout else { return XCTFail("expected split") }
        XCTAssertEqual(split.children.count, 2)
        XCTAssertEqual(split.orientation, .horizontal)
        XCTAssertTrue(ws.layout.contains(surfaceID: newSurface.id))
        XCTAssertNotEqual(ws.focusedPaneID, pane0.id)
    }

    func test_closeSurface_collapsesEmptyPane() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .browser, title: "b")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: p, direction: .right, newSurface: b))
        // close `b` -> split should collapse to single pane node
        s = try r.reduce(s, .closeSurface(wid, b.id))
        guard case .pane = s.workspaces[wid]!.layout else { return XCTFail("expected pane after collapse") }
    }

    func test_closeSelectedSurface_selectsNeighborNotFirst() throws {
        // WHY: closing the selected tab must select the adjacent tab so the user's place in the strip holds; jumping to the first tab loses it.
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .terminal, title: "b")
        let c = SurfaceDescriptor(type: .terminal, title: "c")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .addSurface(wid, paneID: p, descriptor: b))
        s = try r.reduce(s, .addSurface(wid, paneID: p, descriptor: c))
        s = try r.reduce(s, .focusSurface(wid, b.id))
        s = try r.reduce(s, .closeSurface(wid, b.id))
        XCTAssertEqual(s.workspaces[wid]!.layout.find(paneID: p)?.selectedSurfaceID, c.id, "closing the middle tab selects the tab that slid into its place")
        s = try r.reduce(s, .closeSurface(wid, c.id))
        XCTAssertEqual(s.workspaces[wid]!.layout.find(paneID: p)?.selectedSurfaceID, a.id, "closing the last tab selects the previous tab")
    }

    func test_closeSurface_unknownSurface_throwsAndPreservesLayout() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let before = s

        XCTAssertThrowsError(try r.reduce(s, .closeSurface(wid, SurfaceID()))) { error in
            XCTAssertEqual(error as? LayoutError, .surfaceNotFound,
                           "closing a missing tab must fail loudly instead of publishing a fake surface.closed event")
        }
        XCTAssertEqual(s, before,
                       "a failed close for an unknown surface must leave the workspace layout unchanged")
    }

    func test_unknown_workspace_throws() {
        let r = LayoutReducer()
        XCTAssertThrowsError(try r.reduce(LayoutState(), .selectWorkspace(WorkspaceID()))) { e in
            XCTAssertEqual(e as? LayoutError, .workspaceNotFound)
        }
    }

    func test_focusSurface_movesFocusedPane() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .agentApp, title: "b")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: p, direction: .down, newSurface: b))
        s = try r.reduce(s, .focusSurface(wid, a.id))
        XCTAssertEqual(s.workspaces[wid]!.focusedPaneID, p)
    }

    // MARK: - reorderedIndex helper

    /// WHY: reorderedIndex is the single index-adjustment gate for drag-reorder.
    /// A downward drag (dragged < target) must subtract 1 because removing the
    /// dragged item shifts all subsequent indices left; without the adjustment the
    /// item lands one row AFTER the insertion line instead of on it.
    func test_reorderedIndex_downwardDrag_subtractsOne() {
        // [A,B,C,D]: drag A (0) before C (2).
        // Remove A -> [B,C,D].  C is now at 1.  Insert before C -> index 1.
        XCTAssertEqual(LayoutReducer.reorderedIndex(dragged: 0, target: 2), 1,
                       "downward drag must subtract 1 from target to compensate for left-shift after removal")
    }

    /// WHY: upward drag must not adjust the index -- removing an item that sits
    /// after the target does not shift the target.  Adjusting would land the item
    /// one row too high.
    func test_reorderedIndex_upwardDrag_unchanged() {
        // [A,B,C]: drag C (2) before A (0).
        // Remove C -> [A,B].  A is still at 0.  Insert before A -> index 0.
        XCTAssertEqual(LayoutReducer.reorderedIndex(dragged: 2, target: 0), 0,
                       "upward drag must leave target index unchanged  -  " +
                       "the dragged item is after the target so removal does not shift the target")
    }

    /// WHY: dragging to the immediately adjacent slot in each direction must
    /// produce the correct neighbour swap, not a no-op or out-of-bounds.
    func test_reorderedIndex_adjacentDownward_subtractsOne() {
        // [A,B]: drag A (0) before B (1) -> insertIndex = 0.
        XCTAssertEqual(LayoutReducer.reorderedIndex(dragged: 0, target: 1), 0,
                       "dragging one step down must produce insertIndex 0 (adjacent swap)")
    }

    func test_reorderedIndex_adjacentUpward_unchanged() {
        // [A,B]: drag B (1) before A (0) -> insertIndex = 0.
        XCTAssertEqual(LayoutReducer.reorderedIndex(dragged: 1, target: 0), 0,
                       "dragging one step up must produce insertIndex 0 (adjacent swap)")
    }

    /// WHY: same-index input (before-guard caller passes dragged == target)
    /// must return target unchanged so callers that skip the no-op guard do not crash.
    func test_reorderedIndex_sameIndex_unchanged() {
        XCTAssertEqual(LayoutReducer.reorderedIndex(dragged: 2, target: 2), 2,
                       "same dragged and target index must return target unchanged  -  " +
                       "callers guard against this but the helper must not produce a negative index")
    }

    /// WHY: end-to-end reorder via the reducer must produce the visually correct
    /// order for a 4-item downward drag, matching the example in the todo spec:
    /// [A,B,C,D] move A to drop-before-C -> [B,A,C,D].
    func test_reorderWorkspace_fourItem_downwardDrag_landsBeforeTarget() throws {
        let r = LayoutReducer()
        var s = LayoutState()
        s = try r.reduce(s, .createWorkspace(name: "A", cwd: "/a", initial: nil))
        let a = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "B", cwd: "/b", initial: nil))
        let b = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "C", cwd: "/c", initial: nil))
        let c = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "D", cwd: "/d", initial: nil))
        let d = s.window.selectedWorkspaceID!
        // Initial order: [A, B, C, D]
        XCTAssertEqual(s.window.workspaces, [a, b, c, d])

        // Drag A (index 0) before C (index 2).  SidebarView passes targetIndex=2.
        // reorderedIndex(dragged:0, target:2) = 1.
        // Result: [B, A, C, D].
        s = try r.reduce(s, .reorderWorkspace(a, position: 2))
        XCTAssertEqual(s.window.workspaces, [b, a, c, d],
                       "[A,B,C,D] drag A before C must produce [B,A,C,D]  -  " +
                       "the insertion line is at the top of C so A must land immediately before C, not after it")
    }

    func test_layoutErrorLocalizedDescription_isReadable_notTheBridgedEnumCode() {
        // WHY: Activity and other alerts show `error.localizedDescription`. Bridged as a
        // plain Error, workspaceNotFound read "CoreModel.LayoutError error 0", which tells
        // the user nothing about why their conversation did not open.
        for error in [LayoutError.workspaceNotFound, .paneNotFound, .surfaceNotFound, .invalidLayout] {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("LayoutError"), text)
            XCTAssertFalse(text.contains("error 0"), text)
        }
        XCTAssertEqual(LayoutError.workspaceNotFound.localizedDescription,
                       "Its workspace is closed or no longer exists.")
    }
}
