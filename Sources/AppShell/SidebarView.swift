import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoreModel
import Persistence
import AgentRuntime
import Surfaces
import DesignSystemKit
import SocketServer
import Combine

public extension Notification.Name {
    /// Account or provider usage in usage.json changed (throttled by AppContext).
    static let rc2AccountUsageChanged = Notification.Name("rc2AccountUsageChanged")
    /// Posted by AppContext only when the provider-account usage refresh reaches
    /// its terminal state. `rc2AccountUsageChanged` is too broad for that job:
    /// local provider-usage writes post it without querying any provider, so it
    /// can never prove the probe finished.
    static let rc2AccountUsageRefreshSettled = Notification.Name("rc2AccountUsageRefreshSettled")
}

@MainActor
public final class SidebarViewModel: ObservableObject {
    /// Pure view-state for the Insomnia keep-awake status pill. Carries no UI
    /// dependency so the view can render + wire one-click disable from it.
    public struct InsomniaStatusPillState: Equatable {
        public let isVisible: Bool
        public let label: String
        public let disablesInsomniaOnTap: Bool
    }

    /// Derives the status-pill state from whether keep-awake assertions are held.
    /// Visible (with a disable-on-tap intent + human-readable label) only when on.
    nonisolated public static func insomniaStatusPill(enabled: Bool) -> InsomniaStatusPillState {
        InsomniaStatusPillState(
            isVisible: enabled,
            label: enabled ? "Keeping Mac awake" : "",
            disablesInsomniaOnTap: enabled
        )
    }

    public enum InsomniaBatteryDecision {
        case disable
        case keepEnabled
    }

    /// Asks without blocking: the answer arrives through `completion`. A
    /// blocking modal here held every main-actor job, including all remote
    /// RPCs, until the user answered (84 minutes on 2026-10-29).
    public typealias InsomniaBatteryPrompt = @MainActor (
        _ completion: @escaping @MainActor (InsomniaBatteryDecision) -> Void
    ) -> Void
    public typealias OperationErrorPresenter = @MainActor (_ message: String, _ detail: String) -> Void

    // MARK: - WorkspacePrompting seam (:95)

    /// Decision returned by a text-input prompt (rename, description).
    /// `.committed(text)` means the user clicked Save; `.cancelled` means Cancel or dismiss.
    public enum PromptDecision: Equatable {
        case committed(String)
        case cancelled
    }

    /// Decision returned by a confirm-remove alert.
    public enum RemoveDecision: Equatable {
        case confirmed
        case cancelled
    }

    /// Injectable seam that drives the modal DECISION for rename/remove paths.
    /// The real implementation shows NSAlert/NSTextField; the test implementation
    /// returns a hard-coded result without spinning AppKit.
    ///
    /// Mirrors the `InsomniaBatteryPrompt` injection pattern (SidebarView.swift:43, :162).
    public protocol WorkspacePrompting: AnyObject {
        /// Called by `renameWorkspace`/`editDescription`. Must call `completion`
        /// exactly once. The string in `.committed` must already be trimmed.
        @MainActor func promptForText(
            title: String,
            message: String,
            initial: String,
            multiline: Bool,
            completion: @escaping @MainActor (PromptDecision) -> Void
        )

        /// Called by `removeWorkspace` for a single-workspace confirm.
        @MainActor func confirmRemoveOne(
            name: String,
            completion: @escaping @MainActor (RemoveDecision) -> Void
        )

        /// Called by `removeSelectedWorkspaces` for a multi-workspace confirm.
        @MainActor func confirmRemoveMany(
            count: Int,
            names: [String],
            completion: @escaping @MainActor (RemoveDecision) -> Void
        )
    }

    /// Default production prompter: shows the same NSAlert/beginSheetModal/runModal
    /// flow that the inline code used before the seam was introduced.
    /// No behaviour change -- wraps the existing modal calls verbatim.
    public final class AppKitWorkspacePrompter: WorkspacePrompting {
        private weak var viewModel: SidebarViewModel?

        public init(viewModel: SidebarViewModel) {
            self.viewModel = viewModel
        }

        @MainActor public func promptForText(
            title: String,
            message: String,
            initial: String,
            multiline: Bool,
            completion: @escaping @MainActor (PromptDecision) -> Void
        ) {
            viewModel?.presentPromptSheet(
                title: title,
                message: message,
                initial: initial,
                multiline: multiline
            ) { text in
                if let text {
                    completion(.committed(text))
                } else {
                    completion(.cancelled)
                }
            }
        }

