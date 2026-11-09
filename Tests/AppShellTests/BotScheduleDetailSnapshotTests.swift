import AppKit
import CoreModel
import Persistence
import SwiftUI
import XCTest
@testable import AppShell

/// WHY: Bot schedules must open a Run History page (not the editor), show a real Next run, and
/// show a Last run that opens the run's conversation. Set `REMOTE_CODE_BOT_SCHEDULE_ARTIFACT_DIR` to keep PNGs.
@MainActor
final class BotScheduleDetailSnapshotTests: XCTestCase {
    func test_cardOpensDetailNotEditor_andShowsNextAndLastRun() throws {
        let directory = NSTemporaryDirectory() + "bot-schedule-detail-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Check overnight failures"
        vm.routineScheduleNote = "Daily 07:00"
        vm.saveRoutine()
        let routineID = try XCTUnwrap(vm.routines.first?.definition.id)
        vm.setRoutineEnabled(id: routineID, enabled: true)
        vm.setAutonomyActive(true)
        vm.openScheduleTasks()
        let item = try XCTUnwrap(vm.scheduleTaskItems.first)
        let next = item.nextRunLabel(isAutonomyActive: true)
        XCTAssertNotEqual(next, "While MacCode is open")
        XCTAssertNotEqual(next, "—", "a daily schedule always has a next run")

        let authority = try XCTUnwrap(router.botRoutineAuthority)
        let routine = try XCTUnwrap(context.botStore.listRoutines(botID: bot.id).first)
        let conversation = BotConversation(botID: bot.id, title: "Morning scan")
        try context.botStore.upsertConversation(conversation)
        authority.recordManualRoutineRun(
            routine, runID: UUID().uuidString.lowercased(),
            conversationID: conversation.id.value.uuidString.lowercased()
        )
        vm.reloadRoutineRunSummaries()
        let last = try XCTUnwrap(vm.routineRunSummaries[routineID]?.last)
        XCTAssertEqual(last.conversationID, conversation.id, "Last run must point at the run's conversation")

        XCTAssertNil(vm.scheduleTaskDraft)
        vm.openScheduleTaskDetail(item)
        XCTAssertNil(vm.scheduleTaskDraft, "opening a card must not open the editor")
        XCTAssertEqual(vm.scheduleTaskDetailItem?.id, routineID)
        XCTAssertEqual(vm.scheduleDetailRuns.count, 1)
        XCTAssertTrue(vm.scheduleDetailRuns[0].canOpen)

        let tasks = ScheduledTasksViewModel(context: context, router: router, loadImmediately: false)
        let size = CGSize(width: 1_100, height: 760)
        let hosting = NSHostingView(rootView: ScheduledTasksRootView(vm: tasks, botsVM: vm).frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        func shot(_ name: String) throws -> NSBitmapImageRep {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let dir = ProcessInfo.processInfo.environment["REMOTE_CODE_BOT_SCHEDULE_ARTIFACT_DIR"] {
                let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("\(name).png")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
            }
            return bitmap
        }
        let detail = try shot("detail")
        vm.closeScheduleTaskDetail()
        let overview = try shot("overview")
        XCTAssertNotEqual(detail.representation(using: .png, properties: [:]), overview.representation(using: .png, properties: [:]))
    }
}
