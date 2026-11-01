import AgentRuntime
import CoreModel
import Foundation
import Persistence
import XCTest
@testable import AppShell

@MainActor
final class BotContextColdAdmissionTests: XCTestCase {
    func testExactContextIsRejectedBeforeColdDesktopAdmissionForActiveAndRevokedPolicy() throws {
        for revoked in [false, true] {
            let path = try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"])
            let root = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("ColdAdmission-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let context = try AppContext(channel: .debug, dbPathOverride: root.appendingPathComponent("owned.sqlite").path,
                appSupportOverride: root.appendingPathComponent("support").path,
                privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: false,
                contextualSecretStore: InMemoryBotSecretStore())
            let router = AppCommandRouter(context: context)
            context.router = router
            SettingsStore(db: context.db).update { $0.botsControlPlaneEnabled = true }
            let bot = try context.botStore.create(name: "Cold admission", title: "Cold admission", description: "",
                soul: "", provider: .distill, model: "unused", desktopKind: .dockerDesktop)
            let host = context.liveActivityHostIdentity.serverId
            let grant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .general,
                actions: [.read, .send], expectedRevision: 0)
            let thread = AgentThread(title: "Pinned", provider: .distill, model: "unused")
            let conversation = BotConversation(botID: bot.id, title: "Pinned", linkedAgentThreadID: thread.id)
            let pin = try context.botStore.createContextualConversation(conversation, newThread: thread,
                hostID: host, context: .general, policyRevision: grant.policyRevision)
            if revoked {
                _ = try context.botStore.revokeContext(hostID: host, botID: bot.id, context: .general,
                    expectedRevision: grant.policyRevision)
            }
            let vm = BotsViewModel(context: context, router: router, loadImmediately: false, secretStore: InMemoryBotSecretStore())
            vm.computerGuestService = nil
            // The unmounted view model has no selected revision; retain the persisted Docker kind.
            vm.desktopKindOverrideForTesting = .dockerDesktop
            let before = try context.botStore.listConversations(botID: bot.id)
            XCTAssertEqual(vm.guestLaunchState(for: bot.id), .idle)
            // Since 2026-10-23 a VM send is admitted here and its async preflight
            // checks Docker, so only the revoked pin is refused at this point.
            guard revoked else {
                XCTAssertNoThrow(try vm.enqueueHostMessage(botID: bot.id, text: "owned queued intent", conversationID: conversation.id))
                continue
            }
            XCTAssertThrowsError(try vm.enqueueHostMessage(botID: bot.id, text: "owned queued intent", conversationID: conversation.id)) { error in
                XCTAssertTrue(error.localizedDescription.contains("no longer authorized"), "\(error)")
            }
            XCTAssertEqual(try context.botStore.listConversations(botID: bot.id), before)
            XCTAssertTrue(try context.botStore.listQueuedFollowUps(botID: bot.id).isEmpty)
            XCTAssertTrue(try context.messageRepo.list(threadId: thread.id).isEmpty)
            XCTAssertEqual(try context.botStore.conversationContextPin(conversationID: conversation.id), pin)
        }
    }
}
