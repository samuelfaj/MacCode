import Foundation
import CoreModel
import SocketServer

struct PetActivityCounts: Equatable {
    let running: Int
    let needsYou: Int
    let newResults: Int
    let isAvailable: Bool

    static let zero = PetActivityCounts(running: 0, needsYou: 0, newResults: 0, isAvailable: false)

    init(running: Int, needsYou: Int, newResults: Int, isAvailable: Bool = true) {
        self.running = running
        self.needsYou = needsYou
        self.newResults = newResults
        self.isAvailable = isAvailable
    }

    init(_ counts: ActivityCounts) {
        running = counts.running
        needsYou = counts.needsYou
        newResults = counts.newResults
        isAvailable = true
    }

    /// Red badge total: items needing the user plus just-finished results. Saturates instead of overflowing.
    var badgeTotal: Int {
        let (sum, overflow) = needsYou.addingReportingOverflow(newResults)
        return overflow ? Int.max : sum
    }
}

@MainActor
final class PetActivityCountsProjection {
    static let shared = PetActivityCountsProjection()

    private(set) var global = PetActivityCounts.zero
    private(set) var byWorkspace: [String: PetActivityCounts] = [:]
    private var observers: [UUID: (PetActivityCounts, [String: PetActivityCounts]) -> Void] = [:]
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var refreshPending = false
    private var refreshDirty = false
    private var latestWorkspaceIDs: Set<WorkspaceID> = []
    private weak var latestRouter: AppCommandRouter?
    private var eventSubscription: UUID?
    private(set) var completedRefreshCountForTests = 0

    func observe(_ observer: @escaping (PetActivityCounts, [String: PetActivityCounts]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(global, byWorkspace)
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func refresh(router: AppCommandRouter, workspaceIDs: [WorkspaceID]) {
        if latestRouter !== router {
            task?.cancel()
            generation &+= 1
            refreshPending = false
            refreshDirty = false
            // Observers must see the reset too, or `publish` would compare later results
            // against counts they no longer show and drop a real change.
            notifyIfChanged(global: .zero, byWorkspace: [:])
        }
        latestRouter = router
        latestWorkspaceIDs = Set(workspaceIDs)
        if eventSubscription == nil {
            eventSubscription = EventBus.shared.subscribeFromCurrent { [weak self] event in
                let kinds: Set<String> = [
                    "notification.created", "notification.read", "notification.dismissed", "bot.attention.updated", "bot.scheduler.updated",
                    "agent.run.started", "agent.run.finished", "agent.run.completed", "agent.run.failed", "agent.run.cancelled",
                    "agent.request.opened", "agent.request.resolved", "agent.user_input.requested", "agent.user_input.resolved",
                    "agent.thread.read", "agent.thread.updated", "agent.thread.renamed", "agent.thread.deleted", "agent.thread.deleted_many",
                    "bots.attention.changed", "bot.attention.updated", "bot.scheduler.updated", "bot.routine.updated", "bot.routine.run_requested",
                    "bot.run.started", "bot.run.completed", "bot.run.failed",
                    "project.script_started", "project.script.finished", "surface.closed", "workspace.closed",
                ]
                let busyChanged = event.kind == "surface.updated"
                    && event.payload.objectValue?["metadata"]?.objectValue?["busy"] != nil
                guard busyChanged || kinds.contains(event.kind) else { return }
                Task { @MainActor [weak self] in
                    guard let self, let router = self.latestRouter else { return }
                    self.refresh(router: router, workspaceIDs: Array(self.latestWorkspaceIDs))
                }
            }.id
        }
        guard !refreshPending else { refreshDirty = true; return }
        refreshDirty = false
        let requestedWorkspaceIDs = latestWorkspaceIDs
        refreshPending = true
        generation &+= 1
        let request = generation
        task?.cancel()
        task = Task { @MainActor [weak self, weak router] in
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            guard let self, self.generation == request else { return }
            defer {
                if self.generation == request {
                    self.refreshPending = false
                    self.task = nil
                    if (self.refreshDirty || requestedWorkspaceIDs != self.latestWorkspaceIDs), let latestRouter = self.latestRouter {
                        self.refresh(router: latestRouter, workspaceIDs: Array(self.latestWorkspaceIDs))
                    }
                }
            }
            guard let router, !Task.isCancelled, self.latestRouter === router else { return }
            do {
                let counts = try await router.activityCountsOffMain()
                var workspacePages: [String: PetActivityCounts] = [:]
                for workspaceID in requestedWorkspaceIDs {
                    workspacePages[workspaceID.value.uuidString] = PetActivityCounts(counts.byWorkspace[workspaceID.value.uuidString] ?? ActivityCounts(running: 0, queued: 0, needsYou: 0, finished: 0, newResults: 0))
                }
                guard !Task.isCancelled, self.generation == request else { return }
                router.context?.liveActivitySyncCoordinator.submitRunningOutsideAgentCoordinator(counts.runningOutsideAgentCoordinator)
                self.publish(global: PetActivityCounts(counts.global), byWorkspace: workspacePages)
            } catch {
                guard !Task.isCancelled, self.generation == request, self.latestRouter === router else { return }
                self.publish(global: Self.unavailable(self.global), byWorkspace: self.byWorkspace.mapValues(Self.unavailable))
            }
        }
    }

    /// Sidebar and Pet observers rebuild their views on every call, so a refresh that
    /// lands on the counts they already show must not reach them.
    private func publish(global: PetActivityCounts, byWorkspace: [String: PetActivityCounts]) {
        completedRefreshCountForTests &+= 1
        notifyIfChanged(global: global, byWorkspace: byWorkspace)
    }

    private func notifyIfChanged(global: PetActivityCounts, byWorkspace: [String: PetActivityCounts]) {
        guard global != self.global || byWorkspace != self.byWorkspace else { return }
        self.global = global
        self.byWorkspace = byWorkspace
        for observer in observers.values { observer(global, byWorkspace) }
    }

    private static func unavailable(_ counts: PetActivityCounts) -> PetActivityCounts {
        PetActivityCounts(
            running: counts.running,
            needsYou: counts.needsYou,
            newResults: counts.newResults,
            isAvailable: false
        )
    }
}
