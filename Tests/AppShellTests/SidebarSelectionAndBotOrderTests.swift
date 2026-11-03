import XCTest
@testable import AppShell
@testable import CoreModel
import Persistence
import RemoteCodeTreaty

@MainActor
final class SidebarSelectionAndBotOrderTests: XCTestCase {
    private let a = BotID(UUID()), b = BotID(UUID()), c = BotID(UUID())
    private let ws = WorkspaceID(UUID())

    func test_firstMessageTransfersSelectionOnlyForTheCurrentBotDraft() {
        let draft = AgentThreadID(UUID())
        let other = AgentThreadID(UUID())
        XCTAssertFalse(SidebarViewModel.shouldActivateBotConversation(draft: draft, selected: draft, hasMessages: false))
        XCTAssertTrue(SidebarViewModel.shouldActivateBotConversation(draft: draft, selected: draft, hasMessages: true))
        XCTAssertFalse(SidebarViewModel.shouldActivateBotConversation(draft: draft, selected: other, hasMessages: true), "messages from another conversation must not clear the draft selection")
        XCTAssertFalse(SidebarViewModel.shouldActivateBotConversation(draft: nil, selected: draft, hasMessages: true))
    }

    func test_expandedConversationWorkspaces_roundTripsAndSkipsInvalidIDs() {
        // WHY: expanded state must survive restart; a corrupt stored entry must not drop the valid ones.
        let other = WorkspaceID(UUID())
        let raw = SidebarViewModel.encodeExpandedConversationWorkspaces([ws, other])
        XCTAssertEqual(SidebarViewModel.decodeExpandedConversationWorkspaces(raw), [ws, other])
        XCTAssertEqual(SidebarViewModel.decodeExpandedConversationWorkspaces(raw + ["not-a-uuid"]), [ws, other])
        XCTAssertEqual(SidebarViewModel.decodeExpandedConversationWorkspaces(nil), [])
    }

    func test_deskSelection_onlyWhenBotsDeskIsActiveSurface() {
        // WHY: a stale selectedBotID must not highlight a row while a workspace owns the content.
        XCTAssertNil(SidebarViewModel.deskSelection(isBotsSelected: false, screen: .desk, botID: a, context: nil, threadID: nil))
        XCTAssertNil(SidebarViewModel.deskSelection(isBotsSelected: true, screen: .studio, botID: a, context: nil, threadID: nil))
        XCTAssertNil(SidebarViewModel.deskSelection(isBotsSelected: true, screen: .desk, botID: nil, context: nil, threadID: nil))
        XCTAssertEqual(SidebarViewModel.deskSelection(isBotsSelected: true, screen: .desk, botID: a, context: nil, threadID: nil)?.botID, a)
    }

    func test_workspaceBotRowSelected_onlyForItsOwnContext() {
        // WHY: "Developer" under elephant must light up, not the same bot under another workspace or General.
        let sel = SidebarViewModel.DeskSelection(botID: a, context: .workspace(ws), threadID: nil)
        XCTAssertTrue(SidebarViewModel.isBotConversationSelected(botID: a, context: .workspace(ws), in: sel))
        XCTAssertFalse(SidebarViewModel.isBotConversationSelected(botID: a, context: .workspace(WorkspaceID(UUID())), in: sel))
        XCTAssertFalse(SidebarViewModel.isBotConversationSelected(botID: a, context: .general, in: sel))
        XCTAssertFalse(SidebarViewModel.isGeneralBotSelected(a, in: sel))
        XCTAssertFalse(SidebarViewModel.isBotConversationSelected(botID: b, context: .workspace(ws), in: sel))
    }

    func test_generalBotRowSelected_forGeneralOrLegacyChat() {
        XCTAssertTrue(SidebarViewModel.isGeneralBotSelected(a, in: .init(botID: a, context: .general, threadID: nil)))
        XCTAssertTrue(SidebarViewModel.isGeneralBotSelected(a, in: .init(botID: a, context: nil, threadID: nil)))
        XCTAssertFalse(SidebarViewModel.isGeneralBotSelected(a, in: nil))
    }

    func test_reorderedBotIDs_landsBeforeTarget_inBothDirections() {
        XCTAssertEqual(SidebarViewModel.reorderedBotIDs([a, b, c], moving: a, before: c), [b, a, c])
        XCTAssertEqual(SidebarViewModel.reorderedBotIDs([a, b, c], moving: c, before: a), [c, a, b])
        XCTAssertEqual(SidebarViewModel.reorderedBotIDs([a, b, c], moving: a, before: a), [a, b, c])
        XCTAssertEqual(SidebarViewModel.reorderedBotIDs([a, b], moving: c, before: a), [a, b])
    }