        @MainActor public func confirmRemoveOne(
            name: String,
            completion: @escaping @MainActor (RemoveDecision) -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Remove \"\(name)\"?"
            alert.informativeText = "This removes the workspace and its tabs from MacCode. Files on disk are not touched."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            let handler: (NSApplication.ModalResponse) -> Void = { response in
                completion(SidebarRootView.confirmRemoveDecision(response: response) ? .confirmed : .cancelled)
            }
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window, completionHandler: handler)
            } else {
                handler(alert.runModal())
            }
        }

        @MainActor public func confirmRemoveMany(
            count: Int,
            names: [String],
            completion: @escaping @MainActor (RemoveDecision) -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Remove \(count) workspaces?"
            alert.informativeText = "This removes the selected workspaces and their tabs from MacCode. Files on disk are not touched.\n\n" + names.joined(separator: "\n")
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            let handler: (NSApplication.ModalResponse) -> Void = { response in
                completion(SidebarRootView.confirmRemoveDecision(response: response) ? .confirmed : .cancelled)
            }
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window, completionHandler: handler)
            } else {
                handler(alert.runModal())
            }
        }
    }

    /// Injectable workspace prompter. Defaults to `AppKitWorkspacePrompter` (set
    /// after `self` is available in `init`). Tests replace this with a fake that
    /// returns a pre-determined decision without spinning AppKit modals.
    public var workspacePrompter: (any WorkspacePrompting)?
    private let operationErrorPresenter: OperationErrorPresenter

    public weak var context: AppContext?
    public weak var router: AppCommandRouter?

    public struct AuthorizedBotConversationRow: Identifiable, Equatable, Sendable {
        public let botID: BotID
        public let botName: String
        public let handle: String
        public let symbol: String
        public let context: BotContext
        public let conversationID: BotConversationID?
        public let title: String
        public var id: String { "\(botID.value.uuidString):\(context.storageKey)" }

        nonisolated public init(botID: BotID, botName: String, handle: String = "", symbol: String = "", context: BotContext, conversationID: BotConversationID?, title: String) {
            self.botID = botID
            self.botName = botName
            self.handle = handle
            self.symbol = symbol
            self.context = context
            self.conversationID = conversationID
            self.title = title
        }
    }

    @Published public private(set) var authorizedBotConversationRows: [AuthorizedBotConversationRow] = []

    /// One "General Bots" row: Titio, Bots with a general grant, and Bots not linked to any workspace.
    public struct GeneralBotRow: Identifiable, Equatable, Sendable {
        public let botID: BotID
        public let name: String
        public let handle: String
        public let symbol: String
        public let pinned: Bool
        public let hidden: Bool
        /// Unread messages: Titio's inbox count, or a Bot's unread conversations.
        public let unreadCount: Int
        public var id: String { botID.value.uuidString }
        public var isTitio: Bool { handle == TitioIdentity.handle }
        nonisolated public init(botID: BotID, name: String, handle: String, symbol: String, pinned: Bool = false, hidden: Bool = false, unreadCount: Int = 0) {
            self.botID = botID
            self.name = name
            self.handle = handle
            self.symbol = symbol
            self.pinned = pinned
            self.hidden = hidden
            self.unreadCount = unreadCount
        }
    }

    /// A thread under an expanded workspace's "Conversations", with or without a Bot.
    public struct WorkspaceConversationRow: Identifiable, Equatable, Sendable {
        public let threadID: AgentThreadID
        public let workspaceID: WorkspaceID
        public let title: String
        public let botID: BotID?
        public let updatedAt: Date
        public var id: String { threadID.value.uuidString }
        nonisolated public init(threadID: AgentThreadID, workspaceID: WorkspaceID, title: String, botID: BotID?, updatedAt: Date = .distantPast) {
            self.threadID = threadID
            self.workspaceID = workspaceID
            self.title = title
            self.botID = botID
            self.updatedAt = updatedAt
        }
    }

    /// Pure: row id -> short age ("4m") for rows whose displayed title repeats in the same list.
    nonisolated static func duplicateTitleAges(_ rows: [WorkspaceConversationRow], now: Date) -> [String: String] {
        let counts = rows.reduce(into: [String: Int]()) { $0[AgentThreadTitle.display($1.title), default: 0] += 1 }
        var out: [String: String] = [:]
        for row in rows where counts[AgentThreadTitle.display(row.title), default: 0] > 1 {
            let seconds = max(0, Int(now.timeIntervalSince(row.updatedAt)))
            out[row.id] = seconds < 60 ? "now" : seconds < 3600 ? "\(seconds / 60)m" : seconds < 86_400 ? "\(seconds / 3600)h" : "\(seconds / 86_400)d"
        }
        return out
    }

    /// Default title of a thread nobody has written in yet; "+ New conversation" covers it.
    nonisolated static let untitledThreadTitle = "New thread"

    /// Rows shown under one expanded workspace; the workspace row itself opens the full layout.
    nonisolated static let workspaceConversationLimit = 3
    /// Rows loaded per expanded workspace so "Show more" knows the hidden count.
    nonisolated static let workspaceConversationLoadLimit = 50

    /// What the Bots desk shows right now; nil unless the desk is the active surface.
    public struct DeskSelection: Equatable, Sendable {
        public let botID: BotID
        public let context: BotContext?
        public let threadID: AgentThreadID?
        nonisolated public init(botID: BotID, context: BotContext?, threadID: AgentThreadID?) {
            self.botID = botID
            self.context = context
            self.threadID = threadID
        }
    }

    /// Pure: the desk selection only counts while Bots owns the main content on its Chat screen.
    nonisolated static func deskSelection(
        isBotsSelected: Bool, screen: BotsScreen, botID: BotID?, context: BotContext?, threadID: AgentThreadID?
    ) -> DeskSelection? {
        guard isBotsSelected, screen == .desk, let botID else { return nil }
        return DeskSelection(botID: botID, context: context, threadID: threadID)
    }

    /// Pure: later rows beyond the cap still show when they are selected or running.
    nonisolated static func admitsConversation(shown: Int, id: AgentThreadID, always: Set<AgentThreadID>, limit: Int = workspaceConversationLimit) -> Bool {
        shown < limit || always.contains(id)
    }

    /// Pure: collapsed shows at most the cap, selected/running rows first; expanded keeps all.
    nonisolated static func visibleConversations(
        _ rows: [WorkspaceConversationRow], expanded: Bool, always: Set<AgentThreadID>
    ) -> (rows: [WorkspaceConversationRow], hidden: Int, showsToggle: Bool) {
        let limit = workspaceConversationLimit
        guard !expanded else { return (rows, 0, rows.count > limit) }
        let ordered = rows.filter { always.contains($0.threadID) } + rows.filter { !always.contains($0.threadID) }
        let visible = Array(ordered.prefix(limit))
        let hidden = rows.count - visible.count
        return (visible, hidden, hidden > 0)
    }

    /// Pure: the Bot behind the thread open in the Agent App; the listed row wins over the link cache.
    nonisolated static func botID(
        forSelectedThread threadID: AgentThreadID?,
        rows: [WorkspaceConversationRow],
        linkedBot: (AgentThreadID) -> BotID?
    ) -> BotID? {
        guard let threadID else { return nil }
        return rows.first { $0.threadID == threadID }?.botID ?? linkedBot(threadID)
    }

    /// Pure: a workspace Bot row lights up for the Desk selection or for its own linked thread open in that workspace's Agent App.
    nonisolated static func isWorkspaceBotHighlighted(
        botID: BotID, context: BotContext, desk: DeskSelection?,
        selectedWorkspace: WorkspaceID?, selectedThreadBot: BotID?
    ) -> Bool {
        if isBotConversationSelected(botID: botID, context: context, in: desk) { return true }
        guard let selectedWorkspace, selectedThreadBot == botID else { return false }
        return context == .workspace(selectedWorkspace)
    }

    /// Pure: a top-level Bot row also lights up while its linked thread is open in the Agent App.
    nonisolated static func isGeneralBotHighlighted(_ botID: BotID, desk: DeskSelection?, selectedThreadBot: BotID?) -> Bool {
        isGeneralBotSelected(botID, in: desk) || (desk == nil && selectedThreadBot == botID)
    }

    /// Pure: a Bot row spins while the Bot has a live run or its linked thread is running.
    /// Titio's sidebar badge is the same needs-you plus just-finished total as the
    /// pet's red dot and the Dock badge, so every surface shows one number.
    static func titioBadgeCount(_ counts: PetActivityCounts) -> Int {
        counts.isAvailable ? counts.badgeTotal : 0
    }

    nonisolated static func isBotRunning(_ botID: BotID, running: Set<BotID>, runningLinked: Set<BotID>) -> Bool {
        running.contains(botID) || runningLinked.contains(botID)
    }

    /// A top-level Bot row is selected for the General context (or a legacy unpinned chat).
    nonisolated static func isGeneralBotSelected(_ botID: BotID, in selection: DeskSelection?) -> Bool {
        guard let selection, selection.botID == botID else { return false }
        return selection.context == nil || selection.context == .general
    }

    /// A workspace Bot row is selected only for its own workspace context.
    nonisolated static func isBotConversationSelected(botID: BotID, context: BotContext, in selection: DeskSelection?) -> Bool {
        guard let selection, selection.botID == botID else { return false }
        return selection.context == context
    }

    /// Pure drag result: `dragged` leaves its slot and lands immediately before `target`.
    nonisolated static func reorderedBotIDs(_ ids: [BotID], moving dragged: BotID, before target: BotID) -> [BotID] {
        guard dragged != target, ids.contains(dragged), ids.contains(target) else { return ids }
        var next = ids.filter { $0 != dragged }
        next.insert(dragged, at: next.firstIndex(of: target) ?? next.endIndex)
        return next
    }

    /// Pure: untitled threads stay hidden unless they are running or open.
    nonisolated static func showsThread(title: String, id: AgentThreadID, keep: Set<AgentThreadID>) -> Bool {
        title != untitledThreadTitle || keep.contains(id)
    }

    /// Pure: an untitled thread with no message yet is a draft, not a conversation;
    /// it stays out of the sidebar unless it is open or running.
    nonisolated static func isEmptyDraft(title: String, id: AgentThreadID, keep: Set<AgentThreadID>, hasMessages: (AgentThreadID) -> Bool) -> Bool {
        let untitled = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == untitledThreadTitle
        return untitled && !keep.contains(id) && !hasMessages(id)
    }

    @Published public private(set) var generalBots: [GeneralBotRow] = []
    @Published public private(set) var virtualMachines: [BotVirtualMachine] = []
    @Published private(set) var runningBotIDs: Set<BotID> = [] {
        didSet { noteBotsSettled(was: oldValue.union(runningLinkedBotIDs)) }
    }
    @Published private(set) var deskSelection: DeskSelection?
    @Published private(set) var newBotConversationThreadID: AgentThreadID?
    private var draftMessageSink: AnyCancellable?
    @Published private(set) var runningThreadIDs: Set<AgentThreadID> = [] {
        didSet {
            let next = Self.finishedAfterTransition(previous: oldValue, now: runningThreadIDs, current: finishedThreadIDs,
                                                    except: selectedThreadID)
            if next != finishedThreadIDs { finishedThreadIDs = next }
        }
    }
    @Published private(set) var selectedThreadID: AgentThreadID?
    /// Bots whose linked thread is running now, from the coordinator snapshot.
    @Published private(set) var runningLinkedBotIDs: Set<BotID> = [] {
        didSet { noteBotsSettled(was: oldValue.union(runningBotIDs)) }
    }
    /// Child rows whose work just finished: a green dot until the user opens them,
    /// like the workspace row's completed dot.
    @Published private(set) var finishedThreadIDs: Set<AgentThreadID> = []
    @Published private(set) var finishedBotIDs: Set<BotID> = []
    @Published private(set) var finishedSurfaceIDs: Set<SurfaceID> = []

    /// Pure: what left the running set since the last snapshot gains a dot; what
    /// runs again loses it; the row on screen never gets one.
    nonisolated static func finishedAfterTransition<ID: Hashable>(previous: Set<ID>, now: Set<ID>, current: Set<ID>, except: ID?) -> Set<ID> {
        var result = current.union(previous.subtracting(now)).subtracting(now)
        if let except { result.remove(except) }
        return result
    }

    private func noteBotsSettled(was previous: Set<BotID>) {
        let next = Self.finishedAfterTransition(previous: previous, now: runningBotIDs.union(runningLinkedBotIDs),
                                                current: finishedBotIDs, except: deskSelection?.botID)
        if next != finishedBotIDs { finishedBotIDs = next }
    }
    /// Accessibility labels of threads / bots with an active Distill `/loop`.
    @Published private(set) var loopLabelsByThread: [AgentThreadID: String] = [:]
    @Published private(set) var loopLabelsByBot: [BotID: String] = [:]
    private var loopSink: AnyCancellable?
    private var selectedThreadSink: AnyCancellable?
    private weak var observedAgentSurface: AgentAppSurface?
    private var runEventSubscription: UUID?
    public var draggingBotID: BotID?
    @Published public var dropTargetBotID: BotID?
    private var runningBotsSink: AnyCancellable?
    private var deskSelectionSink: AnyCancellable?
    @Published public private(set) var workspaceConversations: [WorkspaceID: [WorkspaceConversationRow]] = [:]
    @Published private(set) var workspaceConversationBots: [BotID: BotDefinition] = [:]
    /// Disclosure state only: expanding never selects or opens a workspace.
    @Published public private(set) var expandedWorkspaceIDs: Set<WorkspaceID> = []
    /// Workspaces whose Conversations list shows every loaded row instead of the first few.
    @Published public private(set) var expandedConversationWorkspaces: Set<WorkspaceID> = []
    nonisolated static let expandedConversationWorkspacesKey = "sidebar.expandedConversationWorkspaces"

    nonisolated static func decodeExpandedConversationWorkspaces(_ raw: [String]?) -> Set<WorkspaceID> {
        Set((raw ?? []).compactMap { UUID(uuidString: $0).map(WorkspaceID.init) })
    }

    nonisolated static func encodeExpandedConversationWorkspaces(_ ids: Set<WorkspaceID>) -> [String] {
        ids.map(\.value.uuidString).sorted()
    }

    /// A workspace submenu section the user can hide.
    public enum WorkspaceSection: String, CaseIterable, Sendable {
        case conversations, bots, vms
        var title: String {
            switch self {
            case .conversations: return "Conversations"
            case .bots: return "Bots"
            case .vms: return "VMs"
            }
        }
    }

    /// Hidden submenu sections, keyed "<workspace uuid>:<section>"; persisted across relaunch.
    @Published public private(set) var collapsedWorkspaceSections: Set<String> = []
    nonisolated static let collapsedWorkspaceSectionsKey = "sidebar.collapsedWorkspaceSections"

    nonisolated static func workspaceSectionKey(_ id: WorkspaceID, _ section: WorkspaceSection) -> String {
        "\(id.value.uuidString):\(section.rawValue)"
    }

    public func isWorkspaceSectionCollapsed(_ id: WorkspaceID, _ section: WorkspaceSection) -> Bool {
        // A search shows every match, even in a hidden section.
        sidebarQuery.isEmpty && collapsedWorkspaceSections.contains(Self.workspaceSectionKey(id, section))
    }

    /// Bots/VMs lists the user expanded past the cap, keyed like `collapsedWorkspaceSections`; persisted.
    @Published public private(set) var expandedSectionLists: Set<String> = []
    nonisolated static let expandedSectionListsKey = "sidebar.expandedSectionLists"

    /// Pure: the first `limit` rows unless expanded; `hidden` counts the rest.
    nonisolated static func capped<T>(_ items: [T], expanded: Bool, limit: Int = workspaceConversationLimit) -> (rows: [T], hidden: Int) {
        guard !expanded, items.count > limit else { return (items, 0) }
        return (Array(items.prefix(limit)), items.count - limit)
    }

    /// Bots/VMs rows to draw under one workspace: capped, except while searching.
    func sectionSlice<T>(_ items: [T], _ id: WorkspaceID, _ section: WorkspaceSection) -> (rows: [T], hidden: Int, expanded: Bool) {
        let expanded = expandedSectionLists.contains(Self.workspaceSectionKey(id, section))
        guard sidebarQuery.isEmpty else { return (items, 0, false) }
        let slice = Self.capped(items, expanded: expanded)
        return (slice.rows, slice.hidden, expanded && items.count > Self.workspaceConversationLimit)
    }

    public func toggleSectionList(_ id: WorkspaceID, _ section: WorkspaceSection) {
        let key = Self.workspaceSectionKey(id, section)
        if expandedSectionLists.contains(key) { expandedSectionLists.remove(key) } else { expandedSectionLists.insert(key) }
        UserDefaults.standard.set(expandedSectionLists.sorted(), forKey: Self.expandedSectionListsKey)
    }

    public func toggleWorkspaceSection(_ id: WorkspaceID, _ section: WorkspaceSection) {
        let key = Self.workspaceSectionKey(id, section)
        if collapsedWorkspaceSections.contains(key) { collapsedWorkspaceSections.remove(key) } else { collapsedWorkspaceSections.insert(key) }
        UserDefaults.standard.set(collapsedWorkspaceSections.sorted(), forKey: Self.collapsedWorkspaceSectionsKey)
    }
    private var didSeedExpandedWorkspace = false
    /// Names the host in search results so equal names on different hosts stay distinguishable.
    public let hostDisplayName: String = Host.current().localizedName ?? "This Mac"

    @Published public var workspaces: [Workspace] = [] {
        didSet {
            busyStateCache.removeAll(keepingCapacity: true)
            busyTooltipCache.removeAll(keepingCapacity: true)
            busySurfaceTitlesCache.removeAll(keepingCapacity: true)
            filteredWorkspacesCache = nil
            refreshActiveSurfaceRows()
        }
    }
    /// Open tabs per workspace, listed under "Open Tabs" above Bots in an expanded workspace.
    @Published private(set) var activeSurfaceRows: [WorkspaceID: [ActiveSurfaceItem]] = [:]
    /// Tabs among `activeSurfaceRows` with work in flight; they get the spinner.
    @Published private(set) var busySurfaceIDs: Set<SurfaceID> = [] {
        didSet {
            let next = Self.finishedAfterTransition(previous: oldValue, now: busySurfaceIDs, current: finishedSurfaceIDs, except: nil)
            if next != finishedSurfaceIDs { finishedSurfaceIDs = next }
        }
    }
    /// PERF-MAC_SHELL_WINDOW-003: memoize per-workspace busy state for the
    /// lifetime of one `workspaces` snapshot so repeated SwiftUI `body`
    /// evaluations don't re-walk panes/surfaces (and the registry) on
    /// every render. Invalidated whenever `workspaces` is reassigned via
    /// `reload`, which is driven by the same mutations that change busy.
    private var busyStateCache: [WorkspaceID: Bool] = [:]
    /// Final tooltip keyed by workspace + running thread titles. Agent titles
    /// win without a SurfaceRegistry walk; surface titles are cached separately.
    private var busyTooltipCache: [WorkspaceID: (titles: [String], tooltip: String?)] = [:]
    private var busySurfaceTitlesCache: [WorkspaceID: [String]] = [:]
    /// Test seam: SurfaceRegistry walks performed for tooltips.
    var busySurfaceWalkCountForTesting = 0
    /// Test seam: inject running titles without a live coordinator run.
    var busyTooltipRunningTitlesOverrideForTesting: [WorkspaceID: [String]]?
    // PERF: filteredWorkspaces is recomputed on every SwiftUI body evaluation
    // and on the drag-scroll timer (16 Hz). Cache the last filtered result and
    // invalidate only when workspaces or filterText changes so repeated renders
    // without filter changes are O(1).
    private var filteredWorkspacesCache: [Workspace]?
    private func refreshActiveSurfaceRows() {
        let all = ActiveSurfaceProjector.items(workspaces: workspaces) { _ in true }
        let next = Dictionary(grouping: all, by: \.workspaceID)
        let busy = Set(Self.busyTabs(all) { SurfaceRegistry.shared.surface($0.surfaceID)?.isBusy == true }.map(\.surfaceID))
        if next != activeSurfaceRows { activeSurfaceRows = next }
        if busy != busySurfaceIDs { busySurfaceIDs = busy }
    }

    /// Browser page loads flicker on every navigation and are not user work, so they get no spinner.
    nonisolated static func busyTabs(_ items: [ActiveSurfaceItem], isBusy: (ActiveSurfaceItem) -> Bool) -> [ActiveSurfaceItem] {
        items.filter { $0.type != .browser && isBusy($0) }
    }

    /// The tab on screen in the selected workspace's focused pane; drives which sidebar row is selected.
    func visibleTab(in ws: Workspace) -> SurfaceDescriptor? {
        guard !isBotsSelected, selectedWorkspaceID == ws.id else { return nil }
        return Self.visibleTab(in: ws)
    }

    nonisolated static func visibleTab(in ws: Workspace) -> SurfaceDescriptor? {
        guard let pane = (ws.focusedPaneID ?? ws.layout.paneIDs().first).flatMap(ws.layout.find(paneID:)) else { return nil }
        return pane.surfaces.first { $0.id == pane.selectedSurfaceID }
    }

    func openActiveSurface(_ item: ActiveSurfaceItem) {
        finishedSurfaceIDs.remove(item.surfaceID)
        router?.windowController?.presentWorkspaceContent()
        try? router?.selectWorkspace(item.workspaceID)
        try? router?.focusSurface(workspace: item.workspaceID, surface: item.surfaceID)
    }

    /// UX-SIDEBAR-COMPLETED-DOT: workspaces whose in-progress action just finished
    /// (busy → idle) and that the user has not opened since. Drives the small
    /// "action completed" dot shown in the spinner's slot. Cleared when the
    /// workspace is selected.
    @Published public private(set) var completedWorkspaces: Set<WorkspaceID> = []
    /// Busy set captured on the previous `reload`, used to detect the busy → idle
    /// transition that marks an action as completed.
    private var previousBusyWorkspaces: Set<WorkspaceID> = []
    @Published public var selectedWorkspaceID: WorkspaceID?
    @Published public var selectedWorkspaceIDs: Set<WorkspaceID> = []
    /// True while the main content pane shows Schedule Tasks (not a workspace).
    @Published public var isScheduledTasksSelected: Bool = false
    /// True while the main content pane shows Active Threads (not a workspace).
    @Published public var isActiveThreadsSelected: Bool = false
    /// True while the main content pane shows Bots (not a workspace).
    @Published public var isBotsSelected: Bool = false
    /// True while the main content pane shows Settings (not a workspace).
    @Published public var isSettingsSelected: Bool = false
    /// Host-authoritative active agent thread count for the sidebar badge.
    @Published public private(set) var activeThreadCount: Int = 0
    @Published private(set) var activityCounts = PetActivityCounts.zero
    /// Bots running now, from the Bots model; shown with the Activity counts.
    @Published private(set) var activeBotCount = 0
    private var activeBotCountSink: AnyCancellable?
    private var botRosterSink: AnyCancellable?
    private var botEventSubscription: UUID?
    private var seenEventSubscription: UUID?
    @Published private(set) var workspaceActivityCounts: [String: PetActivityCounts] = [:]
    private var activityCountsObserver: UUID?
    /// Fired when the user activates a workspace row so the shell can leave
    /// the Schedule Tasks / Active Threads main-content destination.
    var onWorkspaceContentActivated: (() -> Void)?
    /// IMP-MAC_SHELL_WINDOW-009: free-text filter applied to the rendered
    /// workspace list. Empty string shows everything; matching is over
    /// name, description, and cwd. The backing `workspaces` array stays
    /// canonical so drag-reorder indices remain correct.
    @Published public var filterText: String = "" {
        didSet { if filterText != oldValue { filteredWorkspacesCache = nil } }
    }
    @Published public var privateAccountUser: PrivateAccountUser?
    @Published public var relayStatus: RelayHostStatus = RelayHostClient.currentStatus
    private var relayStatusObserver: NSObjectProtocol?
    @Published public var updateAvailability: AppUpdateAvailability = .unknown
    @Published public private(set) var insomniaEnabled: Bool = false
    @Published public private(set) var insomniaAllowDisplaySleep: Bool = true
    @Published public private(set) var insomniaAllowSystemSleepWhenDisplayClosed: Bool = false
    @Published public private(set) var insomniaAllowScreenSaverAfter45MinutesOfInactivity: Bool = true
    /// Provider account usage (Claude + Codex + Grok) for the sidebar card.
    @Published public private(set) var accountUsageSnapshot: ProviderUsageSnapshot = .empty()
    /// One entry per logged-in Distill account (several Claude logins are several rings).
    @Published public private(set) var accountUsageEntries: [AccountUsageEntry] = []
    private var accountStatusesSink: AnyCancellable?
    /// True while a background account-usage refresh (CLI probe) is in flight.
    @Published public private(set) var accountUsageIsRefreshing: Bool = false
    /// Timestamp of the last completed account-usage refresh, or nil when never refreshed.
    @Published public private(set) var accountUsageLastUpdated: Date? = nil
    public var draggingWorkspaceID: WorkspaceID?
    /// UX-MAC_SHELL_WINDOW-012: the row the drag is currently hovering,
    /// so the list can draw an insertion line instead of reordering live.
    @Published public var dropTargetWorkspaceID: WorkspaceID?
    /// :18 -- Edge auto-scroll direction during a drag. -1 = scroll up (near top),
    /// 0 = no scroll, +1 = scroll down (near bottom). Set by WorkspaceDropDelegate;
    /// observed by SidebarRootView to drive a timer-based NSScrollView scroll.
    ///
    /// `dropUpdated` reports the same direction on every drag tick (60-120 Hz)
    /// while the pointer stays in the edge zone, and `@Published` would rebuild
    /// the sidebar body on each of those identical writes. Same-value dedupe as
    /// `AgentComposerState.cursorOffset` (AA-13).
    public var dragScrollEdge: Int = 0 {
        willSet {
            guard newValue != dragScrollEdge else { return }
            objectWillChange.send()
        }
    }
    private var selectionAnchorID: WorkspaceID?
    /// Session-local undo stack for removed workspaces. Newest entry at end.
    /// Not persisted; cleared on app quit.
    private(set) var removedWorkspaceStack: [WorkspaceUndoEntry] = []
    /// PERF-MAC_SIDEBAR-001 (test seam): counts how many times
    /// Legacy test seam retained for source compatibility. Busy tooltips are
    /// now derived from live in-memory surfaces and must not read SQLite.
    var threadListCallCount: Int = 0
    /// PERF-MAC_SIDEBAR-002 (test seam): JSONDecoder of the private account
    /// session. `reload()` still peeks the settings blob so save+reload stays
    /// synchronous, but an unchanged blob must not decode or publish.
    var privateAccountLoadCount: Int = 0
    private var lastPrivateAccountJSON: String?
    private var didPeekPrivateAccountJSON = false
    private var privateAccountObserver: NSObjectProtocol?
    private var accountUsageObserver: NSObjectProtocol?
    private var accountUsageDistributedObserver: NSObjectProtocol?
    /// In-flight off-main reload of usage.json. A new notification cancels the
    /// prior task so a burst of usage changes coalesces into one read.
    private var accountUsageReloadTask: Task<Void, Never>?
    private var authorizedBotRowsTask: Task<Void, Never>?
    private var authorizedBotRowsGeneration: UInt64 = 0
    private var authorizedBotRowsNeedsRefresh = false
    private var authorizedBotRowsHostID: String?
    private var authorizedBotRowsWorkspaceIDs: Set<WorkspaceID>?
    var authorizedBotRowsLoaderForTesting: (@Sendable (BotStore, AgentThreadRepository, String, Set<WorkspaceID>) -> [AuthorizedBotConversationRow]?)?
    private let updateChecker: AppUpdateChecking?
    private let settingsStore: SettingsStore
    private let insomniaPower: InsomniaPowerManaging
    private let powerMonitor: ExternalPowerMonitoring
    private let insomniaBatteryPrompt: InsomniaBatteryPrompt
    private var lastPowerState: ExternalPowerState
    private var showingInsomniaBatteryPrompt = false

    public init(
        context: AppContext,
        router: AppCommandRouter,
        updateChecker: AppUpdateChecking? = nil,
        insomniaPower: InsomniaPowerManaging = MacOSInsomniaPowerManager(),
        powerMonitor: ExternalPowerMonitoring = MacOSExternalPowerMonitor(),
        insomniaBatteryPrompt: @escaping InsomniaBatteryPrompt = { completion in
            SidebarViewModel.defaultInsomniaBatteryPrompt(completion)
        },
        operationErrorPresenter: @escaping OperationErrorPresenter = SidebarViewModel.defaultOperationErrorPresenter
    ) {
        self.context = context
        self.router = router
        self.updateChecker = updateChecker
        self.updateAvailability = updateChecker?.availability ?? .unknown
        self.settingsStore = SettingsStore(db: context.db)
        self.insomniaPower = insomniaPower
        self.powerMonitor = powerMonitor
        self.insomniaBatteryPrompt = insomniaBatteryPrompt
        self.operationErrorPresenter = operationErrorPresenter
        self.lastPowerState = powerMonitor.currentPowerState
        self.expandedConversationWorkspaces = Self.decodeExpandedConversationWorkspaces(
            UserDefaults.standard.stringArray(forKey: Self.expandedConversationWorkspacesKey))
        self.collapsedWorkspaceSections = Set(
            UserDefaults.standard.stringArray(forKey: Self.collapsedWorkspaceSectionsKey) ?? [])
        self.expandedSectionLists = Set(
            UserDefaults.standard.stringArray(forKey: Self.expandedSectionListsKey) ?? [])
        self.relayStatusObserver = NotificationCenter.default.addObserver(
            forName: RelayHostClient.statusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let status = note.object as? RelayHostStatus else { return }
            Task { @MainActor in
                if self?.relayStatus != status { self?.relayStatus = status }
            }
        }
        self.privateAccountObserver = NotificationCenter.default.addObserver(
            forName: .rc2PrivateAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let viewModel = self else { return }
            Task { @MainActor in viewModel.reloadPrivateAccount() }
        }
        self.accountUsageObserver = NotificationCenter.default.addObserver(
            forName: .rc2AccountUsageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let viewModel = self else { return }
            Task { @MainActor in viewModel.reloadAccountUsage() }
        }
        self.accountUsageDistributedObserver =
            ProviderUsageCrossProcess.observeStoreChanged { [weak self] in
                guard let viewModel = self else { return }
                Task { @MainActor in viewModel.reloadAccountUsage() }
            }
        self.updateChecker?.onAvailabilityChanged = { [weak self] availability in
            self?.updateAvailability = availability
        }
        self.powerMonitor.onPowerStateChanged = { [weak self] state in
            self?.handleExternalPowerStateChanged(state)
        }
        self.powerMonitor.start()
        self.loopSink = context.distillLoopStore.$snapshot
            .map { snapshot in
                snapshot.compactMapValues { DistillLoopPresentation.sidebarAccessibilityLabel($0) }
            }
            .removeDuplicates()
            .sink { [weak self] labels in self?.applyLoopLabels(labels) }
        // :95 -- Wire the default AppKit prompter after self is available.
        // Tests replace workspacePrompter with a fake before calling any prompt path.
        workspacePrompter = AppKitWorkspacePrompter(viewModel: self)
        activityCountsObserver = PetActivityCountsProjection.shared.observe { [weak self] global, workspaces in
            // Each @Published write rebuilds the whole sidebar; write only what changed.
            guard let self else { return }
            if self.activityCounts != global { self.activityCounts = global }
            if self.workspaceActivityCounts != workspaces { self.workspaceActivityCounts = workspaces }
        }
        reload()
        reloadInsomnia()
        reloadAccountUsage()
        let accountsController = context.distillAccountsController
        accountStatusesSink = accountsController.$statuses
            .map(AccountUsageEntry.entries)
            .removeDuplicates()
            .sink { [weak self] entries in
                guard let self, self.accountUsageEntries != entries else { return }
                self.accountUsageEntries = entries
                // The iPhone rings and widget read the same account list.
                self.context?.publishAccountUsageDigestFromDisk()
            }
        if !accountsController.hasLoadedState { accountsController.refresh() }
    }

    deinit {
        if let relayStatusObserver {
            NotificationCenter.default.removeObserver(relayStatusObserver)
        }
        if let privateAccountObserver {
            NotificationCenter.default.removeObserver(privateAccountObserver)
        }
        if let accountUsageObserver {
            NotificationCenter.default.removeObserver(accountUsageObserver)
        }
        if let accountUsageDistributedObserver {
            ProviderUsageCrossProcess.removeObserver(accountUsageDistributedObserver)
        }
        accountUsageReloadTask?.cancel()
        authorizedBotRowsTask?.cancel()
        if let botEventSubscription { EventBus.shared.unsubscribe(botEventSubscription) }
        if let runEventSubscription { EventBus.shared.unsubscribe(runEventSubscription) }
        if let seenEventSubscription { EventBus.shared.unsubscribe(seenEventSubscription) }
        if let activityCountsObserver {
            Task { @MainActor in PetActivityCountsProjection.shared.removeObserver(activityCountsObserver) }
        }
        powerMonitor.stop()
        insomniaPower.releaseProcessAssertions()
    }

    private func reloadAuthorizedBotConversationRows() {
        guard let context else {
            authorizedBotRowsTask?.cancel()
            authorizedBotRowsTask = nil
            authorizedBotRowsGeneration &+= 1
            authorizedBotConversationRows = []
            virtualMachines = []
            return
        }
        let hostID = context.liveActivityHostIdentity.serverId
        let workspaceIDs = Set(context.state.workspaces.keys)
        if authorizedBotRowsTask != nil {
            guard authorizedBotRowsHostID == hostID, authorizedBotRowsWorkspaceIDs == workspaceIDs else {
                authorizedBotRowsGeneration &+= 1
                authorizedBotRowsTask?.cancel()
                authorizedBotRowsTask = nil
                authorizedBotRowsNeedsRefresh = false
                authorizedBotConversationRows = []
                authorizedBotRowsHostID = nil
                authorizedBotRowsWorkspaceIDs = nil
                return reloadAuthorizedBotConversationRows()
            }
            authorizedBotRowsNeedsRefresh = true
            return
        }
        let botStore = context.botStore
        let threadRepo = context.threadRepo
        let messageRepo = context.messageRepo
        if authorizedBotRowsHostID != hostID { virtualMachines = [] }
        authorizedBotRowsGeneration &+= 1
        let generation = authorizedBotRowsGeneration
        authorizedBotRowsNeedsRefresh = false
        authorizedBotRowsHostID = hostID
        authorizedBotRowsWorkspaceIDs = workspaceIDs
        let loader = authorizedBotRowsLoaderForTesting
        let expanded = expandedWorkspaceIDs.intersection(workspaceIDs)
        let includeHidden = router?.botsViewModel?.showHidden ?? false
        let live = context.coordinator.activeThreadIdsSnapshot()
        if live != runningThreadIDs { runningThreadIDs = live }
        var selectedThread: AgentThreadID?
        if !isBotsSelected, let wid = selectedWorkspaceID {
            selectedThread = router?.preferredAgentAppSurface(in: wid)?.viewModel.selectedThreadId
        }
        if selectedThread != selectedThreadID { selectedThreadID = selectedThread }
        bindSelectedThreadSurface()
        let keepUntitled = live.union(selectedThread.map { [$0] } ?? []).union(deskSelection?.threadID.map { [$0] } ?? [])
        authorizedBotRowsTask = Task { [weak self] in
            let (result, tree, linkedRunning, conversationBots) = await Task.detached {
                let rows = if let loader { loader(botStore, threadRepo, hostID, workspaceIDs) }
                else { Self.loadAuthorizedBotConversationRows(botStore: botStore, threadRepo: threadRepo, hostID: hostID, workspaceIDs: workspaceIDs) }
                let linkedRunning = Set(((try? botStore.conversationsLinked(to: live)) ?? [:]).values.map(\.botID))
                let tree = Self.loadSidebarTree(botStore: botStore, threadRepo: threadRepo, hostID: hostID, expanded: expanded, includeHidden: includeHidden, keepUntitled: keepUntitled,
                                               hasMessages: { (try? messageRepo.hasAny(threadId: $0)) ?? true })
                var conversationBots: [BotID: BotDefinition] = [:]
                if let tree {
                    for id in Set(tree.conversations.values.flatMap { $0.compactMap(\.botID) }) {
                        if let bot = try? botStore.get(id: id) { conversationBots[id] = bot }
                    }
                }
                return (rows, tree, linkedRunning, conversationBots)
            }.value
            guard let self, !Task.isCancelled, self.authorizedBotRowsGeneration == generation else { return }
            if self.authorizedBotRowsNeedsRefresh {
                self.authorizedBotRowsTask = nil
                self.authorizedBotRowsHostID = nil
                self.authorizedBotRowsWorkspaceIDs = nil
                self.reloadAuthorizedBotConversationRows()
                return
            }
            guard let currentContext = self.context,
                  currentContext.liveActivityHostIdentity.serverId == hostID,
                  Set(currentContext.state.workspaces.keys) == workspaceIDs else {
                self.authorizedBotRowsTask = nil
                self.authorizedBotRowsHostID = nil
                self.authorizedBotRowsWorkspaceIDs = nil
                if self.context != nil {
                    self.authorizedBotConversationRows = []
                    self.reloadAuthorizedBotConversationRows()
                } else {
                    self.authorizedBotConversationRows = []
                }
                return
            }
            if self.runningLinkedBotIDs != linkedRunning { self.runningLinkedBotIDs = linkedRunning }
            if let rows = result {
                if self.authorizedBotConversationRows != rows { self.authorizedBotConversationRows = rows }
            } else {
                self.authorizedBotConversationRows = []
            }
            // A failed read must not keep showing rows from an older authority snapshot.
            let general = tree?.general ?? [], conversations = tree?.conversations ?? [:]
            if self.generalBots != general { self.generalBots = general }
            let machines = tree?.virtualMachines ?? []
            if self.virtualMachines != machines { self.virtualMachines = machines }
            if self.workspaceConversations != conversations { self.workspaceConversations = conversations }
            if self.workspaceConversationBots != conversationBots { self.workspaceConversationBots = conversationBots }
            self.authorizedBotRowsTask = nil
            if self.authorizedBotRowsNeedsRefresh { self.reloadAuthorizedBotConversationRows() }
        }
    }

    func reloadAuthorizedBotConversationRowsAndWait() async {
        reloadAuthorizedBotConversationRows()
        while let task = authorizedBotRowsTask {
            await task.value
        }
    }

    nonisolated static func loadAuthorizedBotConversationRows(
        botStore: BotStore,
        threadRepo: AgentThreadRepository,
        hostID: String,
        workspaceIDs: Set<WorkspaceID>
    ) -> [AuthorizedBotConversationRow]? {
        do {
            let bots = BotOrdering.sorted(try botStore.list())
            var rows: [AuthorizedBotConversationRow] = []
            for bot in bots {
                for binding in try botStore.listContextBindings(hostID: hostID, botID: bot.id)
                where binding.state == .active && binding.actions.contains(.read) {
                    if case .workspace(let workspaceID) = binding.context, !workspaceIDs.contains(workspaceID) { continue }
                    let matching = try botStore.listConversations(botID: bot.id).compactMap { conversation -> (BotConversation, AgentThread)? in
                        guard !conversation.hidden, conversation.groupID == nil,
                              try botStore.authorizesConversation(conversation, hostID: hostID, action: .read),
                              let pin = try botStore.conversationContextPin(conversationID: conversation.id),
                              pin.hostID == hostID, pin.botID == bot.id, pin.context == binding.context,
                              pin.policyRevision == binding.policyRevision, pin.conversationID == conversation.id,
                              let threadID = conversation.linkedAgentThreadID,
                              let thread = try threadRepo.get(id: threadID),
                              thread.actor == .bot(bot.id), thread.actorLockedAt != nil,
                              thread.workspaceId == (binding.context == .general ? nil : workspaceID(for: binding.context)) else { return nil }
                        return (conversation, thread)
                    }.sorted {
                        if $0.0.updatedAt != $1.0.updatedAt { return $0.0.updatedAt > $1.0.updatedAt }
                        return $0.0.id.value.uuidString < $1.0.id.value.uuidString
                    }
                    let conversation = matching.first?.0
                    rows.append(AuthorizedBotConversationRow(botID: bot.id, botName: bot.name, handle: bot.handle, symbol: bot.avatarSymbol, context: binding.context, conversationID: conversation?.id, title: conversation?.title ?? "No conversations"))
                }
            }
            return rows
        } catch { return nil }
    }

    nonisolated static func loadSidebarTree(
        botStore: BotStore,
        threadRepo: AgentThreadRepository,
        hostID: String,
        expanded: Set<WorkspaceID>,
        includeHidden: Bool = false,
        keepUntitled: Set<AgentThreadID> = [],
        hasMessages: (AgentThreadID) -> Bool = { _ in true }
    ) -> (general: [GeneralBotRow], conversations: [WorkspaceID: [WorkspaceConversationRow]], virtualMachines: [BotVirtualMachine])? {
        do {
            // Titio, pinned, user drag order, then most recent.
            let bots = BotOrdering.sorted(try botStore.list(includeHidden: includeHidden))
            var general: [GeneralBotRow] = []
            var workspaceBots: [WorkspaceID: [BotDefinition]] = [:]
            for bot in bots {
                let bindings = try botStore.listContextBindings(hostID: hostID, botID: bot.id)
                if let workspaceID = Self.sidebarWorkspace(for: bot, bindings: bindings) { workspaceBots[workspaceID, default: []].append(bot) }
                guard Self.isGeneralBot(bot, bindings: bindings) else { continue }
                // Titio's badge is the global Activity total (see titioBadgeCount), not a count of its own.
                let unread = bot.handle == TitioIdentity.handle
                    ? 0
                    : ((try? botStore.listConversations(botID: bot.id)) ?? []).filter(\.unread).count
                general.append(GeneralBotRow(botID: bot.id, name: bot.name, handle: bot.handle, symbol: bot.avatarSymbol, pinned: bot.pinned, hidden: bot.hidden,
                                             unreadCount: bot.notificationsEnabled ? unread : 0))
            }
            var conversations: [WorkspaceID: [WorkspaceConversationRow]] = [:]
            for workspaceID in expanded {
                var rows: [WorkspaceConversationRow] = []
                for thread in try threadRepo.list(workspaceId: workspaceID)
                where !thread.isEphemeral && thread.parentThreadId == nil {
                    guard rows.count < Self.workspaceConversationLoadLimit || keepUntitled.contains(thread.id) else { continue }
                    guard !Self.isEmptyDraft(title: thread.title, id: thread.id, keep: keepUntitled, hasMessages: hasMessages) else { continue }
                    // Pinned Bot threads stay visible even when their generated title looks untitled.
                    let pin = try botStore.conversationContextPin(linkedTo: thread.id)
                    if let pin {
                        guard pin.hostID == hostID, pin.context == .workspace(workspaceID),
                              thread.actor == .bot(pin.botID), thread.actorLockedAt != nil,
                              let conversation = try botStore.conversation(id: pin.conversationID), !conversation.hidden,
                              conversation.botID == pin.botID, conversation.linkedAgentThreadID == thread.id,
                              try botStore.authorizesConversation(conversation, hostID: hostID, action: .read) else { continue }
                    } else if !Self.showsThread(title: thread.title, id: thread.id, keep: keepUntitled) {
                        continue
                    }
                    rows.append(WorkspaceConversationRow(threadID: thread.id, workspaceID: workspaceID, title: thread.title, botID: thread.actor.botID, updatedAt: thread.updatedAt))
                }
                let scopedBots = workspaceBots[workspaceID] ?? []
                if !scopedBots.isEmpty {
                    for bot in scopedBots {
                        rows += try Self.unpinnedBotRows(bot: bot, workspaceID: workspaceID, botStore: botStore, threadRepo: threadRepo)
                            .filter { !Self.isEmptyDraft(title: $0.title, id: $0.threadID, keep: keepUntitled, hasMessages: hasMessages) }
                    }
                    rows.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
                    var capped: [WorkspaceConversationRow] = []
                    for row in rows where capped.count < Self.workspaceConversationLoadLimit || keepUntitled.contains(row.threadID) {
                        capped.append(row)
                    }
                    rows = capped
                }
                conversations[workspaceID] = rows
            }
            return (general, conversations, try botStore.listVirtualMachines())
        } catch { return nil }
    }

    public func toggleWorkspaceExpanded(_ id: WorkspaceID) {
        // One workspace open at a time: expanding one collapses the rest.
        expandedWorkspaceIDs = expandedWorkspaceIDs.contains(id) ? [] : [id]
        reloadAuthorizedBotConversationRows()
    }

    public var sidebarQuery: String { filterText.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func botRowMatchesQuery(_ row: AuthorizedBotConversationRow) -> Bool {
        let query = sidebarQuery
        guard !query.isEmpty else { return true }
        return row.botName.range(of: query, options: .caseInsensitive) != nil
            || row.title.range(of: query, options: .caseInsensitive) != nil
    }

    /// The one sidebar search also filters General Bots by name or handle.
    public var visibleGeneralBots: [GeneralBotRow] {
        let query = sidebarQuery
        guard !query.isEmpty else { return generalBots }
        return generalBots.filter {
            $0.name.range(of: query, options: .caseInsensitive) != nil
                || $0.handle.range(of: query, options: .caseInsensitive) != nil
        }
    }

    /// Workspaces in the tree: name matches, or, while searching, a linked Bot matches.
    /// Display order: pinned rows stay first; among the rest, anything with a
    /// spinner moves up. Stable, so the user's order holds inside each group.
    nonisolated static func runningFirst<T>(_ items: [T], isPinned: (T) -> Bool = { _ in false }, isRunning: (T) -> Bool) -> [T] {
        let pinned = items.filter(isPinned)
        let rest = items.filter { !isPinned($0) }
        return pinned + rest.filter(isRunning) + rest.filter { !isRunning($0) }
    }

    public var treeWorkspaces: [Workspace] {
        guard !sidebarQuery.isEmpty else { return workspaces }
        let byName = Set(filteredWorkspaces.map(\.id))
        return workspaces.filter { ws in
            byName.contains(ws.id)
                || authorizedBotConversationRows.contains { $0.context == .workspace(ws.id) && botRowMatchesQuery($0) }
                || !virtualMachineRows(in: ws.id).isEmpty
        }
    }

    public func virtualMachineRows(in workspaceID: WorkspaceID?) -> [BotVirtualMachine] {
        virtualMachines.filter {
            $0.workspaceID == workspaceID
                && (sidebarQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(sidebarQuery))
        }
    }

    public func workspaceVirtualMachineRows(_ id: WorkspaceID) -> [BotVirtualMachine] {
        guard expandedWorkspaceIDs.contains(id) || !sidebarQuery.isEmpty else { return [] }
        return virtualMachineRows(in: id)
    }

    /// Bots linked to one workspace: shown when it is expanded, or as search results.
    public func workspaceBotRows(_ id: WorkspaceID) -> [AuthorizedBotConversationRow] {
        guard expandedWorkspaceIDs.contains(id) || !sidebarQuery.isEmpty else { return [] }
        return authorizedBotConversationRows.filter { $0.context == .workspace(id) && botRowMatchesQuery($0) }
    }

    /// An expanded workspace always leads its Conversations with "+ New conversation"; a search hides it.
    public func showsNewConversation(_ id: WorkspaceID) -> Bool {
        expandedWorkspaceIDs.contains(id) && sidebarQuery.isEmpty
    }

    public func workspaceConversationRows(_ id: WorkspaceID) -> [WorkspaceConversationRow] {
        guard expandedWorkspaceIDs.contains(id) else { return [] }
        let rows = workspaceConversations[id] ?? []
        let query = sidebarQuery
        guard !query.isEmpty else { return conversationSlice(id, rows).rows }
        return rows.filter { $0.title.range(of: query, options: .caseInsensitive) != nil }
    }

    private func conversationSlice(_ id: WorkspaceID, _ rows: [WorkspaceConversationRow]) -> (rows: [WorkspaceConversationRow], hidden: Int, showsToggle: Bool) {
        let always = runningThreadIDs.union(selectedThreadID.map { [$0] } ?? []).union(deskSelection?.threadID.map { [$0] } ?? [])
        return Self.visibleConversations(rows, expanded: expandedConversationWorkspaces.contains(id), always: always)
    }

    /// Show more / Show less state for one workspace; nil while searching or when nothing is hidden.
    public func conversationToggle(_ id: WorkspaceID) -> (hidden: Int, expanded: Bool)? {
        guard expandedWorkspaceIDs.contains(id), sidebarQuery.isEmpty else { return nil }
        let slice = conversationSlice(id, workspaceConversations[id] ?? [])
        guard slice.showsToggle else { return nil }
        return (slice.hidden, expandedConversationWorkspaces.contains(id))
    }

    public func toggleConversationsExpanded(_ id: WorkspaceID) {
        if expandedConversationWorkspaces.contains(id) { expandedConversationWorkspaces.remove(id) } else { expandedConversationWorkspaces.insert(id) }
        saveExpandedConversationWorkspaces()
    }

    /// An expanded workspace always leads its Bots with "+ New bot"; a search hides it.
    /// Open Tabs follow the workspace chevron like Bots and Conversations.
    func openTabRows(_ id: WorkspaceID) -> [ActiveSurfaceItem] {
        Self.openTabRows(activeSurfaceRows, id, expanded: expandedWorkspaceIDs)
    }

    nonisolated static func openTabRows(_ rows: [WorkspaceID: [ActiveSurfaceItem]], _ id: WorkspaceID, expanded: Set<WorkspaceID>) -> [ActiveSurfaceItem] {
        expanded.contains(id) ? rows[id] ?? [] : []
    }

    func hasWorkspaceChildren(_ id: WorkspaceID) -> Bool {
        !openTabRows(id).isEmpty || showsAddBot(id) || !workspaceBotRows(id).isEmpty
            || showsNewConversation(id) || !workspaceConversationRows(id).isEmpty
            || !workspaceVirtualMachineRows(id).isEmpty
    }

    /// The Bot that made this conversation, so its row shows the Bot's avatar instead of the chat icon.
    func conversationBot(_ row: WorkspaceConversationRow) -> BotDefinition? {
        guard let id = row.botID else { return nil }
        return router?.botsViewModel?.bots.first { $0.id == id } ?? workspaceConversationBots[id]
    }

    public func showsAddBot(_ id: WorkspaceID) -> Bool {
        expandedWorkspaceIDs.contains(id) && sidebarQuery.isEmpty
    }

    /// Follows the Agent App rail of the selected workspace so the row highlight needs no persistence round-trip.
    private func bindSelectedThreadSurface() {
        guard !isBotsSelected, let wid = selectedWorkspaceID,
              let surface = router?.preferredAgentAppSurface(in: wid) else {
            selectedThreadSink = nil
            observedAgentSurface = nil
            return
        }
        guard surface !== observedAgentSurface else { return }
        observedAgentSurface = surface
        selectedThreadSink = surface.viewModel.$selectedThreadId.dropFirst().removeDuplicates().sink { [weak self] id in
            self?.agentSelectedThreadChanged(id, in: wid)
        }
    }

    private func agentSelectedThreadChanged(_ id: AgentThreadID?, in wid: WorkspaceID) {
        guard !isBotsSelected, selectedWorkspaceID == wid else { return }
        if id != selectedThreadID { selectedThreadID = id }
        // $selectedThreadId publishes before the value lands; the reload reads the settled value.
        if let id, workspaceConversations[wid]?.contains(where: { $0.threadID == id }) != true {
            DispatchQueue.main.async { [weak self] in self?.reloadAuthorizedBotConversationRows() }
        }
    }

    /// Bot behind the thread open in the selected workspace's Agent App.
    var selectedThreadBotID: BotID? {
        guard let wid = selectedWorkspaceID, !isBotsSelected else { return nil }
        return Self.botID(forSelectedThread: selectedThreadID, rows: workspaceConversations[wid] ?? []) { [context] in
            context?.botStore.cachedBotID(linkedTo: $0)
        }
    }

    /// Run start/finish must flip spinners without waiting for another reload.
    nonisolated static let runEventKinds = ["agent.run.started", "agent.run.finished", "agent.run.completed", "agent.run.failed", "agent.run.cancelled"]

    private func applyLoopLabels(_ labels: [AgentThreadID: String]) {
        loopLabelsByThread = labels
        var byBot: [BotID: String] = [:]
        if let store = context?.botStore,
           let linked = try? store.conversationsLinked(to: Set(labels.keys)) {
            for (thread, conversation) in linked { byBot[conversation.botID] = labels[thread] }
        }
        loopLabelsByBot = byBot
    }

    nonisolated static func shouldActivateBotConversation(
        draft: AgentThreadID?, selected: AgentThreadID?, hasMessages: Bool
    ) -> Bool {
        draft != nil && draft == selected && hasMessages
    }

    func observeActiveBots(_ botsViewModel: BotsViewModel) {
        draftMessageSink = botsViewModel.$deskMessages.sink { [weak self, weak botsViewModel] messages in
            guard let self, Self.shouldActivateBotConversation(
                draft: self.newBotConversationThreadID,
                selected: botsViewModel?.selectedConversation?.linkedAgentThreadID,
                hasMessages: !messages.isEmpty
            ) else { return }
            self.newBotConversationThreadID = nil
        }
        activeBotCountSink = botsViewModel.$activeBotCount.removeDuplicates().sink { [weak self] count in
            self?.activeBotCount = count
        }
        runningBotsSink = botsViewModel.$liveRosterBotIDs.removeDuplicates().sink { [weak self] ids in
            self?.runningBotIDs = ids
        }
        deskSelectionSink = Publishers.CombineLatest4(
            $isBotsSelected, botsViewModel.$screen, botsViewModel.$selectedBotID, botsViewModel.$selectedConversation
        ).sink { [weak self] isBots, screen, botID, conversation in
            guard let self else { return }
            let context = conversation.flatMap { try? self.context?.botStore.conversationContextPin(conversationID: $0.id)?.context }
            let next = Self.deskSelection(isBotsSelected: isBots, screen: screen, botID: botID,
                                          context: context, threadID: conversation?.linkedAgentThreadID)
            if next != self.deskSelection {
                self.deskSelection = next
                self.reloadAuthorizedBotConversationRows()
            }
        }
        // Studio saves (name, avatar, pin, hide, delete) republish the roster.
        botRosterSink = botsViewModel.$bots.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.reloadAuthorizedBotConversationRows()
        }
        // RPC changes (paired phone, Titio's rc_host_call, context grants) land on the event bus.
        if runEventSubscription == nil {
            runEventSubscription = EventBus.shared.subscribeFromCurrent(filter: .kindPrefixes(Self.runEventKinds)) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reloadAuthorizedBotConversationRows() }
            }.id
        }
        // Opening a thread anywhere, or viewing/clearing it in Activity, drops its green dot.
        if seenEventSubscription == nil {
            seenEventSubscription = EventBus.shared.subscribeFromCurrent(
                filter: .kindPrefixes(["agent.thread.read", "notification.read"])
            ) { [weak self] event in
                let threads = Self.seenThreadIDs(kind: event.kind, payload: event.payload)
                let runs = Self.seenRunIDs(kind: event.kind, payload: event.payload)
                Task { @MainActor [weak self] in self?.clearFinished(threads: threads, runs: runs) }
            }.id
        }
        if botEventSubscription == nil {
            botEventSubscription = EventBus.shared.subscribeFromCurrent(
                filter: .kindPrefixes(["bot.created", "bot.deleted", "bot.updated", "bot.settings.updated", "bot.conversation.updated", "bots.attention.changed", "surface.updated"])
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reloadAuthorizedBotConversationRows() }
            }.id
        }
    }

    /// Pure: the thread an `agent.thread.read` event names.
    nonisolated static func seenThreadIDs(kind: String, payload: JSONValue) -> [AgentThreadID] {
        guard kind == "agent.thread.read",
              let raw = payload.objectValue?["thread_id"]?.stringValue, let uuid = UUID(uuidString: raw) else { return [] }
        return [AgentThreadID(uuid)]
    }

    /// Pure: runs an Activity view or clear marked seen; a reopen ("Undo") names none.
    nonisolated static func seenRunIDs(kind: String, payload: JSONValue) -> [AgentRunID] {
        guard kind == "notification.read", let object = payload.objectValue,
              ["viewed", "acknowledged"].contains(object["reason"]?.stringValue ?? "") else { return [] }
        return (object["activity_item_ids"]?.arrayValue ?? []).compactMap { value in
            guard let id = value.stringValue, id.hasPrefix("run:"), let uuid = UUID(uuidString: String(id.dropFirst(4))) else { return nil }
            return AgentRunID(uuid)
        }
    }

    private func clearFinished(threads: [AgentThreadID], runs: [AgentRunID]) {
        var seen = Set(threads)
        if !runs.isEmpty, let db = context?.db {
            seen.formUnion((try? AgentRunResultRepository(db: db).threadIDs(runIds: runs)) ?? [])
        }
        guard !seen.isEmpty else { return }
        let nextThreads = finishedThreadIDs.subtracting(seen)
        if nextThreads != finishedThreadIDs { finishedThreadIDs = nextThreads }
        let bots = Set(seen.compactMap { context?.botStore.cachedBotID(linkedTo: $0) })
        let nextBots = finishedBotIDs.subtracting(bots)
        if nextBots != finishedBotIDs { finishedBotIDs = nextBots }
    }

    /// "2 running · 1 need you", with "· 3 bots" when Bots are running.
    static func activitySubtitle(_ counts: PetActivityCounts, activeBots: Int) -> String {
        guard counts.isAvailable else { return "Activity unavailable" }
        var line = "\(counts.running) running · \(counts.needsYou) need you"
        if activeBots > 0 { line += " · \(activeBots) bot\(activeBots == 1 ? "" : "s")" }
        return line
    }

    /// Re-reads the General Bots list, e.g. after Show hidden changes.
    public func reloadGeneralBots() { reloadAuthorizedBotConversationRows() }

    /// Runs `action` once the Bots content is mounted: Edit, Delete and the Teams actions need it.
    private func withBotsContent(_ action: (BotsViewModel) -> Void) {
        guard let router else { return }
        router.windowController?.presentBotsInMainContent()
        if let botsViewModel = router.botsViewModel { action(botsViewModel) }
    }

    public func editBot(_ id: BotID) {
        guard let bot = try? context?.botStore.get(id: id) else { return }
        withBotsContent { $0.beginEdit(bot) }
    }

    public func requestDeleteBot(_ id: BotID) { withBotsContent { $0.pendingDeleteID = id } }

    public func duplicateBot(_ id: BotID) {
        guard let bot = try? context?.botStore.get(id: id) else { return }
        withBotsContent { $0.duplicateFromRoster(bot) }
    }

    public func setBotPinned(_ id: BotID, _ pinned: Bool) {
        router?.botsViewModel?.setPinned(id: id, pinned: pinned)
        reloadAuthorizedBotConversationRows()
    }

    /// Drops `dragged` just before `target` among the listed top-level Bots and persists the order.
    /// With `inWorkspace`, the move applies to the full Bot order so workspace rows keep every other Bot's slot.
    public func reorderBot(_ dragged: BotID, before target: BotID, inWorkspace: Bool = false) {
        defer { draggingBotID = nil; dropTargetBotID = nil }
        let current: [BotID]
        if inWorkspace {
            guard let all = try? context?.botStore.list(includeHidden: true) else { return }
            current = BotOrdering.sorted(all).map(\.id)
        } else {
            current = generalBots.map(\.botID)
        }
        let ids = Self.reorderedBotIDs(current, moving: dragged, before: target)
        guard ids != current else { return }
        if let botsViewModel = router?.botsViewModel {
            botsViewModel.reorderBots(orderedIDs: ids)
        } else {
            do { try context?.botStore.reorder(orderedIDs: ids) } catch { showOperationError("Could not reorder Bots", detail: error.localizedDescription) }
        }
        reloadAuthorizedBotConversationRows()
    }

    func botPinnedAndHidden(_ id: BotID) -> (pinned: Bool, hidden: Bool) {
        // Context menus build on every row paint.
        // Visible Bots come from the revision-cached roster; only hidden ones fall back to a row read.
        guard let store = context?.botStore,
              let bot = (try? store.listCached())?.first(where: { $0.id == id }) ?? (try? store.get(id: id)) ?? nil else { return (false, false) }
        return (bot.pinned, bot.hidden)
    }

    public func setBotHidden(_ id: BotID, _ hidden: Bool) {
        router?.botsViewModel?.setHidden(id: id, hidden: hidden)
        reloadAuthorizedBotConversationRows()
    }

    /// Opens the Teams manager.
    public func openTeams() { withBotsContent { $0.openTeamsManager() } }

    /// Opens the New Bot flow. From a workspace's "+ New bot" the Bot is exclusive to that workspace.
    public func addBot(inWorkspace workspaceID: WorkspaceID? = nil) {
        guard let router else { return }
        router.windowController?.presentBotsInMainContent()
        router.botsViewModel?.beginCreate(inWorkspace: workspaceID) { [weak self] in
            guard workspaceID != nil else { return }
            self?.reloadAuthorizedBotConversationRows()
            self?.reload()
        }
    }

    /// A General Bot opens its recent general conversation, or its Desk when it has none.
    public func openGeneralBot(_ row: GeneralBotRow) {
        finishedBotIDs.remove(row.botID)
        if let authorized = authorizedBotConversationRows.first(where: { $0.botID == row.botID && $0.context == .general }) {
            // General context: resume its conversation, or start one there; never a workspace transcript.
            return startBotConversation(authorized)
        }
        // A Bot without contextual General access opens its Desk exactly like the Bots roster does.
        do {
            guard let router, try router.openBotsDesk(botID: row.botID) else {
                showOperationError("Could not open Bot", detail: "This Bot is no longer available.")
                return reloadAuthorizedBotConversationRows()
            }
        } catch {
            showOperationError("Could not open Bot", detail: error.localizedDescription)
        }
    }

    /// The empty state of a linked Bot: start a conversation pinned to that workspace.
    public func startBotConversation(_ row: AuthorizedBotConversationRow) {
        finishedBotIDs.remove(row.botID)
        do {
            // A busy Bot reopens its live run; a second click must not spawn a duplicate.
            if let context, let router,
               let running = try Self.runningConversation(
                   try context.botStore.listConversations(botID: row.botID),
                   live: context.coordinator.activeThreadIdsSnapshot(),
                   pinContext: { try context.botStore.conversationContextPin(conversationID: $0)?.context },
                   context: row.context) {
                guard try router.openBotsDesk(botID: row.botID, conversationID: running.id) else {
                    showOperationError("Could not open Bot conversation", detail: "This Bot context is no longer available.")
                    return reloadAuthorizedBotConversationRows()
                }
                newBotConversationThreadID = nil
                reloadAuthorizedBotConversationRows()
                return
            }
            createBotConversation(row)
        } catch {
            showOperationError("Could not start conversation", detail: error.localizedDescription)
        }
    }

    /// "New conversation" with a General Bot: its general context when granted, else its Desk.
    public func startNewGeneralBotConversation(_ row: GeneralBotRow) {
        if let authorized = authorizedBotConversationRows.first(where: { $0.botID == row.botID && $0.context == .general }) {
            return startNewBotConversation(authorized)
        }
        openGeneralBot(row)
    }

    /// Starts a new conversation with the Bot even when one is already running (sidebar "New conversation" menu).
    public func startNewBotConversation(_ row: AuthorizedBotConversationRow) {
        finishedBotIDs.remove(row.botID)
        createBotConversation(row)
    }

    private func createBotConversation(_ row: AuthorizedBotConversationRow) {
        do {
            guard let router, try router.openBotsDesk(botID: row.botID),
                  let botsViewModel = router.botsViewModel,
                  botsViewModel.createDeskThread(in: row.context) else {
                showOperationError("Could not start conversation", detail: router?.botsViewModel?.errorMessage ?? "This Bot context is no longer available.")
                return reloadAuthorizedBotConversationRows()
            }
            newBotConversationThreadID = botsViewModel.selectedConversation?.linkedAgentThreadID
            reloadAuthorizedBotConversationRows()
        } catch {
            showOperationError("Could not start conversation", detail: error.localizedDescription)
        }
    }

    /// First visible, ungrouped conversation whose run is live and whose pin (if any) matches `context`.
    nonisolated static func runningConversation(
        _ conversations: [BotConversation],
        live: Set<AgentThreadID>,
        pinContext: (BotConversationID) throws -> BotContext?,
        context: BotContext
    ) rethrows -> BotConversation? {
        for conversation in conversations where !conversation.hidden && conversation.groupID == nil {
            guard let threadID = conversation.linkedAgentThreadID, live.contains(threadID) else { continue }
            let pin = try pinContext(conversation.id)
            if pin == nil || pin == context { return conversation }
        }
        return nil
    }

    /// First row of a workspace's Conversations: starts an Agent App thread there and opens it.
    public func newWorkspaceConversation(in workspaceID: WorkspaceID) {
        guard let router else { return }
        do {
            try router.createWorkspaceConversation(workspace: workspaceID)
            reloadAuthorizedBotConversationRows()
        } catch {
            showOperationError("Could not start conversation", detail: error.localizedDescription)
        }
    }

    /// Same canonical route as Activity: a Bot thread opens its Desk, any other thread its Agent App.
    public func renameConversation(_ row: WorkspaceConversationRow) {
        presentPromptSheet(title: "Rename conversation", message: "Enter a new conversation title.", initial: row.title) { [weak self] title in
            guard let self, let title else { return }
            do {
                _ = try self.router?.renameAgentThread(thread: row.threadID, title: title)
                self.reloadAuthorizedBotConversationRows()
            } catch {
                self.showOperationError("Could not rename conversation", detail: error.localizedDescription)
            }
        }
    }

    public func deleteConversation(_ row: WorkspaceConversationRow) {
        let alert = NSAlert()
        alert.messageText = "Delete conversation?"
        alert.informativeText = "This permanently deletes “\(row.title)” and its messages. Any active run will stop."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let router = self.router else { return }
            Task { @MainActor in
                do {
                    try await router.deleteAgentThread(thread: row.threadID)
                    if self.newBotConversationThreadID == row.threadID { self.newBotConversationThreadID = nil }
                    self.reloadAuthorizedBotConversationRows()
                } catch {
                    self.showOperationError("Could not delete conversation", detail: error.localizedDescription)
                }
            }
        }
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: complete) }
        else { complete(alert.runModal()) }
    }

    public func openWorkspaceConversation(_ row: WorkspaceConversationRow) {
        newBotConversationThreadID = nil
        finishedThreadIDs.remove(row.threadID)
        guard let router else { return }
        do {
            switch try router.agentThreadOpenDestination(row.threadID) {
            case .bot(let botID, let conversationID):
                // Bot threads open in the Bot's own Desk, not as an Agent App tab.
                _ = try router.openBotsDesk(botID: botID, conversationID: conversationID)
            case .workspace:
                _ = try router.openAgentThread(thread: row.threadID, markRead: false)
            case .unavailable:
                showOperationError("Could not open conversation", detail: "This conversation is no longer available.")
                reloadAuthorizedBotConversationRows()
            }
        } catch {
            showOperationError("Could not open conversation", detail: error.localizedDescription)
        }
    }

    nonisolated private static func workspaceID(for context: BotContext) -> WorkspaceID? {
        if case .workspace(let id) = context { return id }
        return nil
    }

    /// The workspace whose Conversations list a Bot's unpinned conversations: its own `workspaceID`
    /// when actively readable there, else the first readable workspace by UUID string. Nil when none.
    nonisolated static func sidebarWorkspace(for bot: BotDefinition, bindings: [BotContextBinding]) -> WorkspaceID? {
        let readable = bindings.compactMap { binding -> WorkspaceID? in
            guard binding.state == .active, binding.actions.contains(.read) else { return nil }
            return workspaceID(for: binding.context)
        }
        if let own = bot.workspaceID, readable.contains(own) { return own }
        return readable.min { $0.value.uuidString < $1.value.uuidString }
    }

    /// General Bots: Titio, Bots readable in General, and never-bound catalog Bots.
    nonisolated static func isGeneralBot(_ bot: BotDefinition, bindings: [BotContextBinding]) -> Bool {
        // Any workspace binding, even revoked, means the Bot was scoped: revoking must not move it to General.
        let workspaceScoped = bindings.contains { workspaceID(for: $0.context) != nil }
        let generalReadable = bindings.contains { $0.context == .general && $0.state == .active && $0.actions.contains(.read) }
        // Never-bound Bots are the pre-contextual catalog Bots the roster already lists; they open their Desk.
        return bot.handle == TitioIdentity.handle || generalReadable || (bindings.isEmpty && !workspaceScoped)
    }

    /// Inside a workspace only its own Bots and general Bots can be mentioned or consulted.
    nonisolated static func isAvailable(_ bot: BotDefinition, bindings: [BotContextBinding], inWorkspace workspace: WorkspaceID) -> Bool {
        isGeneralBot(bot, bindings: bindings) || sidebarWorkspace(for: bot, bindings: bindings) == workspace
    }

    /// The workspace a Bot's scheduled tasks group under and pin their runs to: the sidebar
    /// workspace, else the Bot's own `workspaceID`.
    nonisolated static func scheduleWorkspace(for bot: BotDefinition, botStore: BotStore, hostID: String) -> WorkspaceID? {
        let bindings = (try? botStore.listContextBindings(hostID: hostID, botID: bot.id)) ?? []
        return sidebarWorkspace(for: bot, bindings: bindings) ?? bot.workspaceID
    }

    /// A Bot's conversations that no context pin lists: plain threads it started (Desk first send,
    /// scheduled run, remote). Hidden, grouped and foreign-owned threads are excluded.
    nonisolated private static func unpinnedBotRows(
        bot: BotDefinition, workspaceID: WorkspaceID, botStore: BotStore, threadRepo: AgentThreadRepository
    ) throws -> [WorkspaceConversationRow] {
        try botStore.listConversations(botID: bot.id).compactMap { conversation -> WorkspaceConversationRow? in
            guard !conversation.hidden, conversation.groupID == nil,
                  let threadID = conversation.linkedAgentThreadID,
                  try botStore.conversationContextPin(linkedTo: threadID) == nil,
                  let thread = try threadRepo.get(id: threadID),
                  thread.workspaceId == nil, !thread.isEphemeral, thread.parentThreadId == nil,
                  thread.actor == .bot(bot.id) else { return nil }
            return WorkspaceConversationRow(threadID: threadID, workspaceID: workspaceID, title: thread.title, botID: bot.id, updatedAt: thread.updatedAt)
        }
    }

    public func openAuthorizedBotConversation(_ row: AuthorizedBotConversationRow) {
        newBotConversationThreadID = nil
        finishedBotIDs.remove(row.botID)
        guard let conversationID = row.conversationID, let context, let router else { return }
        do {
            guard let conversation = try context.botStore.conversation(id: conversationID),
                  conversation.botID == row.botID,
                  let pin = try context.botStore.conversationContextPin(conversationID: conversationID),
                  pin.hostID == context.liveActivityHostIdentity.serverId,
                  pin.botID == row.botID, pin.context == row.context,
                  let threadID = conversation.linkedAgentThreadID,
                  try AppCommandRouter.contextPinnedThreadDestination(threadID, context: context)
                    == .bot(row.botID, conversationID),
                  try router.openBotsDesk(botID: row.botID, conversationID: conversationID) else {
                showOperationError("Could not open Bot conversation", detail: "This Bot context is no longer available.")
                reloadAuthorizedBotConversationRows()
                return
            }
        } catch {
            showOperationError("Could not open Bot conversation", detail: error.localizedDescription)
            reloadAuthorizedBotConversationRows()
        }
    }

    private func saveExpandedConversationWorkspaces() {
        UserDefaults.standard.set(
            Self.encodeExpandedConversationWorkspaces(expandedConversationWorkspaces),
            forKey: Self.expandedConversationWorkspacesKey)
    }

    public func reload() {
        guard let ctx = context else { return }
        let loaded = (try? router?.listWorkspaces()) ?? ctx.state.window.workspaces.compactMap { ctx.state.workspaces[$0] }
        // The stored window order is the single order: pinned first, activity promotes
        // within a group, and a drag reorder lands here. Re-sorting would undo the drop.
        let ordered = loaded
        // Refresh the selection first so a workspace that completed AND became
        // selected this tick is correctly treated as "being viewed" (no dot).
        // While a shell destination owns the main content, keep every workspace
        // row deselected so the destination is unambiguous.
        let shellDestinationSelected = isScheduledTasksSelected || isActiveThreadsSelected || isBotsSelected || isSettingsSelected
        if shellDestinationSelected {
            if selectedWorkspaceID != nil { selectedWorkspaceID = nil }
            if !selectedWorkspaceIDs.isEmpty { selectedWorkspaceIDs.removeAll() }
            selectionAnchorID = nil
        } else if selectedWorkspaceID != ctx.state.window.selectedWorkspaceID {
            selectedWorkspaceID = ctx.state.window.selectedWorkspaceID
        }
        if !didSeedExpandedWorkspace, let selected = ctx.state.window.selectedWorkspaceID {
            didSeedExpandedWorkspace = true
            expandedWorkspaceIDs = [selected]
        }
        updateCompletedWorkspaces(from: ordered)
        if ordered != workspaces {
            workspaces = ordered
        }
        let liveExpanded = expandedConversationWorkspaces.intersection(Set(ordered.map(\.id)))
        if liveExpanded != expandedConversationWorkspaces {
            expandedConversationWorkspaces = liveExpanded
            saveExpandedConversationWorkspaces()
        }
        if !shellDestinationSelected {
            let nextIDs = selectedWorkspaceIDs.intersection(Set(workspaces.map(\.id)))
            if nextIDs != selectedWorkspaceIDs {
                selectedWorkspaceIDs = nextIDs
            }
        }
        refreshActiveCount()
        reloadAuthorizedBotConversationRows()
        // PF-13: the account blob is peeked once at mount. Later rereads are
        // driven by `.rc2PrivateAccountChanged`, not every refreshFromState.
        if !didPeekPrivateAccountJSON {
            reloadPrivateAccount()
        }
    }

    /// Refresh shared server counts after the current UI turn.
    func refreshActiveCount() {
        refreshActiveSurfaceRows()
        guard let router else { return }
        PetActivityCountsProjection.shared.refresh(router: router, workspaceIDs: workspaces.map(\.id))
    }

    /// UX-SIDEBAR-COMPLETED-DOT: detect workspaces whose action just finished and
    /// surface the completed dot. Uses the `busy` metadata that `listWorkspaces`
    /// already batch-computes (agent run / terminal job), so no extra DB work.
    private func updateCompletedWorkspaces(from list: [Workspace]) {
        var nowBusy = Set<WorkspaceID>()
        nowBusy.reserveCapacity(list.count)
        var existing = Set<WorkspaceID>()
        existing.reserveCapacity(list.count)
        for workspace in list {
            existing.insert(workspace.id)
            if workspace.metadata["busy"] == "true" {
                nowBusy.insert(workspace.id)
            }
        }
        let next = Self.completedWorkspacesAfterReload(
            previousBusy: previousBusyWorkspaces,
            nowBusy: nowBusy,
            current: completedWorkspaces,
            existing: existing,
            selected: selectedWorkspaceID)
        if next != completedWorkspaces {
            completedWorkspaces = next
        }
        previousBusyWorkspaces = nowBusy
    }

    /// Pure transition: a workspace that left the busy set since last reload just
    /// completed its action and earns a dot — unless it is the one the user is already
    /// viewing (selected). Currently-busy workspaces show a spinner instead, and
    /// entries for removed workspaces are dropped.
    nonisolated static func completedWorkspacesAfterReload(
        previousBusy: Set<WorkspaceID>,
        nowBusy: Set<WorkspaceID>,
        current: Set<WorkspaceID>,
        existing: Set<WorkspaceID>,
        selected: WorkspaceID?
    ) -> Set<WorkspaceID> {
        var result = current
        for id in previousBusy.subtracting(nowBusy) where id != selected {
            result.insert(id)
        }
        result.subtract(nowBusy)
        // The workspace the user is currently viewing never shows a dot, regardless of
        // how it was selected (click, keyboard, programmatic).
        if let selected { result.remove(selected) }
        result.formIntersection(existing)
        return result
    }

    /// Test seam: mark a workspace's action as completed so the completed-dot /
    /// clear-on-select behavior can be exercised without driving a full run.
    func markCompletedForTesting(_ id: WorkspaceID) {
        completedWorkspaces.insert(id)
    }

    private func reloadPrivateAccount() {
        guard let ctx = context else { return }
        let store = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let json = store.loadRawJSON()
        if didPeekPrivateAccountJSON, json == lastPrivateAccountJSON { return }
        didPeekPrivateAccountJSON = true
        lastPrivateAccountJSON = json
        privateAccountLoadCount += 1
        let next = store.session(fromJSON: json)?.user
        if next != privateAccountUser {
            privateAccountUser = next
        }
    }

    private func reloadInsomnia() {
        let settings = settingsStore.load()
        insomniaEnabled = settings.insomniaEnabled
        insomniaAllowDisplaySleep = settings.insomniaAllowDisplaySleep
        insomniaAllowSystemSleepWhenDisplayClosed = settings.insomniaAllowSystemSleepWhenDisplayClosed
        insomniaAllowScreenSaverAfter45MinutesOfInactivity = settings.insomniaAllowScreenSaverAfter45MinutesOfInactivity
        applyInsomniaPower()
    }

    /// Fire-and-forget reload used by the notification path. The usage.json
    /// read runs off the main actor and a fresh notification cancels the prior
    /// task, so a per-provider burst collapses to a single background read.
    private func reloadAccountUsage() {
        guard let context else {
            accountUsageReloadTask?.cancel()
            accountUsageReloadTask = nil
            applyAccountUsageSnapshot(.empty())
            return
        }
        let appSupport = context.appSupportDirectory
        accountUsageReloadTask?.cancel()
        accountUsageReloadTask = Task { [weak self] in
            let snapshot = await Self.loadAccountUsageSnapshot(appSupportDirectory: appSupport)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.applyAccountUsageSnapshot(snapshot)
            }
        }
    }

    /// Deterministic reload for tests and any caller that must observe the
    /// snapshot right after `await`. Not registered in `accountUsageReloadTask`,
    /// so a later notification cannot cancel it.
    func reloadAccountUsageAndWait() async {
        guard let context else {
            applyAccountUsageSnapshot(.empty())
            return
        }
        let snapshot = await Self.loadAccountUsageSnapshot(
            appSupportDirectory: context.appSupportDirectory
        )
        applyAccountUsageSnapshot(snapshot)
    }

    /// Publish only a changed snapshot so equal usage notifications do not
    /// rebuild the sidebar body.
    private func applyAccountUsageSnapshot(_ snapshot: ProviderUsageSnapshot) {
        if accountUsageSnapshot != snapshot {
            accountUsageSnapshot = snapshot
        }
    }

    private static func loadAccountUsageSnapshot(
        appSupportDirectory: URL
    ) async -> ProviderUsageSnapshot {
        await Task.detached {
            ProviderUsageStore(appSupportDirectory: appSupportDirectory).load()
        }.value
    }

    public func refreshAccountUsageForDetails() {
        guard !accountUsageIsRefreshing else { return }
        guard privateAccountUser != nil, let controller = context?.distillAccountsController else { return }
        accountUsageIsRefreshing = true
        Task { @MainActor [weak self] in
            await controller.refreshAllUsage()
            guard let self else { return }
            self.accountUsageIsRefreshing = false
            self.accountUsageLastUpdated = Date()
            self.context?.publishAccountUsageDigestFromDisk(isRefreshing: false)
        }
    }

    public func setInsomniaEnabled(_ enabled: Bool) {
        insomniaEnabled = enabled
        settingsStore.update {
            $0.insomniaEnabled = enabled
        }
        applyInsomniaPower()
    }

    public func setInsomniaAllowDisplaySleep(_ enabled: Bool) {
        insomniaAllowDisplaySleep = enabled
        settingsStore.update { $0.insomniaAllowDisplaySleep = enabled }
        applyInsomniaPower()
    }

    public func setInsomniaAllowSystemSleepWhenDisplayClosed(_ enabled: Bool) {
        insomniaAllowSystemSleepWhenDisplayClosed = enabled
        settingsStore.update { $0.insomniaAllowSystemSleepWhenDisplayClosed = enabled }
        applyInsomniaPower()
    }

    public func setInsomniaAllowScreenSaverAfter45MinutesOfInactivity(_ enabled: Bool) {
        insomniaAllowScreenSaverAfter45MinutesOfInactivity = enabled
        settingsStore.update { $0.insomniaAllowScreenSaverAfter45MinutesOfInactivity = enabled }
        applyInsomniaPower()
    }

    public func disableInsomniaForAppClose() {
        finishInsomniaSession()
    }

    public static func defaultInsomniaBatteryPrompt(
        _ completion: @escaping @MainActor (InsomniaBatteryDecision) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Insomnia is on while your MacBook is on battery"
        alert.informativeText = "Insomnia can drain the battery because it keeps this Mac awake. Do you want to keep Insomnia on or disable it now?"
        alert.addButton(withTitle: "Disable Insomnia")
        alert.addButton(withTitle: "Keep Insomnia On")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                completion(response == .alertFirstButtonReturn ? .disable : .keepEnabled)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            // No window to attach a sheet to. A modal run from a run-loop block
            // (never inside a main-queue job) still lets the main queue drain.
            RunLoop.main.perform { MainActor.assumeIsolated { finish(alert.runModal()) } }
        }
    }

    private func handleExternalPowerStateChanged(_ state: ExternalPowerState) {
        let previousPowerState = lastPowerState
        lastPowerState = state
        guard previousPowerState != .battery, state == .battery else { return }
        confirmInsomniaOnBatteryIfNeeded()
    }

    private func confirmInsomniaOnBatteryIfNeeded() {
        guard insomniaEnabled, !showingInsomniaBatteryPrompt else { return }
        showingInsomniaBatteryPrompt = true
        insomniaBatteryPrompt { [weak self] decision in
            guard let self else { return }
            self.showingInsomniaBatteryPrompt = false
            if decision == .disable, self.insomniaEnabled {
                self.setInsomniaEnabled(false)
            }
        }
    }

    private func applyInsomniaPower() {
        guard insomniaEnabled else {
            insomniaPower.deactivate()
            return
        }

        guard insomniaPower.activate(reason: "MacCode Insomnia", options: insomniaPowerOptions) else {
            NSLog("RemoteCode Insomnia failed to activate macOS power assertions.")
            finishInsomniaSession()
            // UX-P2: surface the failure so the user knows why the toggle snapped off.
            showOperationError(
                "Insomnia could not keep the display or system awake",
                detail: "macOS denied the power assertion. MacCode may use `pmset` to disable clamshell sleep, which requires administrator privileges. Insomnia has been turned off."
            )
            return
        }
    }

    private func finishInsomniaSession() {
        insomniaEnabled = false
        insomniaPower.deactivate()
        settingsStore.update {
            $0.insomniaEnabled = false
        }
    }

    private var insomniaPowerOptions: InsomniaPowerOptions {
        InsomniaPowerOptions(
            allowDisplaySleep: insomniaAllowDisplaySleep,
            allowSystemSleepWhenDisplayClosed: insomniaAllowSystemSleepWhenDisplayClosed,
            allowScreenSaverAfter45MinutesOfInactivity: insomniaAllowScreenSaverAfter45MinutesOfInactivity
        )
    }

    public func select(_ wid: WorkspaceID) {
        selectedWorkspaceIDs.removeAll()
        selectionAnchorID = wid
        selectedWorkspaceID = wid
        isScheduledTasksSelected = false
        isActiveThreadsSelected = false
        isBotsSelected = false
        isSettingsSelected = false
        // UX-SIDEBAR-COMPLETED-DOT: opening a workspace clears its completed dot.
        completedWorkspaces.remove(wid)
        if !expandedWorkspaceIDs.contains(wid) {
            expandedWorkspaceIDs = [wid]
            reloadAuthorizedBotConversationRows()
        }
        do {
            try router?.selectWorkspace(wid)
        } catch {
            // WHY: the highlight above is painted before the router call so a row
            // click feels immediate. A rejected select (stale row closed underneath
            // this list) must not leave that optimistic highlight claiming a
            // selection the app never made — snap the sidebar back to host truth.
            reload()
        }
        onWorkspaceContentActivated?()
    }

    /// Clears shift-range anchor when leaving workspaces for a shell destination.
    func clearSelectionAnchorForShellDestination() {
        selectionAnchorID = nil
    }

    public func selectWorkspaceRow(_ ws: Workspace, extendingSelection: Bool, togglingSelection: Bool = false) {
        if togglingSelection {
            toggleWorkspaceSelection(ws.id)
        } else if extendingSelection {
            extendWorkspaceSelection(to: ws.id)
        } else {
            select(ws.id)
        }
    }

    private func toggleWorkspaceSelection(_ id: WorkspaceID) {
        if selectedWorkspaceIDs.contains(id) {
            selectedWorkspaceIDs.remove(id)
        } else {
            selectedWorkspaceIDs.insert(id)
        }
        selectionAnchorID = id
    }

    private func extendWorkspaceSelection(to id: WorkspaceID) {
        let anchor = selectionAnchorID ?? selectedWorkspaceID ?? id
        // UX-SIDEBAR-P1-SHIFTRANGE: use filteredWorkspaces so a range selection
        // when a filter is active never includes workspaces the user cannot see.
        // Using the full `workspaces` array would produce a range spanning hidden
        // rows, causing "Remove" to silently delete workspaces outside the filter.
        let visible = treeWorkspaces
        guard let start = visible.firstIndex(where: { $0.id == anchor }),
              let end = visible.firstIndex(where: { $0.id == id }) else {
            selectedWorkspaceIDs.insert(id)
            selectionAnchorID = id
            return
        }
        let range = start <= end ? start...end : end...start
        selectedWorkspaceIDs = Set(range.map { visible[$0].id })
    }

    /// IMP-MAC_SHELL_WINDOW-009: the workspace rows to render, narrowed by
    /// `filterText`. Order matches the canonical `workspaces` array so the
    /// shown rows still carry the real workspace identities used by
    /// drag-reorder (which resolves indices against `workspaces`).
    public var filteredWorkspaces: [Workspace] {
        if let cached = filteredWorkspacesCache { return cached }
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return workspaces }
        let result = workspaces.filter { ws in
            // PERF: avoid per-entry lowercased() alloc on every keystroke — use case-insensitive range
            if ws.name.range(of: query, options: .caseInsensitive) != nil { return true }
            if let desc = ws.metadata["description"], desc.range(of: query, options: .caseInsensitive) != nil { return true }
            return ws.cwd.range(of: query, options: .caseInsensitive) != nil
        }
        filteredWorkspacesCache = result
        return result
    }

    public func newWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            _ = createWorkspaces(fromFolders: Self.uniqueFolderURLs(panel.urls, excluding: workspaces))
        }
    }

    @discardableResult
    public func createWorkspace(fromFolder url: URL) -> Bool {
        guard let router else { return false }
        // DEDUP-P2: if a workspace with the same cwd already exists, flash
        // to it instead of creating a duplicate (drag-drop / Open Recent /
        // Cmd+N all call this path).
        if let existing = Self.findExistingWorkspace(byCwd: url, in: workspaces) {
            select(existing)
            return true
        }
        do {
            _ = try router.createWorkspace(fromFolder: url)
            // UX-MAC_SHELL_WINDOW-005: remember opened folders so they
            // appear under File ▸ Open Recent on the next open.
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            reload()
            return true
        } catch {
            // WHY: a stale File ▸ Open Recent entry, or a folder moved/deleted
            // between the panel and the drop, used to close the panel and do
            // nothing at all — no row, no error, no explanation.
            operationErrorPresenter(
                "Could not add \(url.lastPathComponent)",
                Self.addWorkspaceFailureDetail(for: error)
            )
            return false
        }
    }

    /// User-facing reason a folder could not be added.
    ///
    /// `LayoutError.workspaceNotFound` describes itself generically ("Its
    /// workspace is closed or no longer exists."); on this path it means the
    /// picked folder is gone, so it gets a folder-specific reason.
    nonisolated public static func addWorkspaceFailureDetail(for error: Error) -> String {
        if let layoutError = error as? LayoutError, layoutError == .workspaceNotFound {
            return "That folder no longer exists. It may have been moved, renamed or deleted."
        }
        return error.localizedDescription
    }

    /// Pure helper: returns the ID of the first workspace in `workspaces`
    /// whose cwd resolves to the same standardized path as `url`, or nil if
    /// no match exists.  Path-normalized comparison handles trailing slashes
    /// and symlink-free canonicalization consistently with
    /// `AppCommandRouter.createWorkspace(fromFolder:)`.
    nonisolated public static func findExistingWorkspace(
        byCwd url: URL,
        in workspaces: [Workspace]
    ) -> WorkspaceID? {
        let normalized = url.standardizedFileURL.path
        return workspaces.first { ws in
            URL(fileURLWithPath: ws.cwd).standardizedFileURL.path == normalized
        }?.id
    }

    /// Pure helper: deduplicates a raw panel URL list before workspace-add.
    ///
    /// Removes:
    /// - intra-selection duplicates (same standardized path appearing more than
    ///   once, e.g. a folder and its alias both selected).
    /// - URLs whose cwd already exists in `workspaces` (reuses the same
    ///   path-normalization as `findExistingWorkspace(byCwd:in:)`).
    ///
    /// Input order is preserved.  This is the canonical single place for
    /// multi-folder add dedup; `newWorkspace()` passes the NSOpenPanel result
    /// here before calling `createWorkspaces(fromFolders:)`.
    nonisolated public static func uniqueFolderURLs(
        _ urls: [URL],
        excluding workspaces: [Workspace]
    ) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            guard findExistingWorkspace(byCwd: url, in: workspaces) == nil else { return nil }
            return url
        }
    }

    /// P2-SIDEBAR-SEPARATOR: Returns the index at which a pinned/unpinned
    /// divider should be inserted in `rows`, or `nil` when no divider is
    /// needed (empty list, all rows pinned, or no rows pinned).
    ///
    /// The index equals the count of leading pinned rows, i.e. the position
    /// of the first unpinned row.  Only rows whose metadata["pinned"] == "true"
    /// are considered pinned.
    nonisolated public static func pinnedSeparatorIndex(in rows: [Workspace]) -> Int? {
        guard !rows.isEmpty else { return nil }
        let count = rows.prefix(while: { $0.metadata["pinned"] == "true" }).count
        guard count > 0, count < rows.count else { return nil }
        return count
    }

    @discardableResult
    public func createWorkspaces(fromFolders urls: [URL]) -> Bool {
        urls.reduce(false) { created, url in
            createWorkspace(fromFolder: url) || created
        }
    }

    @discardableResult
    public func createWorkspaces(fromDroppedProviders providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                guard let url = Self.fileURL(fromDroppedItem: item) else { return }
                // UX-P2: reject non-folder drops; only directories can be workspaces.
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue else {
                    DispatchQueue.main.async {
                        self?.showOperationError(
                            "Cannot add \"\(url.lastPathComponent)\" as a workspace",
                            detail: "Only folders can be added as workspaces. Please drop a folder instead."
                        )
                    }
                    return
                }
                DispatchQueue.main.async {
                    _ = self?.createWorkspace(fromFolder: url)
                }
            }
        }
        return true
    }

    nonisolated static func fileURL(fromDroppedItem item: Any?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let data = item as? NSData {
            return URL(dataRepresentation: data as Data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }
        return nil
    }

    public func toggleSidebar() {
        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
    }

    public var showsUpdateControl: Bool {
        updateChecker != nil
    }

    public var updateActionTitle: String {
        switch updateAvailability {
        case .available:
            return "Update Available"
        case .checking:
            return "Checking for Updates"
        case .upToDate:
            return "Up to Date"
        case .failed:
            return "Update Check Failed"
        case .unknown:
            return "Check for Updates"
        }
    }

    public var updateActionEnabled: Bool {
        updateChecker != nil && updateAvailability != .checking
    }

    public var updateActionHighlighted: Bool {
        updateAvailability == .available
    }

    public func checkForUpdates() {
        updateChecker?.checkForUpdates()
    }

    public func openWorkspaceInNewWindow(_ ws: Workspace) {
        router?.openWorkspaceInNewWindow(ws.id)
    }

    public static func finderURL(for ws: Workspace) -> URL? {
        guard !ws.cwd.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: ws.cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: ws.cwd, isDirectory: true)
    }

    public func openWorkspaceInFinder(_ ws: Workspace) {
        guard let url = Self.finderURL(for: ws) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: cmux-style workspace editing (AppKit prompts — reliable,
    // no SwiftUI sheet plumbing).

    /// Builds and configures the NSAlert+accessoryView used by rename/description prompts.
    /// Pure setup -- no modal call. Separated so both the sheet and runModal paths
    /// share identical alert configuration.
    private func buildPromptAlert(title: String, message: String, initial: String, multiline: Bool) -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field: NSTextField
        if multiline {
            // UX-MAC_SHELL_WINDOW-006: descriptions get a taller, wrapping
            // field instead of a single-line entry.
            field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 84))
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.usesSingleLineMode = false
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
        } else {
            field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        }
        field.stringValue = initial
        field.placeholderString = title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return (alert, field)
    }

    /// :15 -- Presents a text-input prompt as a window sheet when a window is
    /// available. Falls back to runModal (blocking) when there is no key window
    /// (e.g. headless tests) so synchronous test callers are unaffected.
    ///
    /// WHY sheet: NSAlert.runModal() blocks all windows in the app, including
    /// detached workspace windows. beginSheetModal attaches the dialog to the
    /// specific window so other windows remain responsive.
    private func presentPromptSheet(title: String, message: String, initial: String, multiline: Bool = false, completion: @escaping (String?) -> Void) {
        let (alert, field) = buildPromptAlert(title: title, message: message, initial: initial, multiline: multiline)
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn
                    ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil)
            }
        } else {
            // Fallback: no window (headless / test). runModal is synchronous;
            // completion fires before this function returns.
            let response = alert.runModal()
            completion(response == .alertFirstButtonReturn
                ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil)
        }
    }

    public func renameWorkspace(_ ws: Workspace) {
        // :95 -- Route through workspacePrompter so tests can drive the decision.
        guard let prompter = workspacePrompter else { return }
        prompter.promptForText(
            title: "Rename workspace",
            message: "New name for \"\(ws.name)\".",
            initial: ws.name,
            multiline: false
        ) { [weak self] decision in
            guard let self else { return }
            guard case .committed(let name) = decision else { return }
            // UX-P3: whitespace-only rename must show an error rather than silently
            // doing nothing, so the user knows the save was rejected.
            guard !name.isEmpty else {
                self.showOperationError("Rename not saved",
                                       detail: "A workspace name cannot be blank. Please enter at least one non-whitespace character.")
                return
            }
            do {
                try self.router?.renameWorkspace(ws.id, name)
            } catch {
                self.showOperationError("Could not rename workspace", detail: error.localizedDescription)
            }
        }
    }

    public func editDescription(_ ws: Workspace) {
        // :95 -- Route through workspacePrompter so tests can drive the decision.
        guard let prompter = workspacePrompter else { return }
        let current = ws.metadata["description"] ?? ""
        prompter.promptForText(
            title: "Workspace description",
            message: "Optional note for \"\(ws.name)\".",
            initial: current,
            multiline: true
        ) { [weak self] decision in
            guard let self else { return }
            guard case .committed(let text) = decision else { return }
            do {
                try self.router?.setWorkspaceDescription(ws.id, text)
            } catch {
                self.showOperationError("Could not update description", detail: error.localizedDescription)
            }
        }
    }

    public func setWorkspaceColor(_ ws: Workspace, _ color: String) {
        try? router?.setWorkspaceColor(ws.id, color)
    }

    public func setWorkspacePinned(_ ws: Workspace, _ pinned: Bool) {
        try? router?.setWorkspacePinned(ws.id, pinned)
        reload()
    }

    public func isWorkspaceBusy(_ ws: Workspace) -> Bool {
        if let cached = busyStateCache[ws.id] { return cached }
        let busy = computeWorkspaceBusy(ws)
        busyStateCache[ws.id] = busy
        return busy
    }

    private func computeWorkspaceBusy(_ ws: Workspace) -> Bool {
        if ws.metadata["busy"] == "true" { return true }
        if let router { return router.isWorkspaceBusy(ws.id) }
        return ws.layout.paneIDs().contains { pid in
            (ws.layout.find(paneID: pid)?.surfaces ?? []).contains {
                guard SurfaceRegistry.shared.surface($0.id)?.isBusy == true else { return false }
                switch $0.type {
                case .terminal, .agentApp:
                    return true
                case .ssh, .browser, .files, .markdown, .filePreview, .rightSidebarTool:
                    return false
                }
            }
        }
    }

    // MARK: Row accessibility value

    /// Pure helper: builds the VoiceOver value string for a workspace row from
    /// pre-computed state flags.  Returns an empty string for an idle, normal row.
    ///
    /// - Parameters:
    ///   - busyDescription: output of `busyTooltip(...)`, or nil when idle.
    ///   - unreadCount: `ws.notificationsUnread`
    ///   - pinned: whether `ws.metadata["pinned"] == "true"`
    ///   - checked: whether the row is in `selectedWorkspaceIDs`
    nonisolated public static func workspaceRowAccessibilityValue(
        busyDescription: String?,
        unreadCount: Int,
        activityDescription: String? = nil,
        pinned: Bool,
        checked: Bool
    ) -> String {
        var parts: [String] = []
        if let desc = busyDescription { parts.append(desc) }
        if unreadCount > 0 { parts.append("\(unreadCount) unread") }
        if let activityDescription, !activityDescription.isEmpty { parts.append(activityDescription) }
        if pinned { parts.append("pinned") }
        if checked { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    // MARK: Busy tooltip

    /// Pure helper: derives a human-readable busy tooltip string from raw title
    /// lists. Thread-busy takes priority over surface-busy. Returns nil when
    /// neither list has entries (idle).
    ///
    /// - Parameters:
    ///   - runningThreadTitles: titles of agent threads whose status == .running
    ///   - busySurfaceTitles: titles of terminal/agentApp surfaces that are busy
    nonisolated public static func busyTooltip(
        runningThreadTitles: [String],
        busySurfaceTitles: [String]
    ) -> String? {
        if let first = runningThreadTitles.first {
            let display = first.isEmpty ? "Untitled" : first
            return "Agent run in thread \"\(display)\""
        }
        if let first = busySurfaceTitles.first {
            let display = first.isEmpty ? "surface" : first
            return "Activity running in \"\(display)\""
        }
        return nil
    }

    /// Thread titles take priority over surfaces. A walk is wasted whenever
    /// an agent is already running in the workspace (the common busy case).
    nonisolated public static func needsBusySurfaceWalk(runningThreadTitles: [String]) -> Bool {
        runningThreadTitles.isEmpty
    }

    /// Returns a tooltip string describing the active busy source for `ws`,
    /// or nil when the workspace is idle.
    public func busyTooltip(for ws: Workspace) -> String? {
        let runningThreadTitles = busyTooltipRunningTitlesOverrideForTesting?[ws.id]
            ?? context?.activeAgentThreadTitles(in: ws.id)
            ?? []
        if let cached = busyTooltipCache[ws.id], cached.titles == runningThreadTitles {
            return cached.tooltip
        }
        if !Self.needsBusySurfaceWalk(runningThreadTitles: runningThreadTitles) {
            let tooltip = Self.busyTooltip(
                runningThreadTitles: runningThreadTitles,
                busySurfaceTitles: []
            )
            busyTooltipCache[ws.id] = (runningThreadTitles, tooltip)
            return tooltip
        }
        let surfaceTitles: [String]
        if let cachedSurfaces = busySurfaceTitlesCache[ws.id] {
            surfaceTitles = cachedSurfaces
        } else {
            busySurfaceWalkCountForTesting += 1
            surfaceTitles = collectBusySurfaceTitles(ws)
            busySurfaceTitlesCache[ws.id] = surfaceTitles
        }
        let tooltip = Self.busyTooltip(
            runningThreadTitles: runningThreadTitles,
            busySurfaceTitles: surfaceTitles
        )
        busyTooltipCache[ws.id] = (runningThreadTitles, tooltip)
        return tooltip
    }

    private func collectBusySurfaceTitles(_ ws: Workspace) -> [String] {
        ws.layout.paneIDs().flatMap { pid -> [String] in
            guard let pane = ws.layout.find(paneID: pid) else { return [] }
            return pane.surfaces.compactMap { desc -> String? in
                guard SurfaceRegistry.shared.surface(desc.id)?.isBusy == true else { return nil }
                switch desc.type {
                case .terminal, .agentApp:
                    return desc.title
                case .ssh, .browser, .files, .markdown, .filePreview, .rightSidebarTool:
                    return nil
                }
            }
        }
    }

    public func reorderWorkspace(_ dragged: WorkspaceID, before target: WorkspaceID) {
        guard dragged != target,
              let targetIndex = workspaces.firstIndex(where: { $0.id == target }) else { return }
        try? router?.reorderWorkspace(dragged, position: targetIndex)
        draggingWorkspaceID = nil
        dropTargetWorkspaceID = nil
        dragScrollEdge = 0
        reload()
    }

    public func removeWorkspace(_ ws: Workspace) {
        // :95 -- Route through workspacePrompter so tests can drive the decision.
        // The AppKitWorkspacePrompter default preserves the :15 sheet/runModal fallback.
        guard let prompter = workspacePrompter else { return }
        prompter.confirmRemoveOne(name: ws.name) { [weak self] decision in
            guard let self, decision == .confirmed else { return }
            do {
                let entry = WorkspaceUndoEntry(name: ws.name, cwd: ws.cwd, metadata: ws.metadata)
                self.removedWorkspaceStack = WorkspaceUndoStack.push(entry, onto: self.removedWorkspaceStack)
                try self.router?.closeWorkspace(ws.id)
            } catch {
                // Roll back the undo push if close failed.
                self.removedWorkspaceStack = WorkspaceUndoStack.pop(from: self.removedWorkspaceStack)?.remaining ?? self.removedWorkspaceStack
                self.showOperationError("Could not remove workspace", detail: error.localizedDescription)
            }
        }
    }

    /// Pure helper: determines whether a context-menu gesture on `clickedID`
    /// should produce a multi-select menu or a single-row menu.
    ///
    /// Multi-select applies when the clicked row is already part of an explicit
    /// multi-item selection (>= 2 IDs in `selectedIDs`).  In that case the
    /// caller should show batch actions labelled with the returned count.
    /// Otherwise it falls through to the normal single-row actions so that
    /// right-clicking an unrelated row, or right-clicking when nothing is
    /// multi-selected, still shows the familiar per-workspace menu.
    ///
    /// - Returns: `(isMulti: true, count: N)` when batch menu is appropriate;
    ///            `(isMulti: false, count: 1)` otherwise.
    nonisolated public static func sidebarContextMenuMode(
        clickedID: WorkspaceID,
        selectedIDs: Set<WorkspaceID>
    ) -> (isMulti: Bool, count: Int) {
        guard selectedIDs.count >= 2, selectedIDs.contains(clickedID) else {
            return (isMulti: false, count: 1)
        }
        return (isMulti: true, count: selectedIDs.count)
    }

    public func pinSelectedWorkspaces(_ pinned: Bool) {
        let ids = selectedWorkspaceIDs
        guard !ids.isEmpty else { return }
        for id in ids {
            try? router?.setWorkspacePinned(id, pinned)
        }
        reload()
    }

    public func removeSelectedWorkspaces() {
        let ids = selectedWorkspaceIDs
        guard !ids.isEmpty else { return }
        var names: [String] = []
        names.reserveCapacity(ids.count)
        for ws in workspaces where ids.contains(ws.id) { names.append(ws.name) }
        // :95 -- Route through workspacePrompter so tests can drive the decision.
        // The AppKitWorkspacePrompter default preserves the :15 sheet/runModal fallback.
        guard let prompter = workspacePrompter else { return }
        prompter.confirmRemoveMany(count: ids.count, names: names) { [weak self] decision in
            guard let self, decision == .confirmed else { return }
            do {
                try self.router?.closeWorkspaces(Array(ids))
            } catch {
                self.showOperationError("Could not remove workspaces", detail: error.localizedDescription)
                return
            }
            self.selectedWorkspaceIDs.removeAll()
            self.selectionAnchorID = nil
            self.reload()
        }
    }

    // MARK: Error surfacing

    public static func defaultOperationErrorPresenter(message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        // :15 -- Sheet so other windows are not blocked by error presentation.
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func showOperationError(_ message: String, detail: String) {
        operationErrorPresenter(message, detail)
    }

    // MARK: Keyboard navigation

    /// Moves the selected workspace up or down by `delta` within `filteredWorkspaces`.
    public func moveSelection(by delta: Int) {
        let rows = treeWorkspaces
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex(where: { $0.id == selectedWorkspaceID }) ?? -1
        let next = max(0, min(rows.count - 1, currentIndex + delta))
        select(rows[next].id)
    }

    /// Opens the currently-selected workspace (no-op if none selected).
    public func openSelectedWorkspace() {
        guard let wid = selectedWorkspaceID else { return }
        select(wid)
    }

    /// Removes the currently-selected workspace after confirmation.
    public func removeSelectedWorkspace() {
        guard let wid = selectedWorkspaceID,
              let ws = workspaces.first(where: { $0.id == wid }) else { return }
        removeWorkspace(ws)
    }

    /// True when there is at least one removed workspace that can be undone.
    public var canUndoRemoveWorkspace: Bool {
        !removedWorkspaceStack.isEmpty
    }

    /// Recreates the most-recently-removed workspace (session-local undo).
    /// No-op when the stack is empty.
    public func undoRemoveWorkspace() {
        guard let (entry, remaining) = WorkspaceUndoStack.pop(from: removedWorkspaceStack) else { return }
        removedWorkspaceStack = remaining
        do {
            let restored = try router?.createWorkspace(name: entry.name, cwd: entry.cwd)
            if let id = restored?.id {
                if entry.metadata["pinned"] == "true" {
                    try? router?.setWorkspacePinned(id, true)
                }
                if let color = entry.metadata["color"], !color.isEmpty {
                    try? router?.setWorkspaceColor(id, color)
                }
                if let desc = entry.metadata["description"], !desc.isEmpty {
                    try? router?.setWorkspaceDescription(id, desc)
                }
            }
            reload()
        } catch {
            showOperationError("Could not restore workspace", detail: error.localizedDescription)
        }
    }
}

// MARK: - Workspace undo stack (pure; no AppKit/SwiftUI imports required for tests)

/// A snapshot of a workspace captured just before removal, enabling session-local undo.
public struct WorkspaceUndoEntry: Equatable, Sendable {
    public let name: String
    public let cwd: String
    public let metadata: [String: String]

    public init(name: String, cwd: String, metadata: [String: String]) {
        self.name = name
        self.cwd = cwd
        self.metadata = metadata
    }
}

/// Pure stack helpers for the removed-workspace undo feature.
/// Operates on a plain `[WorkspaceUndoEntry]` array; callers own the storage.
public enum WorkspaceUndoStack {
    /// Push a new entry onto the stack (newest at end).
    /// Returns the updated stack; entries beyond `maxDepth` are dropped from the front.
    public static func push(
        _ entry: WorkspaceUndoEntry,
        onto stack: [WorkspaceUndoEntry],
        maxDepth: Int = 10
    ) -> [WorkspaceUndoEntry] {
        var next = stack
        next.append(entry)
        if next.count > maxDepth {
            next.removeFirst(next.count - maxDepth)
        }
        return next
    }

    /// Pop the most-recently-removed entry.
    /// Returns `(entry, updatedStack)`, or `nil` when the stack is empty.
    public static func pop(
        from stack: [WorkspaceUndoEntry]
    ) -> (entry: WorkspaceUndoEntry, remaining: [WorkspaceUndoEntry])? {
        guard !stack.isEmpty else { return nil }
        var next = stack
        let entry = next.removeLast()
        return (entry, next)
    }
}

// MARK: - Selection highlight color resolver (pure; no AppKit/SwiftUI imports required for tests)

/// Describes how the sidebar should color a row's selection highlight.
public enum SidebarHighlightTone: Equatable {
    /// Use the workspace's own color (hex swatch, e.g. 0x7CC7FF).
    case workspaceColor(UInt32)
    /// Fall back to the generic selection tint (no workspace color).
    case selection
    /// Multi-select checkmark tint.
    case accent
    /// Unselected — no highlight.
    case none
}

/// Pure, nonisolated resolver: maps row state -> `SidebarHighlightTone`.
///
/// Priority: checked (multi-select) > workspace color when selected > generic selection > none.
public struct SidebarSelectionHighlightResolver {
    public init() {}

    /// - Parameters:
    ///   - colorKey: the workspace's "color" metadata value (empty / nil = no color).
    ///   - isSelected: whether this row is the primary selected workspace.
    ///   - isChecked: whether this row is part of a multi-selection.
    public func resolve(colorKey: String?, isSelected: Bool, isChecked: Bool) -> SidebarHighlightTone {
        if isChecked { return .accent }
        guard isSelected else { return .none }
        if let hex = TabColor.from(colorKey)?.hex {
            return .workspaceColor(hex)
        }
        return .selection
    }

    /// Convenience: build from a `Workspace` and the current selection state.
    public func resolve(workspace: Workspace, isSelected: Bool, isChecked: Bool) -> SidebarHighlightTone {
        resolve(colorKey: workspace.metadata["color"], isSelected: isSelected, isChecked: isChecked)
    }
}

// MARK: - Keyboard intent model (pure; no AppKit/SwiftUI import required for tests)

/// The action the sidebar should perform in response to a key event.
public enum SidebarAction: Equatable {
    case moveUp
    case moveDown
    case openSelected
    case removeSelected
    case focusFilter
    case clearFilter
}

/// Input descriptor for `SidebarKeyIntentMapper`.
/// Uses plain Swift types so the mapper and its tests need no UI imports.
public struct SidebarKeyInput: Equatable {
    public let character: Character
    public let commandDown: Bool
    public let optionDown: Bool
    public let shiftDown: Bool

    public init(character: Character, commandDown: Bool = false, optionDown: Bool = false, shiftDown: Bool = false) {
        self.character = character
        self.commandDown = commandDown
        self.optionDown = optionDown
        self.shiftDown = shiftDown
    }
}

/// Pure, nonisolated mapper from a key input to a `SidebarAction`.
/// Bindings:
///   ↑ / ↓          → moveUp / moveDown
///   Return (↩)     → openSelected
///   Cmd+Delete (⌫) → removeSelected
///   Cmd+F          → focusFilter
///   Escape         → clearFilter
public struct SidebarKeyIntentMapper {
    private static let upCharacter: Character = Character(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let downCharacter: Character = Character(UnicodeScalar(NSDownArrowFunctionKey)!)
    private static let returnCharacter: Character = "\r"
    private static let deleteCharacter: Character = Character(UnicodeScalar(NSDeleteFunctionKey)!)
    private static let backspaceCharacter: Character = "\u{7F}"
    private static let escapeCharacter: Character = "\u{1B}"

    public init() {}

    public func action(for input: SidebarKeyInput) -> SidebarAction? {
        switch (input.character, input.commandDown, input.optionDown, input.shiftDown) {
        case (Self.upCharacter, false, false, false):
            return .moveUp
        case (Self.downCharacter, false, false, false):
            return .moveDown
        case (Self.returnCharacter, false, false, false):
            return .openSelected
        case (Self.deleteCharacter, true, false, false),
             (Self.backspaceCharacter, true, false, false):
            return .removeSelected
        case ("f", true, false, false):
            return .focusFilter
        case (Self.escapeCharacter, false, false, false):
            return .clearFilter
        default:
            return nil
        }
    }
}

/// Shared sidebar action row used by Agentic and Bots so the two
/// modes paint the same chrome (height, type, badge).
struct SidebarActionRow: View {
    let symbol: String
    let title: String
    var isEmphasized: Bool = false
    var isSelected: Bool = false
    var badgeText: String? = nil
    var badgeIsBlue: Bool = false

    var body: some View {
        let highlight = isEmphasized || isSelected
        return HStack(spacing: DS.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: highlight ? .semibold : .regular))
                .frame(width: 20, height: 20)
                .foregroundColor(isEmphasized ? DS.Palette.warning : (isSelected ? DS.Palette.accent : DS.Palette.text))
            Group {
                let lines = title.split(separator: "\n", maxSplits: 1).map(String.init)
                if lines.count == 2 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lines[0]).font(DS.Font.body).lineLimit(1)
                        Text(lines[1]).font(DS.Font.caption2).lineLimit(1)
                    }
                } else {
                    Text(title).font(DS.Font.body).lineLimit(1)
                }
            }
            .fontWeight(highlight ? .semibold : .regular)
            .foregroundColor(isEmphasized ? DS.Palette.warning : (isSelected ? DS.Palette.text : DS.Palette.text))
            Spacer(minLength: 0)
            if let badgeText {
                Text(badgeText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, badgeText == "99+" ? 5 : 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Circle().fill(badgeIsBlue ? Color.blue : DS.Palette.danger))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: 42)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(
                    isEmphasized
                        ? DS.Palette.warning.opacity(0.16)
                        : (isSelected ? DS.Palette.selection : Color.white.opacity(0.001))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(isEmphasized ? DS.Palette.warning.opacity(0.55) : Color.clear,
                              lineWidth: DS.Border.hairline)
        )
    }
}

