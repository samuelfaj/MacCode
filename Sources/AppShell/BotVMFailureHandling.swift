import Foundation
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
import Surfaces

/// The answer to a bot's "run on the Mac?" request could not be saved;
/// the request stays pending.
struct MacExecutionStoreError: Error {
    let underlying: Error
}

/// A desk, peer or hop send found the bot's VM busy in another thread. Nothing
/// was written: the caller keeps its text and shows the notice.
struct BotVMBusyError: LocalizedError, CustomStringConvertible {
    let holder: BotVMRunRegistry.Entry
    var description: String { AppCommandRouter.botVMBusyNotice(holderTitle: holder.title) }
    var errorDescription: String? { description }
}

/// Retries a bot VM provision only for Docker's transient failures. `provision`
/// is re-entrant (it inspects and restarts what an earlier attempt left).
enum BotVMProvisionRetry {
    static func run<T>(
        delays: [TimeInterval] = [2, 5],
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        _ body: () throws -> T
    ) throws -> T {
        for delay in delays {
            do {
                return try body()
            } catch let error as BotComputerDockerError where error == .provisioningFailed || error == .probeTimedOut {
                sleep(delay)
            }
        }
        return try body()
    }
}

extension AppCommandRouter {
    static let macExecutionApprovedFollowUp = "The user approved running on the Mac. Continue."
    static let macExecutionDeclinedFollowUp = "The user declined running on the Mac. Continue in the VM, or stop and explain."

    /// Every Agent App view model that can show a bot thread: the Agent App
    /// tabs and the embedded Bots Desk.
    var botThreadViewModels: [AgentAppViewModel] {
        var models: [AgentAppViewModel] = []
        for case let agent as AgentAppSurface in SurfaceRegistry.shared.all() {
            models.append(agent.viewModel)
        }
        if let desk = botsViewModel?.deskAgentVM { models.append(desk) }
        return models
    }

    /// D12 before a router start: claims the bot's VM for `runID` on a thread
    /// locked to the bot's VM. nil for any other thread. `holder` is the other
    /// thread's run when the VM is busy (nothing was claimed then).
    /// `firstMessage` names a never-used thread as the send will rename it.
    func claimBotVMRun(
        thread: AgentThreadID,
        runID: AgentRunID,
        firstMessage: String? = nil
    ) -> (botID: BotID, holder: BotVMRunRegistry.Entry?)? {
        guard let ctx = context,
              let row = (try? ctx.threadRepo.get(id: thread)) ?? nil,
              let botID = botIDOfVMThread(thread, row: row) else { return nil }
        let untitled = AgentThreadTitle.isPlaceholder(row.title)
            && (try? ctx.messageRepo.hasAny(threadId: thread)) != true
        let title = untitled ? firstMessage.map(AgentThreadTitle.titleFromFirstMessage) ?? row.title : row.title
        let holder = BotVMRunRegistry.shared.tryBegin(
            botID: botID,
            entry: BotVMRunRegistry.Entry(
                threadID: thread, runID: runID, title: title, workspace: row.worktreePath ?? ""
            ),
            resourceID: try? ctx.botStore.guestResourceID(botID: botID, threadID: thread)
        )
        return (botID, holder)
    }

    /// The bot whose VM runs `thread`; nil unless the thread is locked to a bot's VM.
    func botIDOfVMThread(_ thread: AgentThreadID, row: AgentThread? = nil) -> BotID? {
        guard let ctx = context,
              (try? ctx.threadRepo.guestPlacement(of: thread))??.executionTarget == .vm,
              let row = row ?? ((try? ctx.threadRepo.get(id: thread)) ?? nil) else { return nil }
        if case .bot(let id) = row.actor { return id }
        return ((try? ctx.botStore.conversationLinked(to: thread)) ?? nil)?.botID
    }

