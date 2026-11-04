import Foundation
import CoreModel
import Persistence
import SocketServer
import os

private let botRoutineLog = Logger(subsystem: "io.remotecode.app", category: "bot-routines")

/// Runs bot scheduled tasks while RemoteCode is open. The app timer ticks it
/// next to the Agent App scheduler. Each tick claims due slots off the main
/// thread through the paired Bot authority (the executor iOS
/// `bot.routine.run` uses too) and starts each slot as a real Bot run.
@MainActor
final class BotRoutineScheduler {
    /// How long a slot waits for a stopped Docker bot computer to come up.
    static let guestStartTimeout: TimeInterval = 180

    private let authority: () -> BotRemoteControlAuthority?
    private let botsViewModel: () -> BotsViewModel?
    private var tickTask: Task<Void, Never>?
    private var fireTasks: [UUID: Task<Void, Never>] = [:]

    init(
        authority: @escaping () -> BotRemoteControlAuthority?,
        botsViewModel: @escaping () -> BotsViewModel?
    ) {
        self.authority = authority
        self.botsViewModel = botsViewModel
    }

    func tick(now: Date = Date()) {
        // The Bots runtime comes up with the main window; before that a slot
        // could only fail with "Bot runtime is unavailable".
        guard tickTask == nil, botsViewModel() != nil, let authority = authority() else { return }
        tickTask = Task { [weak self] in
            let claims: [BotRemoteControlAuthority.RoutineFire]
            do {
                claims = try await Task.detached(priority: .utility) {
                    try authority.claimDueRoutines(now: now)
                }.value
            } catch {
                botRoutineLog.error("bot_routine.tick_failed error=\(String(describing: error), privacy: .public)")
                claims = []
            }
            guard let self else { return }
            for fire in claims { self.start(fire, authority: authority) }
            self.tickTask = nil
        }
    }

    /// Each slot runs on its own, so a slot waiting for its bot computer never
    /// holds back the next tick.
    private func start(_ fire: BotRemoteControlAuthority.RoutineFire, authority: BotRemoteControlAuthority) {
        let limit = fire.routine.definition.scheduleSpec?.effectiveMaxConcurrentRuns ?? 1
        if let active = botsViewModel()?.activeRoutineRunCount(id: fire.routine.definition.id), active >= limit {
            let run = authority.skipRoutineFire(
                fire,
                reason: ScheduledTaskStore.concurrencyLimitSummary(active: active, limit: limit)
            )
            EventBus.shared.publish(kind: .botSchedulerUpdated, payload: .object([
                "source": .string("bot_routine"),
                "routine_id": .string(fire.routine.definition.id.value.uuidString.lowercased()),
                "bot_id": .string(fire.routine.definition.botID.value.uuidString.lowercased()),
                "result": .string(run["result"] as? String ?? "skipped"),
                "run_id": .null,
            ]))
            return
        }
        let id = UUID()
        fireTasks[id] = Task { [weak self] in
            let notReady = await self?.botsViewModel()?.awaitGuestForScheduledSend(
                botID: fire.routine.definition.botID,
                destination: fire.routine.definition.scheduleSpec?.executionDestination,
                timeout: Self.guestStartTimeout
            )
            let run = notReady.map { authority.failRoutineFire(fire, reason: $0) }
                ?? authority.startRoutineFire(fire)
            EventBus.shared.publish(kind: .botSchedulerUpdated, payload: .object([
                "source": .string("bot_routine"),
                "routine_id": .string(fire.routine.definition.id.value.uuidString.lowercased()),
                "bot_id": .string(fire.routine.definition.botID.value.uuidString.lowercased()),
                "result": .string(run["result"] as? String ?? "failed"),
                "run_id": (run["run_id"] as? String).map(JSONValue.string) ?? .null,
            ]))
            self?.fireTasks[id] = nil
        }
    }

    /// Test seam: waits for the tick in flight and every slot it started.
    func settleForTesting() async {
        await tickTask?.value
        while let next = fireTasks.values.first { await next.value }
    }
}
