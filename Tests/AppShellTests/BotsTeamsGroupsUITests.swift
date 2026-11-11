import XCTest
import AgentRuntime
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence
@testable import Surfaces

/// WHY: teams and group rooms are new places in the Bots sidebar. Someone who
/// never makes a team must keep exactly the "My Bots" list they have today; a
/// bot in two teams must show under both; a group send must show the user's
/// line and who is about to answer at once, without the room ever running a
/// provider; a refused send must keep the text; a rapid switch between groups
/// must never let the older group's work touch the newer one; and the open
/// group, collapsed teams and room draft must survive a relaunch.
@MainActor
final class BotsTeamsGroupsUITests: XCTestCase {
    private static let defaultsKeys = [
        "bots.screen", "bots.selectedBotID", "bots.searchText", "bots.showHidden",
        BotTeamsGroupsController.selectedGroupDefaultsKey,
        BotTeamsGroupsController.inspectorDefaultsKey,
    ]

    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        Self.defaultsKeys.forEach(UserDefaults.standard.removeObject(forKey:))
    }

    override func tearDown() {
        Self.defaultsKeys.forEach(UserDefaults.standard.removeObject(forKey:))
        super.tearDown()
    }

    private struct Fixture {
        let ctx: AppContext
        let router: AppCommandRouter
        let runner: ControlledBotHandoffRunner
        let support: String
        let ana: BotDefinition
        let bob: BotDefinition
        let cid: BotDefinition
        @MainActor var service: BotTeamGroupService { ctx.botTeamGroupService }
    }

    private func openContext(support: String) throws -> (AppContext, AppCommandRouter, ControlledBotHandoffRunner) {
        let ctx = try AppContext(channel: .debug, appSupportOverride: support)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: TerminalRetiringOneShotAdapter(runner: runner))
        let model = BotsViewModel.defaultModel(for: .codex)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: model, label: model, provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "codex"
            )
        ])
        ctx.botGroupOrchestrator.vmPreflight = { _ in nil }
        return (ctx, router, runner)
    }

    private func makeFixture() throws -> Fixture {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2BotsTeamsGroupsUI-\(UUID().uuidString)", isDirectory: true).path
        let (ctx, router, runner) = try openContext(support: support)
        let ana = try ctx.botStore.create(name: "Ana", title: "Writer", description: "", handle: "ana", soul: "ANA-SOUL")
        let bob = try ctx.botStore.create(name: "Bob", title: "Critic", description: "", handle: "bob", soul: "BOB-SOUL")
        let cid = try ctx.botStore.create(name: "Cid", title: "", description: "", handle: "cid", soul: "CID-SOUL")
        return Fixture(ctx: ctx, router: router, runner: runner, support: support, ana: ana, bob: bob, cid: cid)
    }

    private func makeViewModel(_ f: Fixture) -> BotsViewModel {
        let vm = BotsViewModel(context: f.ctx, router: f.router)
        f.router.botsViewModel = vm
        return vm
    }

    private func makeGroup(
        _ f: Fixture,
        title: String = "Launch room",
        bots: [BotDefinition],
        policy: BotGroupPolicy = .roundtable
    ) async throws -> BotGroupConversation {
        try await f.service.createGroup(title: title, policy: policy, participantBotIDs: bots.map(\.id))
    }

    private func waitUntil(timeout: TimeInterval = 6, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Sidebar sections

    func test_withNoTeams_thereAreNoRosterSections() throws {
        let bots = [
            BotDefinition(handle: "ana", name: "Ana", title: "", description: ""),
            BotDefinition(handle: "bob", name: "Bob", title: "", description: ""),
        ]
        XCTAssertNil(
            BotRosterSections.make(roster: bots, teams: [], membersByTeam: [:]),
            "no teams must mean no sections: the roster renders exactly as before"
        )
    }

    func test_aBotInTwoTeamsShowsUnderEach_andOtherBotsHoldsTheRest() {
        let ana = BotDefinition(handle: "ana", name: "Ana", title: "", description: "")
        let bob = BotDefinition(handle: "bob", name: "Bob", title: "", description: "")
        let cid = BotDefinition(handle: "cid", name: "Cid", title: "", description: "")
        let writers = BotTeam(name: "Writers", sortOrder: 0)
        let reviewers = BotTeam(name: "Reviewers", sortOrder: 1)
        let sections = BotRosterSections.make(
            roster: [ana, bob, cid],
            teams: [writers, reviewers],
            membersByTeam: [writers.id: [bob.id, ana.id], reviewers.id: [ana.id]]
        )
        XCTAssertEqual(sections?.teams.map(\.team.name), ["Writers", "Reviewers"])
        XCTAssertEqual(sections?.teams[0].bots.map(\.handle), ["bob", "ana"], "member order, not roster order")
        XCTAssertEqual(sections?.teams[1].bots.map(\.handle), ["ana"], "many-to-many: Ana is listed again")
        XCTAssertEqual(sections?.otherBots.map(\.handle), ["cid"])
    }

    func test_sectionsFollowTheVisibleRoster_soSearchAndHiddenStillApply() {
        let ana = BotDefinition(handle: "ana", name: "Ana", title: "", description: "")
        let bob = BotDefinition(handle: "bob", name: "Bob", title: "", description: "")
        let team = BotTeam(name: "Writers")
        // Bob is filtered out (search or hidden): no team may bring him back.
        let sections = BotRosterSections.make(roster: [ana], teams: [team], membersByTeam: [team.id: [ana.id, bob.id]])
        XCTAssertEqual(sections?.teams.first?.bots.map(\.handle), ["ana"])
        XCTAssertEqual(sections?.otherBots, [])
    }

    func test_teamsAndGroupsMadeElsewhereReachTheSidebar() async throws {
        let f = try makeFixture()
        let vm = makeViewModel(f)
        let controller = vm.teamsGroups
        XCTAssertTrue(controller.teams.isEmpty)
        XCTAssertTrue(controller.groups.isEmpty, "nothing is seeded")

        // A paired device's create publishes an event; the sidebar follows it.
        let team = try f.service.createTeam(name: "Writers", memberBotIDs: [f.ana.id, f.bob.id])
        let group = try await makeGroup(f, bots: [f.ana, f.bob])
        let arrived = await waitUntil {
            controller.teams.map(\.id) == [team.id] && controller.groups.map(\.id) == [group.id]
        }
        XCTAssertTrue(arrived)
        XCTAssertEqual(controller.membersByTeam[team.id], [f.ana.id, f.bob.id])
        XCTAssertEqual(controller.participants(of: group.id).map(\.botID), [f.ana.id, f.bob.id])
    }

    // MARK: - Group room

    func test_groupSendPaintsTheUserLineAndWaitingRowsOnTheSendTurnAndNeverRunsTheRoom() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob])
        let vm = makeViewModel(f)
        vm.openGroup(group.id)
        XCTAssertEqual(vm.screen, .group)
        let room = try XCTUnwrap(vm.teamsGroups.roomVM, "the room mounts on the open turn")
        XCTAssertEqual(room.embedding?.pinnedThreadId, group.roomThreadID)
        XCTAssertEqual(room.selectedThreadId, group.roomThreadID)

        room.prompt = "Plan the launch"
        let started = Date()
        await room.send()
        let acknowledged = Date().timeIntervalSince(started)

        // Immediate path: the user line and one waiting row per bot, painted.
        XCTAssertEqual(room.messages.map(\.role), [.user, .assistant, .assistant])
        XCTAssertEqual(room.messages.first?.content, "Plan the launch")
        XCTAssertEqual(
            room.messages.dropFirst().compactMap { BotPeerTranscript.parseActivity($0.content)?.handle },
            ["ana", "bob"]
        )
        XCTAssertEqual(room.prompt, "", "an accepted send clears the composer")
        XCTAssertLessThan(acknowledged, 0.1, "user row plus waiting rows within 100 ms")
        XCTAssertNil(f.ctx.coordinator.activeRunId(threadId: group.roomThreadID), "the room never runs a provider")

        // Eventual completion: each bot answers on its own thread and the reply
        // replaces its waiting row in the room surface, once.
        let anaStarted = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(anaStarted)
        let anaRequest = try XCTUnwrap(f.runner.requests.first)
        XCTAssertNotEqual(anaRequest.threadId, group.roomThreadID)
        XCTAssertTrue(f.runner.finish(runID: anaRequest.runId, status: .completed, reply: "Ship it Monday."))
        let bobStarted = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(bobStarted)
        XCTAssertTrue(f.runner.finish(
            runID: try XCTUnwrap(f.runner.requests.last).runId, status: .completed, reply: "Too soon."
        ))
        let painted = await waitUntil {
            room.messages.compactMap { BotPeerTranscript.parse($0.content)?.body } == ["Ship it Monday.", "Too soon."]
        }
        XCTAssertTrue(painted)
        XCTAssertEqual(room.messages.count, 3, "replies replace their rows; nothing is appended twice")
        XCTAssertTrue(f.runner.requests.allSatisfy { $0.threadId != group.roomThreadID })
    }

    func test_aRefusedGroupSendKeepsTheTextAndWritesNothing() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob], policy: .mentionsOnly)
        let vm = makeViewModel(f)
        vm.openGroup(group.id)
        let room = try XCTUnwrap(vm.teamsGroups.roomVM)

        room.prompt = "Anyone there?"
        await room.send()
        XCTAssertEqual(room.prompt, "Anyone there?", "a refused send keeps the user's text")
        XCTAssertFalse(room.statusMessage.isEmpty, "the refusal is shown, not swallowed")
        XCTAssertTrue(room.messages.isEmpty)
        XCTAssertTrue(try f.ctx.messageRepo.list(threadId: group.roomThreadID).isEmpty)

        // Attachments are deferred: rejected with a clear error, text kept.
        room.prompt = "@ana look at this"
        room.attachments = [AgentAttachment(path: "/tmp/a.txt", kind: .file)]
        await room.send()
        XCTAssertEqual(room.statusMessage, BotGroupOrchestrator.SendError.attachmentsUnsupported.errorDescription)
        XCTAssertEqual(room.prompt, "@ana look at this")
        XCTAssertTrue(try f.ctx.messageRepo.list(threadId: group.roomThreadID).isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty)
    }

    func test_roomMentionsOfferOnlyTheGroupsParticipants() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.cid])
        let vm = makeViewModel(f)
        vm.openGroup(group.id)
        let room = try XCTUnwrap(vm.teamsGroups.roomVM)
        let mentionable = room.mentionableBotsProvider()
        XCTAssertEqual(mentionable.map(\.handle), ["ana", "cid"], "Bob is not in this room")
    }

    func test_rapidGroupSwitchLetsOnlyTheNewestGroupWin() async throws {
        let f = try makeFixture()
        let first = try await makeGroup(f, title: "A", bots: [f.ana])
        let second = try await makeGroup(f, title: "B", bots: [f.bob])
        try f.ctx.botStore.setGroupAttention(id: first.id, attentionState: .unreadActivity, unread: true)
        try f.ctx.botStore.setGroupAttention(id: second.id, attentionState: .unreadActivity, unread: true)
        let vm = makeViewModel(f)

        vm.openGroup(first.id)
        let roomA = try XCTUnwrap(vm.teamsGroups.roomVM)
        vm.openGroup(second.id)
        let roomB = try XCTUnwrap(vm.teamsGroups.roomVM)
        XCTAssertFalse(roomA === roomB)
        XCTAssertEqual(roomB.embedding?.pinnedThreadId, second.roomThreadID)

        // The deferred "mark read" of A is stale: only B is cleared.
        let cleared = await waitUntil { (try? f.ctx.botStore.group(id: second.id))??.unread == false }
        XCTAssertTrue(cleared)
        XCTAssertEqual(try f.ctx.botStore.group(id: first.id)?.unread, true, "A was left before its read landed")

    }

    func test_aReplyForTheGroupLeftBehindNeverTouchesTheOpenRoom_andWaitsAsUnreadInItsOwn() async throws {
        let f = try makeFixture()
        let first = try await makeGroup(f, title: "A", bots: [f.ana])
        let second = try await makeGroup(f, title: "B", bots: [f.bob])
        let vm = makeViewModel(f)

        vm.openGroup(first.id)
        let roomA = try XCTUnwrap(vm.teamsGroups.roomVM)
        roomA.prompt = "Draft the post"
        await roomA.send()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)

        // Switch to B while Ana is still answering in A.
        vm.openGroup(second.id)
        let roomB = try XCTUnwrap(vm.teamsGroups.roomVM)
        let bReadCleared = await waitUntil { (try? f.ctx.botStore.group(id: second.id))??.unread == false }
        XCTAssertTrue(bReadCleared)
        let bBefore = roomB.messages
        XCTAssertTrue(f.runner.finish(
            runID: try XCTUnwrap(f.runner.requests.first).runId, status: .completed, reply: "Here is the draft."
        ))

        // A's row resolves in A only: A is not on screen, so it is unread there.
        let aUnread = await waitUntil {
            vm.teamsGroups.groups.first { $0.id == first.id }.map { $0.unread && $0.attentionState == .unreadActivity } == true
        }
        XCTAssertTrue(aUnread, "the group left behind is marked unread")
        XCTAssertEqual(roomB.messages, bBefore, "B's room is untouched by A's reply")
        XCTAssertEqual(vm.teamsGroups.groups.first { $0.id == second.id }?.unread, false)

        // Reopening A shows the reply from the store and reads it.
        vm.openGroup(first.id)
        let roomA2 = try XCTUnwrap(vm.teamsGroups.roomVM)
        let shown = await waitUntil {
            roomA2.messages.compactMap { BotPeerTranscript.parse($0.content)?.body } == ["Here is the draft."]
        }
        XCTAssertTrue(shown)
        let aRead = await waitUntil { (try? f.ctx.botStore.group(id: first.id))??.unread == false }
        XCTAssertTrue(aRead)
    }

    func test_aReplyInTheOpenRoomIsReadAsItLands() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana])
        let vm = makeViewModel(f)
        vm.openGroup(group.id)
        let room = try XCTUnwrap(vm.teamsGroups.roomVM)
        room.prompt = "Status?"
        await room.send()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        XCTAssertTrue(f.runner.finish(
            runID: try XCTUnwrap(f.runner.requests.first).runId, status: .completed, reply: "All green."
        ))
        let settled = await waitUntil {
            (try? f.ctx.botStore.group(id: group.id))??.attentionState == BotAttentionState.none
        }
        XCTAssertTrue(settled, "a reply the user is watching needs no dot")
        let stored = try XCTUnwrap(try f.ctx.botStore.group(id: group.id))
        XCTAssertFalse(stored.unread, "paired devices must not get an unread group the Mac user already read")
        let synced = await waitUntil {
            vm.teamsGroups.groups.first { $0.id == group.id }.map { !$0.unread && $0.attentionState == .none } == true
        }
        XCTAssertTrue(synced, "the sidebar row shows no attention dot")

        // Off screen again: the next reply is unread.
        vm.screen = .desk
        XCTAssertNil(vm.teamsGroups.roomVM)
        _ = try f.ctx.botTeamGroupService.send(groupID: group.id, text: "And now?", submitKey: nil)
        let second = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(second)
        XCTAssertTrue(f.runner.finish(
            runID: try XCTUnwrap(f.runner.requests.last).runId, status: .completed, reply: "Still green."
        ))
        let unread = await waitUntil { (try? f.ctx.botStore.group(id: group.id))??.unread == true }
        XCTAssertTrue(unread, "a group nobody is looking at gets its unread dot")
    }

    func test_aFailedTurnIsRetriedFromTheRoom() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana])
        let vm = makeViewModel(f)
        vm.openGroup(group.id)
        let room = try XCTUnwrap(vm.teamsGroups.roomVM)
        room.prompt = "Try this"
        await room.send()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        XCTAssertTrue(f.runner.finish(runID: try XCTUnwrap(f.runner.requests.first).runId, status: .failed, reply: nil))

        let offered = await waitUntil { vm.teamsGroups.retryableTurns[group.id]?.map(\.botID) == [f.ana.id] }
        XCTAssertTrue(offered, "a failed turn has something to act on in the room")
        let stored = try XCTUnwrap(try f.ctx.botStore.group(id: group.id))
        XCTAssertEqual(stored.attentionState, .needsAttention, "a failure still needs the user while the room is open")
        XCTAssertFalse(stored.unread)

        vm.teamsGroups.retryFailedTurns(groupID: group.id)
        let rerun = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(rerun, "Retry runs the bot again")
        XCTAssertTrue(vm.teamsGroups.retryableTurns[group.id]?.isEmpty ?? true, "nothing left to retry while it runs")
        XCTAssertTrue(f.runner.finish(runID: try XCTUnwrap(f.runner.requests.last).runId, status: .completed, reply: "Worked."))
        let painted = await waitUntil {
            room.messages.compactMap { BotPeerTranscript.parse($0.content)?.body } == ["Worked."]
        }
        XCTAssertTrue(painted)
    }

    func test_hidingTheOpenGroupElsewhereKeepsItsRoom() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana])
        let vm = makeViewModel(f)
        vm.openGroup(group.id)
        let room = try XCTUnwrap(vm.teamsGroups.roomVM)

        // A paired device hides it.
        let current = try XCTUnwrap(try f.ctx.botStore.group(id: group.id))
        try f.service.updateGroup(id: group.id, expectedRevision: current.revision) { $0.hidden = true }
        let arrived = await waitUntil { vm.teamsGroups.groups.first { $0.id == group.id }?.hidden == true }
        XCTAssertTrue(arrived, "hidden groups stay listed for Show hidden")
        XCTAssertEqual(vm.screen, .group)
        XCTAssertEqual(vm.teamsGroups.selectedGroup?.hidden, true, "the open room never turns into 'Select a group'")
        XCTAssertTrue(vm.teamsGroups.roomVM === room)

        // Unhide from the Mac (parity with the paired device).
        vm.teamsGroups.setHidden(false, groupID: group.id)
        XCTAssertEqual(try f.ctx.botStore.group(id: group.id)?.hidden, false)

        // A hidden open group survives relaunch too.
        vm.teamsGroups.setHidden(true, groupID: group.id)
        let (ctx2, router2, _) = try openContext(support: f.support)
        let reopened = BotsViewModel(context: ctx2, router: router2)
        router2.botsViewModel = reopened
        XCTAssertEqual(reopened.screen, .group)
        XCTAssertNotNil(reopened.teamsGroups.roomVM)
    }

    func test_theFirstPaintDoesNoListReads_andALateSnapshotNeverOverwritesANewerOne() async throws {
        let f = try makeFixture()
        let team = try f.service.createTeam(name: "Writers", memberBotIDs: [f.ana.id])
        _ = try await makeGroup(f, bots: [f.ana])
        let vm = makeViewModel(f)

        // Immediate path: creating the controller (the roster's first frame)
        // applies nothing synchronously; the lists land in one async pass.
        let controller = vm.teamsGroups
        XCTAssertEqual(controller.reloadCountForTesting, 0)
        XCTAssertTrue(controller.groups.isEmpty)

        // A local reload while the initial pass is in flight wins; the late
        // initial snapshot is dropped.
        controller.reload()
        XCTAssertEqual(controller.reloadCountForTesting, 1)
        XCTAssertEqual(controller.teams.map(\.id), [team.id])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.reloadCountForTesting, 1, "the stale initial snapshot must not apply")

        // Eventual completion on a fresh controller.
        let vm2 = makeViewModel(f)
        let landed = await waitUntil { vm2.teamsGroups.teams.map(\.id) == [team.id] && vm2.teamsGroups.groups.count == 1 }
        XCTAssertTrue(landed)
    }

    func test_theRoomComposerOnlyRelays() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana])
        let vm = makeViewModel(f)
        vm.openGroup(group.id)
        let room = try XCTUnwrap(vm.teamsGroups.roomVM)

        // No provider, model, source, run-as-user, permission or effort
        // choice: none of them would change who answers or how.
        XCTAssertEqual(AgentComposerChromePresentation.controls(for: .relay), [.attach, .sendStop])
        XCTAssertEqual(room.composerPlaceholder, BotTeamsGroupsController.roomPlaceholder)
        let surface = try source("Sources/Surfaces/AgentAppSurface.swift")
        XCTAssertTrue(surface.contains("vm.embedding?.sendInterceptor != nil ? .relay : .power"),
                      "the shared composer derives relay chrome from the interceptor, not a fork")
        XCTAssertTrue(surface.contains("attachEnabled: composerChromeMode != .relay &&"))
        XCTAssertTrue(surface.contains("? AgentComposerChromePresentation.relayAttachUnavailable : nil"),
                      "a disabled attach says why")
        XCTAssertEqual(
            AgentComposerChromePresentation.relayAttachUnavailable,
            BotGroupOrchestrator.SendError.attachmentsUnsupported.errorDescription
        )
    }

    func test_theRoomPresentsItsOwnEditSheet() throws {
        // WHY: the sidebar may be collapsed while the room is open; the
        // inspector's Edit… must not latch a sheet nobody presents.
        let groupsView = try source("Sources/AppShell/BotsTeamsGroups.swift")
        XCTAssertTrue(groupsView.contains("Button(L(\"Edit…\")) { teamsGroups.roomSheet = .editGroup(group.id) }"))
        let room = try XCTUnwrap(groupsView.range(of: "struct BotGroupRoomScreen"))
        let inspector = try XCTUnwrap(groupsView.range(of: "struct BotGroupInspector"))
        XCTAssertTrue(groupsView[room.lowerBound..<inspector.lowerBound].contains(".sheet(item: $teamsGroups.roomSheet)"))
    }

    func test_aGroupDeletedElsewhereClosesItsRoom() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana])
        let vm = makeViewModel(f)
        vm.openGroup(group.id)
        XCTAssertNotNil(vm.teamsGroups.roomVM)
        try await f.service.deleteGroup(id: group.id)
        let closed = await waitUntil { vm.screen != .group }
        XCTAssertTrue(closed, "a deleted group must not leave a dead room on screen")
        XCTAssertNil(vm.teamsGroups.roomVM)
        XCTAssertNil(vm.teamsGroups.selectedGroupID)
    }

    func test_thePrivateThreadIsReadOnly() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana])
        let vm = makeViewModel(f)
        vm.openGroup(group.id)
        let room = try XCTUnwrap(vm.teamsGroups.roomVM)
        room.prompt = "Hi Ana"
        await room.send()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        XCTAssertTrue(f.runner.finish(
            runID: try XCTUnwrap(f.runner.requests.first).runId, status: .completed, reply: "Hello"
        ))
        let linked = await waitUntil { vm.teamsGroups.memberThreadID(groupID: group.id, botID: f.ana.id) != nil }
        XCTAssertTrue(linked, "the member thread shows once the bot answered")

        vm.teamsGroups.openPrivateThread(botID: f.ana.id)
        let privateVM = try XCTUnwrap(vm.teamsGroups.privateThreadVM)
        privateVM.prompt = "side question"
        await privateVM.send()
        XCTAssertEqual(privateVM.statusMessage, BotTeamsGroupsController.privateThreadReadOnlyMessage)
        XCTAssertEqual(privateVM.prompt, "side question")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "nothing runs from the private thread")
        // Retry and Continue say why instead of a dead click.
        await privateVM.retryLastPrompt()
        XCTAssertEqual(privateVM.statusMessage, AgentAppViewModel.interceptedRunRefusal)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "retry from the private thread runs nothing")
        vm.teamsGroups.closePrivateThread()
        XCTAssertNil(vm.teamsGroups.privateThreadVM)
    }

    // MARK: - Edits

    func test_inspectorEditsApplyThroughTheServiceAndStayInBounds() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob])
        let vm = makeViewModel(f)
        vm.openGroup(group.id)
        let controller = vm.teamsGroups

        controller.setPolicy(.lead, groupID: group.id)
        var stored = try XCTUnwrap(try f.ctx.botStore.group(id: group.id))
        XCTAssertEqual(stored.policy, .lead)
        XCTAssertEqual(stored.leadBotID, f.ana.id, "lead defaults to the first participant")
        controller.setMaxAutoHops(99, groupID: group.id)
        stored = try XCTUnwrap(try f.ctx.botStore.group(id: group.id))
        XCTAssertEqual(stored.maxAutoHops, BotGroupConversation.maxAutoHopsCap, "the hop budget is capped at 8")
        XCTAssertEqual(controller.selectedGroup?.maxAutoHops, BotGroupConversation.maxAutoHopsCap)
    }

    func test_editingAGroupSwapsTheLeadForANewParticipant() async throws {
        let f = try makeFixture()
        let group = try await f.service.createGroup(
            title: "Leads", policy: .lead, leadBotID: f.ana.id, participantBotIDs: [f.ana.id, f.bob.id]
        )
        let vm = makeViewModel(f)
        let saved = vm.teamsGroups.saveGroup(id: group.id, draft: .init(
            title: "Leads 2", teamID: nil, participantBotIDs: [f.bob.id, f.cid.id],
            policy: .lead, leadBotID: f.cid.id, maxAutoHops: 2
        ))
        XCTAssertTrue(saved, "the old lead may leave in the same edit that picks a new one")
        let stored = try XCTUnwrap(try f.ctx.botStore.group(id: group.id))
        XCTAssertEqual(stored.title, "Leads 2")
        XCTAssertEqual(stored.policy, .lead)
        XCTAssertEqual(stored.leadBotID, f.cid.id)
        XCTAssertEqual(stored.maxAutoHops, 2)
        XCTAssertEqual(try f.ctx.botStore.listGroupParticipants(groupID: group.id).map(\.botID), [f.bob.id, f.cid.id])
    }

    func test_teamEditorCreatesAndEditsMembership() throws {
        let f = try makeFixture()
        let vm = makeViewModel(f)
        let controller = vm.teamsGroups
        XCTAssertTrue(controller.saveTeam(id: nil, name: "Writers", description: "", memberBotIDs: [f.ana.id]))
        let team = try XCTUnwrap(controller.teams.first, "the new team shows on the same turn")
        XCTAssertTrue(controller.saveTeam(id: team.id, name: "Writers", description: "words", memberBotIDs: [f.ana.id, f.bob.id]))
        XCTAssertEqual(controller.membersByTeam[team.id], [f.ana.id, f.bob.id])
        XCTAssertFalse(controller.saveTeam(id: nil, name: "  ", description: "", memberBotIDs: []))
        XCTAssertEqual(controller.teams.count, 1, "a refused save changes nothing")
    }

    func test_teamsManagerSheetIsOneSheetAndItsControlsDriveTheServiceBackedStore() throws {
        let f = try makeFixture()
        let vm = makeViewModel(f)
        let botCount = vm.bots.count
        vm.openTeamsManager()
        XCTAssertEqual(vm.teamsGroups.sheet, .teams, "the Teams button opens one manager sheet")

        // What the manager's controls call: create on Return, avatar click, inline rename, delete.
        let controller = vm.teamsGroups
        XCTAssertTrue(controller.saveTeam(id: nil, name: "Writers", description: "", memberBotIDs: []))
        let team = try XCTUnwrap(controller.teams.first)
        XCTAssertTrue(controller.saveTeam(id: team.id, name: team.name, description: "", memberBotIDs: [f.ana.id]))
        XCTAssertTrue(controller.saveTeam(id: team.id, name: team.name, description: "", memberBotIDs: [f.ana.id, f.bob.id]))
        XCTAssertEqual(controller.membersByTeam[team.id], [f.ana.id, f.bob.id], "clicking avatars adds members")
        XCTAssertTrue(controller.saveTeam(id: team.id, name: team.name, description: "", memberBotIDs: [f.bob.id]))
        XCTAssertEqual(controller.membersByTeam[team.id], [f.bob.id], "clicking a member's avatar removes it")
        XCTAssertTrue(controller.saveTeam(id: team.id, name: "Authors", description: "", memberBotIDs: [f.bob.id]))
        XCTAssertEqual(controller.teams.first?.name, "Authors", "inline rename keeps the members")
        XCTAssertEqual(controller.membersByTeam[team.id], [f.bob.id])
        controller.deleteTeam(team.id)
        XCTAssertTrue(controller.teams.isEmpty, "delete removes the team and keeps the bots")
        XCTAssertEqual(vm.bots.count, botCount, "the bots stay")

        let source = try source("Sources/AppShell/BotsTeamsGroups.swift")
        XCTAssertTrue(source.contains(".onSubmit(create)"), "Return creates a team")
        XCTAssertTrue(source.contains("pendingTeamDelete = team"), "delete asks first")
        XCTAssertFalse(source.contains("BotTeamEditorSheet"), "the form editor is replaced by the manager")
    }

    // MARK: - Relaunch

    func test_openGroupAndRoomDraftSurviveRelaunch() async throws {
        let f = try makeFixture()
        let team = try f.service.createTeam(name: "Writers", memberBotIDs: [f.ana.id])
        let group = try await makeGroup(f, bots: [f.ana])
        let vm = makeViewModel(f)
        vm.openGroup(group.id)
        let room = try XCTUnwrap(vm.teamsGroups.roomVM)
        room.prompt = "half-written"
        room.dispose()

        let (ctx2, router2, _) = try openContext(support: f.support)
        let reopened = BotsViewModel(context: ctx2, router: router2)
        router2.botsViewModel = reopened
        XCTAssertEqual(reopened.screen, .group)
        XCTAssertEqual(reopened.teamsGroups.selectedGroupID, group.id)
        let room2 = try XCTUnwrap(reopened.teamsGroups.roomVM)
        XCTAssertEqual(room2.embedding?.pinnedThreadId, group.roomThreadID)
        let restored = await waitUntil { room2.prompt == "half-written" }
        XCTAssertTrue(restored, "the room's unsent draft is the user's work")
    }
}
