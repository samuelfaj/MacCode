import XCTest
import CoreModel
@testable import AppShell
@testable import Surfaces

/// The Agent App shows the same floating + as the Bot desk, and it starts a
/// new thread. Embedded layouts (Bot desk, groups, Activity) do not get it.
@MainActor
final class AgentAppNewThreadFABTests: XCTestCase {
    func test_standaloneAgentAppGetsTheNewThreadFABAndItCreatesAThread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rc-fab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.path)
        let workspace = WorkspaceID()
        let surface = AgentAppSurface(
            workspaceID: workspace,
            cwd: NSTemporaryDirectory(),
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo
        )
        let vm = surface.viewModel

        let fab = try XCTUnwrap(AgentAppView.newThreadFAB(layout: .standard, vm: vm))
        XCTAssertEqual(fab.identifier, "agent.thread.new.fab")
        XCTAssertNil(AgentAppView.newThreadFAB(
            layout: AgentAppViewLayout(showsThreadRail: false, showsHeader: false),
            vm: vm
        ), "the Bot desk passes its own +")

        let before = try ctx.threadRepo.list(workspaceId: workspace).count
        fab.action()
        XCTAssertEqual(try ctx.threadRepo.list(workspaceId: workspace).count, before + 1)
    }
}
