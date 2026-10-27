import XCTest
import SwiftUI
import CoreModel
import Persistence
@testable import AgentRuntime
@testable import Surfaces

@MainActor
final class AgentDistillAutoSendTests: XCTestCase {
    func test_disabledAutoPreservesDraftAndOpensSetupBeforeCreatingARun_thenSavedProfileRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("distill")
        let accountHome = home.appendingPathComponent("accounts/acct")
        try FileManager.default.createDirectory(at: accountHome, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"test-only"}}"#.utf8)
            .write(to: accountHome.appendingPathComponent("codex-auth.json"))
        var registry = DistillAccountRegistry(
            version: 1,
            accounts: [DistillAccountStatus(provider: .chatgpt, connected: true, id: "acct", legacy: false)],
            routing: DistillAutoRouting(enabled: false, options: [
                DistillAutoOption(id: "route", accountID: "acct", mainModel: "chatgpt/test")
            ])
        )
        let registryURL = home.appendingPathComponent("accounts.json")
        try JSONEncoder().encode(registry).write(to: registryURL)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path).run()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db), messageRepo: messages, threadRepo: threads,
            providers: [.distill: FakeProviderRunner(provider: .distill)]
        )
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: root.path,
                                  coordinator: coordinator, threadRepo: threads, messageRepo: messages)
        let auto = AgentModelDescriptor(id: "auto", label: "Auto", provider: .distill)
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .distill, models: [auto], binaryPath: "/usr/bin/true", authenticated: true,
            capabilitiesOverride: AgentProviderCapabilities(supportsDistillMainEffortAuto: true),
            modelDiscoverySource: .live
        )]
        vm.provider = .distill
        vm.model = "auto"
        vm.providerLaunchConfig = { _, _ in ("/usr/bin/true", ["DISTILL_HOME": home.path]) }
        let previousGuide = AgentAutoGuide.makeGuide
        AgentAutoGuide.makeGuide = { _ in AnyView(EmptyView()) }
        defer { AgentAutoGuide.makeGuide = previousGuide }
        vm.prompt = "Review the screenshot"
        let before = try Data(contentsOf: registryURL)

        await vm.send()

        XCTAssertTrue(vm.showingAutoRoutingSetup)
        XCTAssertEqual(vm.prompt, "Review the screenshot")
        XCTAssertNil(vm.currentRunId)
        XCTAssertTrue(try threads.list().isEmpty, "setup must happen before any failed thread or run is created")
        XCTAssertEqual(try Data(contentsOf: registryURL), before, "sending must never enable routing without the user's choice")

        registry.routing.enabled = true
        try JSONEncoder().encode(registry).write(to: registryURL, options: .atomic)
        vm.showingAutoRoutingSetup = false
        await vm.send()

        XCTAssertFalse(vm.showingAutoRoutingSetup)
        XCTAssertEqual(vm.prompt, "", vm.statusMessage)
        let thread = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertEqual(try messages.list(threadId: thread).filter { $0.role == .user }.map(\.content), ["Review the screenshot"])
        for _ in 0..<100 where coordinator.activeRunId(threadId: thread) != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