    /// Frees a claim whose run never started and hands the VM to the next
    /// queued thread, as the run-finished callback does for a started run.
    func releaseBotVMRun(_ runID: AgentRunID) {
        guard context?.botGuestRunResolver?.retainsExclusiveVMClaim(runID: runID) != true else { return }
        guard let next = BotVMRunRegistry.shared.releaseAndNextWaiter(runID: runID) else { return }
        Task { @MainActor [weak self] in await self?.handOffBotVM(botID: next.botID, to: next.threadID) }
    }

    /// Starts the thread the free VM was handed to. When that thread does not
    /// take the VM (its queue emptied, it is running, its drain is not
    /// allowed), the VM passes to the next waiter instead of staying idle.
    func handOffBotVM(botID: BotID, to thread: AgentThreadID) async {
        var next: AgentThreadID? = thread
        while let current = next {
            if await context?.botGroupOrchestrator.resumeWaitingTurn(memberThreadID: current) != true {
                try? await drainNextQueuedAgentMessage(thread: current, botVMHandOff: true)
            }
            let currentBotID = ((try? context?.threadRepo.get(id: current)) ?? nil)?.actor.botID ?? botID
            next = BotVMRunRegistry.shared.popWaitingIfFree(botID: currentBotID,
                resourceID: try? context?.botStore.guestResourceID(botID: currentBotID, threadID: current))
        }
    }

    nonisolated static func botVMBusyNotice(holderTitle: String) -> String {
        "The VM is busy in \(holderTitle)"
    }

    /// Queues `thread` behind the run holding the bot's VM and shows the
    /// notice on the surfaces showing it. Returns the notice.
    @discardableResult
    func waitForBotVM(botID: BotID, thread: AgentThreadID, holder: BotVMRunRegistry.Entry) -> String {
        BotVMRunRegistry.shared.addWaiting(botID: botID, threadID: thread,
            resourceID: try? context?.botStore.guestResourceID(botID: botID, threadID: thread))
        let notice = Self.botVMBusyNotice(holderTitle: holder.title)
        for viewModel in botThreadViewModels where viewModel.selectedThreadId == thread {
            viewModel.statusMessage = notice
        }
        publishBotVMWait(thread: thread)
        return notice
    }

    /// iOS parity: republishes the thread's head queued message, whose
    /// `waiting_for_bot_vm` field says which thread holds the bot's VM.
    func publishBotVMWait(thread: AgentThreadID) {
        guard let head = (try? context?.queuedMessageRepo.first(threadId: thread)) ?? nil else { return }
        publishQueuedMessage(kind: "agent.message.queue.updated", head)
    }

    /// D12 for the coordinator's auto-continuation: false when a rebuild or
    /// stop holds the bot's VM (the continuation is skipped).
    func claimBotVMForAutoContinuation(thread: AgentThreadID, runID: AgentRunID) -> Bool {
        claimBotVMRun(thread: thread, runID: runID)?.holder == nil
    }

    func handleMacExecutionRequested(threadID: AgentThreadID, reason: String) {
        pendingMacExecution[threadID] = reason
        // Same host-enforced pause as the handoff card: the reply only asks the model to end
        // its turn. The answer's follow-up resumes the bot; the queue holds until then.
        if let ctx = context, (try? ctx.runRepo.latestActive(for: threadID)) != nil {
            ctx.coordinator.stopRun(threadId: threadID)
        }
        for viewModel in botThreadViewModels {
            viewModel.pendingMacExecutionByThread[threadID] = reason
        }
        // iOS parity: paired devices show the same approve/decline row.
        EventBus.shared.publish(
            kind: .agentMacExecutionRequested,
            payload: ThreadActorWire.macExecutionRequestedEvent(thread: threadID, reason: reason)
        )
    }