public struct SidebarRootView: View {
    private struct VirtualMachineRequest: Identifiable {
        let id = UUID()
        let workspaceID: WorkspaceID?
        var machine: BotVirtualMachine? = nil
    }

    @ObservedObject var vm: SidebarViewModel
    var botsVM: BotsViewModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsInsomniaOptions = false
    @State private var virtualMachineRequest: VirtualMachineRequest?
    /// Toggled to true to programmatically focus the filter field (Cmd+F).
    @State private var filterFocusRequest: Bool = false
    /// :18 -- Timer fires at ~16 Hz while vm.dragScrollEdge != 0 to scroll toward
    /// the top or bottom of the workspace list. Stored so we can invalidate it
    /// when the drag leaves the edge zone or the drop completes.
    @State private var dragScrollTimer: Timer? = nil
    /// Workspace whose "New conversation" popover is open.
    @State private var newConversationMenuWorkspace: WorkspaceID?
    private let onOpenSettings: () -> Void
    private let onOpenAccount: () -> Void
    private let onOpenScheduledTasks: () -> Void
    private let onOpenActiveThreads: () -> Void
    private let keyMapper = SidebarKeyIntentMapper()

    public init(
        vm: SidebarViewModel,
        botsVM: BotsViewModel? = nil,
        onOpenSettings: @escaping () -> Void = {},
        onOpenAccount: @escaping () -> Void = {},
        onOpenScheduledTasks: @escaping () -> Void = {},
        onOpenActiveThreads: @escaping () -> Void = {}
    ) {
        self.vm = vm
        self.botsVM = botsVM
        self.onOpenSettings = onOpenSettings
        self.onOpenAccount = onOpenAccount
        self.onOpenScheduledTasks = onOpenScheduledTasks
        self.onOpenActiveThreads = onOpenActiveThreads
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Spacer(minLength: 0)

                Button { vm.toggleSidebar() } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle sidebar")
                .accessibilityLabel("Toggle sidebar")
                .accessibilityIdentifier("shell.toggleSidebar")

                Button(action: reportBug) {
                    Image(systemName: "ladybug")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Report a bug via email")
                .accessibilityLabel("Report Bug")
                .accessibilityIdentifier("sidebar.reportBug")

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: vm.isSettingsSelected ? .semibold : .regular))
                        .foregroundColor(vm.isSettingsSelected ? DS.Palette.accent : DS.Palette.textSecondary)
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .fill(vm.isSettingsSelected ? DS.Palette.selection : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("sidebar.settings")
                .accessibilityAddTraits(vm.isSettingsSelected ? .isSelected : [])

                // Account usage sits left of the avatar it describes.
                AccountUsageSidebarControl(vm: vm, onOpenAccount: onOpenAccount)

                if vm.privateAccountUser != nil {
                    Button(action: onOpenAccount) {
                        headerAccountAvatar
                            .frame(width: 28, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(accountSubtitle)
                    .accessibilityLabel("Account")
                    .accessibilityValue(accountSubtitle)
                }
            }
            .padding(.horizontal, DS.Space.md)
            .frame(height: 44)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Menu {
                    Button { vm.newWorkspace() } label: { Label("New Workspace", systemImage: "folder.badge.plus") }
                        .accessibilityIdentifier("sidebar.newWorkspace")
                    Button { navigate { vm.addBot() } } label: { Label("New Bot", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("sidebar.newBot")
                    Button { virtualMachineRequest = VirtualMachineRequest(workspaceID: nil) } label: {
                        Label("New VM", systemImage: "desktopcomputer")
                    }
                    .accessibilityIdentifier("sidebar.newVM")
                } label: {
                    SidebarActionRow(symbol: "plus.circle", title: "New")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Create a workspace, Bot or VM")
                .accessibilityIdentifier("sidebar.new")

                Button { navigate(onOpenActiveThreads) } label: {
                    SidebarActionRow(
                        symbol: "bolt.horizontal.circle",
                        title: "Activity\n\(SidebarViewModel.activitySubtitle(vm.activityCounts, activeBots: vm.activeBotCount))",
                        isSelected: vm.isActiveThreadsSelected
                    )
                }
                .buttonStyle(.plain)
                .help(SidebarViewModel.activitySubtitle(vm.activityCounts, activeBots: vm.activeBotCount))
                .accessibilityIdentifier("sidebar.activity")
                .accessibilityLabel("Activity, " + SidebarViewModel.activitySubtitle(vm.activityCounts, activeBots: vm.activeBotCount))
                .accessibilityAddTraits(vm.isActiveThreadsSelected ? .isSelected : [])

                Button { navigate(onOpenScheduledTasks) } label: {
                    SidebarActionRow(
                        symbol: "calendar.badge.clock",
                        title: "Schedule Tasks",
                        isSelected: vm.isScheduledTasksSelected
                    )
                }
                .buttonStyle(.plain)
                .help("Create and manage scheduled Agent tasks")
                .accessibilityIdentifier("sidebar.scheduleTasks")
                .accessibilityAddTraits(vm.isScheduledTasksSelected ? .isSelected : [])

                if vm.showsUpdateControl {
                    Button { vm.checkForUpdates() } label: {
                        SidebarActionRow(
                            symbol: "arrow.down.circle",
                            title: vm.updateActionTitle,
                            isEmphasized: vm.updateActionHighlighted
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.updateActionEnabled)
                    .help(updateHelpText)
                }
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.bottom, DS.Space.lg)

            // IMP-MAC_SHELL_WINDOW-009: keep the filter available whenever
            // there are workspaces or Bots, but do not auto-focus it on sidebar load.
            if !vm.workspaces.isEmpty || !vm.generalBots.isEmpty || !vm.virtualMachines.isEmpty {
                workspaceFilterField
                    .padding(.horizontal, DS.Space.md)
                    .padding(.bottom, DS.Space.sm)
            }

            generalBotsSection

            HStack(spacing: DS.Space.sm) {
                Text("Workspaces")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer(minLength: 0)
                if !vm.selectedWorkspaceIDs.isEmpty {
                    Button("Remove") { vm.removeSelectedWorkspaces() }
                        .buttonStyle(.plain)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.danger)
                        .accessibilityIdentifier("sidebar.removeSelected")
                }
                SidebarSectionMoreMenu(help: "Workspace actions", accessibilityIdentifier: "sidebar.workspaces.more") {
                    Button { vm.newWorkspace() } label: { Label("New Workspace", systemImage: "folder.badge.plus") }
                        .accessibilityIdentifier("sidebar.workspaces.newWorkspace")
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.sm)

            // :18 -- ScrollViewReader exposes a proxy so the edge-scroll timer
            // can call scrollTo(first/last) while the user holds a drag near
            // the top or bottom edge of the list.
            ScrollViewReader { scrollProxy in
                ScrollView {
                    let rows = SidebarViewModel.runningFirst(vm.treeWorkspaces,
                                                             isPinned: { $0.metadata["pinned"] == "true" },
                                                             isRunning: vm.isWorkspaceBusy)
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                        if vm.workspaces.isEmpty {
                            Text("No workspaces")
                                .font(DS.Font.body)
                                .foregroundColor(DS.Palette.textTertiary)
                                .padding(.horizontal, DS.Space.md)
                                .padding(.vertical, DS.Space.sm)
                        } else if rows.isEmpty {
                            Text("No matches")
                                .font(DS.Font.body)
                                .foregroundColor(DS.Palette.textTertiary)
                                .padding(.horizontal, DS.Space.md)
                                .padding(.vertical, DS.Space.sm)
                        } else {
                            let separatorIdx = SidebarViewModel.pinnedSeparatorIndex(in: rows)
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, ws in
                                if index == separatorIdx {
                                    pinnedGroupDivider
                                }
                                workspaceRow(ws)
                                workspaceChildren(ws)
                            }
                        }
                        generalVirtualMachinesSection
                    }
                    .padding(.horizontal, DS.Space.sm)
                }
                .frame(maxHeight: .infinity)
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in
                    handleKeyPress(press)
                }
                // :18 -- Start/stop the edge-scroll timer whenever the drag
                // edge direction changes. The timer fires at ~16 Hz and scrolls
                // one step toward the edge until the pointer leaves the zone.
                .onChange(of: vm.dragScrollEdge) { edge in
                    dragScrollTimer?.invalidate()
                    dragScrollTimer = nil
                    guard edge != 0 else { return }
                    dragScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 16.0, repeats: true) { _ in
                        let rows = vm.filteredWorkspaces
                        guard !rows.isEmpty else { return }
                        if edge < 0, let first = rows.first {
                            scrollProxy.scrollTo(first.id, anchor: .top)
                        } else if edge > 0, let last = rows.last {
                            scrollProxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            accountFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Subtle liquid-glass: a near-transparent tint over the
        // NSVisualEffectView the host sits in (see SidebarView).
        .background(DS.Palette.surface.opacity(0.28))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.045))
                .frame(width: DS.Border.hairline)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            vm.createWorkspaces(fromDroppedProviders: providers)
        }
        // The sidebar material reaches the top edge; only its controls
        // start below the traffic-light band.
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .sheet(item: $virtualMachineRequest, onDismiss: { vm.reloadGeneralBots() }) { request in
            if let context = vm.context {
                BotVirtualMachinesView(
                    store: context.botStore,
                    workspaces: vm.workspaces,
                    initialWorkspaceID: request.workspaceID,
                    initialMachine: request.machine
                )
            }
        }
        // :18 -- The edge-scroll timer holds the ScrollViewProxy and is only
        // invalidated by the next dragScrollEdge change. If the sidebar goes
        // away mid-drag (window close, Agentic/Bots switch) nothing resets that
        // edge, so the 16 Hz timer would keep running against a dead view.
        .onDisappear {
            dragScrollTimer?.invalidate()
            dragScrollTimer = nil
        }
    }

    // MARK: Keyboard handling

    @discardableResult
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let modifiers = press.modifiers
        let input = SidebarKeyInput(
            character: press.key.character,
            commandDown: modifiers.contains(.command),
            optionDown: modifiers.contains(.option),
            shiftDown: modifiers.contains(.shift)
        )
        guard let action = keyMapper.action(for: input) else { return .ignored }
        switch action {
        case .moveUp:
            navigate { vm.moveSelection(by: -1) }
        case .moveDown:
            navigate { vm.moveSelection(by: 1) }
        case .openSelected:
            navigate { vm.openSelectedWorkspace() }
        case .removeSelected:
            vm.removeSelectedWorkspace()
        case .focusFilter:
            filterFocusRequest = true
        case .clearFilter:
            vm.filterText = ""
        }
        return .handled
    }