    func test_untitledThread_visibleOnlyWhenRunningOrSelected() {
        // WHY: a running "New thread" had no row at all, so nothing showed it was running.
        let t = AgentThreadID(UUID())
        XCTAssertFalse(SidebarViewModel.showsThread(title: "New thread", id: t, keep: []))
        XCTAssertTrue(SidebarViewModel.showsThread(title: "New thread", id: t, keep: [t]))
        XCTAssertTrue(SidebarViewModel.showsThread(title: "Fix bug", id: t, keep: []))
    }

    func test_dragReorder_survivesSidebarReload_evenWhenMRUWouldDisagree() throws {
        // WHY: reload() used to re-sort by last activity, silently undoing the user's drop.
        let dir = NSTemporaryDirectory() + "RC2SidebarDrag-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let vm = SidebarViewModel(context: ctx, router: router)
        let first = try router.createWorkspace(name: "one", cwd: "/a")
        let second = try router.createWorkspace(name: "two", cwd: "/b")
        let third = try router.createWorkspace(name: "three", cwd: "/c")
        vm.reload()
        vm.reorderWorkspace(third.id, before: first.id)
        vm.reload()
        XCTAssertEqual(vm.workspaces.map(\.id), [third.id, first.id, second.id])
    }

    func test_duplicateTitleAges_onlyForRepeatedTitles() {
        // WHY: identical conversation titles were indistinguishable; unique ones must stay clean.
        let now = Date(timeIntervalSince1970: 100_000)
        func row(_ title: String, ago: TimeInterval) -> SidebarViewModel.WorkspaceConversationRow {
            .init(threadID: AgentThreadID(UUID()), workspaceID: ws, title: title, botID: nil, updatedAt: now.addingTimeInterval(-ago))
        }
        let a = row("Fix bug", ago: 240), b = row("Fix bug", ago: 7_200), c = row("Other", ago: 10), d = row("Fix bug", ago: 5)
        let ages = SidebarViewModel.duplicateTitleAges([a, b, c, d], now: now)
        XCTAssertEqual(ages[a.id], "4m")
        XCTAssertEqual(ages[b.id], "2h")
        XCTAssertEqual(ages[d.id], "now")
        XCTAssertNil(ages[c.id])
        // Titles equal only after truncation still collide.
        let long = String(repeating: "x", count: 40)
        let e = row(long + "1", ago: 60), f = row(long + "2", ago: 120)
        XCTAssertEqual(SidebarViewModel.duplicateTitleAges([e, f], now: now).count, 2)
    }

    func test_selectedThreadBot_prefersListedRowThenLinkCache() {
        // WHY: the "Developer" row must light up when its linked thread is open in the Agent App rail.
        let t1 = AgentThreadID(UUID()), t2 = AgentThreadID(UUID())
        let rows = [SidebarViewModel.WorkspaceConversationRow(threadID: t1, workspaceID: ws, title: "x", botID: a)]
        XCTAssertEqual(SidebarViewModel.botID(forSelectedThread: t1, rows: rows) { _ in b }, a)
        XCTAssertEqual(SidebarViewModel.botID(forSelectedThread: t2, rows: rows) { _ in b }, b, "thread beyond the listed rows still resolves through the link")
        XCTAssertNil(SidebarViewModel.botID(forSelectedThread: nil, rows: rows) { _ in b })
        XCTAssertNil(SidebarViewModel.botID(forSelectedThread: t2, rows: []) { _ in nil })
    }

    func test_workspaceBotHighlight_forLinkedThreadOnlyInItsWorkspace() {
        let other = WorkspaceID(UUID())
        XCTAssertTrue(SidebarViewModel.isWorkspaceBotHighlighted(botID: a, context: .workspace(ws), desk: nil, selectedWorkspace: ws, selectedThreadBot: a))
        XCTAssertFalse(SidebarViewModel.isWorkspaceBotHighlighted(botID: a, context: .workspace(other), desk: nil, selectedWorkspace: ws, selectedThreadBot: a), "same Bot under another workspace stays plain")
        XCTAssertFalse(SidebarViewModel.isWorkspaceBotHighlighted(botID: b, context: .workspace(ws), desk: nil, selectedWorkspace: ws, selectedThreadBot: a))
        XCTAssertFalse(SidebarViewModel.isWorkspaceBotHighlighted(botID: a, context: .general, desk: nil, selectedWorkspace: ws, selectedThreadBot: a))
        XCTAssertTrue(SidebarViewModel.isWorkspaceBotHighlighted(botID: a, context: .workspace(ws), desk: .init(botID: a, context: .workspace(ws), threadID: nil), selectedWorkspace: nil, selectedThreadBot: nil))
    }

