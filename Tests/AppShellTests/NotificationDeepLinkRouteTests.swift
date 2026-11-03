import XCTest
@testable import AppShell
@testable import Surfaces
import CoreModel

/// Verifies the pure notification payload -> RouteIntent mapper.
///
/// WHY these tests matter:
/// - Tapping a notification is the only entry point for deep-linking into a
///   specific agent thread from outside the app. If the mapper misreads the
///   payload the tap silently does nothing; these tests catch that regression
///   without requiring any AppKit/UI infrastructure.
/// - The mapper is the boundary between the opaque `[AnyHashable: Any]`
///   UNNotification payload and typed domain IDs. Type safety ends here; the
///   tests enforce the contract so callers can trust the output.
@MainActor
final class NotificationDeepLinkRouteTests: XCTestCase {

    private func closeAndUnregisterAgentSurfaces(workspace: WorkspaceID) {
        for surface in SurfaceRegistry.shared.all() {
            guard let agent = surface as? AgentAppSurface,
                  agent.viewModel.workspaceID == workspace else { continue }
            agent.close()
            SurfaceRegistry.shared.unregister(agent.descriptor.id)
        }
    }

    // MARK: - Valid payload

    func testValidThreadIdOnlyProducesIntentWithNilWorkspace() {
        let threadUUID = UUID()
        let intent = AppDelegate.routeFromNotification(
            userInfo: ["threadId": threadUUID.uuidString]
        )

        XCTAssertNotNil(intent,
            "a payload with a valid threadId UUID must always produce an intent — missing workspaceId is not a failure")
        XCTAssertEqual(intent?.threadId?.value, threadUUID,
            "intent threadId must match the exact UUID from the payload")
        XCTAssertNil(intent?.workspaceId,
            "when workspaceId is absent from the payload, intent.workspaceId must be nil so the router uses thread lookup")
    }

    func testValidThreadIdAndWorkspaceIdProducesBothFields() {
        let threadUUID = UUID()
        let workspaceUUID = UUID()
        let intent = AppDelegate.routeFromNotification(
            userInfo: [
                "threadId": threadUUID.uuidString,
                "workspaceId": workspaceUUID.uuidString
            ]
        )

        XCTAssertEqual(intent?.threadId?.value, threadUUID,
            "intent must carry the exact thread UUID from the payload")
        XCTAssertEqual(intent?.workspaceId?.value, workspaceUUID,
            "intent must carry the exact workspace UUID so the router can pre-select the correct workspace tab")
    }

    func testFinalMessageIdIsPreservedAsExactRouteTarget() {
        let threadID = UUID()
        let messageID = UUID()
        let intent = AppDelegate.routeFromNotification(userInfo: [
            "threadId": threadID.uuidString,
            "finalMessageId": messageID.uuidString
        ])
        XCTAssertEqual(intent?.threadId?.value, threadID)
        XCTAssertEqual(intent?.finalMessageId?.value, messageID)
        XCTAssertFalse(intent?.opensActivity ?? true)
    }

    func testGroupedActivityRouteDoesNotCarryFirstThreadOrMessage() {
        let intent = AppDelegate.routeFromNotification(userInfo: [
            "activityDestination": "true",
            "finalMessageId": UUID().uuidString
        ])
        XCTAssertNotNil(intent)
        XCTAssertTrue(intent?.opensActivity ?? false)
        XCTAssertNil(intent?.threadId)
    }

    // MARK: - Missing threadId

    func testMissingThreadIdReturnsNil() {
        let intent = AppDelegate.routeFromNotification(userInfo: [:])

        XCTAssertNil(intent,
            "a payload without threadId must return nil — there is no thread to navigate to")
    }

    func testEmptyPayloadReturnsNil() {
        let intent = AppDelegate.routeFromNotification(userInfo: [:])

        XCTAssertNil(intent, "empty userInfo must return nil")
    }

    // MARK: - Malformed threadId

    func testMalformedThreadIdStringReturnsNil() {
        let intent = AppDelegate.routeFromNotification(
            userInfo: ["threadId": "not-a-uuid"]
        )

        XCTAssertNil(intent,
            "a non-UUID threadId must return nil — routing with a corrupt ID would navigate to the wrong thread")
    }

    func testEmptyThreadIdStringReturnsNil() {
        let intent = AppDelegate.routeFromNotification(
            userInfo: ["threadId": ""]
        )

        XCTAssertNil(intent, "empty threadId string must return nil")
    }

    func testNumericThreadIdReturnsNil() {
        let intent = AppDelegate.routeFromNotification(
            userInfo: ["threadId": "12345"]
        )

        XCTAssertNil(intent, "a numeric string in threadId must return nil")
    }