    /// Opens the system mail client to report a bug to the maintainer.
    private func reportBug() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "samuelfajreldines@gmail.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "MacCode Bug Report")
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private var workspaceFilterField: some View {
        SidebarSearchField(
            placeholder: "Search workspaces, Bots and VMs",
            text: $vm.filterText,
            focusRequest: $filterFocusRequest,
            accessibilityIdentifier: "sidebar.workspaceFilter"
        )
    }

    private var updateHelpText: String {
        switch vm.updateAvailability {
        case .available:
            return "Install the available MacCode update"
        case .checking:
            return "Checking for MacCode updates"
        case .upToDate:
            return "Check again for MacCode updates"
        case .failed(let message):
            return message
        case .unknown:
            return "Check for MacCode updates"
        }
    }

    private var accountFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(DS.Palette.line.opacity(0.55))
                .frame(height: DS.Border.hairline)

            if vm.privateAccountUser == nil {
                Button(action: onOpenAccount) {
                    HStack(spacing: DS.Space.md) {
                        accountAvatar
                        VStack(alignment: .leading, spacing: 1) {
                            Text(accountDisplayName)
                                .font(DS.Font.bodyStrong)
                                .foregroundColor(DS.Palette.text)
                                .lineLimit(1)
                            Text(accountSubtitle)
                                .font(DS.Font.caption2)
                                .foregroundColor(DS.Palette.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(width: 24, height: 24)
                    }
                    .padding(.horizontal, DS.Space.sm)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(Color.white.opacity(0.001))
                    )
                }
                .buttonStyle(.plain)
                .help("Sign in")
                .padding(.horizontal, DS.Space.md)
                .padding(.top, DS.Space.md)

                Rectangle()
                    .fill(Color.white.opacity(0.09))
                    .frame(height: DS.Border.hairline)
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.sm)
            }