    /// Approve switches the thread to the Mac (actor and lock kept); decline leaves the target alone.
    /// Both send a follow-up so the bot learns the outcome. Only ever called from a user click, on
    /// the Mac banner or a paired device (`agent.mac_execution.resolve`): the first answer wins and
    /// later ones get nil. Paired devices learn the answer from `agent.thread.updated`.
    /// A guest thread keeps its marker: its next run (this follow-up, once a
    /// still-finishing guest turn ends) starts a new Mac session with a
    /// handoff summary (`AgentRunCoordinator.pendingMacHandoff`).
    /// The request is consumed only once the target is saved: a store failure
    /// throws `MacExecutionStoreError` and leaves the request and every banner open.
    @discardableResult
    func resolveMacExecution(thread: AgentThreadID, approve: Bool) async throws -> MacExecutionResolveOutcome? {
        // No await from here to the removal below: one answer wins.
        guard let reason = pendingMacExecution[thread] else { return nil }
        var stored: AgentThread?
        do {
            stored = try context?.threadRepo.get(id: thread)
            if approve, let row = stored, try context?.threadRepo.setActor(
                id: thread, actor: row.actor, lockedAt: row.actorLockedAt, executionTarget: .mac
            ) != true {
                stored = nil
            }
        } catch {
            for viewModel in botThreadViewModels {
                viewModel.pendingMacExecutionByThread[thread] = reason
                if viewModel.selectedThreadId == thread {
                    viewModel.statusMessage = "Could not save the answer: \(error.localizedDescription)"
                }
            }
            throw MacExecutionStoreError(underlying: error)
        }
        pendingMacExecution[thread] = nil
        for viewModel in botThreadViewModels {
            viewModel.pendingMacExecutionByThread[thread] = nil
        }
        // The thread is gone: nothing to move and no bot to tell.
        guard var stored else { return nil }
        if approve {
            stored.executionTarget = .mac
            for viewModel in botThreadViewModels {
                viewModel.mirrorExecutionTarget(.mac, thread: thread)
            }
        }
        publishAgentThreadUpdated(stored)
        let followUp: ManualActionResolveOutcome.FollowUp
        do {
            followUp = .sent(try await sendBotThreadFollowUp(
                thread: thread,
                text: approve ? Self.macExecutionApprovedFollowUp : Self.macExecutionDeclinedFollowUp
            ))
        } catch {
            followUp = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            // No follow-up turn will drain the queue held while the request was pending.
            context?.ensureQueueDrainWaiterIfNeeded(threadId: thread)
        }
        let latest = ((try? context?.threadRepo.get(id: thread)) ?? nil) ?? stored
        return MacExecutionResolveOutcome(thread: latest, approved: approve, followUp: followUp)
    }