    // MARK: - Malformed workspaceId (threadId still valid)

    func testMalformedWorkspaceIdYieldsNilWorkspaceButValidThread() {
        let threadUUID = UUID()
        let intent = AppDelegate.routeFromNotification(
            userInfo: [
                "threadId": threadUUID.uuidString,
                "workspaceId": "bad-workspace-id"
            ]
        )

        XCTAssertNotNil(intent,
            "a valid threadId with a malformed workspaceId must still produce an intent — the thread can be found without a workspace hint")
        XCTAssertEqual(intent?.threadId?.value, threadUUID)
        XCTAssertNil(intent?.workspaceId,
            "a malformed workspaceId must fall back to nil so the router uses thread-based lookup rather than crashing")
    }

    func testEmptyWorkspaceIdYieldsNilWorkspaceButValidThread() {
        let threadUUID = UUID()
        let intent = AppDelegate.routeFromNotification(
            userInfo: [
                "threadId": threadUUID.uuidString,
                "workspaceId": ""
            ]
        )

        XCTAssertNotNil(intent)
        XCTAssertNil(intent?.workspaceId)
    }

    // MARK: - Equatability (guards against silent struct mutation)

    func testSamePayloadProducesEqualIntents() {
        let threadUUID = UUID()
        let workspaceUUID = UUID()
        let payload: [String: String] = [
            "threadId": threadUUID.uuidString,
            "workspaceId": workspaceUUID.uuidString
        ]

        let a = AppDelegate.routeFromNotification(userInfo: payload)
        let b = AppDelegate.routeFromNotification(userInfo: payload)

        XCTAssertEqual(a, b,
            "the mapper must be pure and deterministic — same payload must always produce equal intents")
    }

    func testDifferentThreadIdsProduceDifferentIntents() {
        let intent1 = AppDelegate.routeFromNotification(userInfo: ["threadId": UUID().uuidString])
        let intent2 = AppDelegate.routeFromNotification(userInfo: ["threadId": UUID().uuidString])

        XCTAssertNotEqual(intent1, intent2,
            "intents for different thread UUIDs must not be equal — equality is required for stable navigation deduplication")
    }

    func test_openNotificationRoute_usesCanonicalExactThreadRoute_withoutMarkingRead() throws {
        let dir = NSTemporaryDirectory() + "RC2NotificationRoute-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        router.destinationWindowIsKeyForTests = { $0 === controller.window }
        controller.window.isReleasedWhenClosed = false
        let delegate = AppDelegate(channel: .debug, appSupportOverride: dir)
        delegate.context = context
        delegate.router = router
        delegate.windowController = controller
        defer { controller.window.close() }

        let workspace = try router.createWorkspace(name: "NOTIFICATION", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "finished",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.hasUnread = true
        try context.threadRepo.upsert(thread)

        let routed = try delegate.openNotificationRoute(
            NotificationRouteIntent(threadId: thread.id, workspaceId: workspace.id)
        )
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(routed.id) as? AgentAppSurface)

        XCTAssertEqual(surface.viewModel.selectedThreadId, thread.id,
            "notification taps must use the same exact-surface binding route as the pet")
        XCTAssertTrue(try XCTUnwrap(context.threadRepo.get(id: thread.id)).hasUnread,
            "routing must not mark a thread read before the user views it")
    }