            footerUtilityControls
        }
        .background(Color.white.opacity(0.025))
    }

    private var footerUtilityControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            insomniaControl
                .padding(.horizontal, DS.Space.md)
                .padding(.top, DS.Space.sm)
                .padding(.bottom, DS.Space.lg)
        }
    }

    // MARK: - Static seams (:15 :18 :186 :187 :188 :195)

    /// :15 -- Pure decision: maps an NSAlert response to a confirmed remove action.
    ///
    /// WHY separate: the confirmation logic (first button = proceed) must be
    /// testable without running a modal alert on the main thread. Extracted so
    /// both removeWorkspace and removeSelectedWorkspaces share identical semantics.
    ///
    /// - Returns: true when `response == .alertFirstButtonReturn` (Remove button),
    ///            false otherwise (Cancel or sheet dismissal).
    nonisolated public static func confirmRemoveDecision(response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    /// :18 -- Pure decision: maps a pointer Y position relative to a scroll view
    /// to an auto-scroll direction during a drag.
    ///
    /// WHY separate: the arithmetic is trivially testable without a real scroll
    /// view or drag event. The caller (WorkspaceDropDelegate.dropUpdated) passes
    /// real coordinates; tests pass arbitrary values.
    ///
    /// - Parameters:
    ///   - pointerY: pointer Y in the scroll view's coordinate space.
    ///     Y increases downward (AppKit window coords are flipped relative to
    ///     screen; convert before calling if needed).
    ///   - viewHeight: total height of the scroll view.
    ///   - edgeZone: distance from the top or bottom edge that triggers scroll.
    /// - Returns: -1 when pointer is in the top edge zone (scroll up),
    ///            +1 when in the bottom edge zone (scroll down), 0 otherwise.
    nonisolated public static func autoScrollDirection(
        pointerY: CGFloat,
        viewHeight: CGFloat,
        edgeZone: CGFloat
    ) -> Int {
        guard viewHeight > 0, edgeZone > 0 else { return 0 }
        if pointerY < edgeZone { return -1 }
        if pointerY > viewHeight - edgeZone { return 1 }
        return 0
    }

    /// :188 -- Human-readable "last updated" label for the account-usage
    /// timestamp row in the details popover.
    ///
    /// Returns "Never" when `date` is nil.
    /// Returns "Updated just now" when elapsed < 60 s.
    /// Returns "Updated Xm ago" for minutes, "Updated Xh ago" for hours.
    /// Capped at "Updated 24h+ ago" beyond 24 h so the string stays compact.
    ///
    /// WHY separate: the test can verify the label logic without a running VM or
    /// wall-clock dependency -- tests pass an explicit `now`.
    nonisolated public static func lastUpdatedLabel(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never" }
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 0 else { return "Updated just now" }
        if elapsed < 60 { return "Updated just now" }
        let mins = Int(elapsed / 60)
        if mins < 60 { return "Updated \(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "Updated \(hours)h ago" }
        return "Updated 24h+ ago"
    }

    /// Labels the slow provider-account probe explicitly so it cannot be mistaken
    /// for the local per-run usage signal shown elsewhere in the popover.
    nonisolated public static func accountUsageLastUpdatedLabel(
        _ date: Date?,
        now: Date
    ) -> String {
        let label = lastUpdatedLabel(date, now: now)
        guard label != "Never" else { return "Account usage not refreshed" }
        return label.replacingOccurrences(
            of: "Updated",
            with: "Account usage updated",
            options: [.anchored]
        )
    }

    /// P2-SIDEBAR-SEPARATOR: thin rule + "Pinned" caption rendered between
    /// the pinned and unpinned groups.
    private var pinnedGroupDivider: some View {
        HStack(spacing: DS.Space.sm) {
            Rectangle()
                .fill(DS.Palette.line.opacity(0.5))
                .frame(height: DS.Border.hairline)
            Text("Pinned")
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.top, DS.Space.xxs)
        .padding(.bottom, DS.Space.xxs)
        .accessibilityHidden(true)
    }

    private var insomniaHelpText: String {
        "Insomnia keeps this Mac awake while the toggle is on. Settings can allow display sleep, closed-display sleep, or the screen saver without ending the session."
    }

    /// At the 180pt minimum sidebar width the row fits only because the
    /// toggle's hit area carries its own inner margin (no extra row padding)
    /// and the summary line yields its width first.
    private var insomniaControl: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            insomniaToggle
            VStack(alignment: .leading, spacing: 1) {
                Text("Insomnia")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.text)
                    .fixedSize(horizontal: true, vertical: false)
                Text(insomniaStateSummary)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
            .help(insomniaHelpText)
            insomniaOptionsMenu
        }
        .frame(height: 40)
    }

    private var insomniaStateSummary: String {
        guard vm.insomniaEnabled else { return "Off" }
        var allowances: [String] = []
        if vm.insomniaAllowDisplaySleep { allowances.append("display can sleep") }
        if vm.insomniaAllowSystemSleepWhenDisplayClosed { allowances.append("sleep when closed") }
        if vm.insomniaAllowScreenSaverAfter45MinutesOfInactivity { allowances.append("screen saver after 45m") }
        return allowances.isEmpty ? "Mac stays awake" : allowances.joined(separator: " · ")
    }

    private var insomniaToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                vm.setInsomniaEnabled(!vm.insomniaEnabled)
            }
        } label: {
            ZStack(alignment: vm.insomniaEnabled ? .trailing : .leading) {
                Capsule()
                    .fill(vm.insomniaEnabled ? DS.Palette.danger : DS.Palette.surfaceRaised)
                    .overlay(
                        Capsule()
                            .stroke(vm.insomniaEnabled ? Color.clear : DS.Palette.lineStrong.opacity(0.7),
                                    lineWidth: DS.Border.hairline)
                    )
                Circle()
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 1)
                    .padding(2)
            }
            .frame(width: 32, height: 18)
        }
        .buttonStyle(.plain)
        // UX-SIDEBAR-P3-INSOMNIAHIT: 36x36 matches the adjacent options
        // chevron hit area; the previous 36x24 was inconsistent.
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
        .help(insomniaHelpText)
        .accessibilityLabel("Insomnia")
        .accessibilityValue(vm.insomniaEnabled ? "on" : "off")
        .accessibilityHint(insomniaHelpText)
        .accessibilityIdentifier("sidebar.insomnia.toggle")
    }

    private var insomniaOptionsMenu: some View {
        Button {
            showsInsomniaOptions.toggle()
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Palette.textTertiary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsInsomniaOptions, arrowEdge: .trailing) {
            insomniaOptionsPopover
        }
        .help(insomniaHelpText)
        .accessibilityLabel("Insomnia settings")
        .accessibilityIdentifier("sidebar.insomnia.options")
    }

    private var insomniaOptionsPopover: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Toggle("Allow display sleep", isOn: Binding(
                get: { vm.insomniaAllowDisplaySleep },
                set: { vm.setInsomniaAllowDisplaySleep($0) }
            ))
            Toggle("Allow system sleep when display is closed", isOn: Binding(
                get: { vm.insomniaAllowSystemSleepWhenDisplayClosed },
                set: { vm.setInsomniaAllowSystemSleepWhenDisplayClosed($0) }
            ))
            Toggle("Allow screen saver after 45m of inactivity", isOn: Binding(
                get: { vm.insomniaAllowScreenSaverAfter45MinutesOfInactivity },
                set: { vm.setInsomniaAllowScreenSaverAfter45MinutesOfInactivity($0) }
            ))
        }
        .toggleStyle(.checkbox)
        .font(DS.Font.body)
        .foregroundColor(DS.Palette.text)
        .padding(DS.Space.md)
    }

    private var accountAvatar: some View {
        accountAvatar(size: 28, textSize: 11)
    }

    private var headerAccountAvatar: some View {
        accountAvatar(size: 18, textSize: 7.5)
    }

    private func accountAvatar(size: CGFloat, textSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(vm.privateAccountUser == nil ? DS.Palette.surfaceRaised : DS.Palette.accent.opacity(0.22))
                .overlay(
                    Circle()
                        .stroke(DS.Palette.lineStrong.opacity(0.7), lineWidth: DS.Border.hairline)
                )
            Text(accountInitials)
                .font(.system(size: textSize, weight: .semibold))
                .foregroundColor(vm.privateAccountUser == nil ? DS.Palette.textSecondary : DS.Palette.accent)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if vm.privateAccountUser != nil {
                relayStatusBadge(size: max(6, size * 0.34))
            }
        }
    }

    private func relayStatusBadge(size: CGFloat) -> some View {
        Circle()
            .fill(relayStatusColor)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(DS.Palette.surface, lineWidth: max(1, size * 0.2)))
            .offset(x: size * 0.15, y: size * 0.15)
            .help(relayStatusText)
            .accessibilityLabel(relayStatusText)
    }

    private var relayStatusColor: Color {
        switch vm.relayStatus {
        case .connected: return DS.Palette.success
        case .connecting: return DS.Palette.warning
        case .offline, .subscriptionRequired: return DS.Palette.danger
        }
    }

    private var relayStatusText: String {
        switch vm.relayStatus {
        case .connected: return "Relay connected: your iPhone can reach this Mac from anywhere"
        case .connecting: return "Connecting to the relay…"
        case .offline: return "Relay offline: your iPhone can only reach this Mac on the same network"
        case .subscriptionRequired: return "Relay needs an active subscription: your iPhone can only reach this Mac on the same network"
        }
    }

    private var accountDisplayName: String {
        guard let email = vm.privateAccountUser?.email, let local = email.split(separator: "@").first, !local.isEmpty else {
            return "Sign in"
        }
        return String(local)
    }

    private var accountSubtitle: String {
        vm.privateAccountUser?.email ?? "MacCode Account"
    }

    private var accountInitials: String {
        guard let email = vm.privateAccountUser?.email else {
            return "RC"
        }
        var local = email.prefix(while: { $0 != "@" })
        if local.isEmpty {
            local = email.split(separator: "@").first ?? ""
        }
        var initials = ""
        initials.reserveCapacity(2)
        for scalar in local {
            if scalar.isLetter {
                initials.append(scalar)
                if initials.count == 2 { break }
            }
        }
        return initials.isEmpty ? "RC" : initials.uppercased()
    }

    // MARK: Row accessibility helpers

    /// Builds the VoiceOver value string for a workspace row by forwarding to
    /// the pure `SidebarViewModel.workspaceRowAccessibilityValue(...)` helper.
    private func workspaceRowAccessibilityValue(
        ws: Workspace,
        busy: Bool,
        checked: Bool,
        pinned: Bool
    ) -> String {
        let busyDesc = busy ? vm.busyTooltip(for: ws) : nil
        let activity = vm.workspaceActivityCounts[ws.id.description].map(Self.workspaceActivityLabel)
        return SidebarViewModel.workspaceRowAccessibilityValue(
            busyDescription: busyDesc,
            unreadCount: 0,
            activityDescription: activity,
            pinned: pinned,
            checked: checked
        )
    }

    static func workspaceActivityLabel(_ counts: PetActivityCounts) -> String {
        guard counts.isAvailable else { return "Activity unavailable" }
        if counts.running > 0 || counts.needsYou > 0 {
            return [counts.running > 0 ? "\(counts.running) running" : nil, counts.needsYou > 0 ? "\(counts.needsYou) needs you" : nil]
                .compactMap { $0 }.joined(separator: " · ")
        }
        return counts.newResults > 0 ? "New result" : ""
    }

    /// Leaving Bots content keeps drafts and asks before dropping an unsaved new Bot, from any sidebar row.
    private func navigate(_ action: @escaping () -> Void) {
        if vm.isBotsSelected, let botsVM { botsVM.leaveBots(then: action) } else { action() }
    }

    private func botContextLabel(_ context: BotContext) -> String {
        if case .workspace(let id) = context { return vm.workspaces.first { $0.id == id }?.name ?? "Workspace" }
        return "General"
    }

    private func botConversationRow(_ row: SidebarViewModel.AuthorizedBotConversationRow, tintHex: UInt32? = nil) -> some View {
        let selected = vm.newBotConversationThreadID != nil && vm.deskSelection?.threadID == vm.newBotConversationThreadID && vm.deskSelection?.botID == row.botID && vm.deskSelection?.context == row.context
        let running = SidebarViewModel.isBotRunning(row.botID, running: vm.runningBotIDs, runningLinked: vm.runningLinkedBotIDs)
        return Button {
            navigate { vm.startBotConversation(row) }
        } label: {
            HStack(spacing: DS.Space.sm) {
                BotsAvatarView(name: row.botName, handle: row.handle, symbol: row.symbol.isEmpty ? nil : row.symbol, size: 20, attention: running ? .working : .none, tintHex: tintHex)
                    .frame(width: 20, height: 20)
                Text(BotsViewModel.displayName(row.botName)).font(selected ? DS.Font.bodyStrong : DS.Font.body).foregroundColor(selected ? DS.Palette.text : DS.Palette.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
                if let loop = vm.loopLabelsByBot[row.botID] { loopGlyph(loop) }
                if running { DSBusySpinner(label: "Running") } else if vm.finishedBotIDs.contains(row.botID) { finishedDot }
            }
            .padding(.leading, Self.workspaceChildIndent)
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 30)
            .sidebarRowChrome(selected: selected)
            .overlay(alignment: .top) {
                if vm.dropTargetBotID == row.botID {
                    Capsule().fill(DS.Palette.accent).frame(height: 2).padding(.horizontal, DS.Space.sm)
                }
            }
        }
        .buttonStyle(.plain)
        .onDrag {
            vm.draggingBotID = row.botID
            return NSItemProvider(object: row.botID.value.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: BotDropDelegate(vm: vm, target: row.botID, inWorkspace: true))
        .help(searchHelp(type: "Bot", location: botContextLabel(row.context), name: row.conversationID == nil ? "\(row.botName): New conversation" : "\(row.botName), \(row.title)"))
        .accessibilityLabel("\(botContextLabel(row.context)), \(row.botName), \(row.title)")
        .accessibilityValue(running ? "Running" : "")
        .accessibilityIdentifier("sidebar.botConversation.\(row.id)")
        .contextMenu {
            let state = vm.botPinnedAndHidden(row.botID)
            Button(state.pinned ? "Unpin" : "Pin") { vm.setBotPinned(row.botID, !state.pinned) }
            Button(state.hidden ? "Unhide" : "Hide") { vm.setBotHidden(row.botID, !state.hidden) }
            Button("Edit in Studio") { navigate { vm.editBot(row.botID) } }
            Button("Duplicate") { navigate { vm.duplicateBot(row.botID) } }
            Divider()
            Button("Delete", role: .destructive) { navigate { vm.requestDeleteBot(row.botID) } }
        }
    }

    /// Bots: Titio pinned first, then general and unlinked Bots, in roster order.
    @ViewBuilder
    private var generalBotsSection: some View {
        let bots = SidebarViewModel.runningFirst(vm.visibleGeneralBots, isPinned: \.pinned) {
            SidebarViewModel.isBotRunning($0.botID, running: vm.runningBotIDs, runningLinked: vm.runningLinkedBotIDs)
        }
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.sm) {
                Text("Bots")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                SidebarSectionMoreMenu(help: "Bot actions", accessibilityIdentifier: "sidebar.bots.more") {
                    Button { navigate { vm.addBot() } } label: { Label("New Bot", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("sidebar.bots.newBot")
                    Button { vm.openTeams() } label: { Label("Teams", systemImage: "person.3") }
                        .accessibilityIdentifier("sidebar.teams")
                    if let botsVM {
                        Divider()
                        Toggle("Show hidden", isOn: Binding(
                            get: { botsVM.showHidden },
                            set: { botsVM.showHidden = $0; vm.reloadGeneralBots() }
                        ))
                        .accessibilityIdentifier("sidebar.generalBots.showHidden")
                    }
                }
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.bottom, DS.Space.xxs)
            if bots.isEmpty {
                Text(vm.generalBots.isEmpty ? "No bots" : "No matches")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textTertiary)
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, DS.Space.xs)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        ForEach(bots) { generalBotRow($0) }
                    }
                }
                .frame(maxHeight: min(CGFloat(bots.count) * 38, 190))
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.bottom, DS.Space.lg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.generalBots")
    }

    private func generalBotRow(_ row: SidebarViewModel.GeneralBotRow) -> some View {
        let selected = vm.newBotConversationThreadID != nil && vm.deskSelection?.threadID == vm.newBotConversationThreadID && vm.deskSelection?.botID == row.botID && vm.deskSelection?.context == .general
        let running = SidebarViewModel.isBotRunning(row.botID, running: vm.runningBotIDs, runningLinked: vm.runningLinkedBotIDs)
        let unread = row.isTitio ? SidebarViewModel.titioBadgeCount(vm.activityCounts) : row.unreadCount
        return Button { navigate { vm.openGeneralBot(row) } } label: {
            HStack(spacing: DS.Space.sm) {
                BotsAvatarView(name: row.name, handle: row.handle, symbol: row.symbol, size: 20, attention: running ? .working : .none)
                    .frame(width: 20, height: 20)
                Text(BotsViewModel.displayName(row.name)).font(selected ? DS.Font.bodyStrong : DS.Font.body).foregroundColor(DS.Palette.text).lineLimit(1)
                Spacer(minLength: 0)
                if running { DSBusySpinner(label: "Running") } else if vm.finishedBotIDs.contains(row.botID) { finishedDot }
                if unread > 0 { unreadBadge(unread) }
                if row.hidden {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
                if row.isTitio || row.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 34)
            .sidebarRowChrome(selected: selected)
            .overlay(alignment: .top) {
                if vm.dropTargetBotID == row.botID {
                    Capsule().fill(DS.Palette.accent).frame(height: 2).padding(.horizontal, DS.Space.sm)
                }
            }
        }
        .buttonStyle(.plain)
        .onDrag {
            vm.draggingBotID = row.botID
            return NSItemProvider(object: row.botID.value.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: BotDropDelegate(vm: vm, target: row.botID))
        .help(searchHelp(type: "General Bot", location: "General", name: row.name))
        .accessibilityLabel(BotsViewModel.displayName(row.name))
        .accessibilityValue("\(running ? "Running. " : "")\(unread > 0 ? "\(unread) unread. " : "")\(row.pinned ? "Pinned. " : "")\(row.hidden ? "Hidden. " : "")General Bot")
        .accessibilityIdentifier("sidebar.generalBot.\(row.handle)")
        .contextMenu {
            Button(row.pinned ? "Unpin" : "Pin") { vm.setBotPinned(row.botID, !row.pinned) }
            Button(row.hidden ? "Unhide" : "Hide") { vm.setBotHidden(row.botID, !row.hidden) }
            Button("Edit in Studio") { navigate { vm.editBot(row.botID) } }
            Button("Duplicate") { navigate { vm.duplicateBot(row.botID) } }
            Divider()
            Button("Delete", role: .destructive) { navigate { vm.requestDeleteBot(row.botID) } }
        }
    }

    /// Host, workspace and type for one row, so equal names stay distinguishable.
    private func searchHelp(type: String, location: String, name: String) -> String {
        "\(name) · \(type) · \(location) · \(vm.hostDisplayName)"
    }

    /// Section titles line up with the workspace folder icon (row inset `sm`); rows sit
    /// one `lg` step right of the title.
    private static let workspaceChildIndent = DS.Space.lg

    private var generalVirtualMachinesSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.sm) {
                Text("VMs")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityIdentifier("sidebar.generalVMs")
                Spacer(minLength: 0)
                SidebarSectionMoreMenu(help: "VM actions", accessibilityIdentifier: "sidebar.vms.more") {
                    Button("New VM") { virtualMachineRequest = VirtualMachineRequest(workspaceID: nil) }
                }
            }
            .padding(.horizontal, DS.Space.sm)
            ForEach(vm.virtualMachineRows(in: nil)) { virtualMachineRow($0) }
            if vm.virtualMachineRows(in: nil).isEmpty {
                Text(vm.filterText.isEmpty ? "No VMs" : "No matches")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textTertiary)
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, DS.Space.xs)
            }
        }
        .padding(.top, DS.Space.lg)
        .padding(.bottom, DS.Space.sm)
    }

    private func newVirtualMachineRow(workspaceID: WorkspaceID) -> some View {
        Button {
            virtualMachineRequest = VirtualMachineRequest(workspaceID: workspaceID)
        } label: {
            virtualMachineRowLabel("New VM", symbol: "plus", nested: true)
        }
        .buttonStyle(.plain)
        .help("Create a VM for this workspace")
        .accessibilityIdentifier("sidebar.newVM.\(workspaceID.value.uuidString)")
    }

    private func virtualMachineRow(_ machine: BotVirtualMachine) -> some View {
        Button {
            virtualMachineRequest = VirtualMachineRequest(workspaceID: machine.workspaceID, machine: machine)
        } label: {
            virtualMachineRowLabel(machine.name, symbol: "desktopcomputer", nested: machine.workspaceID != nil)
        }
        .buttonStyle(.plain)
        .help("Manage \(machine.name)")
        .accessibilityValue(machine.workspaceID == nil ? "General VM" : "Workspace VM")
        .accessibilityIdentifier("sidebar.vm.\(machine.id.uuidString.lowercased())")
    }

    private func virtualMachineRowLabel(_ title: String, symbol: String, nested: Bool) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .regular))
                .frame(width: 20, height: 20)
                .foregroundColor(DS.Palette.textTertiary)
            Text(title).font(DS.Font.body).foregroundColor(DS.Palette.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, nested ? Self.workspaceChildIndent : 0)
        .padding(.horizontal, DS.Space.sm)
        .frame(height: 30)
        .contentShape(Rectangle())
    }

    private func workspaceSectionHeader(_ title: String, id: String) -> some View {
        Text(title)
            .font(DS.Font.caption2)
            .foregroundColor(DS.Palette.textTertiary)
            .padding(.leading, DS.Space.sm)
            .padding(.top, DS.Space.xxs)
            .accessibilityIdentifier(id)
    }

    /// A section header that hides or shows its rows; the choice persists per workspace.
    private func collapsibleSectionHeader(_ section: SidebarViewModel.WorkspaceSection, workspace ws: Workspace, id: String) -> some View {
        let collapsed = vm.isWorkspaceSectionCollapsed(ws.id, section)
        return Button {
            if reduceMotion { vm.toggleWorkspaceSection(ws.id, section) }
            else { withAnimation(.easeOut(duration: 0.18)) { vm.toggleWorkspaceSection(ws.id, section) } }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Text(section.title)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .padding(.leading, DS.Space.sm)
            .padding(.top, DS.Space.xxs)
            .frame(minHeight: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show \(section.title)" : "Hide \(section.title)")
        .accessibilityLabel(section.title)
        .accessibilityValue(collapsed ? "Hidden" : "Shown")
        .accessibilityHint(collapsed ? "Shows this section" : "Hides this section")
        .accessibilityIdentifier(id)
    }

    /// Children sit on a darker inset panel so the workspace level reads apart from its contents.
    @ViewBuilder
    private func workspaceChildren(_ ws: Workspace) -> some View {
        if vm.hasWorkspaceChildren(ws.id) {
            // Hangs off the workspace row's square bottom edge, aligned with its left border
            // (the chevron column is 16 pt wide); the LazyVStack gap is cancelled so they touch.
            VStack(alignment: .leading, spacing: DS.Space.xxs) { workspaceChildRows(ws) }
                .padding(.vertical, DS.Space.xs)
                .environment(\.sidebarSubmenuRow, true)
                .padding(.leading, 16)
                .padding(.top, -DS.Space.xxs)
                .padding(.bottom, DS.Space.xs)
                .transition(.opacity)
        }
    }

    private func newConversationMenu(_ ws: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            newConversationMenuRow(title: "No Bot", subtitle: "Plain agent conversation", id: "sidebar.newConversation.noBot", action: {
                navigate { vm.newWorkspaceConversation(in: ws.id) }
            }) {
                AgentChoiceIconTile(systemName: "person.fill", tint: DS.Palette.textSecondary, size: 24)
            }
            AgentCompactMenuDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    AgentChoiceSectionHeader("Workspace bots")
                        .padding(.horizontal, DS.Space.sm)
                        .padding(.bottom, 2)
                    let bots = vm.workspaceBotRows(ws.id)
                    if bots.isEmpty {
                        Text("No bots in this workspace")
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                            .padding(.horizontal, DS.Space.sm)
                            .padding(.vertical, DS.Space.xs)
                    } else {
                        ForEach(bots) { row in
                            newConversationMenuRow(
                                title: row.botName,
                                subtitle: row.handle.isEmpty ? nil : "@\(row.handle)",
                                id: "sidebar.newConversation.bot.\(row.botID.value.uuidString)",
                                action: { navigate { vm.startNewBotConversation(row) } }
                            ) {
                                BotsAvatarView(name: row.botName, handle: row.handle, symbol: row.symbol.isEmpty ? nil : row.symbol, size: 24, tintHex: TabColor.from(ws.metadata["color"])?.hex)
                            }
                        }
                    }
                    let general = vm.generalBots.filter { !$0.hidden }
                    if !general.isEmpty {
                        AgentCompactMenuDivider()
                        AgentChoiceSectionHeader("General bots")
                            .padding(.horizontal, DS.Space.sm)
                            .padding(.bottom, 2)
                        ForEach(general) { row in
                            newConversationMenuRow(
                                title: BotsViewModel.displayName(row.name),
                                subtitle: row.handle.isEmpty ? nil : "@\(row.handle)",
                                id: "sidebar.newConversation.generalBot.\(row.botID.value.uuidString)",
                                action: { navigate { vm.startNewGeneralBotConversation(row) } }
                            ) {
                                BotsAvatarView(name: row.name, handle: row.handle, symbol: row.symbol.isEmpty ? nil : row.symbol, size: 24)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            AgentCompactMenuDivider()
            newConversationMenuRow(title: "New bot…", subtitle: nil, id: "sidebar.newConversation.newBot", action: {
                navigate { vm.addBot(inWorkspace: ws.id) }
            }) {
                AgentChoiceIconTile(systemName: "plus", tint: DS.Palette.accent, size: 24)
            }
        }
        .padding(DS.Space.sm)
        .frame(width: 260)
        .background(DS.Palette.surfaceOverlay)
        .accessibilityIdentifier("sidebar.newConversation.menu")
    }

    private func newConversationMenuRow<Leading: View>(
        title: String,
        subtitle: String?,
        id: String,
        action: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        Button {
            newConversationMenuWorkspace = nil
            action()
        } label: {
            HStack(spacing: DS.Space.md) {
                leading()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xs)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
            .dsHoverFill()
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// Open Tabs, followed by Conversations, Bots and VMs.
    @ViewBuilder
    private func workspaceChildRows(_ ws: Workspace) -> some View {
        if case let tabs = vm.openTabRows(ws.id), !tabs.isEmpty {
            workspaceSectionHeader("Open Tabs", id: "sidebar.workspaceOpenTabs.\(ws.id.value.uuidString)")
            let visible = vm.visibleTab(in: ws)?.id
            ForEach(SidebarViewModel.runningFirst(tabs) { vm.busySurfaceIDs.contains($0.surfaceID) }) {
                activeSurfaceRow($0, selected: $0.surfaceID == visible)
            }
        }
        if vm.showsNewConversation(ws.id) || !vm.workspaceConversationRows(ws.id).isEmpty {
            collapsibleSectionHeader(.conversations, workspace: ws, id: "sidebar.workspaceConversations.\(ws.id.value.uuidString)")
        }
        if !vm.isWorkspaceSectionCollapsed(ws.id, .conversations) {
        if vm.showsNewConversation(ws.id) {
            Button { newConversationMenuWorkspace = ws.id } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .regular))
                        .frame(width: 20, height: 20)
                        .foregroundColor(DS.Palette.textTertiary)
                    Text("New conversation").font(DS.Font.body).foregroundColor(DS.Palette.textSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, Self.workspaceChildIndent)
                .padding(.horizontal, DS.Space.sm)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(
                get: { newConversationMenuWorkspace == ws.id },
                set: { if !$0 { newConversationMenuWorkspace = nil } }
            ), arrowEdge: .trailing) {
                newConversationMenu(ws)
            }
            .help("Start a new conversation in \(ws.name)")
            .accessibilityIdentifier("sidebar.newConversation.\(ws.id.value.uuidString)")
        }
        let conversations = SidebarViewModel.runningFirst(vm.workspaceConversationRows(ws.id)) { vm.runningThreadIDs.contains($0.threadID) }
        let ages = SidebarViewModel.duplicateTitleAges(conversations, now: Date())
        ForEach(conversations) { workspaceConversationRow($0, workspace: ws, age: ages[$0.id]) }
        if let toggle = vm.conversationToggle(ws.id) {
            showMoreRow(expanded: toggle.expanded, hidden: toggle.hidden, noun: "conversations",
                        id: "sidebar.conversationsToggle.\(ws.id.value.uuidString)") { vm.toggleConversationsExpanded(ws.id) }
        }
        }
        if vm.showsAddBot(ws.id) || !vm.workspaceBotRows(ws.id).isEmpty {
            collapsibleSectionHeader(.bots, workspace: ws, id: "sidebar.workspaceBots.\(ws.id.value.uuidString)")
        }
        if !vm.isWorkspaceSectionCollapsed(ws.id, .bots) {
        if vm.showsAddBot(ws.id) {
            Button { navigate { vm.addBot(inWorkspace: ws.id) } } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .regular))
                        .frame(width: 20, height: 20)
                        .foregroundColor(DS.Palette.textTertiary)
                    Text("New bot").font(DS.Font.body).foregroundColor(DS.Palette.textSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, Self.workspaceChildIndent)
                .padding(.horizontal, DS.Space.sm)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Create a Bot exclusive to \(ws.name)")
            .accessibilityIdentifier("sidebar.addBot.\(ws.id.value.uuidString)")
        }
        let bots = vm.sectionSlice(SidebarViewModel.runningFirst(vm.workspaceBotRows(ws.id)) {
            SidebarViewModel.isBotRunning($0.botID, running: vm.runningBotIDs, runningLinked: vm.runningLinkedBotIDs)
        }, ws.id, .bots)
        ForEach(bots.rows) { botConversationRow($0, tintHex: TabColor.from(ws.metadata["color"])?.hex) }
        if bots.hidden > 0 || bots.expanded {
            showMoreRow(expanded: bots.expanded, hidden: bots.hidden, noun: "bots",
                        id: "sidebar.botsToggle.\(ws.id.value.uuidString)") { vm.toggleSectionList(ws.id, .bots) }
        }
        }
        if vm.showsNewConversation(ws.id) || !vm.workspaceVirtualMachineRows(ws.id).isEmpty {
            collapsibleSectionHeader(.vms, workspace: ws, id: "sidebar.workspaceVMs.\(ws.id.value.uuidString)")
        }
        if !vm.isWorkspaceSectionCollapsed(ws.id, .vms) {
        if vm.showsNewConversation(ws.id) {
            newVirtualMachineRow(workspaceID: ws.id)
        }
        let machines = vm.sectionSlice(vm.workspaceVirtualMachineRows(ws.id), ws.id, .vms)
        ForEach(machines.rows) { virtualMachineRow($0) }
        if machines.hidden > 0 || machines.expanded {
            showMoreRow(expanded: machines.expanded, hidden: machines.hidden, noun: "VMs",
                        id: "sidebar.vmsToggle.\(ws.id.value.uuidString)") { vm.toggleSectionList(ws.id, .vms) }
        }
        }

    }

    /// "Show more (N)" / "Show less" under a capped workspace list.
    private func showMoreRow(expanded: Bool, hidden: Int, noun: String, id: String, toggle: @escaping () -> Void) -> some View {
        Button {
            if reduceMotion { toggle() } else { withAnimation(.easeOut(duration: 0.18)) { toggle() } }
        } label: {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .regular))
                    .frame(width: 20, height: 20)
                    .foregroundColor(DS.Palette.textTertiary)
                Text(expanded ? "Show less" : "Show more (\(hidden))").font(DS.Font.body).foregroundColor(DS.Palette.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, Self.workspaceChildIndent)
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Show fewer \(noun)" : "Show \(hidden) more \(noun)")
        .accessibilityIdentifier(id)
    }

    private func activeSurfaceRow(_ item: ActiveSurfaceItem, selected: Bool) -> some View {
        let busy = vm.busySurfaceIDs.contains(item.surfaceID)
        return Button { navigate { vm.openActiveSurface(item) } } label: {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: Self.tabSymbol(item.type))
                    .font(.system(size: 11, weight: .regular))
                    .frame(width: 20, height: 20)
                    .foregroundColor(DS.Palette.textTertiary)
                Text(item.title).font(selected ? DS.Font.bodyStrong : DS.Font.body).foregroundColor(selected ? DS.Palette.text : DS.Palette.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
                if busy { DSBusySpinner(label: "Running") } else if vm.finishedSurfaceIDs.contains(item.surfaceID) { finishedDot }
            }
            .padding(.leading, Self.workspaceChildIndent)
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 30)
            .background(busy && !selected ? RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.text.opacity(0.06)) : nil)
            .sidebarRowChrome(selected: selected)
        }
        .buttonStyle(.plain)
        .help("Open \(item.title)")
        .accessibilityLabel(busy ? "\(item.title), running" : item.title)
        .accessibilityIdentifier("sidebar.activeSurface.\(item.surfaceID.value.uuidString)")
    }

    private static func tabSymbol(_ type: SurfaceType) -> String {
        switch type {
        case .terminal: return "terminal"
        case .ssh: return "network"
        case .browser: return "globe"
        case .files: return "folder"
        case .markdown, .filePreview: return "doc.text"
        case .rightSidebarTool: return "doc.text.magnifyingglass"
        case .agentApp: return "bubble.left"
        }
    }

    /// Red like the pet's needs-you dot.
    private func unreadBadge(_ count: Int) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(DS.Font.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(Color.red))
            .help("\(count) unread")
            .accessibilityHidden(true)
            .accessibilityIdentifier("sidebar.unreadBadge")
    }

    private var finishedDot: some View {
        Circle()
            .fill(DS.Palette.success)
            .frame(width: 7, height: 7)
            .frame(width: 16, height: 16)
            .help("Just finished")
            .accessibilityLabel("Just finished")
            .accessibilityIdentifier("sidebar.finishedDot")
    }

    private func loopGlyph(_ label: String) -> some View {
        Image(systemName: DistillLoopPresentation.sidebarSymbol)
            .font(.system(size: 10, weight: .regular))
            .foregroundColor(DS.Palette.textSecondary)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityIdentifier("sidebar.loopGlyph")
    }

    private func workspaceConversationRow(_ row: SidebarViewModel.WorkspaceConversationRow, workspace: Workspace, age: String?) -> some View {
        // A non-Agent tab on screen (Files, Terminal, ...) owns the selection, not the Agent App's thread.
        let tabOnScreen = vm.visibleTab(in: workspace).map { $0.type != .agentApp } ?? false
        let selected = vm.newBotConversationThreadID != row.threadID && (vm.isBotsSelected ? vm.deskSelection?.threadID == row.threadID : (!tabOnScreen && vm.selectedThreadID == row.threadID))
        let running = vm.runningThreadIDs.contains(row.threadID)
        return Button { navigate { vm.openWorkspaceConversation(row) } } label: {
            HStack(spacing: DS.Space.sm) {
                if let bot = vm.conversationBot(row) {
                    BotsAvatarView(name: bot.name, handle: bot.handle, symbol: bot.avatarSymbol.isEmpty ? nil : bot.avatarSymbol, size: 20, attention: running ? .working : .none,
                                   tintHex: vm.workspaceBotRows(workspace.id).contains { $0.botID == bot.id } ? TabColor.from(workspace.metadata["color"])?.hex : nil)
                        .frame(width: 20, height: 20)
                        .accessibilityIdentifier("sidebar.conversationBotAvatar.\(row.threadID.value.uuidString)")
                } else {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 11, weight: .regular))
                        .frame(width: 20, height: 20)
                        .foregroundColor(DS.Palette.textTertiary)
                }
                Text(AgentThreadTitle.display(row.title)).font(selected ? DS.Font.bodyStrong : DS.Font.body).foregroundColor(selected ? DS.Palette.text : DS.Palette.textSecondary).lineLimit(1)
                if let age {
                    Text("· \(age)").font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 0)
                if let loop = vm.loopLabelsByThread[row.threadID] { loopGlyph(loop) }
                if running { DSBusySpinner(label: "Running") } else if vm.finishedThreadIDs.contains(row.threadID) { finishedDot }
            }
            .padding(.leading, Self.workspaceChildIndent)
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 30)
            .sidebarRowChrome(selected: selected)
        }
        .buttonStyle(.plain)
        .help(searchHelp(type: "Conversation", location: workspace.name, name: row.title))
        .accessibilityLabel("\(workspace.name), \(row.title)\(age.map { ", updated \($0)" } ?? "")")
        .accessibilityValue(running ? "Running" : "")
        .accessibilityIdentifier("sidebar.conversation.\(row.id)")
        .contextMenu {
            Button("Open") { navigate { vm.openWorkspaceConversation(row) } }
            Button("Rename…") { vm.renameConversation(row) }
            Button("Copy title") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.title, forType: .string)
            }
            Divider()
            Button("Delete…", role: .destructive) { vm.deleteConversation(row) }
        }
    }

    @ViewBuilder
    private func workspaceRow(_ ws: Workspace) -> some View {
        let selected = vm.selectedWorkspaceID == ws.id
        let checked = vm.selectedWorkspaceIDs.contains(ws.id)
        let desc = ws.metadata["description"]
        let pinned = ws.metadata["pinned"] == "true"
        let busy = vm.isWorkspaceBusy(ws)
        let highlightTone = SidebarSelectionHighlightResolver().resolve(workspace: ws, isSelected: selected, isChecked: checked)
        let expanded = vm.expandedWorkspaceIDs.contains(ws.id)
        HStack(spacing: 0) {
        Button {
            if reduceMotion { vm.toggleWorkspaceExpanded(ws.id) }
            else { withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { vm.toggleWorkspaceExpanded(ws.id) } }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 16, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Collapse" : "Expand")
        .accessibilityLabel(expanded ? "Collapse \(ws.name)" : "Expand \(ws.name)")
        .accessibilityIdentifier("sidebar.workspaceDisclosure.\(ws.id.value.uuidString)")
        Button {
            let flags = NSEvent.modifierFlags
            navigate {
                vm.selectWorkspaceRow(
                    ws,
                    extendingSelection: flags.contains(.shift),
                    togglingSelection: flags.contains(.command))
            }
        } label: {
            HStack(spacing: DS.Space.sm) {
                if checked {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .regular))
                        .frame(width: 20, height: 20)
                        .foregroundColor(DS.Palette.accent)
                }
                Image(systemName: pinned ? "pin.fill" : "folder.fill")
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20, height: 20)
                    .foregroundColor(pinned ? DS.Palette.accent :
                        TabColor.from(ws.metadata["color"]).map { Color(hex: $0.hex) }
                        ?? DS.Palette.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ws.name).font(selected ? DS.Font.bodyStrong : DS.Font.body)
                        .foregroundColor(DS.Palette.text).lineLimit(1)
                    let activity = vm.workspaceActivityCounts[ws.id.description].map(Self.workspaceActivityLabel) ?? ""
                    if !activity.isEmpty {
                        Text(activity).font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textSecondary).lineLimit(1)
                    } else if let d = desc, !d.isEmpty {
                        Text(d).font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                // The counts line says how much; the spinner says it is happening now.
                if busy {
                    // UX-SIDEBAR-P3-BUSYTIP: use the per-workspace busy
                    // source description instead of the generic label so
                    // VoiceOver and tooltip convey agent-run vs terminal.
                    DSBusySpinner(label: vm.busyTooltip(for: ws) ?? "Workspace busy")
                } else if vm.completedWorkspaces.contains(ws.id) {
                    // UX-SIDEBAR-COMPLETED-DOT: the action finished — a small success
                    // dot takes the spinner's slot until the user opens the workspace.
                    Circle()
                        .fill(DS.Palette.success)
                        .frame(width: 7, height: 7)
                        .frame(width: 16, height: 16)
                        .help("Action completed")
                        .accessibilityLabel("Action completed")
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            // UX-SIDEBAR-COMPLETED-DOT: fade/scale the spinner→dot swap in subtly
            // (reduced-motion shows it instantly).
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2),
                       value: vm.completedWorkspaces.contains(ws.id))
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 38)
            .sidebarRowChrome(selected: selected || checked, tone: highlightTone, squareBottom: expanded && vm.hasWorkspaceChildren(ws.id))
            .overlay(alignment: .top) {
                if vm.dropTargetWorkspaceID == ws.id {
                    Capsule()
                        .fill(DS.Palette.accent)
                        .frame(height: 2)
                        .padding(.horizontal, DS.Space.sm)
                }
            }
        }
        .buttonStyle(.plain)
        .help(ws.cwd.isEmpty ? ws.name : ws.cwd)
        // UX-SIDEBAR-P3-A11Y: expose a combined label so VoiceOver reads
        // name + status in one focused element rather than a string of
        // context-free sub-elements (number pill, icon-only pin state, etc).
        .accessibilityLabel(ws.name)
        .accessibilityValue(workspaceRowAccessibilityValue(ws: ws, busy: busy, checked: checked, pinned: pinned))
        .accessibilityIdentifier("sidebar.workspaceRow.\(ws.id.value.uuidString)")
        .onDrag {
            vm.draggingWorkspaceID = ws.id
            return NSItemProvider(object: ws.id.value.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: WorkspaceDropDelegate(vm: vm, target: ws))
        .contextMenu {
            let mode = SidebarViewModel.sidebarContextMenuMode(
                clickedID: ws.id,
                selectedIDs: vm.selectedWorkspaceIDs
            )
            if mode.isMulti {
                // Multi-select context menu: batch actions for all selected workspaces.
                Button { vm.pinSelectedWorkspaces(true) } label: {
                    Label("Pin \(mode.count) Workspaces", systemImage: "pin")
                }
                Button { vm.pinSelectedWorkspaces(false) } label: {
                    Label("Unpin \(mode.count) Workspaces", systemImage: "pin.slash")
                }
                Divider()
                Button("Remove \(mode.count) Workspaces\u{2026}", role: .destructive) {
                    vm.removeSelectedWorkspaces()
                }
            } else {
                // Single-row context menu: per-workspace actions.
                Button { vm.setWorkspacePinned(ws, !pinned) } label: {
                    Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
                }
                Divider()
                Button { vm.openWorkspaceInNewWindow(ws) } label: {
                    Label("Open in New Window", systemImage: "macwindow")
                }
                Button { vm.openWorkspaceInFinder(ws) } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                Divider()
                Button("Rename\u{2026}") { vm.renameWorkspace(ws) }
                Button("Edit description\u{2026}") { vm.editDescription(ws) }
                Menu("Color") {
                    Button { vm.setWorkspaceColor(ws, "") } label: {
                        TabColorMenuLabel.none
                    }
                    ForEach(TabColor.allCases, id: \.self) { c in
                        Button { vm.setWorkspaceColor(ws, c.rawValue) } label: {
                            TabColorMenuLabel(c)
                        }
                    }
                }
                Divider()
                Button("Remove", role: .destructive) { vm.removeWorkspace(ws) }
            }
        }
        }
    }
}

