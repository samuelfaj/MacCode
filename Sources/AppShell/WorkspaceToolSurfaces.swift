import AppKit
import CoreModel
import DesignSystemKit
import Persistence
import SocketServer
import Surfaces
import SwiftUI

/// Workspace tabs for the Bots and VMs that belong to one workspace. They use
/// the `rightSidebarTool` type with a `tool` metadata key (like Feed), so paired
/// clients that only know the existing surface types still decode the layout.
enum WorkspaceTool: String, CaseIterable {
    case bots, vms

    var title: String { self == .bots ? "Bots" : "VMs" }
    var symbol: String { self == .bots ? "person.2" : "desktopcomputer" }

    /// The tool a `rightSidebarTool` descriptor or menu title names; nil for Git/Diff and Feed.
    static func from(metadata: [String: String], title: String) -> WorkspaceTool? {
        if let raw = metadata["tool"] { return WorkspaceTool(rawValue: raw) }
        return allCases.first { $0.title == title }
    }
}

@MainActor
final class WorkspaceToolSurface: NSObject, Surface {
    private(set) var descriptor: SurfaceDescriptor
    let view: NSView
    private var onClose: (() -> Void)?

    init(tool: WorkspaceTool, workspaceID: WorkspaceID, title: String, router: AppCommandRouter, restoredID: SurfaceID? = nil) {
        descriptor = SurfaceDescriptor(
            id: restoredID ?? SurfaceID(), type: .rightSidebarTool, title: title, iconName: tool.symbol,
            metadata: ["workspace": workspaceID.value.uuidString, "tool": tool.rawValue]
        )
        let root: AnyView
        switch tool {
        case .bots:
            let model = WorkspaceBotsModel(workspaceID: workspaceID, router: router)
            root = AnyView(WorkspaceBotsView(model: model))
            onClose = { model.stop() }
        case .vms:
            if let context = router.context, let workspace = context.state.workspaces[workspaceID] {
                root = AnyView(BotVirtualMachinesView(store: context.botStore, workspaces: [workspace], lockedWorkspaceID: workspaceID))
            } else {
                root = AnyView(Text(L("This workspace is no longer available.")).foregroundColor(DS.Palette.textSecondary))
            }
        }
        let host = NSHostingView(rootView: root.frame(maxWidth: .infinity, maxHeight: .infinity).background(DS.Palette.bg))
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view = container
        super.init()
    }

    func focus() { view.window?.makeFirstResponder(view) }
    func unfocus() {}
    func close() { onClose?(); onClose = nil }
    func sendText(_ text: String) {}
    func readText() -> String { descriptor.title }
    func snapshot() -> [String: String] { ["tool": descriptor.metadata["tool"] ?? ""] }
}

/// The workspace's Bots, read with the same authorization rules as the sidebar.
@MainActor
final class WorkspaceBotsModel: ObservableObject {
    @Published private(set) var rows: [SidebarViewModel.AuthorizedBotConversationRow] = []
    @Published private(set) var loaded = false
    let workspaceID: WorkspaceID
    private weak var router: AppCommandRouter?
    private var subscription: UUID?
    private var generation = 0

    init(workspaceID: WorkspaceID, router: AppCommandRouter) {
        self.workspaceID = workspaceID
        self.router = router
        subscription = EventBus.shared.subscribeFromCurrent(
            filter: .kindPrefixes(["bot.created", "bot.deleted", "bot.updated", "bot.settings.updated"])
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }.id
        reload()
    }

    func stop() {
        if let subscription { EventBus.shared.unsubscribe(subscription) }
        subscription = nil
    }

    func reload() {
        guard let context = router?.context else { return }
        generation += 1
        let current = generation
        let botStore = context.botStore, threadRepo = context.threadRepo
        let hostID = context.liveActivityHostIdentity.serverId
        let workspaceID = workspaceID
        Task.detached(priority: .userInitiated) {
            let rows = SidebarViewModel.loadAuthorizedBotConversationRows(
                botStore: botStore, threadRepo: threadRepo, hostID: hostID, workspaceIDs: [workspaceID]
            )?.filter { $0.context == .workspace(workspaceID) }
            await MainActor.run { [weak self] in
                guard let self, self.generation == current else { return }
                if let rows { self.rows = rows }
                self.loaded = true
            }
        }
    }

    func open(_ row: SidebarViewModel.AuthorizedBotConversationRow) {
        _ = try? router?.openBotsDesk(botID: row.botID)
    }

    func newBot() {
        guard let router else { return }
        router.windowController?.presentBotsInMainContent()
        router.botsViewModel?.beginCreate(inWorkspace: workspaceID) { [weak self] in self?.reload() }
    }
}

struct WorkspaceBotsView: View {
    @ObservedObject var model: WorkspaceBotsModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack {
                Text(L("Bots")).font(DS.Font.title)
                Spacer()
                Button { model.newBot() } label: { Label(L("New bot"), systemImage: "plus") }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .help("Create a Bot exclusive to this workspace")
                    .accessibilityIdentifier("workspaceBots.new")
            }
            Text(L("Bots that work in this workspace. Open one to chat in its Desk."))
                .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
            if model.rows.isEmpty {
                Spacer()
                if model.loaded {
                    DSEmptyState(icon: "person.2", title: "No bots yet", subtitle: "Create a Bot to give this workspace a teammate.") {
                        EmptyView()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.xs) {
                        ForEach(model.rows) { row in
                            Button { model.open(row) } label: {
                                HStack(spacing: DS.Space.md) {
                                    BotsAvatarView(name: row.botName, handle: row.handle, symbol: row.symbol.isEmpty ? nil : row.symbol, size: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(BotsViewModel.displayName(row.botName)).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text).lineLimit(1)
                                        Text(row.title).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundColor(DS.Palette.textTertiary)
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal, DS.Space.md)
                                .frame(minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Palette.surface))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open \(row.botName)'s Desk")
                            .accessibilityLabel("\(row.botName), \(row.title)")
                            .accessibilityIdentifier("workspaceBots.bot.\(row.botID.value.uuidString)")
                        }
                    }
                }
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