    func test_openNotificationUserInfo_routesAuthorizedPinnedWorkspaceAndGeneralToExactBotDesk() throws {
        let dir = NSTemporaryDirectory() + "RC2NotificationBotRoute-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        controller.window.isReleasedWhenClosed = false
        defer { controller.window.close() }
        let delegate = AppDelegate(channel: .debug, appSupportOverride: dir)
        delegate.context = context
        delegate.router = router
        delegate.windowController = controller

        let workspace = try router.createWorkspace(name: "Pinned target", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        let bot = try context.botStore.create(name: "Pinned bot", title: "Pinned bot", description: "", provider: .distill)
        let host = context.liveActivityHostIdentity.serverId

        func createPinnedConversation(_ pinContext: BotContext, workspaceID: WorkspaceID?) throws -> (AgentThread, BotConversation) {
            let grant = try context.botStore.grantContext(
                hostID: host, botID: bot.id, context: pinContext, actions: [.read], expectedRevision: nil
            )
            let thread = AgentThread(workspaceId: workspaceID, title: "Pinned notification", provider: .distill, model: "test")
            let conversation = BotConversation(botID: bot.id, title: "Pinned notification", linkedAgentThreadID: thread.id)
            try context.botStore.createContextualConversation(
                conversation, newThread: thread, hostID: host, context: pinContext, policyRevision: grant.policyRevision
            )
            return (thread, conversation)
        }

        let pinned = try createPinnedConversation(.workspace(workspace.id), workspaceID: workspace.id)
        delegate.openNotificationUserInfo(["threadId": pinned.0.id.value.uuidString])
        XCTAssertEqual(router.botsViewModel?.selectedBotID, bot.id)
        XCTAssertEqual(router.botsViewModel?.selectedConversation?.id, pinned.1.id)
        XCTAssertEqual(router.botsViewModel?.selectedConversation?.linkedAgentThreadID, pinned.0.id)

        let general = try createPinnedConversation(.general, workspaceID: nil)
        let messageID = AgentMessageID()
        delegate.openNotificationUserInfo([
            "threadId": general.0.id.value.uuidString,
            "finalMessageId": messageID.value.uuidString
        ])
        XCTAssertEqual(router.botsViewModel?.selectedBotID, bot.id)
        XCTAssertEqual(router.botsViewModel?.screen, .desk)
        XCTAssertEqual(router.botsViewModel?.selectedConversation?.id, general.1.id)
        XCTAssertEqual(router.botsViewModel?.selectedConversation?.linkedAgentThreadID, general.0.id)
    }

    func test_openNotificationUserInfo_refusesRevokedAndForeignPinsWithoutSelectingOtherDestination() throws {
        let dir = NSTemporaryDirectory() + "RC2NotificationDeniedBotRoute-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        controller.window.isReleasedWhenClosed = false
        defer { controller.window.close() }
        let delegate = AppDelegate(channel: .debug, appSupportOverride: dir)
        delegate.context = context
        delegate.router = router
        delegate.windowController = controller
        let workspace = try router.createWorkspace(name: "Alternate", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        let bot = try context.botStore.create(name: "Denied bot", title: "Denied bot", description: "", provider: .distill)
        let host = context.liveActivityHostIdentity.serverId

        func createPinnedConversation(_ pinHost: String, context pinContext: BotContext, workspaceID: WorkspaceID?) throws -> (AgentThread, BotConversation, Int64) {
            let grant = try context.botStore.grantContext(
                hostID: pinHost, botID: bot.id, context: pinContext, actions: [.read], expectedRevision: nil
            )
            let thread = AgentThread(workspaceId: workspaceID, title: "Denied notification", provider: .distill, model: "test")
            let conversation = BotConversation(botID: bot.id, title: "Denied notification", linkedAgentThreadID: thread.id)
            try context.botStore.createContextualConversation(
                conversation, newThread: thread, hostID: pinHost, context: pinContext, policyRevision: grant.policyRevision
            )
            return (thread, conversation, grant.policyRevision)
        }

        let revoked = try createPinnedConversation(host, context: .workspace(workspace.id), workspaceID: workspace.id)
        _ = try context.botStore.revokeContext(hostID: host, botID: bot.id, context: .workspace(workspace.id), expectedRevision: revoked.2)
        let foreign = try createPinnedConversation("foreign-host", context: .general, workspaceID: nil)
        delegate.openNotificationUserInfo(["threadId": revoked.0.id.value.uuidString])
        XCTAssertNil(router.botsViewModel?.selectedBotID)
        XCTAssertNil(router.botsViewModel?.selectedConversation)
        XCTAssertFalse(controller.window.isVisible)
        delegate.openNotificationUserInfo(["threadId": foreign.0.id.value.uuidString])
        XCTAssertNil(router.botsViewModel?.selectedBotID)
        XCTAssertNil(router.botsViewModel?.selectedConversation)
        XCTAssertFalse(controller.window.isVisible)
    }

    /// Only a not-found reveal (transcript still hydrating) is retried, and only twice.
    func test_notificationRevealRetry_onlyNotFoundRetriesWithBoundedDelays() {
        let id = AgentMessageID()
        XCTAssertEqual(AppDelegate.notificationRevealRetryDelay(after: AgentAppSurfaceMessageRevealError.messageNotFound(id), attempt: 0), 0.25)
        XCTAssertEqual(AppDelegate.notificationRevealRetryDelay(after: AgentAppSurfaceMessageRevealError.messageNotFound(id), attempt: 1), 0.75)
        XCTAssertNil(AppDelegate.notificationRevealRetryDelay(after: AgentAppSurfaceMessageRevealError.messageNotFound(id), attempt: 2))
        XCTAssertNil(AppDelegate.notificationRevealRetryDelay(after: AgentAppSurfaceMessageRevealError.selectionChanged, attempt: 0))
    }
}