private struct TabColorMenuLabel: View {
    let title: String
    let swatchImage: NSImage

    init(_ color: TabColor) {
        self.title = color.label
        self.swatchImage = Self.swatchImage(hex: color.hex)
    }

    private init(title: String, swatchImage: NSImage) {
        self.title = title
        self.swatchImage = swatchImage
    }

    static var none: TabColorMenuLabel {
        TabColorMenuLabel(title: "None", swatchImage: noneSwatchImage())
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: swatchImage)
                .renderingMode(.original)
        }
    }

    private static func swatchImage(hex: UInt32) -> NSImage {
        menuImage { rect in
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 2, dy: 2),
                xRadius: 3,
                yRadius: 3
            )
            NSColor(hex: hex).setFill()
            path.fill()
            DS.NS.lineStrong.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private static func noneSwatchImage() -> NSImage {
        menuImage { rect in
            let box = NSBezierPath(
                roundedRect: rect.insetBy(dx: 2, dy: 2),
                xRadius: 3,
                yRadius: 3
            )
            DS.NS.textTertiary.withAlphaComponent(0.9).setStroke()
            box.lineWidth = 1
            box.stroke()

            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 4, y: rect.minY + 4))
            slash.line(to: NSPoint(x: rect.maxX - 4, y: rect.maxY - 4))
            slash.lineWidth = 1.25
            slash.stroke()
        }
    }

    private static func menuImage(draw: @escaping (NSRect) -> Void) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// One selected/hover look for every sidebar row: tone fill plus the 3pt edge bar.