    /// nil when Docker answers and the run's workspace is mounted; otherwise the user-facing failure.
    /// A workspace-less thread (`workspace` nil, a Bots Desk thread) only needs the container up:
    /// its agent runs in the guest user's home, and BotHome is never a mountable workspace.
    /// A bot already running elsewhere keeps its container: the send queues instead of remounting.
    func botVMPreflight(_ botID: BotID, workspace: String?, threadID: AgentThreadID? = nil) async -> String? {
        guard let ctx = context else { return "MacCode is not ready." }
        let docker = botVMDocker
        let service = botVMService(appSupport: ctx.appSupportDirectory)
        let registered = Set(ctx.state.workspaces.values.map(\.cwd))
        let prefetch = guestDistillPrefetch()
        let store = ctx.botStore
        let threads = ctx.threadRepo
        let workspaces = ctx.state.workspaces
        return await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                let destination = try threadID.flatMap { try store.threadExecutionDestination($0) } ?? store.executionDestination(botID: botID)
                let thread = try threadID.map { id -> AgentThread in
                    guard let thread = try threads.get(id: id) else {
                        throw BotStoreError.invalidInput("This conversation no longer exists.")
                    }
                    return thread
                }
                try store.validateExecutionDestination(destination, botID: botID, workspaceID: thread?.workspaceId,
                    contextPin: threadID.flatMap { try store.conversationContextPin(linkedTo: $0) })
                let machine = try destination.virtualMachineID.flatMap { try store.virtualMachine(id: $0) }
                if let owner = machine?.workspaceID {
                    // A worktree has its own path while retaining the workspace identity.
                    guard let ownerWorkspace = workspaces[owner],
                          thread != nil || workspace == nil || workspace == ownerWorkspace.cwd else {
                        return "This VM belongs to another workspace or its workspace is no longer available."
                    }
                }
                let resourceID = try store.guestResourceID(botID: botID, threadID: threadID)
                if BotComputerControl.shared.isControlledByUser(botID, resourceID: resourceID) {
                    return "You are controlling this VM. Return control before starting a conversation."
                }
                prefetch(try docker.info())
                if machine != nil { return nil }
                if let threadID, try store.conversationContextPin(linkedTo: threadID) != nil { return nil }
                if BotVMRunRegistry.shared.active(botID: resourceID) == nil {
                    if let workspace {
                        try service.ensureWorkspaceMounted(botID: resourceID, workspace: workspace, registered: registered)
                    } else {
                        _ = try BotVMProvisionRetry.run { try service.provision(botID: resourceID) }
                    }
                }
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }.value
    }

    private func botVMService(appSupport: URL) -> BotComputerGuestService {
        botVMProvisionServiceForTesting ?? BotComputerGuestService(
            appSupport: appSupport,
            docker: botVMDocker,
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL()
        )
    }

    /// Starts the guest distill download in the background when Docker is up
    /// and distill is installed on the Mac, so a bot's first in-guest run, or
    /// its first run after a host distill update, does not wait for it.
    func guestDistillPrefetch() -> @Sendable (_ dockerInfo: String) -> Void {
        guard let ctx = context else { return { _ in } }
        let provisioner = ctx.distillGuestBinaries
        let override = (try? ctx.settingsRepo.get("cli.distill.path")) ?? nil
        return { info in
            guard let arch = DistillGuestBinaryProvisioner.dockerArchitecture(fromInfo: info),
                  let host = DistillProvisioner.resolveInstalledBinary(override: override) else { return }
            provisioner.prefetch(hostBinary: host, dockerArch: arch)
        }
    }

    /// After a host update: starts the guest download for every architecture
    /// this Mac's bot VMs already run, whether or not Docker is up. A Mac that
    /// never ran a bot VM downloads nothing; its first VM is covered by
    /// `guestDistillPrefetch` when Docker comes up.
    func guestDistillFollowHostUpdate() -> @Sendable () async -> Void {
        guard let ctx = context else { return {} }
        let provisioner = ctx.distillGuestBinaries
        let override = (try? ctx.settingsRepo.get("cli.distill.path")) ?? nil
        return {
            guard let host = DistillProvisioner.resolveInstalledBinary(override: override) else { return }
            for arch in await provisioner.cachedArchitectures() {
                provisioner.prefetch(hostBinary: host, dockerArch: arch)
            }
        }
    }

    /// nil on success; otherwise the user-facing failure.
    func provisionBotVM(_ botID: BotID) async -> String? {
        guard let appSupport = context?.appSupportDirectory else { return "MacCode is not ready." }
        let service = botVMService(appSupport: appSupport)
        let docker = botVMDocker
        let prefetch = guestDistillPrefetch()
        let store = context?.botStore
        return await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                let resourceID = try store?.guestResourceID(botID: botID) ?? botID
                _ = try BotVMProvisionRetry.run { try service.provision(botID: resourceID) }
                Task.detached(priority: .utility) {
                    if let info = try? docker.info() { prefetch(info) }
                }
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }.value
    }
}

/// A restart leaves `bash -lc` execs running inside bot containers with no run owning them.
/// Only `BotGuestLaunchSweep` reaps them, before guest runs are admitted: a guest run's own
/// tool shells are `bash -lc` too.
enum BotVMOrphanScan {
    static func orphans(docker: any BotComputerDockerClienting, names: [String]) -> [String] {
        names.filter { name in
            (try? docker.top(name: name))?.contains("bash -lc") == true
        }
    }

    /// Logs each orphan and kills its stray shells as root. Returns the orphaned container names.
    @discardableResult
    static func reap(docker: any BotComputerDockerClienting, names: [String]) -> [String] {
        let found = orphans(docker: docker, names: names)
        for name in found {
            NSLog("bot vm orphan exec: \(name)")
            _ = try? docker.exec(name: name, command: ["pkill", "-f", "bash -lc"], user: "root", detach: false)
        }
        return found
    }
}
