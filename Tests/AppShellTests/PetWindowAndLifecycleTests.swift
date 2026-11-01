import AppKit
import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence
import SocketServer

@MainActor
final class PetWindowAndLifecycleTests: XCTestCase {
    private func database() throws -> SQLiteDB {
        let directory = NSTemporaryDirectory() + "RC2PetWindow-\(UUID().uuidString)"
        return try Bootstrap(channel: .debug, appSupportOverride: directory).run().1
    }

    private static func centeredDockFrame(for screen: NSScreen) -> CGRect {
        let width = min(640, screen.frame.width * 0.4)
        let height = min(80, screen.frame.height * 0.1)
        return CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.minY,
            width: width,
            height: height
        )
    }

    private static func useCenteredDockFixture(on controller: PetWindowController) {
        controller.dockFrameProviderForTests = { screen in
            Self.centeredDockFrame(for: screen)
        }
    }

    func test_panelAndPopoverUseSeparateAccessibleAllSpacesWindows() throws {
        let db = try database()
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let controller = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: db))
        )
        defer { controller.stop() }

        controller.show()
        let pet = try XCTUnwrap(controller.petPanelForTests)
        XCTAssertTrue(pet.isVisible)
        XCTAssertTrue(pet.styleMask.contains(.borderless))
        XCTAssertTrue(pet.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(pet.level, .floating)
        XCTAssertFalse(pet.isOpaque)
        XCTAssertFalse(pet.hasShadow)
        XCTAssertTrue(pet.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(pet.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(pet.collectionBehavior.contains(.stationary))
        XCTAssertTrue(pet.collectionBehavior.contains(.ignoresCycle))
        XCTAssertEqual(pet.identifier?.rawValue, "pet.window")

        controller.openPopoverForTests()
        let popover = try XCTUnwrap(controller.popoverPanelForTests)
        XCTAssertFalse(popover === pet, "The popover must not share the sprite window and clip it.")
        XCTAssertTrue(popover.isVisible)
        XCTAssertTrue(popover.canBecomeKey)
        XCTAssertTrue(popover.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(popover.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(popover.identifier?.rawValue, "pet.popover")
        if let screen = popover.screen ?? NSScreen.main {
            XCTAssertTrue(screen.visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(popover.frame))
        }

        controller.closePopover()
        XCTAssertFalse(popover.isVisible)
        XCTAssertTrue(pet.isVisible)
    }

    func test_bottomLeftPlacementUsesFreePhysicalCornerWithoutCoveringDock() throws {
        let db = try database()
        let model = PetViewModel(settings: AppSettings(
            petEnabled: true,
            petPosition: "bottomLeft"
        ))
        let controller = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: db))
        )
        Self.useCenteredDockFixture(on: controller)
        defer { controller.stop() }

        controller.show()
        let panel = try XCTUnwrap(controller.petPanelForTests)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        let placementFrame = PetScreenGeometry.petPlacementFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )

        XCTAssertGreaterThanOrEqual(panel.frame.minX, placementFrame.minX - 0.001)
        XCTAssertGreaterThanOrEqual(panel.frame.minY, placementFrame.minY - 0.001)
        XCTAssertEqual(panel.frame.minY, placementFrame.minY, accuracy: 0.001)
        XCTAssertLessThanOrEqual(panel.frame.maxX, placementFrame.maxX + 0.001)
        XCTAssertLessThanOrEqual(panel.frame.maxY, placementFrame.maxY + 0.001)
        XCTAssertFalse(panel.frame.intersects(Self.centeredDockFrame(for: screen)),
            "the pet must not sit under the Dock even when it shares the physical bottom")
    }

    func test_petPanelDoesNotReapplyAppKitSafeAreaWhenDraggedToPhysicalEdge() throws {
        let db = try database()
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let controller = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: db))
        )
        defer { controller.stop() }

        controller.show()
        let panel = try XCTUnwrap(controller.petPanelForTests)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        let proposed = CGRect(origin: screen.frame.origin, size: panel.frame.size)

        XCTAssertEqual(panel.constrainFrameRect(proposed, to: screen), proposed,
            "a borderless desktop pet must not inherit normal-window Dock/menu constraints")
    }

    func test_dragBeyondBottomLeftClampsAndPersistsPhysicalFreeEdge() throws {
        let db = try database()
        let placementStore = PetPlacementStore(repository: SettingsRepository(db: db))
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let controller = PetWindowController(model: model, placementStore: placementStore)
        Self.useCenteredDockFixture(on: controller)
        defer { controller.stop() }

        controller.show()
        let panel = try XCTUnwrap(controller.petPanelForTests)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        let placementFrame = PetScreenGeometry.petPlacementFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        let draggedBeyondEdge = CGRect(
            x: placementFrame.minX - 10,
            y: placementFrame.minY - 10,
            width: panel.frame.width,
            height: panel.frame.height
        )

        controller.finishDragForTests(frame: draggedBeyondEdge)

        XCTAssertGreaterThanOrEqual(panel.frame.minX, placementFrame.minX - 0.001)
        XCTAssertGreaterThanOrEqual(panel.frame.minY, placementFrame.minY - 0.001)
        XCTAssertFalse(panel.frame.intersects(Self.centeredDockFrame(for: screen)))
        XCTAssertEqual(
            try XCTUnwrap(placementStore.load()).position,
            PetPlacement.normalizedPosition(for: panel.frame, in: placementFrame),
            "relaunch must restore the resolved physical edge after the drag"
        )
    }

    func test_relaunchRestoresPetPlacementFromThePersistedStore() throws {
        // WHY: the Pet process can be relaunched independently of the host
        // session. Its last resolved physical placement must survive the
        // controller teardown so the next launch does not jump to a default
        // corner or overlap the Dock.
        let db = try database()
        let placementStore = PetPlacementStore(repository: SettingsRepository(db: db))
        let firstModel = PetViewModel(settings: AppSettings(
            petEnabled: true,
            petPosition: "free"
        ))
        let firstController = PetWindowController(model: firstModel, placementStore: placementStore)
        Self.useCenteredDockFixture(on: firstController)
        firstController.show()
        let firstPanel = try XCTUnwrap(firstController.petPanelForTests)
        let firstScreen = try XCTUnwrap(firstPanel.screen ?? NSScreen.main)
        let firstPlacement = PetScreenGeometry.petPlacementFrame(
            screenFrame: firstScreen.frame,
            visibleFrame: firstScreen.visibleFrame
        )
        let requestedFrame = CGRect(
            x: firstPlacement.minX + firstPlacement.width * 0.37,
            y: firstPlacement.minY + firstPlacement.height * 0.41,
            width: firstPanel.frame.width,
            height: firstPanel.frame.height
        )
        firstController.finishDragForTests(frame: requestedFrame)
        let persisted = try XCTUnwrap(placementStore.load())
        firstController.stop()

        let secondModel = PetViewModel(settings: AppSettings(
            petEnabled: true,
            petPosition: "free"
        ))
        let secondController = PetWindowController(model: secondModel, placementStore: placementStore)
        Self.useCenteredDockFixture(on: secondController)
        defer { secondController.stop() }
        secondController.show()
        let secondPanel = try XCTUnwrap(secondController.petPanelForTests)
        let secondScreen = try XCTUnwrap(secondPanel.screen ?? NSScreen.main)
        let secondPlacement = PetScreenGeometry.petPlacementFrame(
            screenFrame: secondScreen.frame,
            visibleFrame: secondScreen.visibleFrame
        )

        XCTAssertEqual(
            try XCTUnwrap(placementStore.load()).position,
            persisted.position,
            "relaunch must read the same normalized Pet position from SQLite"
        )
        let restored = PetPlacement.normalizedPosition(for: secondPanel.frame, in: secondPlacement)
        XCTAssertEqual(restored.x, persisted.position.x, accuracy: 0.001)
        XCTAssertEqual(restored.y, persisted.position.y, accuracy: 0.001)
    }

    func test_animationStateResizeKeepsVisualPanelOnChosenScreenEdges() throws {
        let db = try database()
        let atlas = try PetAtlas.bundled()
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        model.setFrame(try atlas.canonicalFrame(for: .idle))
        let controller = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: db))
        )
        Self.useCenteredDockFixture(on: controller)
        defer { controller.stop() }

        controller.show()
        let panel = try XCTUnwrap(controller.petPanelForTests)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        let placementFrame = PetScreenGeometry.petPlacementFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(
            PetPlacement.frame(
                size: panel.frame.size,
                normalizedPosition: PetNormalizedPosition(x: 0, y: 0),
                in: placementFrame
            ),
            display: false
        )

        let sleeping = try atlas.canonicalFrame(for: .sleeping)
        model.setFrame(sleeping)
        controller.animationFrameDidChange()

        XCTAssertEqual(panel.frame.minX, placementFrame.minX, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minY, placementFrame.minY, accuracy: 0.001)
        XCTAssertEqual(
            panel.frame.width,
            (CGFloat(sleeping.displayImage.width) * CGFloat(118.0 / 192.0) * 1.5).rounded(),
            accuracy: 0.001
        )
        XCTAssertEqual(
            panel.frame.height,
            (CGFloat(sleeping.displayImage.height) * CGFloat(118.0 / 192.0) * 1.5).rounded(),
            accuracy: 0.001
        )
    }

    func test_animationFrameDidChange_reusesCachedDockPlacementWithoutHitTesting() throws {
        // WHY: pose-size changes used to hit-test the Dock on every animation
        // frame. Placement is stable across sprite envelopes; cache it.
        let db = try database()
        let atlas = try PetAtlas.bundled()
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        model.setFrame(try atlas.canonicalFrame(for: .idle))
        let controller = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: db))
        )
        var providerCalls = 0
        controller.dockFrameProviderForTests = { screen in
            providerCalls += 1
            return Self.centeredDockFrame(for: screen)
        }
        defer { controller.stop() }

        controller.show()
        let panel = try XCTUnwrap(controller.petPanelForTests)
        XCTAssertTrue(panel.isVisible)
        let afterPlacement = controller.dockFrameProviderCallCountForTests
        XCTAssertGreaterThanOrEqual(afterPlacement, 1)
        XCTAssertEqual(providerCalls, afterPlacement)

        let idle = try atlas.canonicalFrame(for: .idle)
        let sleeping = try atlas.canonicalFrame(for: .sleeping)
        for index in 0..<50 {
            model.setFrame(index.isMultiple(of: 2) ? sleeping : idle)
            let frame = panel.frame
            panel.setFrame(
                CGRect(x: frame.minX, y: frame.minY, width: frame.width + 3, height: frame.height + 3),
                display: false
            )
            controller.animationFrameDidChange()
        }

        XCTAssertLessThanOrEqual(
            controller.dockFrameProviderCallCountForTests - afterPlacement,
            1,
            "pose-size changes must not hit-test the Dock on the animation-frame path"
        )
        XCTAssertLessThanOrEqual(providerCalls - afterPlacement, 1)

        let beforeInvalidate = controller.dockFrameProviderCallCountForTests
        controller.invalidateDockPlacementCacheForTests()
        let frame = panel.frame
        panel.setFrame(
            CGRect(x: frame.minX, y: frame.minY, width: frame.width + 3, height: frame.height + 3),
            display: false
        )
        controller.animationFrameDidChange()
        XCTAssertEqual(
            controller.dockFrameProviderCallCountForTests,
            beforeInvalidate + 1,
            "visibleFrame / cache invalidation must miss once and rebuild placement"
        )
        XCTAssertEqual(providerCalls, beforeInvalidate + 1)
    }

    func test_visualEnvelopePreservesEverySupportedPetScale() throws {
        let db = try database()
        let atlas = try PetAtlas.bundled()
        let frame = try atlas.canonicalFrame(for: .idle)
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        model.setFrame(frame)
        let controller = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: db))
        )
        defer { controller.stop() }
        controller.show()
        let panel = try XCTUnwrap(controller.petPanelForTests)
        let sourcePixelScale = CGFloat(118.0 / 192.0)

        for scale in [0.75, 1.0, 1.25, 1.5] {
            let settings = AppSettings(petEnabled: true, petSize: scale)
            model.apply(settings: settings)
            controller.applySettings(settings)

            XCTAssertEqual(
                panel.frame.width,
                (CGFloat(frame.displayImage.width) * sourcePixelScale * scale).rounded(),
                accuracy: 0.001
            )
            XCTAssertEqual(
                panel.frame.height,
                (CGFloat(frame.displayImage.height) * sourcePixelScale * scale).rounded(),
                accuracy: 0.001
            )
        }
    }

    func test_viewModelFormatsBadgeAndSeparatesNeedsYouFromCompleted() {
        // WHY: the badge sums needs-you and just-finished, but the spoken value stays needs-you only.
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let callback = PetAttentionItem(
            id: "callback-1",
            kind: .callback(.approval, isStale: false),
            title: "Approval required",
            detail: nil,
            createdAt: Date(timeIntervalSince1970: 2),
            route: .settings(.general),
            source: .notification(id: "callback-1")
        )
        let outcome = PetAttentionItem(
            id: "outcome-1",
            kind: .notification(.gitCompleted),
            title: "Git delivery completed",
            detail: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            route: .settings(.general),
            source: .notification(id: "outcome-1")
        )
        model.apply(snapshot: PetAttentionSnapshot(items: [callback, outcome]))
        XCTAssertNil(model.badgeText, "Pet attention rows do not classify Activity service counts.")
        model.apply(activityCounts: PetActivityCounts(running: 0, needsYou: 2, newResults: 1))

        XCTAssertEqual(model.badgeText, "3", "badge is needs-you plus just-finished results")
        XCTAssertEqual(model.accessibilityValue, "Activity: 0 running, 2 items need attention", "spoken count stays needs-you only")

        let many = (0..<100).map { index in
            PetAttentionItem(
                id: "row-\(index)",
                kind: .notification(.gitCompleted),
                title: "Git delivery completed",
                detail: nil,
                createdAt: Date(),
                route: .settings(.general),
                source: .notification(id: "row-\(index)")
            )
        }
        model.apply(snapshot: PetAttentionSnapshot(items: many))
        XCTAssertEqual(model.badgeText, "3", "Legacy item count must not replace service counts.")
        model.apply(activityCounts: PetActivityCounts(running: 0, needsYou: 100, newResults: 0))
        XCTAssertEqual(model.badgeText, "99+")
        model.apply(settings: AppSettings(petEnabled: true, petReadyCounterEnabled: false))
        XCTAssertNil(model.badgeText)
    }

    func test_viewModelCountsActiveThreadsWithoutLightingTheAttentionDot() {
        // WHY: the pet shows one indicator, a red dot for what needs you. Running
        // work alone stays in the Active list and accessibility value, never the dot.
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let threadA = AgentThreadID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        let threadB = AgentThreadID(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        let secretTitle = "Run rm -rf /Users/private token=secret-token"

        let projected = PetActiveThreadProjector.items(
            threadIDs: [threadA, threadA, threadB],
            now: Date(timeIntervalSince1970: 1_000)
        ) { id in
            (
                workspaceID: WorkspaceID(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!),
                workspaceName: "star",
                providerName: id == threadA ? "Codex" : "Claude",
                threadTitle: id == threadA ? "make title for agent run" : secretTitle,
                startedAt: id == threadA ? Date(timeIntervalSince1970: 880) : nil,
                lastUpdatePreview: nil as String?
            )
        }

        XCTAssertEqual(projected.count, 2, "Duplicate run IDs for one thread must count once.")
        XCTAssertEqual(projected.map(\.title), ["Agent run in progress", "Agent run in progress"])
        XCTAssertEqual(
            projected.map(\.detail),
            [
                "star - Codex - make title for agent run - 2m",
                "star - Claude - \(AgentThreadTitle.display(secretTitle))"
            ]
        )
        for item in projected {
            XCTAssertFalse(item.title.contains(secretTitle))
            XCTAssertFalse(item.detail?.contains("secret-token") == true)
            XCTAssertFalse(item.id.contains("secret"))
        }

        model.apply(activeThreads: projected)
        model.apply(activityCounts: PetActivityCounts(running: 2, needsYou: 0, newResults: 0))
        XCTAssertEqual(model.activeThreadCount, 2)
        XCTAssertNil(model.badgeText, "Running work alone must not light the red attention dot.")
        XCTAssertEqual(
            model.accessibilityValue,
            "Activity: 2 running, No items need attention"
        )
        XCTAssertFalse(model.isPopoverEmpty)

        model.apply(settings: AppSettings(petEnabled: true, petReadyCounterEnabled: false))
        XCTAssertEqual(
            model.activeThreadCount,
            2,
            "The Active list is independent of the ready-counter preference."
        )
        XCTAssertNil(model.badgeText)

        let attention = PetAttentionItem(
            id: "callback-1",
            kind: .callback(.approval, isStale: false),
            title: "Approval required",
            detail: nil,
            createdAt: Date(),
            route: .settings(.general),
            source: .notification(id: "callback-1")
        )
        model.apply(snapshot: PetAttentionSnapshot(items: [attention]))
        XCTAssertEqual(
            model.accessibilityValue,
            "Activity: 2 running, No items need attention"
        )

        model.apply(activeThreads: [])
        XCTAssertEqual(model.activeThreadCount, 0)
        XCTAssertEqual(model.accessibilityValue, "Activity: 2 running, No items need attention")
        XCTAssertFalse(model.isPopoverEmpty)

        model.apply(snapshot: PetAttentionSnapshot(items: []))
        XCTAssertTrue(model.isPopoverEmpty)
        XCTAssertEqual(model.accessibilityValue, "Activity: 2 running, No items need attention")
    }

    func test_activeThreadProjectorKeepsAuthoritativeMembershipWhenMetadataIsMissing() {
        let threadID = AgentThreadID(UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!)
        let items = PetActiveThreadProjector.items(threadIDs: [threadID]) { _ in nil }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].threadID, threadID)
        XCTAssertEqual(items[0].title, "Agent run in progress")
        XCTAssertNil(items[0].detail)
        if case .agentThread(let routedID, let workspaceID) = items[0].route {
            XCTAssertEqual(routedID, threadID)
            XCTAssertNil(workspaceID)
        } else {
            XCTFail("Active rows must route to their agent thread.")
        }
    }

    func test_placementStoreRoundTripsAndResetsNormalizedDisplayPosition() throws {
        let db = try database()
        let store = PetPlacementStore(repository: SettingsRepository(db: db))
        let placement = PetStoredPlacement(
            displayID: "display-2",
            position: PetNormalizedPosition(x: 0.25, y: 0.75)
        )

        store.save(placement)
        XCTAssertEqual(store.load(), placement)
        store.reset()
        XCTAssertNil(store.load())
    }

    func test_controllerRestoresAttentionSubscribesFromCurrentSequenceAndStopsCleanly() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetLifecycle-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        var thread = AgentThread(
            workspaceId: workspace.id,
            title: "private prompt",
            provider: .codex,
            model: "test",
            status: .completed,
            hasUnread: true
        )
        try context.threadRepo.upsert(thread)
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))

        let baselineSubscribers = EventBus.shared.subscriberCountForTests
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        XCTAssertEqual(controller.modelForTests.count, 1)
        XCTAssertFalse(controller.visualRuntimeIsLoadedForTests,
            "A disabled Pet must retain projection without decoding atlas assets or creating windows.")
        XCTAssertFalse(controller.togglePopoverFromKeyboard())
        XCTAssertEqual(EventBus.shared.subscriberCountForTests, baselineSubscribers + 1)

        EventBus.shared.publish(kind: .agentRunStarted, payload: .object([
            "run_id": .string(UUID().uuidString)
        ]))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(
            controller.modelForTests.animationState,
            .waiting,
            "Attention remains visible, but work pose requires an authoritative Active row."
        )
        XCTAssertFalse(controller.animationTimerIsRunningForTests, "Disabled pet must not own a repeating timer.")

        controller.stop()
        XCTAssertEqual(EventBus.shared.subscriberCountForTests, baselineSubscribers)
        XCTAssertFalse(controller.animationTimerIsRunningForTests)

        thread = try XCTUnwrap(context.threadRepo.get(id: thread.id))
        XCTAssertTrue(thread.hasUnread, "Runtime observation must not clear attention without a verified route.")
    }

    func test_controllerProjectsActiveThreadsWithWorkspaceProviderAndRedactedTitle() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetActiveThreads-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        let secretTitle = "Run rm -rf /Users/private Authorization: Bearer secret-token"
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: secretTitle,
            provider: .codex,
            model: "test",
            status: .running,
            hasUnread: false
        )
        try context.threadRepo.upsert(thread)
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))

        var previousHandlerInvocations = 0
        let previous = context.coordinator.onActiveRunProjectionChanged
        context.coordinator.onActiveRunProjectionChanged = { projection, cause in
            previous?(projection, cause)
            previousHandlerInvocations += 1
        }

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }

        XCTAssertEqual(controller.modelForTests.activeThreadCount, 0)

        let runID = AgentRunID()
        let projection = ActiveRunProjection(runs: [
            .init(threadId: thread.id, runId: runID),
            .init(threadId: thread.id, runId: AgentRunID())
        ])
        context.coordinator.onActiveRunProjectionChanged?(projection, .started)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(
            previousHandlerInvocations,
            1,
            "Pet must chain the existing ActiveRunProjection observer, not replace it."
        )
        XCTAssertEqual(
            controller.modelForTests.activeThreadCount,
            1,
            "Multiple run IDs for one thread still count as one active thread."
        )
        XCTAssertNil(
            controller.modelForTests.badgeText,
            "Red attention dot remains gated by petReadyCounterEnabled and independent of active runs."
        )
        let row = try XCTUnwrap(controller.modelForTests.activeThreads.first)
        XCTAssertEqual(row.title, "Agent run in progress")
        // Display truncation + redaction keep credentials out of the always-on-top row.
        XCTAssertEqual(
            row.detail,
            "Pet - Codex - \(AgentThreadTitle.display(secretTitle))"
        )
        XCTAssertFalse(row.title.contains("rm -rf"))
        XCTAssertFalse(row.detail?.contains("secret-token") == true)
        XCTAssertFalse(controller.modelForTests.accessibilityValue.contains("secret-token"))

        context.coordinator.onActiveRunProjectionChanged?(
            ActiveRunProjection(runs: []),
            .finished(.completed)
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.modelForTests.activeThreadCount, 0)
    }

    func test_itemStartedProgressRepublishKeepsElapsedAndUpdatesLastUpdatePreview() async throws {
        // WHY: material agent.item.started must refresh Live Activity last-update
        // preview without wiping startedAt (elapsed in pet detail / LA statusLine).
        // A prior path called applyActiveThreadIDs with an empty startedByThread
        // map and dropped the "1m" suffix on every tool event.
        let directory = NSTemporaryDirectory() + "RC2PetLAProgress-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "teste o funcionamento do distill",
            provider: .claude,
            model: "opus",
            status: .running,
            hasUnread: false
        )
        try context.threadRepo.upsert(thread)
        let runID = AgentRunID()
        let startedAt = Date().addingTimeInterval(-90)
        try context.runRepo.upsert(AgentRun(
            id: runID,
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: startedAt
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }

        context.coordinator.onActiveRunProjectionChanged?(
            ActiveRunProjection(runs: [.init(threadId: thread.id, runId: runID)]),
            .started
        )
        try await Task.sleep(nanoseconds: 40_000_000)

        let before = try XCTUnwrap(controller.modelForTests.activeThreads.first)
        XCTAssertNil(before.lastUpdatePreview)
        XCTAssertTrue(
            before.detail?.contains("1m") == true,
            "projection with runRepo startedAt must embed elapsed; got \(before.detail ?? "nil")"
        )
        let detailBefore = before.detail

        EventBus.shared.publish(kind: .agentItemStarted, payload: .object([
            "thread_id": .string(thread.id.value.uuidString),
            "item": .object([
                "id": .string("item-git"),
                "type": .string("commandExecution"),
                "summary": .string("git status"),
                "body": .string("git status --short")
            ])
        ]))
        try await Task.sleep(nanoseconds: 40_000_000)

        let after = try XCTUnwrap(controller.modelForTests.activeThreads.first)
        XCTAssertEqual(
            after.lastUpdatePreview,
            "Running: git status",
            "item.started must land lastUpdatePreview for single-active LA description"
        )
        XCTAssertEqual(
            after.detail,
            detailBefore,
            "progress republish must preserve startedAt-derived elapsed detail"
        )
        XCTAssertTrue(after.detail?.contains("1m") == true)
    }

    func test_itemStartedProgressRepublish_usesCachedChromeWithoutDurableLookup() async throws {
        // WHY: Live Activity item.started used to re-run N full threadRepo.get
        // plus bot list/link queries on MainActor. Chrome is already painted.
        let directory = NSTemporaryDirectory() + "RC2PetLAProgressCache-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "cached chrome title",
            provider: .claude,
            model: "opus",
            status: .running,
            hasUnread: false
        )
        try context.threadRepo.upsert(thread)
        let runID = AgentRunID()
        try context.runRepo.upsert(AgentRun(
            id: runID,
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date().addingTimeInterval(-90)
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }

        context.coordinator.onActiveRunProjectionChanged?(
            ActiveRunProjection(runs: [.init(threadId: thread.id, runId: runID)]),
            .started
        )
        try await Task.sleep(nanoseconds: 40_000_000)

        let before = try XCTUnwrap(controller.modelForTests.activeThreads.first)
        XCTAssertGreaterThan(
            controller.activeThreadDurableLookupCountForTesting,
            0,
            "first host projection must still read durable chrome"
        )
        let lookupsAfterProjection = controller.activeThreadDurableLookupCountForTesting
        let detailBefore = before.detail

        try context.db.execute("DELETE FROM agent_threads;")

        EventBus.shared.publish(kind: .agentItemStarted, payload: .object([
            "thread_id": .string(thread.id.value.uuidString),
            "item": .object([
                "id": .string("item-git"),
                "type": .string("commandExecution"),
                "summary": .string("git status"),
                "body": .string("git status --short")
            ])
        ]))
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertTrue(
            controller.progressRepublishUsedCachedChromeForTesting,
            "progress must reuse projected chrome instead of SQLite"
        )
        XCTAssertEqual(
            controller.activeThreadDurableLookupCountForTesting,
            lookupsAfterProjection,
            "item.started must not issue another durable thread get"
        )
        let after = try XCTUnwrap(controller.modelForTests.activeThreads.first)
        XCTAssertEqual(after.lastUpdatePreview, "Running: git status")
        XCTAssertEqual(after.detail, detailBefore)
        XCTAssertEqual(after.workspaceName, "elephant")
    }

    func test_firstProjection_usesListChromeWithoutDurableGet() throws {
        // WHY: the first ActiveRunProjection still walked N full threadRepo.get
        // plus botStore.list and N conversationLinked on MainActor.
        let directory = NSTemporaryDirectory() + "RC2PetFirstChrome-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        var threadIDs: [AgentThreadID] = []
        for index in 0..<8 {
            let thread = AgentThread(
                workspaceId: workspace.id,
                title: "proj-\(index)",
                provider: .codex,
                model: "gpt-5",
                status: .running
            )
            try context.threadRepo.upsert(thread)
            threadIDs.append(thread.id)
        }
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }

        let getsBefore = context.threadRepo.durableGetCountForTesting
        let chromeBefore = context.threadRepo.listChromeCallCountForTesting
        controller.applyActiveThreadIDsForTests(threadIDs)
        XCTAssertEqual(controller.modelForTests.activeThreads.count, 8)
        XCTAssertEqual(
            Set(controller.modelForTests.activeThreads.compactMap(\.detail)).count,
            8
        )
        XCTAssertTrue(
            controller.modelForTests.activeThreads.contains(where: { $0.detail?.contains("proj-0") == true })
        )
        XCTAssertEqual(
            context.threadRepo.durableGetCountForTesting,
            getsBefore,
            "first projection must use listChrome, not N full gets"
        )
        XCTAssertEqual(context.threadRepo.listChromeCallCountForTesting, chromeBefore + 1)
        XCTAssertEqual(controller.activeThreadDurableLookupCountForTesting, 8)
    }

    func test_itemCompletedBurst_doesNotRelistCachedActiveThreadChrome() async throws {
        // WHY: every agent.item.* used to listChrome the active set on MainActor.
        // Chrome is stable across item completions until the thread leaves or is renamed.
        let directory = NSTemporaryDirectory() + "RC2PetChromeCache-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        var threadIDs: [AgentThreadID] = []
        for index in 0..<2 {
            let thread = AgentThread(
                workspaceId: workspace.id,
                title: "cached-\(index)",
                provider: .codex,
                model: "gpt-5",
                status: .running
            )
            try context.threadRepo.upsert(thread)
            threadIDs.append(thread.id)
        }
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }

        controller.applyActiveThreadIDsForTests(threadIDs)
        let chromeAfterCache = context.threadRepo.listChromeCallCountForTesting
        let lookupsAfterCache = controller.activeThreadDurableLookupCountForTesting
        XCTAssertEqual(controller.modelForTests.activeThreads.count, 2)

        for index in 0..<100 {
            let threadID = threadIDs[index % threadIDs.count]
            EventBus.shared.publish(kind: .agentItemCompleted, payload: .object([
                "thread_id": .string(threadID.value.uuidString),
                "item_id": .string("item-\(index)")
            ]))
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertLessThanOrEqual(
            context.threadRepo.listChromeCallCountForTesting - chromeAfterCache,
            2,
            "cached chrome must not listChrome once per item.completed"
        )
        XCTAssertLessThanOrEqual(
            controller.activeThreadDurableLookupCountForTesting - lookupsAfterCache,
            2,
            "cached chrome must not re-count durable lookups once per item.completed"
        )
        XCTAssertNotEqual(
            context.threadRepo.listChromeCallCountForTesting - chromeAfterCache,
            100
        )
        XCTAssertNotEqual(
            controller.activeThreadDurableLookupCountForTesting - lookupsAfterCache,
            100
        )
    }

    func test_firstProjection_listChrome_fasterThanDurableGets() throws {
        let directory = NSTemporaryDirectory() + "RC2PetFirstChromeBench-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "bench", cwd: NSTemporaryDirectory())
        var threadIDs: [AgentThreadID] = []
        threadIDs.reserveCapacity(20)
        for index in 0..<20 {
            let thread = AgentThread(
                workspaceId: workspace.id,
                title: "bench-\(index)",
                provider: .codex,
                model: "gpt-5",
                status: .running
            )
            try context.threadRepo.upsert(thread)
            threadIDs.append(thread.id)
        }
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }

        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            controller.applyActiveThreadIDsForTests(threadIDs)
            for id in threadIDs { _ = try context.threadRepo.get(id: id) }
        }
        var chromeSamples: [Double] = []
        var getSamples: [Double] = []
        chromeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            chromeSamples.append(timeMs {
                for _ in 0..<iterations {
                    controller.applyActiveThreadIDsForTests(threadIDs)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    for id in threadIDs { _ = try context.threadRepo.get(id: id) }
                }
            })
        }
        let chromeMed = median(chromeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - chromeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] pet-first-projection listChrome_ms=%@ durable_get_ms=%@ improvement_pct=%.2f chrome=%@ get=%@",
            String(chromeMed), String(getMed), improvement,
            String(describing: chromeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "batched first projection must beat N durable gets by ≥5% (got \(improvement)%; chrome=\(chromeMed)ms get=\(getMed)ms)"
        )
        XCTAssertEqual(controller.modelForTests.activeThreads.count, 20)
    }

    func test_firstProjection_usesBatchedStartedAtWithoutDurableRunGet() throws {
        // WHY: first ActiveRunProjection compiled N full runRepo.get just to
        // read started_at for elapsed labels.
        let directory = NSTemporaryDirectory() + "RC2PetStartedAt-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "elapsed",
            provider: .claude,
            model: "opus",
            status: .running
        )
        try context.threadRepo.upsert(thread)
        let runID = AgentRunID()
        let startedAt = Date().addingTimeInterval(-90)
        try context.runRepo.upsert(AgentRun(
            id: runID,
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: startedAt
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }

        let getsBefore = context.runRepo.durableGetCountForTesting
        let batchBefore = context.runRepo.startedAtCallCountForTesting
        controller.applyActiveRunProjectionForTests(
            ActiveRunProjection(runs: [.init(threadId: thread.id, runId: runID)])
        )
        let row = try XCTUnwrap(controller.modelForTests.activeThreads.first)
        XCTAssertTrue(
            row.detail?.contains("1m") == true,
            "batched startedAt must still embed elapsed; got \(row.detail ?? "nil")"
        )
        XCTAssertEqual(
            context.runRepo.durableGetCountForTesting,
            getsBefore,
            "first projection must not compile a full run get for elapsed"
        )
        XCTAssertEqual(context.runRepo.startedAtCallCountForTesting, batchBefore + 1)
    }

    func test_startedAtBatch_fasterThanNDurableRunGets() throws {
        let directory = NSTemporaryDirectory() + "RC2PetStartedAtBench-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        _ = try router.createWorkspace(name: "bench", cwd: NSTemporaryDirectory())
        var runIDs: [AgentRunID] = []
        runIDs.reserveCapacity(20)
        let startedAt = Date().addingTimeInterval(-90)
        for index in 0..<20 {
            let thread = AgentThread(title: "run-\(index)", provider: .codex, model: "gpt-5")
            try context.threadRepo.upsert(thread)
            let run = AgentRun(
                threadId: thread.id,
                provider: .codex,
                model: "gpt-5",
                status: .running,
                startedAt: startedAt
            )
            try context.runRepo.upsert(run)
            runIDs.append(run.id)
        }
        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = try context.runRepo.startedAt(ids: runIDs)
            for id in runIDs { _ = try context.runRepo.get(id: id) }
        }
        var batchSamples: [Double] = []
        var getSamples: [Double] = []
        batchSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            batchSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try context.runRepo.startedAt(ids: runIDs)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    for id in runIDs { _ = try context.runRepo.get(id: id) }
                }
            })
        }
        let batchMed = median(batchSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - batchMed) / getMed * 100.0
        NSLog(
            "[perf-proof] run-started-at batch_ms=%@ durable_get_ms=%@ improvement_pct=%.2f batch=%@ get=%@",
            String(batchMed), String(getMed), improvement,
            String(describing: batchSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "batched startedAt must beat N durable run gets by ≥5% (got \(improvement)%; batch=\(batchMed)ms get=\(getMed)ms)"
        )
    }

    /// WHY: EventBus run start/finish used to full-get the 10-column run row
    /// (including error_message) just to emit started_at_ms / duration_ms.
    func test_runTimingProbe_fasterThanDurableGet() throws {
        let directory = NSTemporaryDirectory() + "RC2RunTimingProbe-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let thread = AgentThread(title: "timing", provider: .codex, model: "gpt-5")
        try context.threadRepo.upsert(thread)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let finishedAt = Date(timeIntervalSince1970: 1_700_000_012)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-5",
            status: .completed,
            startedAt: startedAt,
            finishedAt: finishedAt,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try context.runRepo.upsert(run)

        let getsBefore = context.runRepo.durableGetCountForTesting
        let probesBefore = context.runRepo.timingProbeCountForTesting
        let timing = try XCTUnwrap(context.runRepo.timing(of: run.id))
        XCTAssertEqual(timing.startedAt.timeIntervalSince1970, startedAt.timeIntervalSince1970, accuracy: 0.001)
        let probedFinished = try XCTUnwrap(timing.finishedAt)
        XCTAssertEqual(probedFinished.timeIntervalSince1970, finishedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(context.runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertEqual(context.runRepo.timingProbeCountForTesting, probesBefore + 1)

        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = try context.runRepo.timing(of: run.id)
            _ = try context.runRepo.get(id: run.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try context.runRepo.timing(of: run.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try context.runRepo.get(id: run.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] run-timing probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "run timing probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    func test_progressRepublish_cachedChrome_fasterThanDurableApply() throws {
        let directory = NSTemporaryDirectory() + "RC2PetLAProgressBench-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "bench", cwd: NSTemporaryDirectory())
        var threadIDs: [AgentThreadID] = []
        threadIDs.reserveCapacity(20)
        let startedAt = Date().addingTimeInterval(-90)
        for index in 0..<20 {
            let thread = AgentThread(
                workspaceId: workspace.id,
                title: "bench-\(index)",
                provider: .codex,
                model: "gpt-5",
                status: .running
            )
            try context.threadRepo.upsert(thread)
            try context.runRepo.upsert(AgentRun(
                threadId: thread.id,
                provider: .codex,
                model: "gpt-5",
                status: .running,
                startedAt: startedAt
            ))
            threadIDs.append(thread.id)
        }
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }

        controller.applyActiveThreadIDsForTests(threadIDs, startedByThread: Dictionary(
            uniqueKeysWithValues: threadIDs.map { ($0, startedAt) }
        ))
        XCTAssertEqual(controller.modelForTests.activeThreads.count, 20)

        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup {
            controller.republishActiveThreadsForLiveActivityForTests()
            controller.applyActiveThreadIDsForTests(threadIDs, startedByThread: [:])
        }

        var cacheSamples: [Double] = []
        var durableSamples: [Double] = []
        cacheSamples.reserveCapacity(samples)
        durableSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            cacheSamples.append(timeMs {
                for _ in 0..<iterations {
                    controller.republishActiveThreadsForLiveActivityForTests()
                }
            })
            durableSamples.append(timeMs {
                for _ in 0..<iterations {
                    controller.applyActiveThreadIDsForTests(threadIDs, startedByThread: [:])
                }
            })
        }
        let cacheMed = median(cacheSamples)
        let durableMed = median(durableSamples)
        let improvement = (durableMed - cacheMed) / durableMed * 100.0
        NSLog(
            "[perf-proof] pet-la-progress cache_ms=%@ durable_apply_ms=%@ improvement_pct=%.2f cache=%@ durable=%@",
            String(cacheMed), String(durableMed), improvement,
            String(describing: cacheSamples), String(describing: durableSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "cached Live Activity progress must beat durable apply by ≥5% (got \(improvement)%; cache=\(cacheMed)ms durable=\(durableMed)ms)"
        )
        XCTAssertTrue(controller.progressRepublishUsedCachedChromeForTesting)
    }

    func test_mergingStartedAtByThreadPreservesRetainedWhenIncomingEmpty() {
        let a = AgentThreadID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let b = AgentThreadID(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let merged = PetController.mergingStartedAtByThread(
            activeThreadIDs: [a],
            incoming: [:],
            retained: [a: t0, b: t1]
        )
        XCTAssertEqual(merged[a], t0, "empty incoming must keep retained startedAt for still-active threads")
        XCTAssertNil(merged[b], "inactive threads must leave the cache")

        let overridden = PetController.mergingStartedAtByThread(
            activeThreadIDs: [a],
            incoming: [a: t1],
            retained: [a: t0]
        )
        XCTAssertEqual(overridden[a], t1, "host projection startedAt wins when provided")
    }

    func test_controllerHydratesPersistentAttentionKindsBeforeRendering() throws {
        let directory = NSTemporaryDirectory() + "RC2PetHydration-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        let fileSurface = try router.createSurface(
            workspace: workspace.id,
            type: .browser,
            paneID: nil,
            title: "Files"
        )
        defer { try? router.closeSurface(workspace: workspace.id, surface: fileSurface.id) }
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "private prompt",
            provider: .codex,
            model: "test",
            status: .running
        )
        try context.threadRepo.upsert(thread)
        try context.providerPendingCallbackRepo.record(
            threadId: thread.id,
            request: AssistantPendingRequest(
                id: "approval-1",
                turnId: "turn-1",
                kind: .commandExecution,
                title: "private command",
                detail: "private detail",
                createdAtMs: 1_000
            )
        )
        try NotificationRepository(db: context.db).insert(AppNotification(
            id: "conflict-1",
            workspaceId: workspace.id,
            surfaceId: fileSurface.id,
            title: "private path",
            category: PetNotificationCategory.fileConflict.rawValue
        ))
        try NotificationRepository(db: context.db).insert(AppNotification(
            id: "server-1",
            title: "private listener error",
            category: PetNotificationCategory.serverListenerFailed.rawValue
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        XCTAssertEqual(controller.modelForTests.count, 3)
        XCTAssertEqual(
            controller.modelForTests.animationState,
            .approval,
            "A restored approval/file conflict must outrank generic waiting and reconnecting."
        )
    }

    func test_routerThreadReadEventRefreshesTheVisibleCounter() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetThreadRead-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "private prompt",
            provider: .codex,
            model: "test",
            status: .completed,
            hasUnread: true
        )
        try context.threadRepo.upsert(thread)
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()
        XCTAssertEqual(controller.modelForTests.count, 1)

        try router.markAgentThreadRead(thread: thread.id)
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(controller.modelForTests.count, 0)
    }

    func test_controllerCapturesCursorBeforeRefreshAndReplaysOnlyNewStartupBacklog() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetCursor-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))

        EventBus.shared.publish(kind: .gitPush, payload: .object([
            "workspace_id": .string(UUID().uuidString),
            "ok": .bool(false)
        ]))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.afterStartupCursorCapturedForTests = {
            EventBus.shared.publish(kind: .agentRunStarted, payload: .object([
                "run_id": .string(UUID().uuidString)
            ]))
        }

        controller.start()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(
            controller.modelForTests.count,
            0,
            "A first-start watermark must not project terminal history published before its cursor."
        )
        XCTAssertEqual(
            controller.modelForTests.animationState,
            .idle,
            "The post-cursor startup event must not expose work without an authoritative Active row, while pre-cursor terminal history stays excluded."
        )
    }

    func test_controllerProcessesConcurrentLiveEventsInSequenceOrder() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetOrderedEvents-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    EventBus.shared.publish(kind: .agentRunStarted, payload: .object([
                        "run_id": .string(UUID().uuidString)
                    ]))
                }
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(
            controller.handledEventOutOfOrderForTests,
            "The Pet reducer must observe the EventBus sequence monotonically under concurrent publication."
        )
        XCTAssertEqual(controller.handledEventCountForTests, 100,
            "Every concurrent meaningful event must reach the reducer exactly once.")
    }

    func test_highRateNoiseBurstIsPrefilteredBeforeMainActor() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetOutputPrefilter-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        for _ in 0..<250 {
            EventBus.shared.publish(kind: .surfaceOutput, payload: .object([:]))
            EventBus.shared.publish(kind: .agentItemDelta, payload: .object([:]))
            EventBus.shared.publish(kind: .agentItemProgress, payload: .object([:]))
            EventBus.shared.publish(kind: .agentAccountUsage, payload: .object([:]))
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            controller.handledEventCountForTests,
            0,
            "High-rate reducer noise must be discarded before dispatching work to MainActor."
        )
    }

    func test_providerRuntimeEventsArePrefilteredBeforeMainActor() async throws {
        // WHY: Codex/Grok runtime telemetry is ~30 Hz and never maps to a pet
        // domain event. It must die in the EventBus subscriber, not on MainActor.
        let directory = NSTemporaryDirectory() + "RC2PetRuntimePrefilter-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        XCTAssertTrue(PetController.isPrefilteredNoiseKind("agent.provider_runtime.event"))
        XCTAssertTrue(PetController.isPrefilteredNoiseKind("token_saver.digest"))
        XCTAssertTrue(PetController.isPrefilteredNoiseKind("agent.item.delta"))
        XCTAssertFalse(PetController.isPrefilteredNoiseKind("agent.item.completed"))

        for _ in 0..<100 {
            EventBus.shared.publish(kind: .agentProviderRuntimeEvent, payload: .object([
                "method": .string("session/update")
            ]))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            controller.handledEventCountForTests,
            0,
            "provider_runtime.event must be discarded before MainActor handle"
        )

        EventBus.shared.publish(kind: .agentItemCompleted, payload: .object([
            "thread_id": .string(UUID().uuidString),
            "item_id": .string("item-1")
        ]))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(
            controller.handledEventCountForTests,
            1,
            "a useful item.completed must still reach handle after the prefilter"
        )
    }

    func test_controllerReplaysPersistedTerminalBeyondRecentRingWithoutAnimatingIt() throws {
        let directory = NSTemporaryDirectory() + "RC2PetProjectionRecovery-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let baseline = EventBus.shared.currentSeq
        try context.settingsRepo.set(PetController.projectionWatermarkKey, String(baseline))
        let terminalPayload = JSONValue.object([
            "workspace_id": .string(UUID().uuidString),
            "ok": .bool(false)
        ])
        let terminalSequence = baseline + 1
        let terminalJSON = String(
            decoding: try JSONEncoder().encode(terminalPayload),
            as: UTF8.self
        )
        try context.eventLog.append(
            seq: terminalSequence,
            kind: "git.push",
            payloadJSON: terminalJSON
        )
        var noiseEvents: [EventBus.Event] = []
        for offset in 1...300 {
            let sequence = terminalSequence + Int64(offset)
            try context.eventLog.append(
                seq: sequence,
                kind: "agent.account.usage",
                payloadJSON: "{}"
            )
            noiseEvents.append(EventBus.Event(
                seq: sequence,
                kind: "agent.account.usage",
                payload: .object([:]),
                ts: Date().timeIntervalSince1970
            ))
        }
        let capturedSequence = terminalSequence + 300
        EventBus.shared.reloadFromPersistence(
            lastSeq: capturedSequence,
            recent: Array(noiseEvents.suffix(256))
        )

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        XCTAssertEqual(controller.modelForTests.count, 1)
        XCTAssertEqual(
            controller.modelForTests.animationState,
            .waiting,
            "Recovery projects durable attention without replaying an old failure animation."
        )
        XCTAssertEqual(
            try context.settingsRepo.get(PetController.projectionWatermarkKey),
            String(capturedSequence),
            "A successful paged scan advances through non-candidate rows after projecting every candidate."
        )
        XCTAssertEqual(
            try NotificationRepository(db: context.db).list(unreadOnly: true).map(\.id),
            ["pet.event.\(terminalSequence)"]
        )
    }

    func test_projectionRecoveryAdvancesAcrossPersistedNoiseWhenNoCandidateExists() throws {
        let directory = NSTemporaryDirectory() + "RC2PetProjectionNoise-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let baseline = EventBus.shared.currentSeq
        try context.settingsRepo.set(PetController.projectionWatermarkKey, String(baseline))
        let noiseSequence = baseline + 1
        try context.eventLog.append(
            seq: noiseSequence,
            kind: "agent.account.usage",
            payloadJSON: "{}"
        )
        EventBus.shared.reloadFromPersistence(lastSeq: noiseSequence, recent: [])

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        XCTAssertEqual(controller.modelForTests.count, 0)
        XCTAssertEqual(
            try context.settingsRepo.get(PetController.projectionWatermarkKey),
            String(noiseSequence)
        )
    }

    func test_projectionRecoveryFailureSurvivesInitialAttentionRefresh() throws {
        let directory = NSTemporaryDirectory() + "RC2PetProjectionFailure-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let baseline = EventBus.shared.currentSeq
        try context.settingsRepo.set(PetController.projectionWatermarkKey, String(baseline))
        let corruptSequence = baseline + 1
        try context.eventLog.append(
            seq: corruptSequence,
            kind: "git.push",
            payloadJSON: "{"
        )
        EventBus.shared.reloadFromPersistence(lastSeq: corruptSequence, recent: [])

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        XCTAssertEqual(controller.modelForTests.routeError, "A ready item could not be restored.")
        XCTAssertEqual(
            try context.settingsRepo.get(PetController.projectionWatermarkKey),
            String(baseline),
            "A failed candidate must remain behind the watermark for the next recovery attempt."
        )
    }

    func test_projectionRecoveryNeverRewindsWatermarkWhenDurableLogIsAhead() throws {
        let directory = NSTemporaryDirectory() + "RC2PetWatermarkAhead-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let capturedCursor = EventBus.shared.currentSeq
        let storedWatermark = capturedCursor + 20
        try context.settingsRepo.set(PetController.projectionWatermarkKey, String(storedWatermark))
        try context.eventLog.append(
            seq: capturedCursor + 50,
            kind: "git.push",
            payloadJSON: "{}"
        )

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        XCTAssertEqual(
            try context.settingsRepo.get(PetController.projectionWatermarkKey),
            String(storedWatermark),
            "A low in-memory cursor must not rewind durable projection state."
        )
        XCTAssertNotNil(controller.modelForTests.routeError)
    }

    func test_settingsRouteRemainsUnreadWhenExactSettingsOpenCannotBeVerified() throws {
        let directory = NSTemporaryDirectory() + "RC2PetSettingsRoute-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let repository = NotificationRepository(db: context.db)
        try repository.insert(AppNotification(
            id: "provider-update",
            title: "private provider error",
            category: PetNotificationCategory.providerUpdateFailed.rawValue
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true))
        var requestedRoute: PetSettingsRoute?
        let controller = try PetController(
            context: context,
            router: router,
            openSettings: { route in
                requestedRoute = route
                return false
            }
        )
        defer { controller.stop() }
        controller.start()

        let item = try XCTUnwrap(controller.modelForTests.items.first)
        controller.windowControllerForTests.onOpenItem?(item)

        XCTAssertEqual(requestedRoute, .providers)
        XCTAssertEqual(try repository.list(unreadOnly: true).map(\.id), ["provider-update"])
        XCTAssertNotNil(controller.modelForTests.routeError)
    }

    func test_successfulRouteDismissalKeepsVerifiedDestinationKey() throws {
        let directory = NSTemporaryDirectory() + "RC2PetRouteDismiss-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let repository = NotificationRepository(db: context.db)
        try repository.insert(AppNotification(
            id: "provider-update-success-route",
            title: "private provider error",
            category: PetNotificationCategory.providerUpdateFailed.rawValue
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true))
        let controller = try PetController(
            context: context,
            router: router,
            openSettings: { $0 == .providers }
        )
        defer { controller.stop() }
        controller.start()
        let previous = PetLifecycleRecordingKeyWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        controller.windowControllerForTests.keyWindowProviderForTests = { previous }
        controller.windowControllerForTests.openPopoverForTests()

        let item = try XCTUnwrap(controller.modelForTests.items.first)
        controller.windowControllerForTests.onOpenItem?(item)

        XCTAssertEqual(previous.restoreCount, 0)
        XCTAssertTrue(try repository.list(unreadOnly: true).isEmpty)
        XCTAssertFalse(controller.windowControllerForTests.isPopoverVisible)
    }

    /// WHY: viewing Activity must not mark results read or resolve attention as a side effect.
    func test_petDoesNotBulkMarkResultsSeenOrResolveAttention() throws {
        let directory = NSTemporaryDirectory() + "RC2PetMarkAllDismiss-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "private prompt",
            provider: .codex,
            model: "test",
            status: .completed,
            hasUnread: true
        )
        try context.threadRepo.upsert(thread)
        let repository = NotificationRepository(db: context.db)
        try repository.insert(AppNotification(
            id: "git-completed-mark-all",
            workspaceId: workspace.id,
            title: "private git path",
            category: PetNotificationCategory.gitCompleted.rawValue
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true))
        let controller = try PetController(
            context: context,
            router: router,
            openSettings: { _ in false }
        )
        defer { controller.stop() }
        controller.start()

        XCTAssertEqual(controller.modelForTests.count, 2)
        controller.windowControllerForTests.openPopoverForTests()
        XCTAssertTrue(controller.windowControllerForTests.isPopoverVisible)

        XCTAssertEqual(controller.modelForTests.count, 2)
        XCTAssertTrue(controller.windowControllerForTests.isPopoverVisible)
        XCTAssertTrue(try XCTUnwrap(context.threadRepo.get(id: thread.id)).hasUnread)
        XCTAssertEqual(try repository.list(unreadOnly: true).count, 1)
    }

    func test_noiseDoesNotPostponeIdleSleep() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetNoiseIdle-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReduceMotion: true))
        let controller = try PetController(
            context: context,
            router: router,
            openSettings: { _ in false },
            idleTimeoutNanoseconds: 15_000_000
        )
        defer { controller.stop() }
        controller.start()

        for _ in 0..<5 {
            EventBus.shared.publish(kind: .agentAccountUsage, payload: .object([:]))
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(
            controller.modelForTests.animationState,
            .sleeping,
            "Ignored usage noise must not keep an otherwise idle pet awake."
        )
    }

    func test_controllerSleepsAfterIdleAndPetInteractionWakesIt() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetIdle-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReduceMotion: true))
        let controller = try PetController(
            context: context,
            router: router,
            openSettings: { _ in false },
            idleTimeoutNanoseconds: 10_000_000
        )
        defer { controller.stop() }

        controller.start()
        controller.windowControllerForTests.dockFrameProviderForTests = { screen in
            Self.centeredDockFrame(for: screen)
        }
        // start() already cached the real Dock; place against the fixture Dock.
        controller.windowControllerForTests.invalidateDockPlacementCacheForTests()
        let panel = try XCTUnwrap(controller.windowControllerForTests.petPanelForTests)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        let placementFrame = PetScreenGeometry.petPlacementFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(
            PetPlacement.frame(
                size: panel.frame.size,
                normalizedPosition: PetNormalizedPosition(x: 0, y: 0),
                in: placementFrame
            ),
            display: false
        )
        let idleSize = panel.frame.size
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.modelForTests.animationState, .sleeping)
        XCTAssertNotEqual(panel.frame.size, idleSize,
            "the controller frame callback must resize the window to the sleeping visual envelope")
        XCTAssertEqual(panel.frame.minX, placementFrame.minX, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minY, placementFrame.minY, accuracy: 0.001)

        controller.windowControllerForTests.onInteraction?()
        XCTAssertEqual(controller.modelForTests.animationState, .idle)
        XCTAssertEqual(panel.frame.width, idleSize.width, accuracy: 0.001)
        XCTAssertEqual(panel.frame.height, idleSize.height, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minX, placementFrame.minX, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minY, placementFrame.minY, accuracy: 0.001)

        XCTAssertTrue(controller.togglePopoverFromKeyboard())
        XCTAssertTrue(controller.windowControllerForTests.isVisible)
        XCTAssertTrue(controller.windowControllerForTests.isPopoverVisible)
        XCTAssertTrue(controller.togglePopoverFromKeyboard())
        XCTAssertFalse(controller.windowControllerForTests.isPopoverVisible)
    }

    func test_systemWakeClearsSleepAndRearmsIdleDeadline() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetWakeIdle-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReduceMotion: true))
        let controller = try PetController(
            context: context,
            router: router,
            openSettings: { _ in false },
            idleTimeoutNanoseconds: 10_000_000
        )
        defer { controller.stop() }
        controller.start()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.modelForTests.animationState, .sleeping)

        controller.handleSystemWake()
        XCTAssertEqual(controller.modelForTests.animationState, .idle)
        for _ in 0..<40 {
            if controller.modelForTests.animationState == .sleeping { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(controller.modelForTests.animationState, .sleeping,
            "Wake must rearm the idle deadline instead of leaving the Pet permanently awake.")
    }
}

@MainActor
private final class PetLifecycleRecordingKeyWindow: NSWindow {
    private(set) var restoreCount = 0
    override var isVisible: Bool { true }
    override var canBecomeKey: Bool { true }
    override func makeKeyAndOrderFront(_ sender: Any?) { restoreCount += 1 }
}