private struct SidebarRowChrome: ViewModifier {
    let tone: SidebarHighlightTone
    let selected: Bool
    /// An expanded workspace row squares its bottom edge so its dropdown attaches below it.
    var squareBottom = false
    /// Rows inside an expanded workspace put their selection bar on the right edge.
    @Environment(\.sidebarSubmenuRow) private var submenuRow
    @State private var hovering = false

    func body(content: Content) -> some View {
        let radius = DS.Radius.control
        content
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: radius, bottomLeadingRadius: squareBottom ? 0 : radius,
                    bottomTrailingRadius: squareBottom ? 0 : radius, topTrailingRadius: radius, style: .continuous
                )
                .fill(Self.fill(tone, hovering: hovering))
            )
            .overlay(alignment: submenuRow ? .trailing : .leading) {
                if tone != .none {
                    Self.bar(tone)
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                        .padding(.vertical, 5)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func fill(_ tone: SidebarHighlightTone, hovering: Bool) -> Color {
        switch tone {
        case .workspaceColor(let hex): return Color(hex: hex).opacity(0.22)
        case .accent: return DS.Palette.accent.opacity(0.22)
        case .selection: return DS.Palette.selection.opacity(0.75)
        case .none: return hovering ? DS.Palette.selection.opacity(0.35) : Color.white.opacity(0.001)
        }
    }

    static func bar(_ tone: SidebarHighlightTone) -> Color {
        switch tone {
        case .workspaceColor(let hex): return Color(hex: hex)
        case .accent, .selection: return DS.Palette.accent
        case .none: return Color.clear
        }
    }
}

private extension View {
    func sidebarRowChrome(selected: Bool, tone: SidebarHighlightTone? = nil, squareBottom: Bool = false) -> some View {
        modifier(SidebarRowChrome(tone: tone ?? (selected ? .selection : .none), selected: selected, squareBottom: squareBottom))
    }
}

private struct SidebarSubmenuRowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sidebarSubmenuRow: Bool {
        get { self[SidebarSubmenuRowKey.self] }
        set { self[SidebarSubmenuRowKey.self] = newValue }
    }
}