    func test_generalBotHighlight_forLinkedThread_butDeskSelectionWins() {
        XCTAssertTrue(SidebarViewModel.isGeneralBotHighlighted(a, desk: nil, selectedThreadBot: a))
        XCTAssertFalse(SidebarViewModel.isGeneralBotHighlighted(b, desk: nil, selectedThreadBot: a))
        XCTAssertFalse(SidebarViewModel.isGeneralBotHighlighted(a, desk: .init(botID: b, context: nil, threadID: nil), selectedThreadBot: a), "an open desk for another Bot owns the highlight")
        XCTAssertTrue(SidebarViewModel.isGeneralBotHighlighted(a, desk: .init(botID: a, context: nil, threadID: nil), selectedThreadBot: nil))
    }

    func test_conversationCap_neverHidesSelectedOrRunningThreads() {
        let sel = AgentThreadID(UUID()), other = AgentThreadID(UUID())
        let cap = SidebarViewModel.workspaceConversationLimit
        XCTAssertTrue(SidebarViewModel.admitsConversation(shown: cap - 1, id: other, always: []))
        XCTAssertFalse(SidebarViewModel.admitsConversation(shown: cap, id: other, always: [sel]))
        XCTAssertTrue(SidebarViewModel.admitsConversation(shown: cap + 3, id: sel, always: [sel]), "the open thread is listed even past the cap")
    }

    private func convRows(_ n: Int) -> [SidebarViewModel.WorkspaceConversationRow] {
        (0..<n).map { SidebarViewModel.WorkspaceConversationRow(threadID: AgentThreadID(UUID()), workspaceID: ws, title: "T\($0)", botID: nil) }
    }

    func test_visibleConversations_noToggleWhenWithinCap() {
        // WHY: a short list must not grow a pointless Show more row.
        let rows = convRows(SidebarViewModel.workspaceConversationLimit)
        let out = SidebarViewModel.visibleConversations(rows, expanded: false, always: [])
        XCTAssertEqual(out.rows, rows)
        XCTAssertFalse(out.showsToggle)
        XCTAssertEqual(out.hidden, 0)
    }

    func test_visibleConversations_collapsedKeepsCapWithAlwaysFirstAndCountsHidden() {
        // WHY: visible rows must not move when a selected/running thread appears past the cap; it is appended.
        let rows = convRows(12)
        let always = rows[10].threadID
        let cap = SidebarViewModel.workspaceConversationLimit
        let out = SidebarViewModel.visibleConversations(rows, expanded: false, always: [always])
        XCTAssertEqual(out.rows, Array(rows[0..<cap]) + [rows[10]])
        XCTAssertEqual(out.hidden, rows.count - out.rows.count)
        XCTAssertTrue(out.showsToggle)
    }

    func test_visibleConversations_expandedShowsAllAndKeepsToggle() {
        // WHY: Show less must stay reachable after expanding.
        let rows = convRows(12)
        let out = SidebarViewModel.visibleConversations(rows, expanded: true, always: [])
        XCTAssertEqual(out.rows, rows)
        XCTAssertTrue(out.showsToggle)
    }

    func test_cappedSectionShowsThreeThenShowMore() {
        // WHY: Bots and VMs lists follow Conversations: New + 3 rows + Show more (N).
        let items = Array(0..<7)
        let collapsed = SidebarViewModel.capped(items, expanded: false)
        XCTAssertEqual(collapsed.rows, [0, 1, 2])
        XCTAssertEqual(collapsed.hidden, 4)
        XCTAssertEqual(SidebarViewModel.capped(items, expanded: true).rows, items, "Show more reveals every row")
        XCTAssertEqual(SidebarViewModel.capped([0, 1, 2], expanded: false).hidden, 0, "a short list grows no Show more row")
    }

    func test_botRunning_whenOwnRunOrLinkedThreadRuns() {
        XCTAssertTrue(SidebarViewModel.isBotRunning(a, running: [a], runningLinked: []))
        XCTAssertTrue(SidebarViewModel.isBotRunning(a, running: [], runningLinked: [a]))
        XCTAssertFalse(SidebarViewModel.isBotRunning(a, running: [b], runningLinked: [c]))
    }

    func test_runEventKinds_matchPublishedKinds() {
        // WHY: a typo here silently freezes spinners; kinds must equal the treaty raw values.
        let published: Set<String> = [RemoteCodeEventKind.agentRunStarted, .agentRunFinished, .agentRunCompleted, .agentRunFailed, .agentRunCancelled].map(\.rawValue).reduce(into: []) { $0.insert($1) }
        XCTAssertEqual(Set(SidebarViewModel.runEventKinds), published)
    }
}