private struct BotDropDelegate: DropDelegate {
    @ObservedObject var vm: SidebarViewModel
    let target: BotID
    var inWorkspace = false

    func dropEntered(info: DropInfo) {
        vm.dropTargetBotID = (vm.draggingBotID != nil && vm.draggingBotID != target) ? target : nil
    }

    func dropExited(info: DropInfo) {
        if vm.dropTargetBotID == target { vm.dropTargetBotID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        if let dragged = vm.draggingBotID { vm.reorderBot(dragged, before: target, inWorkspace: inWorkspace) }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

private struct WorkspaceDropDelegate: DropDelegate {
    @ObservedObject var vm: SidebarViewModel
    let target: Workspace

    func dropEntered(info: DropInfo) {
        guard vm.draggingWorkspaceID != nil, vm.draggingWorkspaceID != target.id else {
            vm.dropTargetWorkspaceID = nil
            return
        }
        // UX-MAC_SHELL_WINDOW-012: show an insertion line on hover and
        // commit the reorder on drop, rather than shuffling rows live.
        vm.dropTargetWorkspaceID = target.id
    }

    func dropExited(info: DropInfo) {
        if vm.dropTargetWorkspaceID == target.id {
            vm.dropTargetWorkspaceID = nil
        }
        vm.dragScrollEdge = 0
    }

    func performDrop(info: DropInfo) -> Bool {
        if let dragged = vm.draggingWorkspaceID, dragged != target.id {
            vm.reorderWorkspace(dragged, before: target.id)
        }
        vm.draggingWorkspaceID = nil
        vm.dropTargetWorkspaceID = nil
        vm.dragScrollEdge = 0
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // :18 -- Edge auto-scroll: while the user holds a drag near the top or
        // bottom of the sidebar's content window, SidebarRootView's scroll timer
        // fires and scrolls toward the edge.
        //
        // Strategy: convert the current mouse screen position into window Y,
        // use the key window's content height as a proxy for the scrollable
        // region height. The 40-pt edge zone matches typical row height so
        // one-row proximity triggers the scroll.
        if let window = NSApp.keyWindow {
            let screenPt = NSEvent.mouseLocation
            let windowPt = window.convertPoint(fromScreen: screenPt)
            let contentH = window.contentView?.bounds.height ?? window.frame.height
            // pointerY in top-left-origin space: flip AppKit's bottom-origin Y.
            let pointerY = contentH - windowPt.y
            vm.dragScrollEdge = SidebarRootView.autoScrollDirection(
                pointerY: pointerY,
                viewHeight: contentH,
                edgeZone: 40
            )
        } else {
            vm.dragScrollEdge = 0
        }
        return DropProposal(operation: .move)
    }
}

/// Shared sidebar filter chrome. Workspaces and Bots use this so letter,
/// height, padding, and the clear affordance cannot drift.
struct SidebarSearchField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var focusRequest: Bool
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            NonAutoFocusTextField(
                placeholder: placeholder,
                text: $text,
                focusRequest: $focusRequest,
                accessibilityIdentifier: accessibilityIdentifier
            )
            .font(DS.Font.body)
            .foregroundColor(DS.Palette.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: DS.Control.sidebarSearchHeight)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(DS.Palette.surfaceRaised.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.lineStrong.opacity(0.5), lineWidth: DS.Border.hairline)
                )
        )
    }
}

private struct NonAutoFocusTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    /// Set to `true` to programmatically focus the field (e.g. Cmd+F); resets to `false` once handled.
    @Binding var focusRequest: Bool
    let accessibilityIdentifier: String

    func makeNSView(context: Context) -> ManualFocusTextField {
        let field = ManualFocusTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = NSColor(DS.Palette.text)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor(DS.Palette.textTertiary)]
        )
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ field: ManualFocusTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.focusRequest = $focusRequest
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.setAccessibilityLabel(placeholder)
        if field.stringValue != text {
            field.stringValue = text
        }
        if focusRequest {
            field.programmaticFocus()
            let resetRequest = $focusRequest
            DispatchQueue.main.async { resetRequest.wrappedValue = false }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focusRequest: $focusRequest)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var focusRequest: Binding<Bool>

        init(text: Binding<String>, focusRequest: Binding<Bool>) {
            self.text = text
            self.focusRequest = focusRequest
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }

    final class ManualFocusTextField: NSTextField {
        private var allowManualFocus = false

        override var acceptsFirstResponder: Bool {
            allowManualFocus
        }

        /// Programmatically grant focus without a mouse event (e.g. Cmd+F keyboard shortcut).
        func programmaticFocus() {
            allowManualFocus = true
            window?.makeFirstResponder(self)
        }

        override func mouseDown(with event: NSEvent) {
            allowManualFocus = true
            super.mouseDown(with: event)
        }

        override func resignFirstResponder() -> Bool {
            allowManualFocus = false
            return super.resignFirstResponder()
        }
    }
}

@MainActor
public final class SidebarView: NSObject {
    public let view: NSView
    public weak var context: AppContext?
    public weak var router: AppCommandRouter?
    private let viewModel: SidebarViewModel
    public let botsViewModel: BotsViewModel
    private let host: NSHostingView<SidebarRootView>
    private var settingsController: SettingsWindowController?
    private var accountController: AccountWindowController?
    private let updater: AppUpdateChecking?
    /// Main window mounts Schedule Tasks in the workspace content column.
    public var onPresentScheduledTasks: (() -> Void)?
    /// Main window mounts Active Threads in the workspace content column.
    public var onPresentActiveThreads: (() -> Void)?
    /// Main window mounts Settings in the workspace content column.
    public var onPresentSettings: (() -> Void)?
    /// Fired when a workspace is selected so main content leaves shell destinations.
    public var onWorkspaceContentActivated: (() -> Void)? {
        get { viewModel.onWorkspaceContentActivated }
        set { viewModel.onWorkspaceContentActivated = newValue }
    }

    public init(
        context: AppContext,
        router: AppCommandRouter,
        updater: AppUpdateChecking? = nil
    ) {
        self.context = context
        self.router = router
        self.updater = updater
        self.viewModel = SidebarViewModel(context: context, router: router, updateChecker: updater)
        self.botsViewModel = BotsViewModel(context: context, router: router)
        self.viewModel.observeActiveBots(botsViewModel)
        let h = NSHostingView(rootView: SidebarRootView(vm: viewModel, botsVM: botsViewModel))
        h.translatesAutoresizingMaskIntoConstraints = false
        // NSHostingView is opaque by default; let the vibrancy show.
        h.wantsLayer = true
        h.layer?.backgroundColor = NSColor.clear.cgColor
        RemoteCodeAppearance.apply(to: h)
        self.host = h
        // Subtle Liquid Glass: an under-window vibrancy material behind
        // the translucent SwiftUI sidebar. Chrome only — per design rules
        // glass never goes on main content.
        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .active
        container.translatesAutoresizingMaskIntoConstraints = false
        RemoteCodeAppearance.apply(to: container)
        container.addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: container.topAnchor),
            h.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            h.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        self.view = container
        super.init()
        router.botsViewModel = botsViewModel
        h.rootView = SidebarRootView(
            vm: viewModel,
            botsVM: botsViewModel,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onOpenAccount: { [weak self] in self?.showAccount() },
            onOpenScheduledTasks: { [weak self] in self?.showScheduledTasks() },
            onOpenActiveThreads: { [weak self] in self?.showActiveThreads() }
        )
    }

    public func setScheduledTasksSelected(_ selected: Bool) {
        viewModel.isScheduledTasksSelected = selected
        if selected {
            viewModel.isActiveThreadsSelected = false
            viewModel.isBotsSelected = false
            viewModel.isSettingsSelected = false
            // Visual deselect of all workspace rows while Schedule Tasks is active.
            viewModel.selectedWorkspaceID = nil
            viewModel.selectedWorkspaceIDs.removeAll()
            viewModel.clearSelectionAnchorForShellDestination()
        }
    }

    func refreshActiveCount() {
        viewModel.refreshActiveCount()
    }

    public func setActiveThreadsSelected(_ selected: Bool) {
        viewModel.isActiveThreadsSelected = selected
        if selected {
            viewModel.isScheduledTasksSelected = false
            viewModel.isBotsSelected = false
            viewModel.isSettingsSelected = false
            viewModel.selectedWorkspaceID = nil
            viewModel.selectedWorkspaceIDs.removeAll()
            viewModel.clearSelectionAnchorForShellDestination()
        }
    }

    public func setBotsSelected(_ selected: Bool) {
        viewModel.isBotsSelected = selected
        if selected {
            viewModel.isScheduledTasksSelected = false
            viewModel.isActiveThreadsSelected = false
            viewModel.isSettingsSelected = false
            viewModel.selectedWorkspaceID = nil
            viewModel.selectedWorkspaceIDs.removeAll()
            viewModel.clearSelectionAnchorForShellDestination()
        }
    }

    public func setSettingsSelected(_ selected: Bool) {
        viewModel.isSettingsSelected = selected
        if selected {
            viewModel.isScheduledTasksSelected = false
            viewModel.isActiveThreadsSelected = false
            viewModel.isBotsSelected = false
            viewModel.selectedWorkspaceID = nil
            viewModel.selectedWorkspaceIDs.removeAll()
            viewModel.clearSelectionAnchorForShellDestination()
        }
    }

    public func refresh() {
        viewModel.reload()
    }

    var workspacesForTesting: [Workspace] { viewModel.workspaces }
    var viewModelForTesting: SidebarViewModel { viewModel }

    /// Canonical workspace-add path for shell-level entry points such as the
    /// header "+" and the empty-state button: DEDUP-P2, File ▸ Open Recent and
    /// the failure sheet all live in the view model, so creating the workspace
    /// anywhere else silently duplicates a cwd and hides failures.
    @discardableResult
    public func createWorkspace(fromFolder url: URL) -> Bool {
        viewModel.createWorkspace(fromFolder: url)
    }

    public func disableInsomniaForAppClose() {
        viewModel.disableInsomniaForAppClose()
    }

    @objc private func showSettings() {
        if let onPresentSettings {
            onPresentSettings()
            return
        }
        guard let context else { return }
        // Defer hydration to the post-commit freshness pass so the first
        // click paints the window immediately (AGENTS.md loading rule).
        let controller = settingsController ?? SettingsWindowController(
            context: context,
            updater: updater,
            loadImmediately: false
        )
        settingsController = controller
        if let window = view.window {
            controller.show(attachedTo: window)
        } else {
            controller.show()
        }
    }

    @objc private func showAccount() {
        guard let context else { return }
        let controller = accountController ?? AccountWindowController(
            context: context, loadImmediately: false
        )
        accountController = controller
        if let window = view.window {
            controller.show(attachedTo: window)
        } else {
            controller.show()
        }
    }

    @objc private func showScheduledTasks() {
        // Prefer the main content column (same place workspaces open). Fall
        // back to a detached window only if the shell presenter is missing.
        if let onPresentScheduledTasks {
            onPresentScheduledTasks()
            return
        }
        guard let context, let router else { return }
        let controller = ScheduledTasksWindowController(context: context, router: router)
        controller.show()
    }

    @objc private func showActiveThreads() {
        if let onPresentActiveThreads {
            onPresentActiveThreads()
            return
        }
        // No detached fallback: Active Threads is main-content only.
    }
}

/// The "..." menu on the right of a sidebar section header (Bots, Workspaces).
struct SidebarSectionMoreMenu<Content: View>: View {
    let help: String
    let accessibilityIdentifier: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 24, height: DS.Control.sidebarSearchHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
